import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/secure_storage_options.dart';

/// Users register this exact redirect URI on their own Spotify app.
const spotifySyncRedirect = 'mornye://spotify-sync';

class SpotifySyncException implements Exception {
  const SpotifySyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
    required this.canSync,
    this.imageUrl,
  });
  final String id;
  final String name;
  final int trackCount;
  final String? imageUrl;

  /// Spotify only returns items of playlists the user owns or collaborates on.
  final bool canSync;
}

/// RFC 7636 S256 challenge: base64url(sha256(verifier)) without padding.
String pkceChallenge(String verifier) => base64Url
    .encode(sha256.convert(ascii.encode(verifier)).bytes)
    .replaceAll('=', '');

String _randomUrlSafe(int bytes) {
  final random = Random.secure();
  return base64Url
      .encode([for (var i = 0; i < bytes; i++) random.nextInt(256)])
      .replaceAll('=', '');
}

String? _firstImage(Object? images) =>
    images is List && images.isNotEmpty && images.first is Map
    ? (images.first as Map)['url'] as String?
    : null;

SpotifyPlaylist parseSpotifyPlaylist(Map<String, dynamic> json, String meId) {
  // Spotify renamed `tracks` to `items` in February 2026; accept both.
  final items = (json['items'] ?? json['tracks']) as Map?;
  final owner = json['owner'] as Map?;
  return SpotifyPlaylist(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    trackCount: (items?['total'] as num?)?.toInt() ?? 0,
    imageUrl: _firstImage(json['images']),
    canSync: owner?['id'] == meId || json['collaborative'] == true,
  );
}

