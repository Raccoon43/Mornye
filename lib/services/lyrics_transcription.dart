import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// Providers whose API takes audio: OpenAI, Groq and OpenAI-compatible
/// servers through Whisper, Gemini through its own model.
bool lyricsTranscriptionSupported(LyricsAiProvider provider) =>
    provider == LyricsAiProvider.openAi ||
    provider == LyricsAiProvider.groq ||
    provider == LyricsAiProvider.custom ||
    provider == LyricsAiProvider.gemini;

String _lrcTime(num seconds) {
  final centis = (seconds * 100).round();
  final minutes = centis ~/ 6000;
  final rest = (centis % 6000) / 100;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${rest.toStringAsFixed(2).padLeft(5, '0')}';
}

// Lines Whisper makes up over music, learned from video subtitles.
final _madeUpLine = RegExp(
  r'thanks? (you )?for watching|subscribe|like and share|'
  r'subtitles? (by|made)|captions? by|transcri(bed|ption) by|'
  r'am\s*ara\s*\.\s*org|see you (in the )?next (video|time)|'
  // Chinese subtitle credits and "like, subscribe" outros.
  r'字幕|点赞|訂閱|订阅',
  caseSensitive: false,
);

/// Whether Whisper likely invented [segment]: no voice was heard, it looped
/// on one phrase, or it reads like a video outro.
bool _madeUp(Map<dynamic, dynamic> segment, String text) {
  final noSpeech = segment['no_speech_prob'];
  final logProb = segment['avg_logprob'];
  final ratio = segment['compression_ratio'];
  // Whisper's own thresholds for silence and for repetition loops.
  return (noSpeech is num &&
          logProb is num &&
          noSpeech > 0.6 &&
          logProb < -1) ||
      (ratio is num && ratio > 2.4) ||
      _madeUpLine.hasMatch(text);
}

final _letter = RegExp(r'\p{L}', unicode: true);

/// The Whisper language a song's title, artist or album is written in, for
/// scripts Whisper cannot mistake: kana, Hangul, then Han. Null otherwise.
// shortcut: a kanji-only Japanese title reads as Chinese; upgrade with a
// per-song language setting if that comes up.
String? whisperLanguageHint(String text) {
  bool has(RegExp script) => script.hasMatch(text);
  if (has(RegExp(r'[぀-ヿ]'))) return 'ja';
  if (has(RegExp(r'[ᄀ-ᇿ㄰-㆏가-힯]'))) return 'ko';
  if (has(RegExp(r'[㐀-䶿一-鿿]'))) return 'zh';
  return null;
}

/// Writing system of a letter: Latin, CJK (Han, kana, Hangul) or else its
/// 128-letter Unicode block, which keeps scripts like Sinhala apart.
Object _script(int rune) {
  if (rune < 0x370 || (rune >= 0x1E00 && rune < 0x1F00)) return 'latin';
  if ((rune >= 0x1100 && rune < 0x1200) ||
      (rune >= 0x3040 && rune < 0x3190) ||
      (rune >= 0x3400 && rune < 0xA000) ||
      (rune >= 0xAC00 && rune < 0xD7B0) ||
      (rune >= 0x20000 && rune < 0x30000)) {
    return 'cjk';
  }
  return rune >> 7;
}

