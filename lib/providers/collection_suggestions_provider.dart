import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/collection_suggestions.dart';
import 'package:mornye/services/platform_bridge.dart';

/// Suggestions for the collection [key] (`playlist:<id>`, `album:<id>`...)
/// in refresh [round], from its [tracks] (most important first). Equal by
/// key and round only, so a rebuild with a new track list keeps the loaded
/// suggestions.
class CollectionSuggestionsRequest {
  const CollectionSuggestionsRequest({
    required this.key,
    required this.round,
    required this.tracks,
  });

  final String key;
  final int round;
  final List<Track> tracks;

  @override
  bool operator ==(Object other) =>
      other is CollectionSuggestionsRequest &&
      other.key == key &&
      other.round == round;

  @override
  int get hashCode => Object.hash(key, round);
}

/// How long suggestions stay after their page closes, so reopening it does
/// not ask the extension again.
const collectionSuggestionsKeepAlive = Duration(minutes: 10);

/// Songs to suggest under a collection.
final collectionSuggestionsProvider = FutureProvider.autoDispose
    .family<CollectionSuggestions, CollectionSuggestionsRequest>((
      ref,
      request,
    ) async {
      ref.watch(extensionProvider.select(collectionSuggestionSourceKey));
      final extensions = ref.read(extensionProvider);
      final seeds = collectionSuggestionSeeds(
        request.tracks,
        round: request.round,
      );
      final source = collectionSuggestionSource(
        extensions,
        seeds,
        preferred: ref.watch(
          settingsProvider.select((s) => s.suggestionSource),
        ),
      );
      if (source == null) return CollectionSuggestions.empty;
      Future<CollectionSuggestions> load(CollectionSuggestionSource source) =>
          loadCollectionSuggestions(
            tracks: request.tracks,
            source: source,
            round: request.round,
            related: (extensionId, seeds, limit) =>
                PlatformBridge.getExtensionRelatedTracks(
                  extensionId,
                  seeds,
                  limit: limit,
                ),
            search: (extensionId, query) =>
                PlatformBridge.searchTracksWithMetadataProvider(
                  extensionId,
                  query,
                  limit: 15,
                ),
          );
      var suggestions = await load(source);
      // A chosen source with nothing to suggest falls back to the automatic
      // one, so the section (and its source button) stays on screen.
      final auto = collectionSuggestionSource(extensions, seeds);
      if (suggestions.tracks.isEmpty &&
          auto != null &&
          auto.extensionId != source.extensionId) {
        suggestions = await load(auto);
      }
      final link = ref.keepAlive();
      final timer = Timer(collectionSuggestionsKeepAlive, link.close);
      ref.onDispose(timer.cancel);
      return suggestions;
    });