/// Maps one page of `/playlists/{id}/items`, skipping local files, podcast
/// episodes and removed tracks.
List<Track> parseSpotifyPlaylistItems(Map<String, dynamic> page) {
  final tracks = <Track>[];
  for (final entry in (page['items'] as List?) ?? const []) {
    if (entry is! Map) continue;
    final item = entry['item'] ?? entry['track'];
    if (item is! Map || entry['is_local'] == true || item['is_local'] == true) {
      continue;
    }
    final id = item['id'];
    if (id is! String || (item['type'] ?? 'track') != 'track') continue;
    final album = item['album'] as Map?;
    final artists = [
      for (final a in (item['artists'] as List?) ?? const [])
        if (a is Map && a['name'] is String) a['name'] as String,
    ];
    final albumArtists = [
      for (final a in (album?['artists'] as List?) ?? const [])
        if (a is Map && a['name'] is String) a['name'] as String,
    ];
    tracks.add(
      Track(
        id: id,
        name: (item['name'] as String?) ?? '',
        artistName: artists.join(', '),
        albumName: (album?['name'] as String?) ?? '',
        albumArtist: albumArtists.isEmpty ? null : albumArtists.join(', '),
        coverUrl: _firstImage(album?['images']),
        isrc: (item['external_ids'] as Map?)?['isrc'] as String?,
        duration: ((item['duration_ms'] as num?)?.toInt() ?? 0) ~/ 1000,
        trackNumber: (item['track_number'] as num?)?.toInt(),
        discNumber: (item['disc_number'] as num?)?.toInt(),
        releaseDate: album?['release_date'] as String?,
        explicit: item['explicit'] == true,
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

/// Signs in with the user's own Spotify app (OAuth PKCE, no secret) and mirrors
/// their playlists into library playlists. Re-syncing only adds tracks that
/// are new on Spotify; tracks removed in Mornye stay removed.
class SpotifySyncService {
  SpotifySyncService({
    http.Client? client,
    FlutterSecureStorage? storage,
    Stream<Uri>? links,
  }) : _client = client ?? http.Client(),
       _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: secureStorageAndroidOptions,
             mOptions: secureStorageMacOsOptions,
           ),
       _links = links;

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final Stream<Uri>? _links;
  static const _clientIdKey = 'spotify_sync_client_id';
  static const _refreshKey = 'spotify_sync_refresh_token';
  static const _mapKey = 'spotify_sync_playlists';
  static const _api = 'https://api.spotify.com/v1';
  String? _accessToken;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String?> clientId() => _storage.read(key: _clientIdKey);

  Future<bool> isLoggedIn() async =>
      (await _storage.read(key: _refreshKey)) != null;

  Future<void> logout() async {
    _accessToken = null;
    await _storage.delete(key: _refreshKey);
  }

  /// Opens Spotify's login page and waits for it to redirect back.
  // shortcut: the PKCE verifier lives in memory, so a login fails if the OS
  // kills the app while the browser is open; persist it if users hit that.
  Future<void> login(String clientId) async {
    clientId = clientId.trim();
    if (clientId.isEmpty) {
      throw const SpotifySyncException('Enter your Spotify Client ID first.');
    }
    await _storage.write(key: _clientIdKey, value: clientId);
    final verifier = _randomUrlSafe(64);
    final state = _randomUrlSafe(16);
    final callback = (_links ?? AppLinks().uriLinkStream)
        .firstWhere(
          (u) =>
              u.scheme == 'mornye' &&
              u.host == 'spotify-sync' &&
              u.queryParameters['state'] == state,
        )
        .timeout(const Duration(minutes: 5));
    final authorize = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': spotifySyncRedirect,
      'code_challenge_method': 'S256',
      'code_challenge': pkceChallenge(verifier),
      'scope': 'playlist-read-private playlist-read-collaborative',
      'state': state,
    });
    if (!await _launch(authorize)) {
      unawaited(callback.catchError((_) => Uri()));
      throw const SpotifySyncException('Could not open the browser.');
    }
    final Uri uri;
    try {
      uri = await callback;
    } on TimeoutException {
      throw const SpotifySyncException('Spotify login timed out.');
    }
    final code = uri.queryParameters['code'];
    if (code == null) {
      throw SpotifySyncException(
        'Spotify login failed: ${uri.queryParameters['error'] ?? 'no code'}',
      );
    }
    await _token(clientId, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': spotifySyncRedirect,
      'code_verifier': verifier,
    });
  }

  Future<bool> _launch(Uri uri) async {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return true;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
    return false;
  }

  Future<void> _token(String clientId, Map<String, String> body) async {
    final response = await _client
        .post(
          Uri.https('accounts.spotify.com', '/api/token'),
          body: {...body, 'client_id': clientId},
        )
        .timeout(const Duration(seconds: 20));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      if (json['error'] == 'invalid_grant' &&
          body['grant_type'] == 'refresh_token') {
        await logout();
        throw const SpotifySyncException(
          'Spotify session expired. Log in again.',
        );
      }
      throw SpotifySyncException(
        'Spotify login failed: ${json['error_description'] ?? json['error']}',
      );
    }
    _accessToken = json['access_token'] as String;
    _expiresAt = DateTime.now().add(
      Duration(seconds: (json['expires_in'] as num).toInt() - 60),
    );
    // Spotify may rotate the refresh token; keep whichever came last.
    if (json['refresh_token'] case final String refresh) {
      await _storage.write(key: _refreshKey, value: refresh);
    }
  }

  Future<String> _bearer({bool force = false}) async {
    if (!force && _accessToken != null && DateTime.now().isBefore(_expiresAt)) {
      return _accessToken!;
    }
    final refresh = await _storage.read(key: _refreshKey);
    final id = await clientId();
    if (refresh == null || id == null) {
      throw const SpotifySyncException('Log in to Spotify first.');
    }
    await _token(id, {'grant_type': 'refresh_token', 'refresh_token': refresh});
    return _accessToken!;
  }

  Future<Map<String, dynamic>> _get(String url) async {
    var refreshed = false;
    for (var attempt = 0; attempt < 4; attempt++) {
      final response = await _client
          .get(
            Uri.parse(url),
            headers: {'Authorization': 'Bearer ${await _bearer()}'},
          )
          .timeout(const Duration(seconds: 20));
      switch (response.statusCode) {
        case 200:
          return jsonDecode(response.body) as Map<String, dynamic>;
        case 401 when !refreshed:
          refreshed = true;
          await _bearer(force: true);
        case 429:
          final wait = int.tryParse(response.headers['retry-after'] ?? '') ?? 2;
          await Future<void>.delayed(Duration(seconds: wait.clamp(1, 30)));
        case 403:
          throw const SpotifySyncException(
            'Spotify refused access. Add this account under User Management '
            'in your Spotify app dashboard.',
          );
        default:
          throw SpotifySyncException(
            'Spotify returned ${response.statusCode}.',
          );
      }
    }
    throw const SpotifySyncException('Spotify is busy. Try again later.');
  }

  Future<List<Map<String, dynamic>>> _pages(String url) async {
    final pages = <Map<String, dynamic>>[];
    String? next = url;
    while (next != null) {
      final page = await _get(next);
      pages.add(page);
      next = page['next'] as String?;
    }
    return pages;
  }

  Future<List<SpotifyPlaylist>> playlists() async {
    final me = (await _get('$_api/me'))['id'] as String;
    return [
      for (final page in await _pages('$_api/me/playlists'))
        for (final p in (page['items'] as List?) ?? const [])
          if (p is Map<String, dynamic> && p['id'] is String)
            parseSpotifyPlaylist(p, me),
    ];
  }

  Future<List<Track>> playlistTracks(String playlistId) async => [
    for (final page in await _pages('$_api/playlists/$playlistId/items'))
      ...parseSpotifyPlaylistItems(page),
  ];

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
