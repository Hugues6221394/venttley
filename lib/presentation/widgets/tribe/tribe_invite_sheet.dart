import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../theme/glass_tokens.dart';
import '../profile_avatar.dart';
import '../verified_badge.dart';

/// Invite people to a tribe by typing part of a name.
///
/// One sheet, used by both places a keeper can invite from. There were two
/// implementations before — a dialog on the members screen and a bottom sheet
/// in manage — and they had drifted: different labels, different error copy,
/// one of them silently dropping the personal note. Both asked for an exact
/// handle and looked it up on a button press, so getting a character wrong
/// produced "No user found with that username", which reads as "that person
/// does not exist".
///
/// Results arrive as you type. Somebody already in the tribe, or already
/// invited, is still listed — with the reason, rather than being hidden — so
/// the keeper can see they have already done it instead of sending an invite
/// that the unique constraint quietly swallows.
Future<void> showTribeInviteSheet(
  BuildContext context, {
  required String tribeId,
  required String tribeName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _TribeInviteSheet(tribeId: tribeId, tribeName: tribeName),
  );
}

class _TribeInviteSheet extends ConsumerStatefulWidget {
  const _TribeInviteSheet({required this.tribeId, required this.tribeName});

  final String tribeId;
  final String tribeName;

  @override
  ConsumerState<_TribeInviteSheet> createState() => _TribeInviteSheetState();
}

class _TribeInviteSheetState extends ConsumerState<_TribeInviteSheet> {
  final _search = TextEditingController();
  final _note = TextEditingController();
  String _query = '';
  bool _noteOpen = false;

  /// Who has been invited during this sitting. The server knows too, but the
  /// row must flip the instant it is tapped rather than after a refetch.
  final _justInvited = <String>{};
  final _sending = <String>{};

  @override
  void dispose() {
    _search.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _invite(TribeInviteCandidate person) async {
    setState(() => _sending.add(person.userId));
    final note = _note.text.trim();
    try {
      await ref
          .read(repositoryProvider)
          .inviteToTribe(
            tribeId: widget.tribeId,
            invitedUserId: person.userId,
            message: note.isEmpty ? null : note,
          );
      if (!mounted) return;
      setState(() {
        _sending.remove(person.userId);
        _justInvited.add(person.userId);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending.remove(person.userId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not invite @${person.pseudonym}.')),
      );
      debugPrint('inviteToTribe failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final results = ref.watch(
      tribeInviteCandidatesProvider((
        tribeId: widget.tribeId,
        query: _query,
      )),
    );

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withOpacity(0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Invite to ${widget.tribeName}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _search,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search by name or @handle',
                      prefixIcon: const Icon(Icons.person_search_outlined),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                      filled: true,
                      fillColor: GlassTokens.cardChip(context),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  // Folded away by default. It applies to every invite sent
                  // from this sheet, which is worth saying out loud rather
                  // than letting a keeper assume it is per person.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _noteOpen = !_noteOpen),
                      icon: Icon(
                        _noteOpen
                            ? Icons.expand_less_rounded
                            : Icons.edit_note_rounded,
                        size: 18,
                      ),
                      label: Text(
                        _noteOpen ? 'Hide note' : 'Add a note',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  if (_noteOpen)
                    TextField(
                      controller: _note,
                      maxLength: 160,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Sent with every invite from here',
                        counterText: '',
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: switch (results) {
                AsyncValue(hasValue: true, :final value?)
                    when value.isNotEmpty =>
                  ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                    itemCount: value.length,
                    itemBuilder: (context, i) => _CandidateRow(
                      person: value[i],
                      sending: _sending.contains(value[i].userId),
                      invited:
                          value[i].alreadyInvited ||
                          _justInvited.contains(value[i].userId),
                      onInvite: () => _invite(value[i]),
                    ),
                  ),
                AsyncValue(hasValue: true) => _Message(
                  icon: _query.trim().length < 2
                      ? Icons.keyboard_alt_outlined
                      : Icons.search_off_rounded,
                  text: _query.trim().length < 2
                      ? 'Type a couple of letters to find people.'
                      : 'Nobody matching "${_query.trim()}".',
                ),
                AsyncValue(:final error?) => _Message(
                  icon: Icons.error_outline_rounded,
                  text: _explain(error),
                ),
                _ => const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Postgres raises these as bare strings; the keeper should read something
  /// they can act on rather than a Postgrest exception.
  String _explain(Object error) {
    final text = error.toString();
    if (text.contains('rate_limited')) {
      return 'That was a lot of searching. Give it a moment.';
    }
    if (text.contains('not_the_keeper')) {
      return 'Only the keeper of this tribe can send invites.';
    }
    return 'Could not search right now.';
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.person,
    required this.sending,
    required this.invited,
    required this.onInvite,
  });

  final TribeInviteCandidate person;
  final bool sending;
  final bool invited;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = GlassTokens.onCardMuted(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: ProfileAvatar(
        avatarSeed: person.avatarSeed,
        label: person.pseudonym,
        profilePhotoUrl: person.profilePhotoUrl,
        size: 40,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              person.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (person.isVerified) ...[
            const SizedBox(width: 4),
            const VerifiedBadge(size: 14),
          ],
          if (person.isFriend) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Friend',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '@${person.pseudonym}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: muted),
      ),
      trailing: _trailing(context, muted),
    );
  }

  Widget _trailing(BuildContext context, Color muted) {
    if (sending) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    // Members and people already asked stay in the list. Hiding them would
    // leave a keeper searching for somebody they cannot find and concluding
    // the search is broken.
    if (person.alreadyMember) {
      return Text(
        'Member',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: muted),
      );
    }
    if (invited) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_rounded, size: 15, color: VentlyColors.berryMagenta),
          const SizedBox(width: 4),
          Text(
            'Invited',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: VentlyColors.berryMagenta,
            ),
          ),
        ],
      );
    }
    return FilledButton(
      onPressed: onInvite,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      child: const Text('Invite'),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.onCardMuted(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: muted),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
