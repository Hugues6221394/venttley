import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/colors.dart';

/// Cloudflare Turnstile, obtained in a WebView because there is no native SDK.
///
/// Turnstile is the free control standing between this app's sign-in endpoint
/// and unlimited password guessing. Supabase enforces it server-side: with
/// CAPTCHA switched on, a sign-in carrying no token is refused before the
/// password is ever checked.
///
/// THE RISK THIS CARRIES
///
/// Enforcement is fail-closed by design, and Turnstile inside a WebView is
/// documented as fragile — it needs JavaScript, DOM storage, third-party
/// cookies, and a reachable challenges.cloudflare.com. On a poor connection
/// none of that is guaranteed. For an app people open when they are struggling,
/// "the security widget did not load so you cannot reach your account" is a
/// serious failure, not an inconvenience.
///
/// So this is built to be honest about failing rather than to hide it:
///   * [siteKey] empty means the gate is off and callers get null. Shipping the
///     client before enabling enforcement is therefore completely safe.
///   * A timeout, so a widget that never resolves cannot hang the sign-in
///     button forever.
///   * Failure surfaces a retry and a way out, never a dead end.
class TurnstileGate {
  const TurnstileGate._();

  /// Public identifier. Safe in the binary — Cloudflare's secret half lives in
  /// Supabase and never ships here.
  static const String siteKey = String.fromEnvironment(
    'TURNSTILE_SITE_KEY',
    defaultValue: '0x4AAAAAAEiOfBhV7zbkY4Ie',
  );

  /// Turn the gate on only once tokens are known to be arriving. Kept separate
  /// from [siteKey] so the key can ship inert and be switched on without
  /// another release cutting anyone off.
  static const bool enabled = bool.fromEnvironment(
    'TURNSTILE_ENABLED',
    defaultValue: false,
  );

  static bool get isConfigured => enabled && siteKey.trim().isNotEmpty;

  /// A token for one sign-in or sign-up attempt, or null if the gate is off.
  ///
  /// Throws [TurnstileUnavailable] when the gate is on and no token could be
  /// obtained, so the caller can say something true rather than sending an
  /// attempt that the server will reject for reasons the person cannot see.
  static Future<String?> token(
    BuildContext context, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isConfigured) return null;

    final result = await showModalBottomSheet<_TurnstileResult>(
      context: context,
      isDismissible: true,
      // The shell paints its floating nav over anything a branch puts near the
      // bottom of the screen.
      useRootNavigator: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _TurnstileSheet(siteKey: siteKey, timeout: timeout),
    );

    if (result == null) return null; // dismissed — treated as "not now"
    if (result.token != null) return result.token;
    throw TurnstileUnavailable(result.error ?? 'turnstile_failed');
  }
}

/// The check could not be completed. Distinct from a rejected password so the
/// UI can offer a retry instead of implying the credentials were wrong.
class TurnstileUnavailable implements Exception {
  const TurnstileUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'TurnstileUnavailable($reason)';
}

class _TurnstileResult {
  const _TurnstileResult({this.token, this.error});
  final String? token;
  final String? error;
}

class _TurnstileSheet extends StatefulWidget {
  const _TurnstileSheet({required this.siteKey, required this.timeout});

  final String siteKey;
  final Duration timeout;

  @override
  State<_TurnstileSheet> createState() => _TurnstileSheetState();
}

class _TurnstileSheetState extends State<_TurnstileSheet> {
  late final WebViewController _controller;
  Timer? _deadline;
  bool _settled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'Turnstile',
        onMessageReceived: (message) => _handle(message.message),
      )
      // baseUrl matters: Turnstile validates the origin it is rendered from,
      // and an about:blank origin is rejected. This must match a hostname
      // listed on the widget in the Cloudflare dashboard.
      ..loadHtmlString(_html(widget.siteKey), baseUrl: 'https://venttly.app');

    _deadline = Timer(widget.timeout, () {
      if (!mounted || _settled) return;
      _finish(const _TurnstileResult(error: 'timeout'));
    });
  }

  void _handle(String raw) {
    if (_settled) return;
    try {
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      final token = payload['token'] as String?;
      if (token != null && token.isNotEmpty) {
        _finish(_TurnstileResult(token: token));
        return;
      }
      setState(() => _error = (payload['error'] as String?) ?? 'failed');
    } catch (_) {
      setState(() => _error = 'unreadable_response');
    }
  }

  void _finish(_TurnstileResult result) {
    if (_settled || !mounted) return;
    _settled = true;
    _deadline?.cancel();
    Navigator.of(context).pop(result);
  }

  void _retry() {
    setState(() => _error = null);
    _controller.loadHtmlString(
      _html(widget.siteKey),
      baseUrl: 'https://venttly.app',
    );
  }

  @override
  void dispose() {
    _deadline?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withOpacity(.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Quick check',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              'This keeps automated attacks off other people\'s accounts. '
              'It usually passes on its own.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withOpacity(.7),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 90,
              child: _error == null
                  ? WebViewWidget(controller: _controller)
                  : const SizedBox.shrink(),
            ),
            if (_error != null) ...[
              Text(
                'The check could not load. That is usually the connection, '
                'not you.',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: VentlyColors.berryMagenta,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton(
                    onPressed: _retry,
                    child: const Text('Try again'),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: () => _finish(_TurnstileResult(error: _error)),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Rendered explicitly rather than with the auto-render attribute so the
  /// callbacks are wired before the widget can fire, and every outcome —
  /// success, error, expiry — comes back through one channel.
  static String _html(String siteKey) =>
      '''
<!doctype html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer></script>
    <style>
      html,body { margin:0; padding:0; background:transparent; }
      #box { display:flex; justify-content:center; padding-top:4px; }
    </style>
  </head>
  <body>
    <div id="box"></div>
    <script>
      function send(payload) {
        try { Turnstile.postMessage(JSON.stringify(payload)); } catch (e) {}
      }
      window.onloadTurnstileCallback = function () {
        try {
          window.turnstile.render('#box', {
            sitekey: '$siteKey',
            callback: function (t) { send({ token: t }); },
            'error-callback': function (e) { send({ error: String(e || 'error') }); },
            'expired-callback': function () { send({ error: 'expired' }); },
            'timeout-callback': function () { send({ error: 'timeout' }); }
          });
        } catch (e) { send({ error: 'render_failed' }); }
      };
      // The script tag is async; if it never arrives, say so rather than
      // leaving a blank box that looks like the app has hung.
      setTimeout(function () {
        if (!window.turnstile) send({ error: 'script_unreachable' });
      }, 12000);
    </script>
  </body>
</html>
''';
}
