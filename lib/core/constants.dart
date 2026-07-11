/// Global compile-time constants for Venttly.
library;

class VentlyConfig {
  /// Live Supabase project. These are publishable / anon credentials and are
  /// safe to ship in the client — every table is protected by Row Level
  /// Security policies that key off `auth.uid()`.
  ///
  /// You can override them at build time with --dart-define to point the app
  /// at a different environment, e.g. staging:
  ///   flutter run --dart-define=SUPABASE_URL=https://staging.supabase.co \
  ///               --dart-define=SUPABASE_ANON_KEY=eyJ...
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://gyeibgaqrmnepbnfbtzc.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd5ZWliZ2Fxcm1uZXBibmZidHpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNDE0NzAsImV4cCI6MjA5NDcxNzQ3MH0.6fwanb3ZFLsTLR5ntJxZfspdumWgZFPPRywm5HajKOE',
  );

  /// Set to `true` (or pass --dart-define=USE_MOCK_BACKEND=true) to bypass the
  /// network and run against the in-memory seed dataset. Useful for offline
  /// development or running tests.
  static const bool _forceMock = bool.fromEnvironment(
    'USE_MOCK_BACKEND',
    defaultValue: false,
  );

  static bool get useMockBackend =>
      _forceMock || supabaseUrl.isEmpty || supabaseAnonKey.isEmpty;

  /// Tenor (Google) API key for the GIF picker in replies. Get a free key at
  /// https://developers.google.com/tenor/guides/quickstart and pass it at
  /// build time: --dart-define=TENOR_API_KEY=AIza...  When empty, the GIF
  /// picker shows a friendly "not configured" message instead of results.
  static const String tenorApiKey = String.fromEnvironment(
    'TENOR_API_KEY',
    defaultValue: '',
  );

  static bool get gifSearchEnabled => tenorApiKey.isNotEmpty;

  /// COPPA / FTC compliance — registration is hard-blocked under 13,
  /// users 13–17 are placed in a restricted safety tier.
  static const int minAge = 13;
  static const int restrictedMaxAge = 17;

  /// Sentry DSN — live for the Venttly project (EU region).
  /// Override at build time for staging or to disable in CI:
  ///   flutter run --dart-define=SENTRY_DSN=''            # no-op
  ///   flutter run --dart-define=SENTRY_DSN=https://other@…
  /// When the default is replaced by an empty string, Sentry init
  /// short-circuits in main.dart.
  static const String sentryDsn = String.fromEnvironment(
    'SENTRY_DSN',
    defaultValue:
        'https://2aceec425a13bf7b6e29350e4b700cb9@o4511605237284864.ingest.de.sentry.io/4511605242069072',
  );

  /// Build environment label surfaced to Sentry + app_events.
  static const String env = String.fromEnvironment(
    'VENTTLY_ENV',
    defaultValue: 'dev',
  );

  /// Sentry performance-trace sample rate. Low by default for cost control.
  static const String _sentryTracesRaw = String.fromEnvironment(
    'SENTRY_TRACES',
    defaultValue: '0.1',
  );
  static double get sentryTracesSampleRate =>
      double.tryParse(_sentryTracesRaw) ?? 0.1;

  /// Optional Groq API key used by the Tier-2 LlamaGuard moderation call.
  /// Pass at build time:
  ///   flutter run --dart-define=GROQ_API_KEY=gsk_...
  ///
  /// When empty, the moderation pipeline runs Tier-1 keyword scan only and
  /// the LLM step is skipped (safe-fail, not block-fail).
  static const String groqApiKey = String.fromEnvironment(
    'GROQ_API_KEY',
    defaultValue: '',
  );

  /// Groq chat model used for safety triage. The model is prompted to emit
  /// a strict JSON verdict so we can keep the moderation contract identical
  /// across whatever model Groq surfaces on the account. Override at build
  /// time when the plan changes:
  ///   flutter run --dart-define=GROQ_GUARD_MODEL=llama-3.3-70b-versatile
  static const String groqGuardModel = String.fromEnvironment(
    'GROQ_GUARD_MODEL',
    defaultValue: 'llama-3.3-70b-versatile',
  );

  // =========================================================================
  // Phase A — service env keys
  //
  // Every integration in the architecture spec is keyed off a single
  // --dart-define. When a key is empty the corresponding service falls
  // back to a no-op or the local Supabase implementation, so the app
  // runs identically in dev with zero external accounts.
  //
  // Build example:
  //   flutter run \
  //     --dart-define=POSTHOG_KEY=phc_... \
  //     --dart-define=POSTHOG_HOST=https://eu.posthog.com \
  //     --dart-define=UPSTASH_REDIS_REST_URL=https://… \
  //     --dart-define=UPSTASH_REDIS_REST_TOKEN=… \
  //     --dart-define=MEILISEARCH_HOST=https://… \
  //     --dart-define=MEILISEARCH_KEY=…
  // =========================================================================

  /// Clerk — identity provider. When unset, falls back to the existing
  /// Supabase Auth flows (anonymous username + email + recovery phrase).
  /// See docs/architecture.md → Auth migration.
  static const String clerkPublishableKey =
      String.fromEnvironment('CLERK_PUBLISHABLE_KEY', defaultValue: '');
  static const String clerkFrontendApi =
      String.fromEnvironment('CLERK_FRONTEND_API', defaultValue: '');

  /// PostHog — product analytics + feature flags.
  /// Project: Venttly (US Cloud, project id 480284).
  /// Override the key with --dart-define=POSTHOG_KEY='' to silence
  /// analytics in CI / mock runs.
  static const String posthogKey = String.fromEnvironment(
    'POSTHOG_KEY',
    defaultValue: 'phc_tDyuFaUpZvN2pp2xWssF5JvGtQUagY5FKhfJ2fEdSojZ',
  );
  static const String posthogHost = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://us.i.posthog.com',
  );

  /// Upstash Redis (REST). Used by CacheService for cross-process cache.
  /// When empty, CacheService stays in-memory-only.
  static const String upstashRedisRestUrl =
      String.fromEnvironment('UPSTASH_REDIS_REST_URL', defaultValue: '');
  static const String upstashRedisRestToken =
      String.fromEnvironment('UPSTASH_REDIS_REST_TOKEN', defaultValue: '');

  /// Meilisearch host + admin / search key. When empty, SearchService
  /// falls through to the Postgres `search_global` RPC.
  static const String meilisearchHost =
      String.fromEnvironment('MEILISEARCH_HOST', defaultValue: '');
  static const String meilisearchKey =
      String.fromEnvironment('MEILISEARCH_KEY', defaultValue: '');

  /// Resend — transactional email. Wired through the email-dispatcher
  /// edge function, never called from the client (so the API key stays
  /// server-side). The flag below tells the client whether to surface
  /// "we'll email you" copy.
  static const String resendFromAddress = String.fromEnvironment(
    'RESEND_FROM_ADDRESS',
    defaultValue: 'hello@venttly.app',
  );
  static const bool resendEnabled =
      bool.fromEnvironment('RESEND_ENABLED', defaultValue: false);

  /// Deep-link the OAuth (Google) flow returns to. Must be allow-listed in
  /// Supabase → Authentication → URL Configuration and registered as a native
  /// deep link (Android intent-filter / iOS URL scheme). Empty ⇒ let the SDK
  /// use its platform default. Example: 'rw.vently.vently_app://login-callback'.
  static const String oauthRedirectUrl =
      String.fromEnvironment('OAUTH_REDIRECT_URL', defaultValue: '');

  /// Whether to surface the optional Google / phone sign-in buttons. Off by
  /// default so the buttons only appear once their providers are configured.
  static const bool socialAuthEnabled =
      bool.fromEnvironment('SOCIAL_AUTH_ENABLED', defaultValue: true);

  /// Stripe — publishable key for the Flutter SDK. The secret key lives
  /// only in the payment-webhook edge function.
  static const String stripePublishableKey =
      String.fromEnvironment('STRIPE_PUBLISHABLE_KEY', defaultValue: '');

  /// Firebase Cloud Messaging. The client uses Firebase iOS/Android
  /// config files at build time (GoogleService-Info.plist /
  /// google-services.json) — this env var is just a feature flag to
  /// skip FCM init when no Firebase project is wired.
  static const bool fcmEnabled =
      bool.fromEnvironment('FCM_ENABLED', defaultValue: false);

  /// OpenTelemetry collector endpoint (Honeycomb / Tempo / Grafana).
  /// When empty, the OTEL exporter no-ops.
  static const String otelEndpoint =
      String.fromEnvironment('OTEL_ENDPOINT', defaultValue: '');
  static const String otelHeaders =
      String.fromEnvironment('OTEL_HEADERS', defaultValue: '');

  // Convenience getters — true only when the corresponding integration
  // has been provisioned in the ops dashboard.
  static bool get isClerkEnabled         => clerkPublishableKey.isNotEmpty;
  static bool get isPosthogEnabled       => posthogKey.isNotEmpty;
  static bool get isUpstashEnabled       => upstashRedisRestUrl.isNotEmpty &&
                                            upstashRedisRestToken.isNotEmpty;
  static bool get isMeilisearchEnabled   => meilisearchHost.isNotEmpty;
  static bool get isResendEnabled        => resendEnabled;
  static bool get isStripeEnabled        => stripePublishableKey.isNotEmpty;
  static bool get isFcmEnabled           => fcmEnabled;
  static bool get isOtelEnabled          => otelEndpoint.isNotEmpty;
  static bool get isSentryEnabled        => sentryDsn.isNotEmpty;
}

