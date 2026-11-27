import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_transcription.dart';
import 'package:mornye/services/lyrics_translation_languages.dart';
import 'package:mornye/utils/lyrics_parser.dart';

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

  test('segments Whisper made up are left out', () {
    expect(
      transcriptionSegmentsToLrc([
        {'start': 1, 'text': 'Real line', 'no_speech_prob': 0.1},
        {'start': 5, 'text': 'Thank you for watching!'},
        {
          'start': 9,
          'text': 'Silence',
          'no_speech_prob': 0.9,
          'avg_logprob': -1.5,
        },
        {'start': 12, 'text': 'la la la la', 'compression_ratio': 3.1},
        {'start': 13, 'text': '由 Am ara.org 社群提供的字幕'},
        {'start': 14, 'text': '请不吝点赞 订阅 转发'},
        {
          'start': 15,
          'text': 'Loud chorus',
          'no_speech_prob': 0.9,
          'avg_logprob': -0.2,
        },
      ]),
      '[00:01.00]Real line\n[00:15.00]Loud chorus',
    );
  });

  test('lines in a script foreign to the song are left out', () {
    expect(
      transcriptionSegmentsToLrc([
        {'start': 1, 'text': 'බවට්ට කියන්නේ අපි'},
        {'start': 5, 'text': '敢问路在何方'},
        {'start': 9, 'text': 'Oh yeah'},
        {'start': 12, 'text': '路在脚下'},
      ]),
      '[00:05.00]敢问路在何方\n[00:09.00]Oh yeah\n[00:12.00]路在脚下',
    );
    expect(
      transcriptionSegmentsToLrc([
        {'start': 1, 'text': 'Hold me tight'},
        {'start': 4, 'text': 'Never let go'},
        {'start': 7, 'text': '사랑해'},
      ]),
      '[00:01.00]Hold me tight\n[00:04.00]Never let go\n[00:07.00]사랑해',
    );
  });

  test('sound labels over a song in another script are left out', () {
    expect(
      transcriptionSegmentsToLrc([
        {'start': 1, 'text': 'Zither Harp'},
        {'start': 3, 'text': '[Music]'},
        {'start': 4, 'text': '♪ Music ♪'},
        {'start': 5, 'text': '敢问路在何方'},
        {'start': 7, 'text': 'Piano 之歌'},
        {'start': 9, 'text': 'Oh yeah'},
      ]),
      '[00:05.00]敢问路在何方\n[00:07.00]Piano 之歌\n[00:09.00]Oh yeah',
    );
    // An English song keeps them: they may be its words.
    expect(
      transcriptionSegmentsToLrc([
        {'start': 1, 'text': 'Piano'},
        {'start': 4, 'text': 'Play it again'},
      ]),
      '[00:01.00]Piano\n[00:04.00]Play it again',
    );
  });

  test('picker languages map to the codes Whisper takes', () {
    expect(whisperLanguageCode('zh-Hans'), 'zh');
    expect(whisperLanguageCode('pt-BR'), 'pt');
    expect(whisperLanguageCode('fil'), 'tl');
    expect(whisperLanguageCode('nb'), 'no');
    expect(whisperLanguageCode('ja'), 'ja');
    // Every picker language must be one Whisper knows.
    // Whisper's own language list.
    const whisper = {
      'en',
      'zh',
      'de',
      'es',
      'ru',
      'ko',
      'fr',
      'ja',
      'pt',
      'tr',
      'pl',
      'ca',
      'nl',
      'ar',
      'sv',
      'it',
      'id',
      'hi',
      'fi',
      'vi',
      'he',
      'uk',
      'el',
      'ms',
      'cs',
      'ro',
      'da',
      'hu',
      'ta',
      'no',
      'th',
      'ur',
      'hr',
      'bg',
      'lt',
      'la',
      'mi',
      'ml',
      'cy',
      'sk',
      'te',
      'fa',
      'lv',
      'bn',
      'sr',
      'az',
      'sl',
      'kn',
      'et',
      'mk',
      'br',
      'eu',
      'is',
      'hy',
      'ne',
      'mn',
      'bs',
      'kk',
      'sq',
      'sw',
      'gl',
      'mr',
      'pa',
      'si',
      'km',
      'sn',
      'yo',
      'so',
      'af',
      'oc',
      'ka',
      'be',
      'tg',
      'sd',
      'gu',
      'am',
      'yi',
      'lo',
      'uz',
      'fo',
      'ht',
      'ps',
      'tk',
      'nn',
      'mt',
      'sa',
      'lb',
      'my',
      'bo',
      'tl',
      'mg',
      'as',
      'tt',
      'haw',
      'ln',
      'ha',
      'ba',
      'jw',
      'su',
      'yue',
    };
    for (final language in lyricsTranslationLanguages) {
      expect(whisper, contains(whisperLanguageCode(language.code)));
    }
  });

  test('a song tagged in an East Asian script names its language', () {
    expect(whisperLanguageHint('Where Lies the Path Ahead (黑神话:悟空)'), 'zh');
    expect(whisperLanguageHint('夜に駆ける YOASOBI'), 'ja');
    expect(whisperLanguageHint('봄날 BTS'), 'ko');
    expect(whisperLanguageHint('Hello Adele'), isNull);
  });

  test('a language hint goes to Whisper', () async {
    final mock = MockClient((request) async {
      expect(request.body, contains('name="language"\r\n\r\nzh'));
      return http.Response(jsonEncode({'segments': <Object>[]}), 200);
    });
    final client = clientFor(LyricsAiProvider.groq, mock);
    expect(await client.transcribe('/l.flac', '/l.flac', language: 'zh'), '');
  });

  test('Whisper words become karaoke times the parser reads', () {
    final lrc = transcriptionSegmentsToLrc(
      [
        {'start': 1.0, 'text': 'Hello there'},
        {'start': 3.0, 'text': 'Bye'},
        {'start': 5.0, 'text': 'No words'},
      ],
      words: [
        {'word': 'Hello', 'start': 1.0, 'end': 1.4},
        {'word': ' there', 'start': 1.5, 'end': 2.0},
        {'word': 'Bye', 'start': 3.1, 'end': 3.6},
      ],
    );
    expect(
      lrc,
      '[00:01.00]<00:01.00>Hello <00:01.50>there<00:02.00>\n'
      '[00:03.00]<00:03.10>Bye<00:03.60>\n'
      '[00:05.00]No words',
    );
    final parsed = LyricsParser.parse(lrc);
    expect(parsed.wordSynced, isTrue);
    expect(parsed.lines.first.text, 'Hello there');
    expect(parsed.lines.first.words, hasLength(2));
  });

  test('plain lines take the times their words are heard at', () {
    final transcript = LyricsParser.parse(
      '[00:01.00]<00:01.00>Hello, <00:01.50>there<00:02.00>\n'
      '[00:06.00]<00:06.00>bye <00:06.40>now<00:07.00>',
    );
    expect(
      syncLyricsToTranscript(
        'Hello there\nNot heard at all\n\nBye now',
        transcript,
      ),
      '[00:01.00]<00:01.00>Hello <00:01.50>there<00:02.00>\n'
      '[00:03.50]Not heard at all\n'
      '[00:06.00]<00:06.00>Bye <00:06.40>now<00:07.00>',
    );
    expect(syncLyricsToTranscript('Other words\nEntirely', transcript), isNull);
  });

  test('a chorus written once repeats where it is sung again', () {
    // Each sung line: its words half a second apart from [start].
    String sung(int start, String text) {
      final words = text.split(' ');
      String at(int i) =>
          '00:${(start + i * 0.5).toStringAsFixed(2).padLeft(5, '0')}';
      return '[${at(0)}]'
          '${[for (var i = 0; i < words.length; i++) '<${at(i)}>${words[i]}'].join(' ')}'
          '<${at(words.length)}>';
    }

    final transcript = LyricsParser.parse(
      [
        sung(1, 'walking down the street'),
        sung(4, 'sing it loud tonight'),
        sung(7, 'every voice together now'),
        sung(10, 'back home again'),
        sung(13, 'sing it loud tonight'),
        sung(16, 'every voice together now'),
      ].join('\n'),
    );
    final lrc = syncLyricsToTranscript(
      'Walking down the street\nSing it loud tonight\n'
      'Every voice together now\nBack home again',
      transcript,
    );
    final parsed = LyricsParser.parse(lrc!);
    expect(parsed.wordSynced, isTrue);
    expect(
      [for (final line in parsed.lines) (line.time.inSeconds, line.text)],
      [
        (1, 'Walking down the street'),
        (4, 'Sing it loud tonight'),
        (7, 'Every voice together now'),
        (10, 'Back home again'),
        (13, 'Sing it loud tonight'),
        (16, 'Every voice together now'),
      ],
    );
    expect(parsed.lines[4].words[1].time, const Duration(milliseconds: 13500));
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

  test('a retry asks again only when the kept transcript is empty', () async {
    var calls = 0;
    final mock = MockClient((_) async {
      calls++;
      return http.Response(
        jsonEncode({
          'segments': [
            if (calls > 1) {'start': 2.0, 'text': 'Sung'},
          ],
        }),
        200,
      );
    });
    final client = clientFor(LyricsAiProvider.openAi, mock);
    expect(await client.transcribe('/e.flac', '/e.flac'), '');
    expect(await client.transcribe('/e.flac', '/e.flac'), '');
    expect(calls, 1);
    expect(
      await client.transcribe('/e.flac', '/e.flac', retryEmpty: true),
      '[00:02.00]Sung',
    );
    expect(
      await client.transcribe('/e.flac', '/e.flac', retryEmpty: true),
      '[00:02.00]Sung',
    );
    expect(calls, 2);
  });

  test('a refresh asks again even with a kept transcript', () async {
    var calls = 0;
    final mock = MockClient((_) async {
      calls++;
      return http.Response(
        jsonEncode({
          'segments': [
            {'start': 1.0 * calls, 'text': 'Take $calls'},
          ],
        }),
        200,
      );
    });
    final client = clientFor(LyricsAiProvider.openAi, mock);
    expect(await client.transcribe('/r.flac', '/r.flac'), '[00:01.00]Take 1');
    expect(
      await client.transcribe('/r.flac', '/r.flac', refresh: true),
      '[00:02.00]Take 2',
    );
    expect(await client.transcribe('/r.flac', '/r.flac'), '[00:02.00]Take 2');
    expect(calls, 2);
  });

  test('Groq transcribes through its own Whisper model', () async {
    final mock = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
      expect(request.body, contains('whisper-large-v3'));
      return http.Response(
        jsonEncode({
          'segments': [
            {'start': 2.0, 'text': 'Sung'},
          ],
        }),
        200,
      );
    });
    final client = clientFor(LyricsAiProvider.groq, mock);
    expect(await client.transcribe('/f.flac', '/f.flac'), '[00:02.00]Sung');
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
