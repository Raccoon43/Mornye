import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/services/lyrics_ai_client.dart';
import 'package:mornye/services/lyrics_transcription.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/utils/text_direction.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/lyrics_editor_sheet.dart';
import 'package:mornye/widgets/lyrics_options_activity.dart';
import 'package:mornye/widgets/lyrics_options_button.dart'
    show showLyricsLanguagePicker;
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The directions of plain lyrics' lines, worked out once for each lyrics.
final _plainLyricDirections =
    Expando<({List<TextDirection?> text, List<TextDirection?> lines})>();

bool lyricsTranscriptionEnabled(AppSettings settings) =>
    lyricsTranscriptionSupported(
      LyricsAiProvider.fromId(settings.lyricsAiProvider),
    );

const _transcriptLanguageKey = 'lyrics_transcript_language_v1:';

/// The lyrics language picker's code picked for [source]'s AI lyrics, or
/// null to detect it.
// shortcut: one preference per song, never pruned; move to a capped map if
// many songs get one.
Future<String?> transcriptLanguageOf(String source) async =>
    (await SharedPreferences.getInstance()).getString(
      '$_transcriptLanguageKey$source',
    );

/// Picks [code] for [source]'s AI lyrics; empty goes back to detecting it.
Future<void> setTranscriptLanguage(String source, String code) async {
  final prefs = await SharedPreferences.getInstance();
  final key = '$_transcriptLanguageKey$source';
  await (code.isEmpty ? prefs.remove(key) : prefs.setString(key, code));
}

/// Sends a song to the lyrics AI provider. Reads its providers now: the
/// widget may be gone when the key arrives. A [retry] sends a song whose
/// kept transcript is empty again; a [refresh] sends it again regardless.
/// The language picked for the song, or else the [item]'s tags, tell
/// Whisper the language to hear.
LyricsTranscriber playerLyricsTranscriber(
  WidgetRef ref,
  MediaItem? item, {
  bool retry = false,
  bool refresh = false,
}) {
  final language = whisperLanguageHint(
    [item?.title, item?.artist, item?.album].nonNulls.join(' '),
  );
  final settings = ref.read(settingsProvider);
  final keyFuture = ref.read(
    lyricsAiKeyProvider(settings.lyricsAiProvider).future,
  );
  final newClient = ref.read(lyricsAiHttpClientProvider);
  return (source, path) async {
    final key = await keyFuture;
    if (!lyricsAiReady(settings, key)) return '';
    final picked = await transcriptLanguageOf(source);
    final client = newClient();
    try {
      return await LyricsTranscriptionClient(
        lyricsAiConfigFor(settings, apiKey: key),
        client: client,
      ).transcribe(
        source,
        path,
        retryEmpty: retry,
        refresh: refresh,
        language: picked == null ? language : whisperLanguageCode(picked),
      );
    } finally {
      client.close();
    }
  };
}

class PlayerLyricsSection extends ConsumerWidget {
  const PlayerLyricsSection({
    super.key,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.isActive,
    this.animateWords = true,
    this.options,
    this.onShareLyrics,
  });

  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final bool isActive;
  final bool animateWords;
  final Widget? options;