/// The eighteen + two emotional story channels.
class FeedCategories {
  static const List<String> all = [
    'confessions', 'testimonies', 'relationships', 'family_issues',
    'mental_health', 'campus_life', 'adulting', 'regrets', 'trauma',
    'friendship', 'faith_spirituality', 'questions', 'secrets', 'vent_zone',
    'dark_thoughts', 'funny_confessions', 'dreams_goals', 'hot_takes',
    'late_night', 'healing_corner',
  ];

  /// Categories that disable DM initiation to protect vulnerable users.
  static const Set<String> dmRestricted = {'confessions', 'trauma'};

  /// Categories that surface crisis helplines + heightened safety scans.
  static const Set<String> crisisAware = {'dark_thoughts', 'trauma', 'mental_health'};

  static String label(String key) {
    switch (key) {
      case 'family_issues':     return 'Family Issues';
      case 'mental_health':     return 'Mind & Mood';
      case 'campus_life':       return 'Campus Life';
      case 'faith_spirituality':return 'Faith & Beliefs';
      case 'vent_zone':         return 'Rant Room';
      case 'dark_thoughts':     return 'Late Thoughts';
      case 'funny_confessions': return 'Funny Moments';
      case 'dreams_goals':      return 'Dreams & Goals';
      case 'hot_takes':         return 'Hot Takes';
      case 'late_night':        return 'Late Night';
      case 'healing_corner':    return 'Glow Up';
      case 'testimonies':       return 'Stories';
      case 'relationships':     return 'Dating & Love';
      case 'trauma':            return 'Comebacks';
      case 'questions':         return 'Ask';
      case 'friendship':        return 'Connections';
      case 'adulting':          return 'Adulting';
      case 'regrets':           return 'Regrets';
      case 'secrets':           return 'Secrets';
      case 'confessions':       return 'Confessions';
      default:
        return key[0].toUpperCase() + key.substring(1);
    }
  }
}

/// Mood badges (kept in sync with the `mood_badge_type` enum in Postgres).
class Moods {
  static const List<String> all = [
    'sad', 'lonely', 'angry', 'confused', 'happy', 'healing', 'broken',
    'hopeful', 'exhausted', 'overthinking', 'anxious', 'grateful',
  ];

  static String label(String key) =>
      key[0].toUpperCase() + key.substring(1);

  static String emoji(String key) {
    switch (key) {
      case 'sad':           return '\u{1F622}';
      case 'lonely':        return '\u{1F494}';
      case 'angry':         return '\u{1F621}';
      case 'confused':      return '\u{1F615}';
      case 'happy':         return '\u{1F60A}';
      case 'healing':       return '\u{1F33F}';
      case 'broken':        return '\u{1F494}';
      case 'hopeful':       return '\u{2728}';
      case 'exhausted':     return '\u{1F635}';
      case 'overthinking':  return '\u{1F32A}';
      case 'anxious':       return '\u{1F630}';
      case 'grateful':      return '\u{1F64F}';
      default:              return '\u{1FAB7}';
    }
  }
}
