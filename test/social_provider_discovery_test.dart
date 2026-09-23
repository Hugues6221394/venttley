import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Why "Continue with Google" never appeared.
///
/// The button was gated on the google_sign_in feature flag, read through
/// flagEnabled(..., fallback: false). Flags come from my_feature_flags(),
/// which is GRANT EXECUTE ... TO authenticated — and the welcome screen is the
/// one place in the app with no session. A signed-out client gets
///
///   {"code":"42501","message":"permission denied for function my_feature_flags"}
///
/// so the flag map is null, the fallback wins, and the button is hidden. The
/// flag being switched on changed nothing, because it was never being read.
///
/// The provider list from /auth/v1/settings is unauthenticated by design and
/// answers the question the flag was standing in for. It also cannot drift:
/// turning Google off in Supabase removes the button on its own.
void main() {
  final welcome = File(
    'lib/presentation/screens/onboarding/welcome_screen.dart',
  ).readAsStringSync();

  test('the pre-auth button does not depend on a post-auth flag', () {
    expect(
      welcome,
      isNot(contains("flagEnabled(ref, 'google_sign_in'")),
      reason:
          'a signed-out client cannot read flags, so this is always the '
          'fallback — the button can never show',
    );
    expect(welcome, contains('enabledAuthProvidersProvider'));
    expect(welcome, contains("providers.contains('google')"));
  });

  test('provider discovery uses the unauthenticated settings endpoint', () {
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();

    expect(backend, contains('/auth/v1/settings'));
    expect(
      backend,
      contains("headers: {'apikey': VentlyConfig.supabaseAnonKey}"),
      reason: 'it has to work with no session, which is the whole point',
    );
    // A failed lookup must hide the button, not show a button that cannot
    // work. An empty set does that.
    expect(backend, contains('if (res.statusCode != 200) return const {};'));
  });

  test('other screens may still use flags', () {
    // The lesson is narrower than "flags are bad": a flag is fine wherever
    // there is a session. It is only pre-auth surfaces that cannot read one.
    final providers = File('lib/core/providers.dart').readAsStringSync();
    expect(providers, contains('bool flagEnabled('));
  });
}
