import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/motion_artwork_folder.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/spotify_sync_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

typedef PlayerArtworkAlbum = ({String album, String artist});

final motionArtworkStoreProvider = Provider((ref) => MotionArtworkStore());

final motionArtworkFolderProvider = Provider((ref) => MotionArtworkFolder());

/// An album and the song, or one of its songs, whose folder may hold the
/// album's `cover.mp4`.
typedef PlayerArtworkSong = ({String album, String artist, String source});

/// Player and local album pages read artwork saved by downloads or re-enrich.
/// Opening either must never search extensions or download more artwork.
final playerMotionArtworkProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, PlayerArtworkAlbum>((ref, album) async {
      if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
        return null;
      }
      if (album.album.trim().isEmpty || album.artist.trim().isEmpty) {
        return null;
      }
      return ref.watch(motionArtworkStoreProvider).find(album);
    });

/// The artwork for a song: a `cover.mp4` in its folder first, since that
/// one belongs to exactly this album and is the user's own file, then the
/// artwork saved for the album.
final songMotionArtworkProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, PlayerArtworkSong>((ref, song) async {
      if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
        return null;
      }
      final (beside, saved) = await (
        ref.watch(motionArtworkFolderProvider).find(song.source),
        ref.watch(
          playerMotionArtworkProvider((
            album: song.album,
            artist: song.artist,
          )).future,
        ),
      ).wait;
      return beside ?? saved;
    });

/// The mini and full player's artwork: the song's saved motion cover, else
/// its Spotify Canvas while Spotify is connected. Both players watch this
/// same provider so they share one decoder.
final playerSongMotionArtworkProvider = FutureProvider.autoDispose
    .family<
      MotionArtwork?,
      ({String album, String artist, String source, String title})
    >((ref, song) async {
      // A song already playing when the user connects Spotify looks again.
      void retry() => ref.invalidateSelf();
      spotifySyncService.connection.addListener(retry);
      ref.onDispose(() => spotifySyncService.connection.removeListener(retry));
      final saved = await ref.watch(
        songMotionArtworkProvider((
          album: song.album,
          artist: song.artist,
          source: song.source,
        )).future,
      );
      if (saved != null || !ref.mounted) return saved;
      if (!ref.read(settingsProvider).motionArtworkEnabled) return null;
      if (!spotifySyncService.isConnected) return null;
      var id = spotifyTrackIds[song.source];
      if (id == null) {
        // Songs from the library or a restored queue: the download's id.
        final item = await ref
            .read(downloadHistoryProvider.notifier)
            .getByFilePathAsync(song.source);
        if (isSpotifyTrackId(item?.spotifyId)) id = item!.spotifyId;
      }
      // Songs downloaded from other sources: Spotify search by title.
      if (id == null && song.title.isNotEmpty && song.artist.isNotEmpty) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!ref.mounted) return null;
        id = await spotifySyncService.findTrackId(song.title, song.artist);
      }
      if (id == null || !ref.mounted) return null;
      // Songs skipped past quickly never ask Spotify.
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!ref.mounted) return null;
      final file = await spotifySyncService.canvasFile(
        id,
        await _canvasCache(),
      );
      // Song rows show the motion badge for Canvases already saved.
      if (file != null) ref.invalidate(songHasMotionArtworkProvider);
      return file == null || !ref.mounted ? null : MotionArtwork(file);
    });

Future<Directory> _canvasCache() async =>
    Directory('${(await getTemporaryDirectory()).path}/spotify_canvas');

/// A song row's motion badge: its album's saved animated cover, or a
/// Spotify Canvas saved from playing it. Never asks Spotify or extensions.
final songHasMotionArtworkProvider = FutureProvider.autoDispose
    .family<bool, ({String album, String artist, String? spotifyId})>((
      ref,
      song,
    ) async {
      if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
        return false;
      }
      final id = song.spotifyId;
      if (isSpotifyTrackId(id) &&
          await File('${(await _canvasCache()).path}/$id.mp4').exists()) {
        return true;
      }
      final album = await ref.watch(
        playerMotionArtworkProvider((
          album: song.album,
          artist: song.artist,
        )).future,
      );
      return album != null;
    });

/// Optional video is kept outside audio tags, after the metadata write succeeds.
Future<void> saveReEnrichedMotionArtwork(
  ProviderContainer container, {
  required Map<String, dynamic> metadata,
  required String albumName,
  required String artistName,
}) async {
  final source = normalizeRemoteHttpUrl(metadata['header_video']?.toString());
  if (source == null) return;
  final album = (
    album:
        normalizeOptionalString(metadata['album_name']?.toString()) ??
        albumName,
    artist:
        normalizeOptionalString(metadata['artist_name']?.toString()) ??
        artistName,
  );
  try {
    final artwork = await container
        .read(motionArtworkStoreProvider)
        .save(album, resolveSource: () async => source);
    if (artwork != null) {
      container.invalidate(playerMotionArtworkProvider(album));
    }
  } catch (error) {
    final log = AppLogger('ReEnrichMotionArtwork');
    log.w('Optional artwork save failed: $error');
  }
}
