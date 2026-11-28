import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/track.dart';

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
    this.imageUrl,
  });
  final String id;
  final String name;
  final int trackCount;
  final String? imageUrl;
}

String? _firstImage(Object? images) =>
    images is List && images.isNotEmpty && images.first is Map
    ? (images.first as Map)['url'] as String?
    : null;

SpotifyPlaylist parseSpotifyPlaylist(Map<String, dynamic> json) {
  // Spotify renamed `tracks` to `items` in February 2026; accept both.
  final items = (json['items'] ?? json['tracks']) as Map?;
  return SpotifyPlaylist(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    trackCount: (items?['total'] as num?)?.toInt() ?? 0,
    imageUrl: _firstImage(json['images']),
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

/// Reads the user's playlists with the access token of their own Spotify web
/// player session (see `SpotifyWebLoginPage`) and mirrors them into library
/// playlists. Re-syncing only adds tracks that are new on Spotify; tracks
/// removed in Mornye stay removed.
///
/// Test build only: this uses Spotify's web player session, which Spotify's
/// terms do not allow for third-party apps. The token stays in memory and is
/// never stored or logged.
class SpotifySyncService {
  SpotifySyncService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _mapKey = 'spotify_sync_playlists';
  static const _api = 'https://api.spotify.com/v1';
  static const _maxPages = 100;
  String? _token;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isConnected => _token != null && DateTime.now().isBefore(_expiresAt);

  /// Keeps a token captured from the web player. Web player tokens last an
  /// hour; reconnecting after that reuses the WebView's login cookies.
  void connect(String token) {
    _token = token;
    _expiresAt = DateTime.now().add(const Duration(minutes: 50));
  }

  void disconnect() => _token = null;

  Future<Map<String, dynamic>> _get(String url) async {
    final token = _token;
    if (token == null || !isConnected) {
      throw const SpotifySyncException('Connect to Spotify first.');
    }
    for (var attempt = 0; attempt < 4; attempt++) {
      final response = await _client
          .get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 20));
      // Test build: status and path only, never the token or headers.
      debugPrint(
        'SpotifySync ${response.statusCode} ${Uri.parse(url).path}'
        '?${Uri.parse(url).query} (${response.body.length} bytes)',
      );
      switch (response.statusCode) {
        case 200:
          return jsonDecode(response.body) as Map<String, dynamic>;
        case 401:
          disconnect();
          throw const SpotifySyncException(
            'Spotify session expired. Connect again.',
          );
        case 429:
          final wait = int.tryParse(response.headers['retry-after'] ?? '') ?? 2;
          await Future<void>.delayed(Duration(seconds: wait.clamp(1, 30)));
        default:
          // Test build: name the endpoint and status so a failing run shows
          // whether Spotify accepts the web player token here.
          throw SpotifySyncException(
            'Spotify returned ${response.statusCode} for '
            '${Uri.parse(url).path}.',
          );
      }
    }
    throw const SpotifySyncException('Spotify is busy. Try again later.');
  }

  Future<List<Map<String, dynamic>>> _pages(String url) async {
    final pages = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? next = url;
    while (next != null) {
      // A repeated or endless `next` link would loop forever on the account.
      if (!seen.add(next) || pages.length >= _maxPages) {
        throw SpotifySyncException(
          'Spotify kept sending more pages for ${Uri.parse(url).path}.',
        );
      }
      final page = await _get(next);
      pages.add(page);
      next = page['next'] as String?;
    }
    return pages;
  }

  Future<List<SpotifyPlaylist>> playlists() async => [
    for (final page in await _pages('$_api/me/playlists?limit=50'))
      for (final p in (page['items'] as List?) ?? const [])
        if (p is Map<String, dynamic> && p['id'] is String)
          parseSpotifyPlaylist(p),
  ];

  Future<List<Track>> playlistTracks(String playlistId) async {
    List<Map<String, dynamic>> pages;
    try {
      pages = await _pages('$_api/playlists/$playlistId/items');
    } on SpotifySyncException catch (e) {
      // The pre-2026 name, in case this token still gets the old API.
      if (!e.message.contains(' 404 ')) rethrow;
      pages = await _pages('$_api/playlists/$playlistId/tracks');
    }
    return [for (final page in pages) ...parseSpotifyPlaylistItems(page)];
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
