import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/lyrics_parser.dart';
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

String _lrcTime(num seconds) {
  final centis = (seconds * 100).round();
  final minutes = centis ~/ 6000;
  final rest = (centis % 6000) / 100;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${rest.toStringAsFixed(2).padLeft(5, '0')}';
}

/// Whisper `verbose_json` segments as LRC lines. With Whisper's [words],
/// each line carries enhanced LRC word times for karaoke highlighting.
String transcriptionSegmentsToLrc(
  List<dynamic> segments, {
  List<dynamic> words = const [],
}) {
  final timed = [
    for (final word in words)
      if (word is Map &&
          word['start'] is num &&
          word['end'] is num &&
          (word['word']?.toString().trim() ?? '').isNotEmpty)
        (
          text: word['word'].toString().trim(),
          start: word['start'] as num,
          end: word['end'] as num,
        ),
  ];
  final starts = [
    for (final segment in segments)
      if (segment is Map && segment['start'] is num) segment['start'] as num,
  ];
  final lines = <String>[];
  for (final segment in segments) {
    if (segment is! Map) continue;
    final text = segment['text']?.toString().trim() ?? '';
    final start = segment['start'];
    if (text.isEmpty || start is! num) continue;
    // A word belongs to the last segment starting at or before it.
    final next = starts
        .where((s) => s > start)
        .fold<num?>(null, (low, s) => low == null || s < low ? s : low);
    final mine = [
      for (final word in timed)
        if (word.start >= start && (next == null || word.start < next)) word,
    ];
    final body = mine.isEmpty
        ? text
        : '${mine.map((w) => '<${_lrcTime(w.start)}>${w.text}').join(' ')}'
              '<${_lrcTime(mine.last.end)}>';
    lines.add('[${_lrcTime(start)}]$body');
  }
  return lines.join('\n');
}

/// LRC for the [plain] lyric lines, each timed where its words are heard in
/// [transcript]. Null when too few lines are heard to trust the timing.
String? syncLyricsToTranscript(String plain, ParsedLyrics transcript) {
  final space = RegExp(r'\s+');
  final nonWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);
  String norm(String word) => word.toLowerCase().replaceAll(nonWord, '');
  final heard = [
    for (final line in transcript.lines)
      if (line.words.isNotEmpty)
        for (final word in line.words) (word: norm(word.text), time: word.time)
      else
        for (final word in line.text.split(space))
          (word: norm(word), time: line.time),
  ].where((w) => w.word.isNotEmpty).toList();
  final lines = [
    for (final line in plain.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (heard.isEmpty || lines.isEmpty) return null;

  final times = List<Duration?>.filled(lines.length, null);
  var cursor = 0;
  for (var i = 0; i < lines.length; i++) {
    final words = lines[i]
        .split(space)
        .map(norm)
        .where((w) => w.isNotEmpty)
        .toList();
    // shortcut: greedy forward match of a word pair in a window; a song
    // sung out of order or a transcript far off its words loses lines.
    match:
    for (var k = 0; k < words.length && k < 3; k++) {
      final end = (cursor + 40).clamp(0, heard.length);
      for (var at = cursor; at < end; at++) {
        if (heard[at].word != words[k]) continue;
        final pair =
            k + 1 >= words.length ||
            (at + 1 < heard.length && heard[at + 1].word == words[k + 1]);
        if (!pair) continue;
        times[i] = heard[at].time;
        cursor = at + 1 + (words.length - k - 1) ~/ 2;
        break match;
      }
    }
  }
  if (times.where((t) => t != null).length * 2 < lines.length) return null;

  // Lines not heard sit evenly between their heard neighbours.
  final out = <String>[];
  var prevIndex = -1;
  var prev = Duration.zero;
  for (var i = 0; i < lines.length; i++) {
    var time = times[i];
    if (time == null) {
      final next = times.indexWhere((t) => t != null, i);
      time = next < 0
          ? prev + const Duration(seconds: 2) * (i - prevIndex)
          : prev +
                (times[next]! - prev) * ((i - prevIndex) / (next - prevIndex));
    } else {
      prevIndex = i;
    }
    if (time < prev) time = prev;
    if (times[i] != null) prev = time;
    out.add('[${_lrcTime(time.inMilliseconds / 1000)}]${lines[i]}');
  }
  return out.join('\n');
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
          // The fields map holds one value per name; the second goes as a part.
          ..files.add(
            http.MultipartFile.fromString('timestamp_granularities[]', 'word'),
          )
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
    final words = body['words'];
    return segments is List
        ? transcriptionSegmentsToLrc(
            segments,
            words: words is List ? words : const [],
          )
        : '';
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
