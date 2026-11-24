import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/screens/settings/spotify_web_login_page.dart';
import 'package:mornye/services/spotify_sync_service.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Connects through the user's Spotify web player session and mirrors chosen
/// playlists into library playlists. Test build only: opt-in behind a
/// warning about Spotify's terms.
class SpotifySyncPage extends ConsumerStatefulWidget {
  const SpotifySyncPage({super.key});

  @override
  ConsumerState<SpotifySyncPage> createState() => _SpotifySyncPageState();
}

const _acceptedKey = 'spotify_web_sync_accepted';

class _SpotifySyncPageState extends ConsumerState<SpotifySyncPage> {
  bool _busy = false;
  List<SpotifyPlaylist>? _playlists;
  final _syncing = <String>{};

  @override
  void initState() {
    super.initState();
    if (spotifySyncService.isConnected) unawaited(_run(_load));
  }

  void _toast(String message) =>
      showAppSnackBar(context, content: Text(message));

  String _message(Object error) => error is SpotifySyncException
      ? error.message
      : context.friendlyError(error);

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _toast(_message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final playlists = await spotifySyncService.playlists();
    if (mounted) setState(() => _playlists = playlists);
  }

  Future<bool> _accepted() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_acceptedKey) ?? false) return true;
    if (!mounted) return false;
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.spotifySyncRiskTitle),
        content: Text(l10n.spotifySyncRiskBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.spotifySyncRiskAccept),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    await prefs.setBool(_acceptedKey, true);
    return true;
  }

  Future<void> _connect() async {
    if (!await _accepted() || !mounted) return;
    final token = await pushPage<String>(
      context,
      (_) => const SpotifyWebLoginPage(),
    );
    if (token == null || !mounted) return;
    spotifySyncService.connect(token);
    await _run(_load);
  }

  Future<void> _disconnect() async {
    spotifySyncService.disconnect();
    await WebViewCookieManager().clearCookies();
    if (mounted) setState(() => _playlists = null);
  }

  Future<void> _sync(SpotifyPlaylist playlist) async {
    // The container outlives this page if the user leaves mid-sync.
    final container = ProviderScope.containerOf(context, listen: false);
    final notifier = container.read(libraryCollectionsProvider.notifier);
    setState(() => _syncing.add(playlist.id));
    try {
      final added = await spotifySyncService.sync(
        playlist,
        exists: (id) async {
          await notifier.ensurePlaylistLoaded(id);
          return container.read(libraryCollectionsProvider).playlistById(id) !=
              null;
        },
        create: notifier.createPlaylist,
        add: (id, tracks) async =>
            (await notifier.addTracksToPlaylist(id, tracks)).addedCount,
      );
      if (mounted) _toast(context.l10n.spotifySyncDone(playlist.name, added));
    } catch (error) {
      if (mounted) _toast(_message(error));
    } finally {
      if (mounted) setState(() => _syncing.remove(playlist.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final playlists = _playlists;
    final connected = spotifySyncService.isConnected;
    const spinner = AppLoadingIndicator(size: 18, strokeWidth: 2);
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.spotifySyncTitle),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.info_outline_rounded,
                  title: l10n.spotifySyncSubtitle,
                  subtitle: l10n.spotifySyncRiskBody,
                ),
                if (connected)
                  SettingsItem(
                    icon: Icons.logout_rounded,
                    title: l10n.spotifySyncDisconnect,
                    trailing: _busy ? spinner : null,
                    onTap: _busy ? null : _disconnect,
                  )
                else
                  SettingsItem(
                    icon: Icons.login_rounded,
                    title: l10n.spotifySyncConnect,
                    trailing: _busy ? spinner : null,
                    onTap: _busy ? null : _connect,
                  ),
              ],
            ),
          ),
          if (connected) ...[
            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: l10n.spotifySyncPlaylists),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsItem(
                    icon: Icons.playlist_add_check_rounded,
                    title: l10n.spotifySyncHint,
                  ),
                  if (playlists != null && playlists.isEmpty)
                    SettingsItem(title: l10n.spotifySyncEmpty),
                  for (final p in playlists ?? const <SpotifyPlaylist>[])
                    SettingsItem(
                      icon: Icons.queue_music_rounded,
                      title: p.name,
                      subtitle: l10n.spotifySyncSongs(p.trackCount),
                      trailing: _syncing.contains(p.id)
                          ? spinner
                          : const Icon(Icons.sync_rounded),
                      onTap: _syncing.contains(p.id) ? null : () => _sync(p),
                    ),
                ],
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}
