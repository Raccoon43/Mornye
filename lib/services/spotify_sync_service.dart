import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/track.dart';

class SpotifySyncException implements Exception {
  const SpotifySyncException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    this.trackCount,
    this.imageUrl,
  });
  final String id;
  final String name;

  /// The library list does not carry track counts.
  final int? trackCount;
  final String? imageUrl;
}

/// What the web player page hands over: its access token, its client token
/// and the WebView's user agent, so requests look like the player's own.
class SpotifyWebSession {
  const SpotifyWebSession({
    required this.token,
    this.clientToken,
    this.userAgent,
  });
  final String token;
  final String? clientToken;
  final String? userAgent;
}

Object? _at(Object? json, List<Object> path) {
  var node = json;
  for (final key in path) {
    if (key is String && node is Map) {
      node = node[key];
    } else if (key is int && node is List && key < node.length) {
      node = node[key];
    } else {
      return null;
    }
  }
  return node;
}

String? _idFromUri(Object? uri) =>
    uri is String && uri.contains(':') ? uri.split(':').last : null;

String _artistNames(Object? artists) => [
  for (final a in (_at(artists, ['items']) as List?) ?? const [])
    if (_at(a, ['profile', 'name']) case final String name) name,
].join(', ');

/// Finds the player's main script in the open.spotify.com page.
String? spotifyPlayerBundleUrl(String html) => RegExp(
  r'https://open\.spotifycdn\.com/cdn/build/web-player/web-player\.[0-9a-f]+\.js',
).firstMatch(html)?.group(0);

/// Persisted query hashes by operation name, read from the player's script.
/// They change with each Spotify deploy, so they are read at runtime.
Map<String, String> spotifyQueryHashes(String script) => {
  for (final m in RegExp(
    r'"(\w+)","query","([0-9a-f]{64})"',
  ).allMatches(script))
    m.group(1)!: m.group(2)!,
};

/// Playlists from one `libraryV3` page. Folders, Liked Songs and anything
/// that is not a playlist are skipped.
List<SpotifyPlaylist> parseSpotifyLibrary(Map<String, dynamic> page) => [
  for (final entry in (page['items'] as List?) ?? const [])
    if (_at(entry, ['item', 'data']) case final Map<String, dynamic> data
        when data['__typename'] == 'Playlist')
      if (_idFromUri(data['uri']) case final String id)
        SpotifyPlaylist(
          id: id,
          name: (data['name'] as String?) ?? '',
          imageUrl:
              _at(data, ['images', 'items', 0, 'sources', 0, 'url']) as String?,
        ),
];

/// Tracks from one `fetchPlaylistContents` page (`playlistV2.content`),
/// skipping local files, podcast episodes and removed tracks.
List<Track> parseSpotifyPlaylistItems(Map<String, dynamic> content) {
  final tracks = <Track>[];
  for (final entry in (content['items'] as List?) ?? const []) {
    final data = _at(entry, ['itemV2', 'data']);
    if (data is! Map || data['__typename'] != 'Track') continue;
    final id = _idFromUri(data['uri']);
    if (id == null) continue;
    final album = data['albumOfTrack'] as Map?;
    final albumArtist = _artistNames(album?['artists']);
    final ms = _at(data, ['trackDuration', 'totalMilliseconds']) as num?;
    tracks.add(
      Track(
        id: id,
        name: (data['name'] as String?) ?? '',
        artistName: _artistNames(data['artists']),
        albumName: (album?['name'] as String?) ?? '',
        albumArtist: albumArtist.isEmpty ? null : albumArtist,
        coverUrl: _at(album, ['coverArt', 'sources', 0, 'url']) as String?,
        duration: (ms?.toInt() ?? 0) ~/ 1000,
        trackNumber: (data['trackNumber'] as num?)?.toInt(),
        discNumber: (data['discNumber'] as num?)?.toInt(),
        explicit: _at(data, ['contentRating', 'label']) == 'EXPLICIT',
      ),
    );
  }
  return tracks;
}

/// Tracks Spotify added since the last sync, once each.
List<Track> unseenSpotifyTracks(List<Track> tracks, Set<String> seen) {
  final ids = {...seen};
  return [
    for (final t in tracks)
      if (ids.add(t.id)) t,
  ];
}

