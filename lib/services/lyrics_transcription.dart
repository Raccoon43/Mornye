import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:path_provider/path_provider.dart';

/// Returns LRC lyrics heard in the song at [path], or empty when it has no
/// words. [source] names the song for the transcript cache.
typedef LyricsTranscriber = Future<String> Function(String source, String path);

/// Providers whose API takes audio: OpenAI and OpenAI-compatible servers
/// through Whisper, Gemini through its own model.
bool lyricsTranscriptionSupported(LyricsAiProvider provider) =>
    provider == LyricsAiProvider.openAi ||
    provider == LyricsAiProvider.custom ||
    provider == LyricsAiProvider.gemini;

/// Whisper `verbose_json` segments as LRC lines.
String transcriptionSegmentsToLrc(List<dynamic> segments) {
  final lines = <String>[];
  for (final segment in segments) {
    if (segment is! Map) continue;
    final text = segment['text']?.toString().trim() ?? '';
    final start = segment['start'];
    if (text.isEmpty || start is! num) continue;
    final centis = (start * 100).round();
    final minutes = centis ~/ 6000;
    final seconds = (centis % 6000) / 100;
    lines.add(
      '[${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toStringAsFixed(2).padLeft(5, '0')}]$text',
    );
  }
  return lines.join('\n');
}

/// The LRC lines of a model's answer, without code fences or remarks.
String lrcLinesOf(String answer) => answer
    .split('\n')
    .map((line) => line.trim())
    .where((line) => RegExp(r'^\[\d{1,2}:\d{2}(\.\d{1,3})?\]').hasMatch(line))
    .join('\n');

class LyricsTranscriptionException implements Exception {
  const LyricsTranscriptionException(this.message);
  final String message;

  @override
  String toString() => 'LyricsTranscriptionException: $message';
}

/// Transcribes a song's vocals with the lyrics AI provider. Transcripts are
/// kept on the device so a song is sent once.
class LyricsTranscriptionClient {
  LyricsTranscriptionClient(
    this.config, {
    http.Client? client,
    Future<FFmpegResult> Function(List<String>)? ffmpeg,
    Future<Directory> Function()? cacheRoot,
  }) : _client = client ?? http.Client(),
       _ffmpeg = ffmpeg ?? FFmpegExecution.arguments,
       _cacheRoot = cacheRoot ?? getApplicationCacheDirectory;

  final LyricsAiConfig config;
  final http.Client _client;
  final Future<FFmpegResult> Function(List<String>) _ffmpeg;
  final Future<Directory> Function() _cacheRoot;

  // shortcut: Whisper is the one OpenAI model with segment times; a custom
  // server naming it otherwise needs a model setting.
  static const whisperModel = 'whisper-1';

  Future<File> _cacheFile(String source) async {
    final name = sha1.convert(utf8.encode(source)).toString();
    return File('${(await _cacheRoot()).path}/transcribed_lyrics/$name.lrc');
  }

  Future<String> transcribe(String source, String path) async {
    if (!lyricsTranscriptionSupported(config.provider)) {
      throw const LyricsTranscriptionException('provider takes no audio');
    }
    final cache = await _cacheFile(source);
    if (await cache.exists()) return cache.readAsString();

    // Mono 16 kHz speech-quality MP3 keeps a long song far under the
    // providers' upload limits.
    final input = isContentUri(path)
        ? await FFmpegKitConfig.getSafParameterForRead(path)
        : path;
    if (input == null || input.isEmpty) {
      throw const LyricsTranscriptionException('cannot open the song');
    }
    final audio = await FFmpegOutput.tempPath('mp3');
    final String lrc;
    try {
      final result = await _ffmpeg([
        '-y',
        '-i',
        input,
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '32k',
        audio,
      ]);
      if (!result.success) {
        throw LyricsTranscriptionException('ffmpeg ${result.returnCode}');
      }
      final bytes = await File(audio).readAsBytes();
      lrc = config.provider == LyricsAiProvider.gemini
          ? await _gemini(bytes)
          : await _whisper(bytes);
    } finally {
      await FFmpegOutput.cleanup(audio);
    }
    // An empty transcript is kept too: a song without words is not sent again.
    await cache.parent.create(recursive: true);
    await cache.writeAsString(lrc);
    return lrc;
  }

  Future<String> _whisper(List<int> bytes) async {
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('${config.openAiBase}/audio/transcriptions'),
          )
          ..fields['model'] = whisperModel
          ..fields['response_format'] = 'verbose_json'
          ..fields['timestamp_granularities[]'] = 'segment'
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: 'song.mp3'),
          );
    if (config.apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${config.apiKey}';
    }
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    final body = _decode(response);
    final segments = body['segments'];
    return segments is List ? transcriptionSegmentsToLrc(segments) : '';
  }

  Future<String> _gemini(List<int> bytes) async {
    final response = await _client.post(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '${config.model}:generateContent',
      ),
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': config.apiKey,
      },
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'text':
                    'Transcribe the sung lyrics of this song as LRC: one '
                    'line per sung line, each starting with its start time '
                    'as [mm:ss.xx]. Answer with the LRC lines only. If '
                    'nothing is sung, answer with nothing.',
              },
              {
                'inline_data': {
                  'mime_type': 'audio/mp3',
                  'data': base64Encode(bytes),
                },
              },
            ],
          },
        ],
      }),
    );
    final body = _decode(response);
    final candidates = body['candidates'];
    if (candidates is! List || candidates.isEmpty) return '';
    final first = candidates.first;
    final content = first is Map ? first['content'] : null;
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List) return '';
    return lrcLinesOf(
      parts.map((part) => part is Map ? part['text'] ?? '' : '').join('\n'),
    );
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode != 200) {
      throw LyricsTranscriptionException('HTTP ${response.statusCode}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw const LyricsTranscriptionException('unexpected response');
    }
    return body;
  }
}