  /// Long-pressing lyrics opens sharing, preselecting a timed line.
  final ValueChanged<LyricLine?>? onShareLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(
      settingsProvider.select(
        (settings) =>
            (settings.playerShowPronunciation, settings.playerShowTranslation),
      ),
    );
    // The AI translation is keyed by these; a change picks another one.
    ref.watch(
      settingsProvider.select(
        (settings) => (
          settings.lyricsAiProvider,
          settings.lyricsAiModel,
          settings.lyricsAiBaseUrl,
          settings.lyricsTranslationLanguage,
          settings.locale,
          settings.lyricsAutoTranslate,
          settings.lyricsAiWordSync,
          settings.lyricsRomanize,
          settings.lyricsRomanizedMainLine,
          settings.lyricsAutoTranscribe,
        ),
      ),
    );
    ref.watch(lyricsTranslationProvider.select((state) => state.results));
    final translation = ref.read(lyricsTranslationProvider.notifier);
    return ListenableBuilder(
      listenable: metadata,
      builder: (context, _) {
        _transcribeIfMissing(ref);
        return LyricsOptionsActivity(
          child: _buildLyricsSection(
            context,
            ref,
            visibility,
            translation.shown(metadata.lyrics),
          ),
        );
      },
    );
  }

  /// Asks the AI provider for the words of a song that has no lyrics, or
  /// for the timing of its plain lyrics, when the setting is on. The
  /// controller runs it once per song.
  void _transcribeIfMissing(WidgetRef ref) {
    final settings = ref.read(settingsProvider);
    if (!settings.lyricsAutoTranscribe ||
        metadata.loading ||
        metadata.transcribing ||
        metadata.lyrics.synced ||
        !lyricsTranscriptionEnabled(settings)) {
      return;
    }
    final transcribe = playerLyricsTranscriber(ref, metadata.item);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => metadata.transcribeLyrics(transcribe),
    );
  }

  Widget _buildLyricsSection(
    BuildContext context,
    WidgetRef ref,
    (bool, bool) visibility,
    ParsedLyrics lyrics,
  ) {
    // Center in the part the player's controls leave visible. Only these
    // states depend on it, so a lyric list does not rebuild as they fade.
    if (metadata.loading || metadata.searchingOnline || metadata.transcribing) {
      return Builder(
        builder: (context) => Padding(
          padding: EdgeInsets.only(bottom: LyricsCoveredBottom.of(context)),
          child: const Center(child: AppLoadingIndicator()),
        ),
      );
    }
    if (metadata.lyrics.isEmpty) {
      // Scrolls when a short screen leaves too little room above the
      // controls, so the search button stays reachable.
      return LayoutBuilder(
        builder: (_, constraints) {
          final covered = LyricsCoveredBottom.of(context);
          return SingleChildScrollView(
            padding: EdgeInsets.only(bottom: covered),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                minHeight: constraints.hasBoundedHeight
                    ? (constraints.maxHeight - covered).clamp(
                        0.0,
                        double.infinity,
                      )
                    : 0,
              ),
              child: Center(child: _noLyrics(context, ref)),
            ),
          );
        },
      );
    }
    return _lyricsContent(context, visibility, lyrics);
  }

  Widget _noLyrics(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(
          Icons.lyrics_outlined,
          size: 40,
          color: colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          metadata.onlineSearchMissed
              ? context.l10n.nowPlayingNoLyricsOnline
              : context.l10n.nowPlayingNoLyrics,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        if (metadata.canSearchOnline) ...[
          const SizedBox(height: 16),
          ExpressiveButton(
            tonal: true,
            onPressed: () async {
              await metadata.searchOnline();
              if (context.mounted && metadata.onlineLyricsSaveFailed) {
                showAppSnackBar(
                  context,
                  content: Text(context.l10n.snackbarFailedToEmbedLyrics),
                );
              }
            },
            icon: const Icon(Icons.manage_search),
            child: Text(context.l10n.nowPlayingSearchLyricsOnline),
          ),
        ],
        if (metadata.canTranscribe &&
            lyricsTranscriptionEnabled(ref.read(settingsProvider))) ...[
          const SizedBox(height: 8),
          ExpressiveButton(
            key: const ValueKey('lyrics-transcribe'),
            tonal: true,
            onPressed: () async {
              final found = await metadata.transcribeLyrics(
                playerLyricsTranscriber(ref, metadata.item, retry: true),
                force: true,
              );
              if (!found && context.mounted) {
                showAppSnackBar(
                  context,
                  content: Text(context.l10n.lyricsTranscribeFailed),
                );
              }
            },
            icon: const Icon(Icons.auto_awesome),
            child: Text(context.l10n.lyricsTranscribeAction),
          ),
          // The lyrics menu is hidden without lyrics, so the language is
          // picked here when a transcript heard nothing.
          ExpressiveButton(
            key: const ValueKey('lyrics-transcript-language'),
            text: true,
            onPressed: () async {
              final source = metadata.source;
              if (source == null) return;
              final current = await transcriptLanguageOf(source) ?? '';
              if (!context.mounted) return;
              final picked = await showLyricsLanguagePicker(
                context,
                title: context.l10n.lyricsTranscriptLanguage,
                subtitle: metadata.item?.title,
                selected: current,
                appDefaultLabel: context.l10n.lyricsTranscriptLanguageAuto,
              );
              if (picked == null || picked == current) return;
              await setTranscriptLanguage(source, picked);
              final found = await metadata.transcribeLyrics(
                playerLyricsTranscriber(ref, metadata.item, retry: true),
                force: true,
              );
              if (!found && context.mounted) {
                showAppSnackBar(
                  context,
                  content: Text(context.l10n.lyricsTranscribeFailed),
                );
              }
            },
            icon: const Icon(Icons.record_voice_over_outlined),
            child: Text(context.l10n.lyricsTranscriptLanguage),
          ),
        ],
        if (canEditPlayerLyrics(metadata)) ...[
          const SizedBox(height: 8),
          ExpressiveButton(
            key: const ValueKey('lyrics-write'),
            text: true,
            onPressed: () => openLyricsEditor(context, metadata),
            icon: const Icon(Icons.edit_note),
            child: Text(context.l10n.lyricsEditWrite),
          ),
        ],
      ],
    ),
  );

  Widget _lyricsContent(
    BuildContext context,
    (bool, bool) visibility,
    ParsedLyrics lyrics,
  ) {
    if (metadata.lyrics.synced) {
      return Stack(
        fit: StackFit.expand,
        children: [
          SyncedLyricsView(
            lyrics: lyrics,
            seekPreview: seekPreview,
            credits: _lyricsCredits(context),
            colorScheme: colorScheme,
            isActive: isActive,
            animateWords: animateWords,
            showPronunciation: visibility.$1,
            showTranslation: visibility.$2,
            onLongPressLine: onShareLyrics,
            songKey: songLyricsOffsetKeyOf(metadata.item),
          ),
          if (options != null)
            PositionedDirectional(
              end: context.isMornye ? mornyeLyricsContentInset : 24,
              bottom: 8,
              child: options!,
            ),
        ],
      );
    }
    final plain = SingleChildScrollView(
      // Leaves room for the options button over the end of the text.
      padding: EdgeInsets.fromLTRB(24, 16, 24, options == null ? 32 : 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onLongPress: onShareLyrics == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onShareLyrics!(null);
                  },
            child: LyricsTextScale(
              child: _plainLyrics(context, visibility, lyrics),
            ),
          ),
          ?_lyricsCredits(context),
        ],
      ),
    );
    if (options == null) return plain;
    return Stack(
      fit: StackFit.expand,
      children: [
        plain,
        PositionedDirectional(
          end: context.isMornye ? mornyeLyricsContentInset : 24,
          bottom: 8,
          child: options!,
        ),
      ],
    );
  }

  /// Lyrics without timing, with each line's pronunciation and translation
  /// under it while they are shown.
  Widget _plainLyrics(
    BuildContext context,
    (bool, bool) visibility,
    ParsedLyrics lyrics,
  ) {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
      height: 1.6,
      color: colorScheme.onSurface,
    );
    String? shown(String? value, bool visible) =>
        visible && value?.trim().isNotEmpty == true ? value!.trim() : null;
    final hasSupplements = lyrics.lines.any(
      (line) =>
          shown(line.romanization, visibility.$1) != null ||
          shown(line.translation, visibility.$2) != null,
    );
    final ambientDirection = Directionality.of(context);
    final directions = _plainLyricDirections[lyrics] ??= (
      text: lyricLineDirections(lyrics.plainText.split('\n')),
      lines: lyricLineDirections(lyrics.lines.map((line) => line.text)),
    );
    if (!hasSupplements) {
      // Each line reads in its own direction. One text has one, so lyrics
      // mixing both directions get a text a line, laid out the same.
      final first = directions.text.firstOrNull;
      if (directions.text.every((direction) => direction == first)) {
        return Text(
          lyrics.plainText,
          textDirection: first ?? ambientDirection,
          style: style,
          textAlign: TextAlign.center,
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, line) in lyrics.plainText.split('\n').indexed)
            Text(
              line,
              textDirection: directions.text[index] ?? ambientDirection,
              style: style,
              textAlign: TextAlign.center,
            ),
        ],
      );
    }
    final supplementStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      height: 1.4,
      color: colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, line) in lyrics.lines.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  line.text,
                  textDirection: directions.lines[index] ?? ambientDirection,
                  style: style,
                  textAlign: TextAlign.center,
                ),
                for (final supplement in [
                  shown(line.romanization, visibility.$1),
                  shown(line.translation, visibility.$2),
                ])
                  if (supplement != null)
                    Text(
                      supplement,
                      textDirection:
                          strongTextDirection(supplement) ??
                          directions.lines[index] ??
                          ambientDirection,
                      style: supplementStyle,
                      textAlign: TextAlign.center,
                    ),
              ],
            ),
          ),
      ],
    );
  }

  LyricsCredits? _lyricsCredits(BuildContext context) {
    final (:writers, :provider) = metadata.credits;
    if (metadata.transcribed) {
      return LyricsCredits(
        writers: writers,
        provider: context.l10n.nowPlayingLyricsTranscribed,
      );
    }
    if (metadata.aiSynced) {
      return LyricsCredits(
        writers: writers,
        provider: context.l10n.nowPlayingLyricsAiSynced,
      );
    }
    if (writers == null && provider == null) return null;
    return LyricsCredits(writers: writers, provider: provider);
  }
}
