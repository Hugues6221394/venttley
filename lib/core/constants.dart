/// Global compile-time constants for Vently.
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

  /// COPPA / FTC compliance — registration is hard-blocked under 13,
  /// users 13–17 are placed in a restricted safety tier.
  static const int minAge = 13;
  static const int restrictedMaxAge = 17;
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
      case 'mental_health':     return 'Mental Health';
      case 'campus_life':       return 'Campus Life';
      case 'faith_spirituality':return 'Faith & Beliefs';
      case 'vent_zone':         return 'Vent Zone';
      case 'dark_thoughts':     return 'Dark Thoughts';
      case 'funny_confessions': return 'Funny Moments';
      case 'dreams_goals':      return 'Dreams & Goals';
      case 'hot_takes':         return 'Hot Takes';
      case 'late_night':        return 'Late Night';
      case 'healing_corner':    return 'Healing Corner';
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
