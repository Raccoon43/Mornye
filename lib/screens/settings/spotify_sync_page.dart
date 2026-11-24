import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/spotify_sync_service.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Logs in with the user's own Spotify app and mirrors chosen playlists into
/// library playlists.
class SpotifySyncPage extends ConsumerStatefulWidget {
  const SpotifySyncPage({super.key});

  @override
  ConsumerState<SpotifySyncPage> createState() => _SpotifySyncPageState();
}

class _SpotifySyncPageState extends ConsumerState<SpotifySyncPage> {
  final _clientId = TextEditingController();
  bool _loggedIn = false;
  bool _busy = false;
  List<SpotifyPlaylist>? _playlists;
  final _syncing = <String>{};

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _clientId.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _clientId.text = await spotifySyncService.clientId() ?? '';
    final loggedIn = await spotifySyncService.isLoggedIn();
    if (!mounted) return;
    setState(() => _loggedIn = loggedIn);
    if (loggedIn) await _run(_load);
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

  Future<void> _login() => _run(() async {
    await spotifySyncService.login(_clientId.text);
    if (!mounted) return;
    setState(() => _loggedIn = true);
    await _load();
  });

  Future<void> _logout() async {
    await spotifySyncService.logout();
    if (!mounted) return;
    setState(() {
      _loggedIn = false;
      _playlists = null;
    });
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
    const spinner = AppLoadingIndicator(size: 18, strokeWidth: 2);
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.spotifySyncTitle),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: l10n.spotifySyncSetup),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.info_outline_rounded,
                  title: l10n.spotifySyncSubtitle,
                  subtitle: l10n.spotifySyncSetupSteps,
                ),
                SettingsItem(
                  icon: Icons.link_rounded,
                  title: l10n.spotifySyncRedirect,
                  subtitle: spotifySyncRedirect,
                  onTap: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: spotifySyncRedirect),
                    );
                    if (context.mounted) _toast(l10n.spotifySyncCopied);
                  },
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: AppTextField(
                controller: _clientId,
                label: l10n.spotifySyncClientId,
                autocorrect: false,
                textInputAction: TextInputAction.done,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                if (_loggedIn)
                  SettingsItem(
                    icon: Icons.logout_rounded,
                    title: l10n.spotifySyncLogout,
                    trailing: _busy ? spinner : null,
                    onTap: _busy ? null : _logout,
                  )
                else
                  SettingsItem(
                    icon: Icons.login_rounded,
                    title: l10n.spotifySyncLogin,
                    trailing: _busy ? spinner : null,
                    onTap: _busy ? null : _login,
                  ),
              ],
            ),
          ),
          if (_loggedIn) ...[
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
                      subtitle: p.canSync
                          ? l10n.spotifySyncSongs(p.trackCount)
                          : l10n.spotifySyncNotOwned,
                      trailing: _syncing.contains(p.id)
                          ? spinner
                          : p.canSync
                          ? const Icon(Icons.sync_rounded)
                          : null,
                      onTap: p.canSync && !_syncing.contains(p.id)
                          ? () => _sync(p)
                          : null,
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
