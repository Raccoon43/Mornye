import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/spotify_sync_service.dart';

const _bundle =
    'https://open.spotifycdn.com/cdn/build/web-player/web-player.05da289c.js';
final _libHash = 'a' * 64;
final _plHash = 'b' * 64;
final _canvasHash = 'c' * 64;
const _canvasMp4 = 'https://canvaz.scdn.co/upload/v.mp4';

http.Response _canvasReply(String typename, String type) => http.Response(
  jsonEncode({
    'data': {
      'trackUnion': {
        '__typename': typename,
        'canvas': {'type': type, 'url': _canvasMp4},
      },
    },
  }),
  200,
);

Map<String, dynamic> _track(String id, {String type = 'Track'}) => {
  'itemV2': {
    'data': {
      '__typename': type,
      'uri': 'spotify:track:$id',
      'name': 'Song $id',
      'trackDuration': {'totalMilliseconds': 215900},
      'contentRating': {'label': 'EXPLICIT'},
      'artists': {
        'items': [
          {
            'profile': {'name': 'A'},
          },
          {
            'profile': {'name': 'B'},
          },
        ],
      },
      'albumOfTrack': {
        'name': 'Album',
        'artists': {
          'items': [
            {
              'profile': {'name': 'A'},
            },
          ],
        },
        'coverArt': {
          'sources': [
            {'url': 'https://i.example/a.jpg'},
          ],
        },
      },
    },
  },
};

/// Answers the page and bundle; [pathfinder] gets each decoded query body.
SpotifySyncService _service(
  http.Response Function(Map<String, dynamic> body) pathfinder,
) =>
    SpotifySyncService(
      client: MockClient((request) async {
        final url = request.url.toString();
        if (url == 'https://open.spotify.com/') {
          return http.Response('<script src="$_bundle"></script>', 200);
        }
        if (url == _bundle) {
          return http.Response(
            'x("libraryV3","query","$_libHash",!1),'
            'y("fetchPlaylistContents","query","$_plHash",!1),'
            'z("canvas","query","$_canvasHash",!1)',
            200,
          );
        }
        // The public Canvas CDN gets no Spotify headers.
        if (url == _canvasMp4) {
          expect(request.headers['authorization'], isNull);
          return http.Response.bytes([1, 2, 3], 200);
        }
        expect(
          request.headers['authorization'],
          'Bearer token-1234567890abcdef',
        );
        expect(request.headers['client-token'], 'ct');
        return pathfinder(jsonDecode(request.body) as Map<String, dynamic>);
      }),
    )..connect(
      const SpotifyWebSession(
        token: 'token-1234567890abcdef',
        clientToken: 'ct',
      ),
    );

Map<String, dynamic> _libraryItem(Map<String, dynamic> data) => {
  'item': {'data': data},
};

