import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/services/identity_service.dart';
import '../theme/colors.dart';

/// What we currently know about a handle somebody is typing.
enum UsernameStatus {
  /// Nothing typed yet, or too little to judge.
  idle,

  /// The shape is wrong, so there is no point asking the server.
  malformed,

  /// Asking.
  checking,

  free,
  taken,

  /// The lookup failed. Deliberately distinct from `taken`: a network blip
  /// must not tell somebody a name is gone when it is not.
  unknown,
}

/// Debounced availability lookups for one text field.
///
/// Debounced at 350ms rather than per keystroke: "Sar" is a prefix of a name
/// somebody is halfway through typing, and answering it costs a round trip to
/// tell them something they were not asking.
class UsernameAvailability extends ChangeNotifier {
  UsernameAvailability(this._ref);

  final Ref _ref;
  Timer? _debounce;
  String _pending = '';

  UsernameStatus _status = UsernameStatus.idle;
  UsernameStatus get status => _status;

  /// The handle the current [status] describes. Held so a late reply for an
  /// older handle can be dropped rather than shown against a newer one.
  String _describes = '';
  String get describes => _describes;

  void check(String raw) {
    final username = raw.trim();
    _pending = username;

    if (username.isEmpty) {
      _set(UsernameStatus.idle, username);
      return;
    }
    if (!IdentityService.usernamePattern.hasMatch(username)) {
      _set(UsernameStatus.malformed, username);
      return;
    }

    _set(UsernameStatus.checking, username);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _ask(username));
  }

  Future<void> _ask(String username) async {
    try {
      final free = await _ref.read(repositoryProvider).usernameAvailable(
        username,
      );
      // Typing moved on while we were waiting. Showing this would label a
      // handle with an answer about a different one.
      if (_pending != username) return;
      _set(free ? UsernameStatus.free : UsernameStatus.taken, username);
    } catch (_) {
      if (_pending != username) return;
      _set(UsernameStatus.unknown, username);
    }
  }

  void _set(UsernameStatus status, String username) {
    if (_status == status && _describes == username) return;
    _status = status;
    _describes = username;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final usernameAvailabilityProvider =
    ChangeNotifierProvider.autoDispose<UsernameAvailability>(
      UsernameAvailability.new,
    );

/// The tick, the cross, and the sentence beside them.
class UsernameAvailabilityHint extends StatelessWidget {
  const UsernameAvailabilityHint({
    super.key,
    required this.status,
    required this.username,
  });

  final UsernameStatus status;
  final String username;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (IconData? icon, Color colour, String text) = switch (status) {
      UsernameStatus.idle => (
        null,
        scheme.onSurface.withOpacity(0.6),
        'This is the name on your vents — and how you sign in next time.',
      ),
      UsernameStatus.malformed => (
        Icons.close_rounded,
        VentlyColors.dangerRed,
        '3–20 letters, numbers or underscores.',
      ),
      UsernameStatus.checking => (
        null,
        scheme.onSurface.withOpacity(0.6),
        'Checking…',
      ),
      UsernameStatus.free => (
        Icons.check_circle_rounded,
        VentlyColors.berryMagenta,
        '$username is yours.',
      ),
      UsernameStatus.taken => (
        Icons.close_rounded,
        VentlyColors.dangerRed,
        '$username is taken. Try another.',
      ),
      // Not "taken": a failed lookup must never tell somebody a name is gone
      // when it may not be. The insert is the real check and will say so.
      UsernameStatus.unknown => (
        null,
        scheme.onSurface.withOpacity(0.6),
        "Couldn't check that just now — you can still continue.",
      ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status == UsernameStatus.checking)
          const Padding(
            padding: EdgeInsets.only(top: 2, right: 7),
            child: SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
          )
        else if (icon != null) ...[
          Icon(icon, size: 14, color: colour),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: colour,
              fontWeight: status == UsernameStatus.free ||
                      status == UsernameStatus.taken
                  ? FontWeight.w700
                  : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}
