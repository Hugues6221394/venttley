import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/user_friendly_errors.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';

/// The 18+ check that stands in front of Tribe creation.
///
/// Creating a Tribe hands someone authority over a space that 13–17 year olds
/// use, so the floor is real. But a floor is not an excuse for a bad moment:
/// the person on the other side is usually an adult who simply wants to start a
/// community, and they should not be made to feel accused.
///
/// Three shapes, because three genuinely different things are happening:
///
///   adult          → nothing at all. No dialog, no confirmation, no friction.
///   month_required → one question, asked once, with the reason stated plainly.
///   minor          → a clear no, without shaming, and without pretending the
///                    decision is negotiable.
///
/// Asked *before* the flow opens. Discovering at submit time that you were
/// never allowed to do this — after filling in a name, a description, rules and
/// an avatar — is the version of this that makes people give up on a product.
///
/// The answer is the server's; nothing here decides anything. A modified client
/// that skips this sheet still gets `adults_only` from create_managed_tribe.
Future<bool> ensureCanCreateTribe(BuildContext context, WidgetRef ref) async {
  TribeCreationEligibility eligibility;
  try {
    eligibility = await ref.read(repositoryProvider).tribeCreationEligibility();
  } catch (e) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          UserFriendlyErrors.message(
            e,
            fallback: "Couldn't check this right now. Please try again.",
          ),
        ),
      ),
    );
    return false;
  }

  if (eligibility.canCreate) return true;
  if (!context.mounted) return false;

  if (eligibility.needsBirthMonth) {
    final result = await showModalBottomSheet<bool>(
      context: context,
      // Above the shell: its nav pill is painted over the branch and would
      // otherwise swallow this sheet's own buttons.
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => const _BirthMonthSheet(),
    );
    return result ?? false;
  }

  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (_) => const _AdultsOnlySheet(),
  );
  return false;
}

class _AdultsOnlySheet extends StatelessWidget {
  const _AdultsOnlySheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.shield_outlined,
              color: VentlyColors.berryMagenta,
              size: 30,
            ),
            const SizedBox(height: 12),
            Text(
              'Tribes are kept by adults',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 20,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 8),
            // Says why, not just no. And it is careful not to imply the person
            // did something wrong: they are welcome here, this one role is not
            // open to them yet.
            Text(
              'Keeping a Tribe means looking after other people, including '
              'members who are under 18. We hold that to 18 and over.\n\n'
              'Everything else is yours as normal — vents, whispers, friends, '
              'chats, and joining any Tribe you like.',
              style: TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: context.ink.withOpacity(0.75),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: FilledButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Got it',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One question for the one cohort that needs it.
class _BirthMonthSheet extends ConsumerStatefulWidget {
  const _BirthMonthSheet();

  @override
  ConsumerState<_BirthMonthSheet> createState() => _BirthMonthSheetState();
}

class _BirthMonthSheetState extends ConsumerState<_BirthMonthSheet> {
  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  int? _month;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final month = _month;
    if (month == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(repositoryProvider)
          .setMyBirthMonth(month + 1);
      if (!mounted) return;
      if (result.canCreate) {
        Navigator.of(context).pop(true);
        return;
      }
      // Answered honestly and is not 18 yet. Say so here rather than letting
      // them walk into the flow and be refused at the end.
      setState(() {
        _busy = false;
        _error =
            "Thanks — looks like you'll turn 18 later this year. "
            'You can create a Tribe once your birthday has passed.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = UserFriendlyErrors.message(
          e,
          fallback: "Couldn't save that. Please try again.",
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quick check before you start',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 20,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 8),
            // The reason is stated because being asked for personal detail
            // without one is what makes a form feel invasive. And the limit is
            // stated too — a month, never a full date.
            Text(
              'Keeping a Tribe is for 18 and over. We know your birth year, '
              'which puts you right on the line this year — so which month '
              'were you born?\n\n'
              'Just the month. We never ask for the day.',
              style: TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: context.ink.withOpacity(0.75),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _months.length; i++)
                  ChoiceChip(
                    label: Text(_months[i].substring(0, 3)),
                    selected: _month == i,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _month = i),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: const TextStyle(
                  color: VentlyColors.dangerRed,
                  fontSize: 13.5,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Not now',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      // Disabled until a month is chosen: a submit that can
                      // only fail is a worse answer than a button that waits.
                      onPressed: (_month == null || _busy) ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: VentlyColors.berryMagenta,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Continue',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
