import 'dart:async';

import '../../core/constants.dart';
import '../../core/logger.dart';
import '../../domain/entities/entities.dart';
import 'supabase_backend.dart';

/// Abstract identity provider.
///
/// Today every call site uses Supabase Auth directly (via
/// SupabaseBackend.signUp / signIn / signUpWithEmail). Wrapping those
/// behind an interface lets us swap to Clerk (or any other provider)
/// later without changing repo or UI code.
///
/// Implementations:
///   * [_SupabaseAuthProvider] — the existing flows (username + email
///                               + recovery phrase). Default until
///                               `CLERK_PUBLISHABLE_KEY` is set.
///   * `_ClerkAuthProvider`   — to be wired when Clerk is provisioned.
///                               When live, Clerk owns identity and
///                               we still sync to Supabase on first
///                               sign-in (clerk_user_id → users row).
abstract class AuthProvider {
  static AuthProvider? _instance;
  static AuthProvider instance({SupabaseBackend? supabase}) {
    final existing = _instance;
    if (existing != null) return existing;
    if (VentlyConfig.isClerkEnabled) {
      log.warn(
        'auth.clerk_not_implemented',
        props: {'fallback': 'supabase'},
      );
    }
    _instance = _SupabaseAuthProvider(supabase);
    return _instance!;
  }

  String get name; // 'supabase' | 'clerk'

  Future<AuthOutcome> signUpAnonymous({
    required String username,
    required String password,
    required String avatarSeed,
    required DateTime birthDate,
  });

  Future<AuthOutcome> signUpEmail({
    required String email,
    required String password,
    required String username,
    required String avatarSeed,
    required DateTime birthDate,
  });

  Future<AppUser> signIn({
    required String username,
    required String password,
  });

  Future<AppUser> signInEmail({
    required String email,
    required String password,
  });

  Future<void> signOut();
}

class AuthOutcome {
  final AppUser? user;             // null when email verification pending
  final String? recoveryPhrase;    // null on email-only flows
  final bool emailConfirmationPending;
  const AuthOutcome({
    this.user,
    this.recoveryPhrase,
    this.emailConfirmationPending = false,
  });
}

class _SupabaseAuthProvider implements AuthProvider {
  _SupabaseAuthProvider(this._supabase);
  final SupabaseBackend? _supabase;

  @override
  String get name => 'supabase';

  SupabaseBackend get _live {
    final s = _supabase;
    if (s == null) throw StateError('Supabase backend not initialised');
    return s;
  }

  // Notes: these methods are intentionally thin. The heavy lifting
  // (sealing the recovery phrase, persisting session metadata, etc)
  // happens in VentlyRepository.registerAccount / registerAccountWithEmail
  // — this provider just exposes the surface for the future Clerk swap.

  @override
  Future<AuthOutcome> signUpAnonymous({
    required String username,
    required String password,
    required String avatarSeed,
    required DateTime birthDate,
  }) async {
    throw UnimplementedError(
        'Use VentlyRepository.registerAccount — the recovery-phrase '
        'pipeline lives there. This provider exposes the surface that '
        'a Clerk implementation will replace.');
  }

  @override
  Future<AuthOutcome> signUpEmail({
    required String email,
    required String password,
    required String username,
    required String avatarSeed,
    required DateTime birthDate,
  }) async {
    throw UnimplementedError(
        'Use VentlyRepository.registerAccountWithEmail.');
  }

  @override
  Future<AppUser> signIn({
    required String username,
    required String password,
  }) =>
      _live.signIn(username: username, password: password);

  @override
  Future<AppUser> signInEmail({
    required String email,
    required String password,
  }) =>
      _live.signInWithEmail(email: email, password: password);

  @override
  Future<void> signOut() => _live.logout();
}