/// The script most of [items] are written in, or null when there are none.
Object? _mostUsed(Iterable<Object?> items) {
  final counts = <Object, int>{};
  for (final item in items.nonNulls) {
    counts[item] = (counts[item] ?? 0) + 1;
  }
  return counts.isEmpty
      ? null
      : counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

Object? _lineScript(String text) => _mostUsed(
  _letter.allMatches(text).map((m) => _script(m.group(0)!.runes.first)),
);

/// Whisper `verbose_json` segments as LRC lines. With Whisper's [words],
/// each line carries enhanced LRC word times for karaoke highlighting.
/// Segments Whisper likely made up are left out, as are lines written in
/// a script other than the song's own or Latin: over music Whisper guesses
/// a wrong language for a part.
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
  final kept = [
    for (final segment in segments)
      if (segment is Map)
        (
          segment: segment,
          text: segment['text']?.toString().trim() ?? '',
          script: _lineScript(segment['text']?.toString() ?? ''),
        ),
  ].where((s) => s.text.isNotEmpty && !_madeUp(s.segment, s.text)).toList();
  // One vote per line: a Han character holds a syllable, so counting letters
  // would let a short line in an alphabet outweigh real Chinese lines. Latin
  // lines always stay, so they don't vote: a mostly English K-pop song keeps
  // its Korean.
  final songScript = _mostUsed(
    kept.map((s) => s.script).where((s) => s != 'latin'),
  );
  final lines = <String>[];
  for (final (:segment, :text, :script) in kept) {
    final start = segment['start'];
    if (start is! num) continue;
    if (script != null && script != songScript && script != 'latin') continue;
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
/// [transcript], word by word when the transcript has word times. Lines sung
/// again where the text does not repeat them, like a chorus written once,
/// repeat where they are heard. Null when too few lines are heard to trust
/// the timing.
String? syncLyricsToTranscript(String plain, ParsedLyrics transcript) {
  final space = RegExp(r'\s+');
  final nonWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);
  String norm(String word) => word.toLowerCase().replaceAll(nonWord, '');
  final heard = [
    for (final line in transcript.lines)
      if (line.words.isNotEmpty)
        for (final word in line.words)
          (word: norm(word.text), time: word.time, end: word.end)
      else
        for (final word in line.text.split(space))
          (word: norm(word), time: line.time, end: line.end),
  ].where((w) => w.word.isNotEmpty).toList();
  final lines = [
    for (final line in plain.split('\n'))
      if (line.trim().isNotEmpty) line.trim().split(space),
  ];
  if (heard.isEmpty || lines.isEmpty) return null;
  final keys = [for (final line in lines) line.map(norm).toList()];
  final counts = [
    for (final key in keys) key.where((k) => k.isNotEmpty).length,
  ];
  // Words of a line that must be heard to place it.
  int need(int i) => (counts[i] * 2 + 2) ~/ 3;

  // The heard index of each word of line [i] when it is sung from a word
  // heard in [from, to) with at least [enough] of its words heard.
  List<int?>? find(int i, int from, int to, int enough) {
    final key = keys[i];
    if (counts[i] == 0) return null;
    for (var k = 0; k < key.length && k < 3; k++) {
      if (key[k].isEmpty) continue;
      for (var at = from; at < to && at < heard.length; at++) {
        if (heard[at].word != key[k]) continue;
        final sung = List<int?>.filled(key.length, null)..[k] = at;
        var found = 1;
        var next = at + 1;
        for (var w = k + 1; w < key.length; w++) {
          if (key[w].isEmpty) continue;
          // shortcut: a word may sit up to 2 misheard words on; a
          // transcript further off loses that word's time.
          for (var q = next; q < next + 3 && q < heard.length; q++) {
            if (heard[q].word != key[w]) continue;
            sung[w] = q;
            next = q + 1;
            found++;
            break;
          }
        }
        if (found >= enough) return sung;
      }
    }
    return null;
  }

  int first(List<int?> sung) => sung.firstWhere((q) => q != null)!;
  int last(List<int?> sung) => sung.lastWhere((q) => q != null)!;

  // shortcut: greedy forward match; a song sung out of order loses lines.
  final sung = List<List<int?>?>.filled(lines.length, null);
  var cursor = 0;
  for (var i = 0; i < lines.length; i++) {
    // A chorus sung again before this line may push it past the window.
    final match =
        find(i, cursor, cursor + 40, need(i)) ??
        find(i, cursor, heard.length, max(3, need(i)));
    if (match == null) continue;
    sung[i] = match;
    cursor = last(match) + 1;
  }
  if (sung.where((s) => s != null).length * 2 < lines.length) return null;

  // Lines not heard sit evenly between their heard neighbours.
  final times = [for (final s in sung) s == null ? null : heard[first(s)].time];
  final entries = <({Duration time, int line, List<int?>? sung})>[];
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
    entries.add((time: time, line: i, sung: sung[i]));
  }

  // Heard words no line took: a run of two or more lines sung again.
  final taken = List.filled(heard.length, false);
  void take(List<int?> s) {
    for (var q = first(s); q <= last(s); q++) {
      taken[q] = true;
    }
  }

  bool free(List<int?> s) => s.every((q) => q == null || !taken[q]);
  for (final s in sung) {
    if (s != null) take(s);
  }
  for (var at = 0; at < heard.length; at++) {
    if (taken[at]) continue;
    for (var j = 0; j + 1 < lines.length; j++) {
      if (sung[j] == null) continue;
      final run = <(int, List<int?>)>[];
      var s = find(j, at, at + 1, need(j));
      for (var i = j; s != null && free(s);) {
        run.add((i, s));
        if (++i >= lines.length) break;
        final from = last(s) + 1;
        s = find(i, from, from + 4, need(i));
      }
      if (run.length < 2) continue;
      for (final (i, s) in run) {
        take(s);
        entries.add((time: heard[first(s)].time, line: i, sung: s));
      }
      at = last(run.last.$2);
      break;
    }
  }
  // Repeats join in heard order; equal times keep the written order.
  final order = [for (var i = 0; i < entries.length; i++) i]
    ..sort((a, b) {
      final byTime = entries[a].time.compareTo(entries[b].time);
      return byTime != 0 ? byTime : a.compareTo(b);
    });

  String stamp(Duration time) => _lrcTime(time.inMilliseconds / 1000);
  String lrcLine(({Duration time, int line, List<int?>? sung}) entry) {
    final words = lines[entry.line];
    final s = entry.sung;
    if (s == null || !transcript.wordSynced) {
      return '[${stamp(entry.time)}]${words.join(' ')}';
    }
    // Words not heard sit evenly between the heard ones around them.
    final at = <Duration>[];
    var low = entry.time;
    for (var w = 0; w < words.length; w++) {
      final q = s[w];
      var time = low;
      if (q != null) {
        time = heard[q].time;
      } else {
        final before = s.lastIndexWhere((x) => x != null, w);
        final after = s.indexWhere((x) => x != null, w);
        if (after >= 0) {
          final from = before < 0 ? entry.time : heard[s[before]!].time;
          time =
              from +
              (heard[s[after]!].time - from) *
                  ((w - before) / (after - before));
        }
      }
      if (time < low) time = low;
      at.add(low = time);
    }
    final end = heard[last(s)].end;
    final body = [
      for (var w = 0; w < words.length; w++) '<${stamp(at[w])}>${words[w]}',
    ].join(' ');
    return '[${stamp(entry.time)}]$body'
        '${end == null ? '' : '<${stamp(end)}>'}';
  }

  return order.map((i) => lrcLine(entries[i])).join('\n');
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
  String get whisperModel => config.provider == LyricsAiProvider.groq
      ? 'whisper-large-v3'
      : 'whisper-1';

  // v5: made-up subtitle credits (spaced "Am ara.org", Chinese 字幕) are dropped.
  Future<File> _cacheFile(String source) async {
    final name = sha1.convert(utf8.encode(source)).toString();
    return File('${(await _cacheRoot()).path}/transcribed_lyrics_v5/$name.lrc');
  }

  /// [retryEmpty] sends the song again when its kept transcript is empty;
  /// [refresh] sends it again whatever was kept. [language] (ISO 639-1)
  /// stops Whisper guessing it from an instrumental intro.
  Future<String> transcribe(
    String source,
    String path, {
    bool retryEmpty = false,
    bool refresh = false,
    String? language,
  }) async {
    if (!lyricsTranscriptionSupported(config.provider)) {
      throw const LyricsTranscriptionException('provider takes no audio');
    }
    final cache = await _cacheFile(source);
    if (!refresh && await cache.exists()) {
      final kept = await cache.readAsString();
      if (kept.trim().isNotEmpty || !retryEmpty) return kept;
    }

    // Mono 16 kHz MP3 keeps a long song far under the
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
        '64k',
        audio,
      ]);
      if (!result.success) {
        throw LyricsTranscriptionException('ffmpeg ${result.returnCode}');
      }
      final bytes = await File(audio).readAsBytes();
      lrc = config.provider == LyricsAiProvider.gemini
          ? await _gemini(bytes)
          : await _whisper(bytes, language);
    } finally {
      await FFmpegOutput.cleanup(audio);
    }
    // An empty transcript is kept too: a song without words is not sent again.
    await cache.parent.create(recursive: true);
    await cache.writeAsString(lrc);
    return lrc;
  }

  Future<String> _whisper(List<int> bytes, String? language) async {
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('${config.openAiBase}/audio/transcriptions'),
          )
          ..fields['model'] = whisperModel
          ..fields.addAll({'language': ?language})
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