void main() {
  test('reads bundle URL and query hashes', () {
    expect(spotifyPlayerBundleUrl('a "$_bundle" b'), _bundle);
    expect(spotifyQueryHashes('"libraryV3","query","$_libHash"'), {
      'libraryV3': _libHash,
    });
  });

  test('playlists pages to totalCount and skips non-playlists', () async {
    final offsets = <int>[];
    final service = _service((body) {
      expect(body['operationName'], 'libraryV3');
      expect(jsonEncode(body['extensions']), contains(_libHash));
      final offset = (body['variables'] as Map)['offset'] as int;
      offsets.add(offset);
      return http.Response(
        jsonEncode({
          'data': {
            'me': {
              'libraryV3': {
                'totalCount': 60,
                'items': [
                  _libraryItem({
                    '__typename': 'Playlist',
                    'uri': 'spotify:playlist:p$offset',
                    'name': 'List $offset',
                    'images': {
                      'items': [
                        {
                          'sources': [
                            {'url': 'https://i.example/p.jpg'},
                          ],
                        },
                      ],
                    },
                  }),
                  _libraryItem({'__typename': 'Folder', 'uri': 'spotify:f:1'}),
                  _libraryItem({'__typename': 'PseudoPlaylist'}),
                ],
              },
            },
          },
        }),
        200,
      );
    });
    final lists = await service.playlists();
    expect(offsets, [0, 50]);
    expect(lists.map((p) => p.id), ['p0', 'p50']);
    expect(lists.first.name, 'List 0');
    expect(lists.first.imageUrl, 'https://i.example/p.jpg');
    expect(lists.first.trackCount, isNull);
  });

  test('stops after 100 pages when totalCount never ends', () async {
    var calls = 0;
    final service = _service((body) {
      expect(body['operationName'], 'fetchPlaylistContents');
      calls++;
      return http.Response(
        jsonEncode({
          'data': {
            'playlistV2': {
              'content': {
                'totalCount': 1 << 30,
                'items': [_track('$calls')],
              },
            },
          },
        }),
        200,
      );
    });
    await expectLater(
      service.playlistTracks('x'),
      throwsA(isA<SpotifySyncException>()),
    );
    expect(calls, 100);
  });

  test('a 429 fails on the first request without retrying', () async {
    var calls = 0;
    final service = _service((_) {
      calls++;
      return http.Response('{}', 429);
    });
    await expectLater(
      service.playlists(),
      throwsA(
        isA<SpotifySyncException>().having(
          (e) => e.message,
          'message',
          contains('429'),
        ),
      ),
    );
    expect(calls, 1);
  });

  group('canvasFile', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('canvas'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('saves a video Canvas and reuses the file', () async {
      var calls = 0;
      final service = _service((body) {
        calls++;
        expect(body['operationName'], 'canvas');
        expect(body['variables'], {'trackUri': 'spotify:track:t1'});
        return _canvasReply('Track', 'VIDEO_LOOPING_RANDOM');
      });
      final uri = await service.canvasFile('t1', dir);
      expect(uri, File('${dir.path}/t1.mp4').uri.toString());
      expect(File('${dir.path}/t1.mp4').readAsBytesSync(), [1, 2, 3]);
      expect(await service.canvasFile('t1', dir), uri);
      expect(calls, 1);
    });

    test('skips image canvases and non-tracks', () async {
      final image = _service((_) => _canvasReply('Track', 'IMAGE'));
      expect(await image.canvasFile('t1', dir), isNull);
      final gone = _service((_) => _canvasReply('NotFound', 'VIDEO'));
      expect(await gone.canvasFile('t2', dir), isNull);
      expect(dir.listSync(), isEmpty);
    });

    test('asks nothing while disconnected and never throws', () async {
      var calls = 0;
      final service = _service((_) {
        calls++;
        return http.Response('{}', 429);
      });
      expect(await service.canvasFile('t1', dir), isNull);
      // A 429 pauses Canvas lookups instead of retrying each song.
      expect(await service.canvasFile('t2', dir), isNull);
      expect(calls, 1);
      service.disconnect();
      expect(await service.canvasFile('t3', dir), isNull);
      expect(calls, 1);
    });
  });

  test('parses tracks and skips episodes and junk', () {
    final tracks = parseSpotifyPlaylistItems({
      'items': [
        _track('1'),
        _track('2', type: 'Episode'),
        {'itemV2': null},
        'junk',
      ],
    });
    expect(tracks.map((t) => t.id), ['1']);
    final t = tracks.single;
    expect(t.name, 'Song 1');
    expect(t.artistName, 'A, B');
    expect(t.albumName, 'Album');
    expect(t.albumArtist, 'A');
    expect(t.coverUrl, 'https://i.example/a.jpg');
    expect(t.duration, 215);
    expect(t.explicit, isTrue);
  });

  test('unseenSpotifyTracks drops seen and repeated tracks', () {
    Track t(String id) => parseSpotifyPlaylistItems({
      'items': [_track(id)],
    }).single;
    final result = unseenSpotifyTracks([t('1'), t('2'), t('2'), t('3')], {'1'});
    expect(result.map((t) => t.id), ['2', '3']);
  });
}
