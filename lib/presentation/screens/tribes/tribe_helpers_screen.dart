import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// What the signed-in account may do in a given Tribe.
///
/// Every screen that shows a management control should ask this first. Hiding
/// a control is only a courtesy — the server re-checks each action — but
/// offering a button that always fails is its own kind of broken.
final myTribePermissionsProvider =
    FutureProvider.family<List<String>, String>((ref, tribeId) async {
  return ref.read(repositoryProvider).myTribePermissions(tribeId);
});

final tribePermissionGrantsProvider =
    FutureProvider.family<TribePermissionGrants, String>((ref, tribeId) async {
  return ref.read(repositoryProvider).tribePermissionGrants(tribeId);
});

/// The Keeper's screen for handing out individual capabilities.
///
/// Deliberately Keeper-only and deliberately not delegable: someone who could
/// grant permissions could grant themselves the rest, and then every other
/// boundary in the Tribe would be decorative.
class TribeHelpersScreen extends ConsumerWidget {
  const TribeHelpersScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(tribeBySlugProvider(slug)).valueOrNull;
    final me = ref.watch(sessionProvider);

    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Helpers')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'Only the Keeper can decide who helps run this Tribe.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }

    final grants = ref.watch(tribePermissionGrantsProvider(tribe.tribeId));

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Helpers',
            style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: VentlyPremiumBackground(
        child: grants.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Text(UserFriendlyErrors.message(error),
                  textAlign: TextAlign.center),
            ),
          ),
          data: (data) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
            children: [
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Share the load, not the keys',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Give someone exactly the job you want them to do. '
                      'Deleting this Tribe, handing it to someone else, '
                      'pausing it and choosing helpers stay with you — no '
                      'helper can reach any of that.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: context.ink.withOpacity(.72),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (data.helpers.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      Icon(Icons.group_outlined,
                          size: 34, color: context.ink.withOpacity(.3)),
                      const SizedBox(height: 10),
                      const Text(
                        'No helpers yet',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Promote someone from the members list, then choose '
                        'what they can do here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: context.ink.withOpacity(.65),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final helper in data.helpers) ...[
                  _HelperCard(
                    tribeId: tribe.tribeId,
                    helper: helper,
                    catalog: data.catalog,
                  ),
                  const SizedBox(height: 12),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HelperCard extends ConsumerStatefulWidget {
  const _HelperCard({
    required this.tribeId,
    required this.helper,
    required this.catalog,
  });

  final String tribeId;
  final TribeHelper helper;
  final List<TribePermissionOption> catalog;

  @override
  ConsumerState<_HelperCard> createState() => _HelperCardState();
}

class _HelperCardState extends ConsumerState<_HelperCard> {
  late Set<String> _selected = widget.helper.permissions.toSet();
  bool _saving = false;

  bool get _dirty =>
      !_setsMatch(_selected, widget.helper.permissions.toSet());

  static bool _setsMatch(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).setTribeMemberPermissions(
            widget.tribeId,
            widget.helper.userId,
            _selected.toList(),
          );
      ref.invalidate(tribePermissionGrantsProvider(widget.tribeId));
      ref.invalidate(myTribePermissionsProvider(widget.tribeId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _selected.isEmpty
                ? '@${widget.helper.pseudonym} is a regular member again.'
                : '@${widget.helper.pseudonym} can now help with '
                    '${_selected.length} thing${_selected.length == 1 ? '' : 's'}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(UserFriendlyErrors.message(error))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfileAvatar(
                avatarSeed: widget.helper.avatarSeed ?? '',
                label: widget.helper.pseudonym,
                size: 34,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('@${widget.helper.pseudonym}',
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                    Text(
                      _selected.isEmpty
                          ? 'No permissions'
                          : '${_selected.length} of ${widget.catalog.length}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: context.ink.withOpacity(.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final option in widget.catalog)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _selected.contains(option.key),
              onChanged: _saving
                  ? null
                  : (on) => setState(() {
                        if (on == true) {
                          _selected.add(option.key);
                        } else {
                          _selected.remove(option.key);
                        }
                      }),
              title: Text(option.label,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w800)),
              subtitle: Text(
                option.description,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.3,
                  color: context.ink.withOpacity(.65),
                ),
              ),
            ),
          if (_dirty)
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _selected.isEmpty ? 'Remove as helper' : 'Save',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
