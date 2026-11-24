import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/equalizer_settings.dart';

/// One headphone measurement listed in AutoEq's results index.
class AutoEqEntry {
  const AutoEqEntry(this.name, this.source, this.path);
  final String name;

  /// Who measured it, plus the rig when the index names one.
  final String source;

  /// Folder relative to `results/`, URL-encoded as the index writes it.
  final String path;
}

final _entryLine = RegExp(r'^- \[(.+?)\]\(\./(.+?)\) by (.+)$');

List<AutoEqEntry> parseAutoEqIndex(String markdown) => [
  for (final line in markdown.split('\n'))
    if (_entryLine.firstMatch(line.trim()) case final m?)
      AutoEqEntry(m[1]!, m[3]!, m[2]!),
];

/// Reads `GraphicEQ: 20 -0.2; 21 -0.2; ...` into (Hz, dB) points.
List<(double, double)> parseGraphicEq(String text) {
  final start = text.indexOf('GraphicEQ:');
  if (start < 0) throw const FormatException('Not a GraphicEQ profile');
  final points = <(double, double)>[];
  for (final pair in text.substring(start + 10).split(';')) {
    final parts = pair.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    final hz = double.tryParse(parts[0]), db = double.tryParse(parts[1]);
    if (hz == null || db == null || hz <= 0 || !db.isFinite) continue;
    points.add((hz, db));
  }
  if (points.length < 2) throw const FormatException('Empty GraphicEQ');
  return points..sort((a, b) => a.$1.compareTo(b.$1));
}

/// Samples the correction at the 31-band centres. Tone controls are cleared
/// because the profile is a whole curve. Without auto headroom the preamp
/// takes the biggest boost off, so the correction cannot clip.
EqualizerSettings autoEqSettings(
  List<(double, double)> points,
  EqualizerSettings current,
) {
  double at(double hz) {
    if (hz <= points.first.$1) return points.first.$2;
    if (hz >= points.last.$1) return points.last.$2;
    var i = 1;
    while (points[i].$1 < hz) {
      i++;
    }
    final (x0, y0) = points[i - 1];
    final (x1, y1) = points[i];
    final t = math.log(hz / x0) / math.log(x1 / x0);
    return y0 + (y1 - y0) * t;
  }

  final bands = EqualizerSettings(gains: List.filled(31, 0.0)).frequencies;
  final gains = [for (final hz in bands) at(hz).clamp(-15.0, 15.0)];
  final peak = gains.fold(0.0, math.max);
  return current.copyWith(
    gains: gains,
    preamp: current.autoHeadroom ? 0 : -peak.clamp(0.0, 24.0),
    bass: 0,
    treble: 0,
  );
}

/// Downloads AutoEq data from GitHub. The index is cached on disk; an
/// applied profile lives on in the equalizer settings, so it needs no cache.
class AutoEqService {
  AutoEqService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  static const _base =
      'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results';
  List<AutoEqEntry>? _index;

  Future<String> _get(String url) async {
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('AutoEq returned ${response.statusCode}');
    }
    return response.body;
  }

  Future<List<AutoEqEntry>> index() async {
    if (_index != null) return _index!;
    final file = File(
      '${(await getApplicationSupportDirectory()).path}/autoeq_index.md',
    );
    final cached = await file.exists();
    String markdown;
    if (cached &&
        DateTime.now().difference(await file.lastModified()).inDays < 30) {
      markdown = await file.readAsString();
    } else {
      try {
        markdown = await _get('$_base/INDEX.md');
        await file.writeAsString(markdown);
      } catch (_) {
        if (!cached) rethrow;
        markdown = await file.readAsString();
      }
    }
    return _index = parseAutoEqIndex(markdown);
  }

  Future<List<(double, double)>> profile(AutoEqEntry entry) {
    final folder = Uri.decodeComponent(entry.path.split('/').last);
    final file = Uri.encodeComponent('$folder GraphicEQ.txt');
    return _get('$_base/${entry.path}/$file').then(parseGraphicEq);
  }
}

final autoEqService = AutoEqService();
