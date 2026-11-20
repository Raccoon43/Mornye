import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_transcription.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('transcribe_test');
    // The temp audio file lands under it too.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => root.path,
    );
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  // Writes the output path ffmpeg was given, as the real run would.
  Future<FFmpegResult> fakeFfmpeg(List<String> arguments) async {
    await File(arguments.last).writeAsBytes([1, 2, 3]);
    return FFmpegResult(success: true, returnCode: 0, output: '');
  }

  LyricsTranscriptionClient clientFor(
    LyricsAiProvider provider,
    http.Client http,
  ) => LyricsTranscriptionClient(
    LyricsAiConfig(provider: provider, model: 'm', apiKey: 'k', baseUrl: ''),
    client: http,
    ffmpeg: fakeFfmpeg,
    cacheRoot: () async => root,
  );

  test('Whisper segments become LRC lines', () {
    expect(
      transcriptionSegmentsToLrc([
        {'start': 1.234, 'text': ' Hello '},
        {'start': 75.5, 'text': 'World'},
        {'start': 80, 'text': '  '},
      ]),
      '[00:01.23]Hello\n[01:15.50]World',
    );
  });

  test('a model answer keeps only its LRC lines', () {
    expect(
      lrcLinesOf('```\n[00:01.00]One\nnote\n[01:02.5]Two\n```'),
      '[00:01.00]One\n[01:02.5]Two',
    );
  });

  test('OpenAI transcribes once and reads the cache after', () async {
    var calls = 0;
    final mock = MockClient((request) async {
      calls++;
      expect(request.url.path, endsWith('/audio/transcriptions'));
      expect(request.headers['Authorization'], 'Bearer k');
      return http.Response(
        jsonEncode({
          'segments': [
            {'start': 2.0, 'text': 'Sung'},
          ],
        }),
        200,
      );
    });
    final client = clientFor(LyricsAiProvider.openAi, mock);
    expect(await client.transcribe('/a.flac', '/a.flac'), '[00:02.00]Sung');
    expect(await client.transcribe('/a.flac', '/a.flac'), '[00:02.00]Sung');
    expect(calls, 1);
  });

  test('Gemini sends the audio inline and keeps its LRC lines', () async {
    final mock = MockClient((request) async {
      expect(request.headers['x-goog-api-key'], 'k');
      // Raw JSON compare: no casts through the nested request body.
      expect(request.body, contains('"data":"${base64Encode([1, 2, 3])}"'));
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Here:\n[00:03.00]Words'},
                ],
              },
            },
          ],
        }),
        200,
      );
    });
    final client = clientFor(LyricsAiProvider.gemini, mock);
    expect(await client.transcribe('/b.flac', '/b.flac'), '[00:03.00]Words');
  });

  test('an HTTP error is thrown and not cached', () async {
    var status = 500;
    final mock = MockClient(
      (_) async => http.Response(jsonEncode({'segments': <Object>[]}), status),
    );
    final client = clientFor(LyricsAiProvider.openAi, mock);
    await expectLater(
      client.transcribe('/c.flac', '/c.flac'),
      throwsA(isA<LyricsTranscriptionException>()),
    );
    status = 200;
    expect(await client.transcribe('/c.flac', '/c.flac'), '');
  });

  test('providers without audio input are refused', () async {
    final client = clientFor(
      LyricsAiProvider.anthropic,
      MockClient((_) async => http.Response('', 200)),
    );
    await expectLater(
      client.transcribe('/d.flac', '/d.flac'),
      throwsA(isA<LyricsTranscriptionException>()),
    );
  });
}
