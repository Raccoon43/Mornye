import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/spotify_sync_service.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Opens Spotify's web player for the user to sign in to and pops with the
/// session the player sends with its own requests. The session is passed
/// back in memory only. Test build only.
class SpotifyWebLoginPage extends StatefulWidget {
  const SpotifyWebLoginPage({super.key});

  @override
  State<SpotifyWebLoginPage> createState() => _SpotifyWebLoginPageState();
}

const _loginUrl =
    'https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F';

// Watches the player's own fetch and XHR calls to its private API for the
// Bearer token and client token, then sends both once to the app. If no
// client token shows up within 30 s, the token goes alone.
const _hook = r'''
(function(){
  if (window.__mornyeHook) return; window.__mornyeHook = true;
  var tok = null, ct = null, sent = false;
  function send(){
    if (sent || !tok) return; sent = true;
    MornyeToken.postMessage(JSON.stringify({token: tok, clientToken: ct, ua: navigator.userAgent}));
  }
  setTimeout(send, 30000);
  function spotify(url){
    try { return /(^|\.)spotify\.com$/.test(new URL(url, location.href).hostname); } catch(e){ return false; }
  }
  function grab(url, k, v){
    if (typeof v !== 'string' || !spotify(url)) return;
    k = String(k).toLowerCase();
    if (k === 'authorization') { var m = /^Bearer\s+(\S+)$/i.exec(v); if (m) tok = m[1]; }
    else if (k === 'client-token' && v) ct = v;
    if (tok && ct) send();
  }
  function each(h, fn){
    if (!h) return;
    if (typeof Headers !== 'undefined' && h instanceof Headers) h.forEach(function(v, k){ fn(k, v); });
    else if (Array.isArray(h)) h.forEach(function(p){ fn(p[0], p[1]); });
    else for (var k in h) fn(k, h[k]);
  }
  var f = window.fetch;
  window.fetch = function(input, init){
    try {
      var isReq = typeof Request !== 'undefined' && input instanceof Request;
      var url = typeof input === 'string' ? input : (input && input.url) || String(input);
      var fn = function(k, v){ grab(url, k, v); };
      if (isReq) each(input.headers, fn);
      each(init && init.headers, fn);
    } catch(e){}
    return f.apply(this, arguments);
  };
  var open = XMLHttpRequest.prototype.open, set = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function(m, u){ this.__mornyeUrl = u; return open.apply(this, arguments); };
  XMLHttpRequest.prototype.setRequestHeader = function(k, v){ try { grab(this.__mornyeUrl, k, v); } catch(e){} return set.apply(this, arguments); };
})();
''';

class _SpotifyWebLoginPageState extends State<SpotifyWebLoginPage> {
  late final WebViewController _controller;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller =
        WebViewController(
            // The web player shows "Playback disabled" and loads nothing else
            // unless the WebView may use protected (DRM) media.
            onPermissionRequest: (request) =>
                request.types.every(
                  (t) =>
                      t ==
                      AndroidWebViewPermissionResourceType.protectedMediaId,
                )
                ? request.grant()
                : request.deny(),
          )
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
    if (_done) return;
    final Object? json;
    try {
      json = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (json is! Map) return;
    final token = json['token'];
    if (token is! String || token.length < 20 || token.contains(' ')) return;
    _done = true;
    final session = SpotifyWebSession(
      token: token,
      clientToken: json['clientToken'] as String?,
      userAgent: json['ua'] as String?,
    );
    if (mounted) Navigator.pop(context, session);
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
