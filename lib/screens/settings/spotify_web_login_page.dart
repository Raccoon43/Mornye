import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Opens Spotify's web player for the user to sign in to and pops with the
/// access token the player sends with its own requests. The token is passed
/// back in memory only. Test build only.
class SpotifyWebLoginPage extends StatefulWidget {
  const SpotifyWebLoginPage({super.key});

  @override
  State<SpotifyWebLoginPage> createState() => _SpotifyWebLoginPageState();
}

const _loginUrl =
    'https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F';

// Watches the player's own fetch and XHR calls for its Bearer token, sends
// it once to the app, then opens Your Library so the player makes a call.
const _hook = r'''
(function(){
  if (window.__mornyeHook) return; window.__mornyeHook = true;
  var sent = false;
  function grab(url, value){
    if (sent || typeof value !== 'string') return;
    var m = /^Bearer\s+(\S+)$/i.exec(value); if (!m) return;
    try { var h = new URL(url, location.href).hostname; if (!/(^|\.)spotify\.com$/.test(h)) return; } catch(e){ return; }
    sent = true; MornyeToken.postMessage(m[1]);
  }
  function scan(url, headers){
    if (!headers) return;
    if (typeof Headers !== 'undefined' && headers instanceof Headers) { grab(url, headers.get('authorization')); return; }
    if (Array.isArray(headers)) { headers.forEach(function(p){ if (p && String(p[0]).toLowerCase()==='authorization') grab(url, p[1]); }); return; }
    for (var k in headers) if (k.toLowerCase()==='authorization') grab(url, headers[k]);
  }
  var f = window.fetch;
  window.fetch = function(input, init){
    try {
      var url = typeof input === 'string' ? input : (input && input.url) || String(input);
      if (input && typeof input === 'object' && input.headers) scan(url, input.headers);
      if (init) scan(url, init.headers);
    } catch(e){}
    return f.apply(this, arguments);
  };
  var open = XMLHttpRequest.prototype.open, set = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function(m, u){ this.__mornyeUrl = u; return open.apply(this, arguments); };
  XMLHttpRequest.prototype.setRequestHeader = function(k, v){ try { if (String(k).toLowerCase()==='authorization') grab(this.__mornyeUrl, v); } catch(e){} return set.apply(this, arguments); };
  try { history.pushState({}, '', '/collection/playlists'); dispatchEvent(new PopStateEvent('popstate')); } catch(e){}
})();
''';

class _SpotifyWebLoginPageState extends State<SpotifyWebLoginPage> {
  late final WebViewController _controller;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // No user-agent override: a desktop UA clashes with the WebView's
      // Android client hints and Spotify's login check rejects it.
      ..addJavaScriptChannel('MornyeToken', onMessageReceived: _onToken)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Keep spotify: and intent:// links from leaving the app.
          onNavigationRequest: (request) {
            final scheme = Uri.tryParse(request.url)?.scheme;
            return scheme == 'http' || scheme == 'https'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (url) {
            if (Uri.tryParse(url)?.host == 'open.spotify.com') {
              _controller.runJavaScript(_hook).ignore();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_loginUrl));
    // The login check runs in third-party iframes that need their cookies.
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      ).setAcceptThirdPartyCookies(platform, true).ignore();
    }
  }

  void _onToken(JavaScriptMessage message) {
    final token = message.message;
    if (_done || token.length < 20 || token.contains(RegExp(r'\s'))) return;
    _done = true;
    if (mounted) Navigator.pop(context, token);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.spotifySyncConnect)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              context.l10n.spotifySyncLoginHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
