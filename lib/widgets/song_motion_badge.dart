import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';

/// A small icon after a library song's title when it has an animated
/// album cover or a saved Spotify Canvas.
class SongMotionBadge extends ConsumerWidget {
  const SongMotionBadge({super.key, required this.item});

  final UnifiedLibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasMotion = ref.watch(
      songHasMotionArtworkProvider((
        album: item.albumName,
        artist: item.artistName,
        spotifyId: item.historyItem?.spotifyId,
      )),
    );
    if (hasMotion.value != true) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: Icon(
        Icons.motion_photos_on_outlined,
        size: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        semanticLabel: context.l10n.motionArtwork,
      ),
    );
  }
}
