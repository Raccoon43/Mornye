import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';

/// Shows the current synced lyric line as the Android media session's
/// subtitle, so Android Auto and other session readers show it under the
/// title. Only the session copy changes: the app's media item and the
/// notification keep the artist.
class SessionLyricsService {
  SessionLyricsService({
    PlayerMetadataController? metadata,
    Future<void> Function(String mediaId, String? line)? send,
  }) : _metadata = metadata ?? PlayerMetadataController(),
       _send = send ?? AudioService.setAndroidSessionLine {
    _metadata.addListener(_update);
  }

  static final instance = SessionLyricsService();
  static final _log = AppLogger('SessionLyrics');

  final PlayerMetadataController _metadata;
  final Future<void> Function(String mediaId, String? line) _send;
  final _subscriptions = <StreamSubscription<Object?>>[];
  AudioHandler? _handler;
  Timer? _ticker;
  (String, String?)? _sent;

  void bind(AudioHandler handler) {
    if (identical(_handler, handler)) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _handler = handler;
    _subscriptions.add(
      handler.mediaItem.listen((item) {
        // Library songs are SAF documents playback never resolves to a
        // path; reading their lyrics needs the same inspection the phone's
        // lyrics page asks for.
        unawaited(_metadata.load(item, inspectUnresolvedContentUri: true));
        _update();
      }),
    );
    _subscriptions.add(
      handler.playbackState.listen((state) {
        if (state.playing) {
          // A 500 ms tick keeps the line within half a second of the song.
          _ticker ??= Timer.periodic(
            const Duration(milliseconds: 500),
            (_) => _update(),
          );
        } else {
          _ticker?.cancel();
          _ticker = null;
        }
        _update();
      }),
    );
  }

  @visibleForTesting
  static String? lineAt(ParsedLyrics lyrics, Duration position) {
    if (!lyrics.synced) return null;
    var index = LyricsParser.activeIndex(lyrics.lines, position);
    // Backing vocals overlap their lead; the one-line subtitle keeps the lead.
    while (index >= 0 && lyrics.lines[index].isBackground) {
      index--;
    }
    if (index < 0) return null;
    final text = lyrics.lines[index].text.trim();
    return text.isEmpty ? null : text;
  }

  void _update() {
    final handler = _handler;
    final item = handler?.mediaItem.value;
    if (handler == null || item == null) return;
    final line = lineAt(_metadata.lyrics, handler.playbackState.value.position);
    final next = (item.id, line);
    if (next == _sent) return;
    _sent = next;
    _send(item.id, line).catchError((Object error) {
      _log.w('Session lyric line failed: $error');
    });
  }
}
