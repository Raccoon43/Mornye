import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/spotify_sync_service.dart';

Map<String, dynamic> _track(String id, {String type = 'track'}) => {
  'id': id,
  'type': type,
  'name': 'Song $id',
  'duration_ms': 215900,
  'explicit': true,
  'track_number': 3,
  'disc_number': 1,
  'external_ids': {'isrc': 'USX$id'},
  'artists': [
    {'name': 'A'},
    {'name': 'B'},
  ],
  'album': {
    'name': 'Album',
    'release_date': '2024-05-01',
    'images': [
      {'url': 'https://i.example/big.jpg'},
      {'url': 'https://i.example/small.jpg'},
    ],
    'artists': [
      {'name': 'A'},
    ],
  },
};

void main() {
  test('playlists stops on an endless or repeated next link', () async {
    var calls = 0;
    final endless = SpotifySyncService(
      client: MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'items': <Object>[],
            'next': 'https://api.spotify.com/v1/me/playlists?offset=$calls',
          }),
          200,
        );
      }),
    )..connect('t');
    await expectLater(
      endless.playlists(),
      throwsA(isA<SpotifySyncException>()),
    );
    expect(calls, 100);

    final repeated = SpotifySyncService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'items': <Object>[],
            'next': 'https://api.spotify.com/v1/me/playlists?offset=50',
          }),
          200,
        ),
      ),
    )..connect('t');
    await expectLater(
      repeated.playlists(),
      throwsA(isA<SpotifySyncException>()),
    );
  });

  test('parses both item shapes and skips local, episode and removed', () {
    final tracks = parseSpotifyPlaylistItems({
      'items': [
        {'item': _track('1')},
        {'track': _track('2')},
        {'item': null},
        {'is_local': true, 'item': _track('3')},
        {'item': _track('4', type: 'episode')},
        'junk',
      ],
    });
    expect(tracks.map((t) => t.id), ['1', '2']);
    final t = tracks.first;
    expect(t.name, 'Song 1');
    expect(t.artistName, 'A, B');
    expect(t.albumArtist, 'A');
    expect(t.coverUrl, 'https://i.example/big.jpg');
    expect(t.isrc, 'USX1');
    expect(t.duration, 215);
    expect(t.trackNumber, 3);
    expect(t.releaseDate, '2024-05-01');
    expect(t.explicit, isTrue);
  });

  test('playlist total from either key', () {
    final current = parseSpotifyPlaylist({
      'id': 'p1',
      'name': 'Mine',
      'items': {'total': 12},
    });
    expect((current.name, current.trackCount), ('Mine', 12));
    expect(
      parseSpotifyPlaylist({
        'id': 'p2',
        'tracks': {'total': 4},
      }).trackCount,
      4,
    );
    expect(parseSpotifyPlaylist({'id': 'p3'}).trackCount, 0);
  });

  test('unseenSpotifyTracks drops seen and repeated tracks', () {
    Track t(String id) => parseSpotifyPlaylistItems({
      'items': [
        {'item': _track(id)},
      ],
    }).single;
    final result = unseenSpotifyTracks([t('1'), t('2'), t('2'), t('3')], {'1'});
    expect(result.map((t) => t.id), ['2', '3']);
  });
}