/// Reads the user's playlists through their own Spotify web player session
/// (see `SpotifyWebLoginPage`) and mirrors them into library playlists.
/// Re-syncing only adds tracks that are new on Spotify; tracks removed in
/// Mornye stay removed.
///
/// Test build only: this calls the web player's private API, which Spotify's
/// terms do not allow for third-party apps. The public Web API answers web
/// player tokens with 429 QUOTA_EXCEEDED. Tokens stay in memory and are never
/// stored or logged.
class SpotifySyncService {
  SpotifySyncService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _mapKey = 'spotify_sync_playlists';
  static const _web = 'https://open.spotify.com';
  static const _pathfinder =
      'https://api-partner.spotify.com/pathfinder/v2/query';
  static const _pageSize = 50;
  static const _maxPages = 100;
  static const _maxCanvasBytes = 16 << 20;
  SpotifyWebSession? _session;
  Map<String, String>? _hashes;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  final _canvases = <String, Future<String?>>{};
  DateTime _canvasPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isConnected =>
      _session != null && DateTime.now().isBefore(_expiresAt);

  /// Web player tokens last an hour; reconnecting after that reuses the
  /// WebView's login cookies.
  void connect(SpotifyWebSession session) {
    _session = session;
    _hashes = null;
    _expiresAt = DateTime.now().add(const Duration(minutes: 50));
  }

  void disconnect() => _session = null;

  Map<String, String> get _browserHeaders => {
    'origin': _web,
    'referer': '$_web/',
    if (_session?.userAgent case final String ua) 'user-agent': ua,
  };

  Future<String> _hash(String operation) async {
    var hashes = _hashes;
    if (hashes == null) {
      // A phone UA gets the mobile player, whose main script lacks the
      // library queries; the desktop player's script has them.
      const headers = {
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36',
      };
      final page = await _client
          .get(Uri.parse('$_web/'), headers: headers)
          .timeout(const Duration(seconds: 20));
      final bundle = spotifyPlayerBundleUrl(page.body);
      if (bundle == null) {
        throw const SpotifySyncException(
          'Could not find the Spotify web player script.',
        );
      }
      final script = await _client
          .get(Uri.parse(bundle), headers: headers)
          .timeout(const Duration(seconds: 30));
      hashes = _hashes = spotifyQueryHashes(script.body);
    }
    final hash = hashes[operation];
    if (hash == null) {
      throw SpotifySyncException(
        'Spotify changed its web player ($operation is gone).',
      );
    }
    return hash;
  }

  Future<Map<String, dynamic>> _query(
    String operation,
    Map<String, Object?> variables,
  ) async {
    final session = _session;
    if (session == null || !isConnected) {
      throw const SpotifySyncException('Connect to Spotify first.');
    }
    final hash = await _hash(operation);
    final response = await _client
        .post(
          Uri.parse(_pathfinder),
          headers: {
            ..._browserHeaders,
            'authorization': 'Bearer ${session.token}',
            if (session.clientToken case final String ct) 'client-token': ct,
            'app-platform': 'WebPlayer',
            'accept': 'application/json',
            'content-type': 'application/json;charset=UTF-8',
          },
          body: jsonEncode({
            'variables': variables,
            'operationName': operation,
            'extensions': {
              'persistedQuery': {'version': 1, 'sha256Hash': hash},
            },
          }),
        )
        .timeout(const Duration(seconds: 20));
    // Test build: operation, status and size only, never headers.
    debugPrint(
      'SpotifySync $operation ${response.statusCode} '
      '(${response.body.length} bytes)',
    );
    switch (response.statusCode) {
      case 200:
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final data = json['data'];
        if (data is Map<String, dynamic>) return data;
        throw SpotifySyncException(
          'Spotify refused $operation: '
          '${_at(json, ['errors', 0, 'message']) ?? 'no data'}.',
        );
      case 401:
        disconnect();
        throw const SpotifySyncException(
          'Spotify session expired. Connect again.',
        );
      case 429:
        throw const SpotifySyncException(
          'Spotify is rate limiting this sign-in (429). Try again later.',
          statusCode: 429,
        );
      default:
        throw SpotifySyncException(
          'Spotify returned ${response.statusCode} for $operation.',
        );
    }
  }

