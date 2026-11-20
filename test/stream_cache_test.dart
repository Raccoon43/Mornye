import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:path/path.dart' as p;

void main() {
  test('play-now flag survives a queue save', () {
    final item = DownloadItem(
      id: 'stream-1',
      track: const Track(
        id: 't',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      ),
      service: 'provider-a',
      createdAt: DateTime.utc(2026, 11, 15),
      streamOnly: true,
    );
    final json =
        jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>;
    expect(DownloadItem.fromJson(json).streamOnly, isTrue);
    expect(
      DownloadItem.fromJson(json..remove('streamOnly')).streamOnly,
      isFalse,
    );
  });

  test('clearing the stream cache keeps only the playing file', () async {
    final dir = await Directory.systemTemp.createTemp('stream_cache');
    addTearDown(() => dir.delete(recursive: true));
    final old = File(p.join(dir.path, 'old.flac'))..writeAsStringSync('a');
    final playing = File(p.join(dir.path, 'new.flac'))..writeAsStringSync('b');

    await clearStreamCache(dir, keep: playing.path);

    expect(old.existsSync(), isFalse);
    expect(playing.existsSync(), isTrue);
  });
}
