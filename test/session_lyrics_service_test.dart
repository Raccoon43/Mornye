import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/session_lyrics_service.dart';
import 'package:mornye/utils/lyrics_parser.dart';

void main() {
  ParsedLyrics lyrics(List<LyricLine> lines, {bool synced = true}) =>
      ParsedLyrics(
        synced: synced,
        wordSynced: false,
        lines: lines,
        plainText: '',
      );
  const second = Duration(seconds: 1);

  test('picks the line playing at the position', () {
    final song = lyrics(const [
      LyricLine(time: second, text: ' First '),
      LyricLine(time: Duration(seconds: 3), text: 'Second'),
      LyricLine(time: Duration(seconds: 4), text: 'Echo', isBackground: true),
      LyricLine(time: Duration(seconds: 6), text: '  '),
    ]);

    expect(SessionLyricsService.lineAt(song, Duration.zero), isNull);
    expect(SessionLyricsService.lineAt(song, second * 2), 'First');
    expect(SessionLyricsService.lineAt(song, second * 3), 'Second');
    expect(SessionLyricsService.lineAt(song, second * 5), 'Second');
    expect(SessionLyricsService.lineAt(song, second * 7), isNull);
  });

  test('shows nothing for unsynced lyrics', () {
    final song = lyrics(const [LyricLine(time: second, text: 'Words')],
        synced: false);
    expect(SessionLyricsService.lineAt(song, second * 2), isNull);
  });
}