  /// Pages an offset/limit query until its `totalCount` is reached.
  Future<List<Map<String, dynamic>>> _pages(
    String operation,
    Map<String, Object?> variables,
    Object? Function(Map<String, dynamic> data) list,
  ) async {
    final pages = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += _pageSize) {
      // A wrong or growing totalCount would page forever on the account.
      if (pages.length >= _maxPages) {
        throw SpotifySyncException('Spotify kept sending more $operation.');
      }
      final page = list(
        await _query(operation, {
          ...variables,
          'offset': offset,
          'limit': _pageSize,
        }),
      );
      if (page is! Map<String, dynamic>) {
        throw SpotifySyncException('Spotify sent no $operation result.');
      }
      pages.add(page);
      final total = (page['totalCount'] as num?)?.toInt() ?? 0;
      if ((page['items'] as List?)?.isEmpty ?? true) break;
      if (offset + _pageSize >= total) break;
    }
    return pages;
  }

  Future<List<SpotifyPlaylist>> playlists() async => [
    for (final page in await _pages('libraryV3', {
      'filters': ['Playlists'],
      'order': null,
      'textFilter': null,
      'features': ['LIKED_SONGS', 'YOUR_EPISODES_V2', 'EVENTS'],
      // Flattened, so playlists inside folders are listed too.
      'flatten': true,
      'folderUri': null,
      'includeFoldersWhenFlattening': true,
    }, (data) => _at(data, ['me', 'libraryV3'])))
      ...parseSpotifyLibrary(page),
  ];

  Future<List<Track>> playlistTracks(String playlistId) async => [
    for (final page in await _pages('fetchPlaylistContents', {
      'uri': 'spotify:playlist:$playlistId',
      'includeEpisodeContentRatingsV2': false,
    }, (data) => _at(data, ['playlistV2', 'content'])))
      ...parseSpotifyPlaylistItems(page),
  ];

  /// [trackId]'s looping Canvas video saved in [cache] as a `file://` URI,
  /// or null when the track has none or Spotify is not connected. Never
  /// throws: the player asks on every song change.
  Future<String?> canvasFile(String trackId, Directory cache) async {
    final file = File('${cache.path}/$trackId.mp4');
    if (await file.exists()) return file.uri.toString();
    if (!isConnected || DateTime.now().isBefore(_canvasPausedUntil)) {
      return null;
    }
    try {
      return await (_canvases[trackId] ??= _downloadCanvas(trackId, file));
    } catch (error) {
      _canvases.remove(trackId);
      if (error is SpotifySyncException && error.statusCode == 429) {
        _canvasPausedUntil = DateTime.now().add(const Duration(minutes: 10));
      }
      debugPrint('SpotifySync canvas skipped (${error.runtimeType})');
      return null;
    }
  }

  Future<String?> _downloadCanvas(String trackId, File file) async {
    final data = await _query('canvas', {'trackUri': 'spotify:track:$trackId'});
    if (_at(data, ['trackUnion', '__typename']) != 'Track') return null;
    final canvas = _at(data, ['trackUnion', 'canvas']);
    // Image and GIF canvases are not videos the player can loop.
    final type = _at(canvas, ['type']);
    if (type is! String || !type.startsWith('VIDEO')) return null;
    final url = _at(canvas, ['url']);
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || uri.scheme != 'https') return null;
    // The CDN file is public: no Spotify headers go with it.
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 20));
    // shortcut: buffers the whole file before the size check; fine for Canvas
    // clips of a few MB, stream it if they ever grow.
    final bytes = response.bodyBytes;
    if (response.statusCode != 200 ||
        bytes.isEmpty ||
        bytes.length > _maxCanvasBytes) {
      return null;
    }
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
    return file.uri.toString();
  }

  /// Mirrors [playlist] into a library playlist and returns how many tracks
  /// were added. A deleted mirror is recreated with every track.
  Future<int> sync(
    SpotifyPlaylist playlist, {
    required Future<bool> Function(String id) exists,
    required Future<String> Function(String name) create,
    required Future<int> Function(String id, List<Track> tracks) add,
  }) async {
    final tracks = await playlistTracks(playlist.id);
    final prefs = await SharedPreferences.getInstance();
    final map =
        jsonDecode(prefs.getString(_mapKey) ?? '{}') as Map<String, dynamic>;
    final entry = map[playlist.id] as Map<String, dynamic>?;
    var localId = entry?['pl'] as String?;
    var seen = {...?(entry?['seen'] as List?)?.cast<String>()};
    if (localId == null || !await exists(localId)) {
      localId = await create(playlist.name);
      seen = {};
    }
    final added = await add(localId, unseenSpotifyTracks(tracks, seen));
    map[playlist.id] = {
      'pl': localId,
      'seen': {...seen, for (final t in tracks) t.id}.toList(),
    };
    await prefs.setString(_mapKey, jsonEncode(map));
    return added;
  }
}

final spotifySyncService = SpotifySyncService();
