import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/blocked_accounts_sheet.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/user_link.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/verified_badge.dart';

/// Friends — Image #15.
///
/// Surface stack (top → bottom):
///   1. Brand header (menu / "Venttly" magenta wordmark / bell)
///   2. Instant Connect card (Share Link + My QR sheet)
///   3. Friend Requests section (Accept / Ignore w/ Mutual Tribes + dot)
///   4. Quick Suggestions strip — friend_suggestions RPC
///   5. My Friends (N) — searchable, alphabetically grouped, ··· menu,
///      heart toggle backed by toggle_friend_favorite RPC
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(myFriendsProvider);
    ref.invalidate(incomingFriendRequestsProvider);
    ref.invalidate(outgoingFriendRequestsProvider);
    ref.invalidate(friendSuggestionsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider);
    final friendsAsync = ref.watch(myFriendsProvider);
    final incoming = ref.watch(incomingFriendRequestsProvider).valueOrNull ??
        const <FriendRequest>[];
    final suggestionsAsync = ref.watch(friendSuggestionsProvider);

    final filteredFriends =
        _applyQuery(friendsAsync.valueOrNull ?? const [], _query.text);
    final grouped = _groupAlphabetically(filteredFriends);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
          onRefresh: _refresh,
          color: VentlyColors.berryMagenta,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: _FriendsHeader(onMenu: () => _openMoreSheet(context)),
              ),
              SliverToBoxAdapter(
                child: _InstantConnectCard(me: me),
              ),
              if (incoming.isNotEmpty)
                SliverToBoxAdapter(
                  child: _RequestsSection(incoming: incoming),
                ),
              SliverToBoxAdapter(
                child: _QuickSuggestionsSection(async: suggestionsAsync),
              ),
              SliverToBoxAdapter(
                child: _MyFriendsHeader(
                  total: friendsAsync.valueOrNull?.length ?? 0,
                  query: _query,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (friendsAsync.isLoading && friendsAsync.valueOrNull == null)
                const SliverToBoxAdapter(child: _ListSkeleton())
              else if (filteredFriends.isEmpty)
                SliverToBoxAdapter(
                  child: _EmptyState(
                    icon: Icons.diversity_3_rounded,
                    title: friendsAsync.valueOrNull?.isEmpty ?? true
                        ? 'No friends yet.'
                        : 'No matches.',
                    body: friendsAsync.valueOrNull?.isEmpty ?? true
                        ? 'Share your link, scan a QR, or pick a Quick Suggestion above.'
                        : 'Try a different name.',
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  sliver: SliverList.builder(
                    itemCount: grouped.length,
                    itemBuilder: (ctx, i) {
                      final entry = grouped[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                            child: Text(
                              entry.letter,
                              style: const TextStyle(
                                color: VentlyColors.berryMagenta,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          for (final f in entry.friends)
                            RepaintBoundary(child: _FriendRow(friend: f)),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  List<FriendSummary> _applyQuery(List<FriendSummary> all, String q) {
    final cleaned = q.trim().toLowerCase();
    if (cleaned.isEmpty) return all;
    return all
        .where((f) => f.pseudonym.toLowerCase().contains(cleaned))
        .toList();
  }

  List<_AlphabeticalGroup> _groupAlphabetically(List<FriendSummary> friends) {
    final sorted = [...friends]
      ..sort((a, b) {
        final fav = (b.isFavorite ? 1 : 0) - (a.isFavorite ? 1 : 0);
        if (fav != 0) return fav;
        return a.pseudonym.toLowerCase().compareTo(b.pseudonym.toLowerCase());
      });
    final groups = <String, List<FriendSummary>>{};
    for (final f in sorted) {
      final letter = f.pseudonym.isEmpty
          ? '#'
          : f.pseudonym[0].toUpperCase();
      groups.putIfAbsent(letter, () => []).add(f);
    }
    final keys = groups.keys.toList()..sort();
    return [
      for (final k in keys) _AlphabeticalGroup(letter: k, friends: groups[k]!),
    ];
  }

  void _openMoreSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'More',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.shield_outlined,
                    color: context.ink),
                title: const Text('Blocked accounts',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(ctx);
                  _openBlockedSheet(context);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.outbox_outlined,
                    color: context.ink),
                title: const Text('Sent requests',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(ctx);
                  _openOutgoingSheet(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openBlockedSheet(BuildContext context) {
    showBlockedAccountsSheet(context);
  }

  void _openOutgoingSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _OutgoingSheet(),
    );
  }
}

class _AlphabeticalGroup {
  final String letter;
  final List<FriendSummary> friends;
  _AlphabeticalGroup({required this.letter, required this.friends});
}

// =========================================================================
// HEADER
// =========================================================================

class _FriendsHeader extends StatelessWidget {
  const _FriendsHeader({required this.onMenu});
  final VoidCallback onMenu;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.menu_rounded,
                color: context.ink),
            onPressed: onMenu,
          ),
          const Text(
            'Venttly',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.notifications_none_rounded,
                color: VentlyColors.berryMagenta),
            onPressed: () => context.push('/notifications'),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// INSTANT CONNECT
// =========================================================================

class _InstantConnectCard extends StatelessWidget {
  const _InstantConnectCard({required this.me});
  final AppUser? me;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
      child: GlassCard(
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFDFEA),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.qr_code_2_rounded,
                      color: VentlyColors.berryMagenta, size: 30),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Instant Connect',
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 3),
                      const Text(
                        'Share your profile or add a friend.',
                        style: TextStyle(
                          color: Color(0xFF8B5566),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: me == null
                        ? null
                        : () => _shareLink(context, me!),
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: const Text(
                      'Share Link',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: me == null
                        ? null
                        : () => _showMyQr(context, me!),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFFE3EC),
                      foregroundColor: VentlyColors.berryMagenta,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    icon: const Icon(Icons.qr_code_scanner, size: 16),
                    label: const Text(
                      'My QR',
                      style: TextStyle(fontWeight: FontWeight.w900),
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

  void _shareLink(BuildContext context, AppUser me) {
    final link = 'https://venttly.app/u/${me.anonymousPseudonym}';
    Share.share(
      'Find me on Venttly — anonymous, supportive, real.\n@${me.anonymousPseudonym}\n$link',
      subject: 'Venttly — anonymous social',
    );
  }

  void _showMyQr(BuildContext context, AppUser me) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'My QR',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Others scan this to connect with you instantly.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF8B5566),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              _RealQrCard(handle: me.anonymousPseudonym),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: context.isDark
                      ? context.glass()
                      : VentlyColors.cardBlush,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '@${me.anonymousPseudonym}',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Scan to add. Or copy and share the link below anywhere.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.ink.withOpacity(0.6),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Real QR code rendered via qr_flutter. Encodes the
/// `https://venttly.app/u/<handle>` deep link — scannable from any
/// camera app and routable through the existing /user/<id> path once
/// the marketing site is live.
class _RealQrCard extends StatelessWidget {
  const _RealQrCard({required this.handle});
  final String handle;
  @override
  Widget build(BuildContext context) {
    final url = 'https://venttly.app/u/$handle';
    return Container(
      width: 220,
      height: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.5)),
      ),
      child: QrImageView(
        data: url,
        version: QrVersions.auto,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: VentlyColors.deepBurgundy,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: VentlyColors.deepBurgundy,
        ),
        embeddedImage: null,
      ),
    );
  }
}

// =========================================================================
// FRIEND REQUESTS
// =========================================================================

class _RequestsSection extends ConsumerWidget {
  const _RequestsSection({required this.incoming});
  final List<FriendRequest> incoming;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = incoming.take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Text(
                  'Friend Requests',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: VentlyColors.berryMagenta,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${incoming.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                for (final r in shown) _RequestCard(request: r),
                if (incoming.length > 3)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {},
                      style: TextButton.styleFrom(
                        foregroundColor: VentlyColors.berryMagenta,
                      ),
                      child: Text(
                        'See ${incoming.length - 3} more',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends ConsumerWidget {
  const _RequestCard({required this.request});
  final FriendRequest request;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => openUserProfile(context, request.otherUserId),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ProfileAvatar(
                      avatarSeed: request.otherAvatarSeed,
                      label: request.otherPseudonym,
                      size: 44,
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: const Color(0xFF21C76A),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        request.otherPseudonym,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _relative(request.createdAt),
                        style: TextStyle(
                          color: context.ink.withOpacity(0.55),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: VentlyColors.softMauve),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    await ref
                        .read(repositoryProvider)
                        .acceptFriendRequest(request.friendshipId);
                    ref.invalidate(incomingFriendRequestsProvider);
                    ref.invalidate(myFriendsProvider);
                    ref.invalidate(friendSuggestionsProvider);
                    ref.invalidate(friendStatusProvider(request.otherUserId));
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: VentlyColors.berryMagenta,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text('Accept',
                      style: TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    await ref
                        .read(repositoryProvider)
                        .declineFriendRequest(request.friendshipId);
                    ref.invalidate(incomingFriendRequestsProvider);
                    ref.invalidate(friendStatusProvider(request.otherUserId));
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFFE3EC),
                    foregroundColor: VentlyColors.berryMagenta,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text('Ignore',
                      style: TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// QUICK SUGGESTIONS
// =========================================================================

class _QuickSuggestionsSection extends StatelessWidget {
  const _QuickSuggestionsSection({required this.async});
  final AsyncValue<List<FriendSuggestion>> async;
  @override
  Widget build(BuildContext context) {
    final list = async.valueOrNull ?? const <FriendSuggestion>[];
    if (async.isLoading && list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 3,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, __) => Container(
              width: 140,
              decoration: BoxDecoration(
                color: context.glass(0.9),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                    color: VentlyColors.softMauve.withOpacity(0.3)),
              ),
            ),
          ),
        ),
      );
    }
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text(
              'Quick Suggestions',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (ctx, i) => _SuggestionCard(s: list[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends ConsumerStatefulWidget {
  const _SuggestionCard({required this.s});
  final FriendSuggestion s;
  @override
  ConsumerState<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends ConsumerState<_SuggestionCard> {
  bool _sent = false;
  bool _busy = false;

  Future<void> _add() async {
    if (_busy || _sent) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .sendFriendRequest(widget.s.userId);
      ref.invalidate(outgoingFriendRequestsProvider);
      ref.invalidate(friendSuggestionsProvider);
      if (!mounted) return;
      setState(() => _sent = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      margin: EdgeInsets.zero,
      borderRadius: 22,
      child: SizedBox(
        width: 132,
        child: Column(
        children: [
          ProfileAvatar(
            avatarSeed: widget.s.avatarSeed,
            label: widget.s.pseudonym,
            profilePhotoUrl: widget.s.profilePhotoUrl,
            size: 58,
            showVerifiedBadge: widget.s.isVerified,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  widget.s.pseudonym,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
              ),
              if (widget.s.isVerified) ...[
                const SizedBox(width: 3),
                const VerifiedBadge(size: 13),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            widget.s.rationale,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ink.withOpacity(0.6),
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 30,
            child: FilledButton(
              onPressed: _add,
              style: FilledButton.styleFrom(
                backgroundColor: _sent
                    ? VentlyColors.softMauve.withOpacity(0.4)
                    : const Color(0xFFFFE3EC),
                foregroundColor: VentlyColors.berryMagenta,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: VentlyColors.berryMagenta),
                    )
                  : Text(
                      _sent ? 'PENDING' : 'ADD',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                        letterSpacing: 0.6,
                      ),
                    ),
            ),
          ),
        ],
        ),
      ),
    ).animate().fadeIn(duration: 220.ms);
  }
}

// =========================================================================
// MY FRIENDS
// =========================================================================

class _MyFriendsHeader extends StatelessWidget {
  const _MyFriendsHeader({
    required this.total,
    required this.query,
    required this.onChanged,
  });
  final int total;
  final TextEditingController query;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
              children: [
                const TextSpan(text: 'My Friends '),
                TextSpan(
                  text: '($total)',
                  style: const TextStyle(
                      color: VentlyColors.berryMagenta,
                      fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: context.glass(0.9),
              borderRadius: BorderRadius.circular(22),
              border:
                  Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.search_rounded,
                    size: 18, color: VentlyColors.berryMagenta),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: query,
                    onChanged: onChanged,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Find a friend…',
                      hintStyle: TextStyle(
                        color: context.ink.withOpacity(0.42),
                        fontWeight: FontWeight.w700,
                      ),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendRow extends ConsumerWidget {
  const _FriendRow({required this.friend});
  final FriendSummary friend;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/user/${friend.userId}'),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              ProfileAvatar(
                avatarSeed: friend.avatarSeed,
                label: friend.pseudonym,
                profilePhotoUrl: friend.profilePhotoUrl,
                size: 48,
                showVerifiedBadge: friend.isVerified,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            friend.pseudonym,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (friend.isVerified) ...[
                          const SizedBox(width: 4),
                          const VerifiedBadge(size: 14),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Friends since ${_relative(friend.acceptedAt)}',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.55),
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              _FavoriteHeart(friend: friend),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.more_vert_rounded,
                    color: context.ink, size: 20),
                onPressed: () => _showActions(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        friend.pseudonym,
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    if (friend.isVerified) ...[
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 15),
                    ],
                  ],
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.person_outline,
                    color: context.ink),
                title: const Text('View profile',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  context.push('/user/${friend.userId}');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.chat_bubble_outline,
                    color: context.ink),
                title: const Text('Message',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  try {
                    final room =
                        await ref.read(repositoryProvider).sendMessageRequest(
                              peerUserId: friend.userId,
                              peerPseudonym: friend.pseudonym,
                              peerAvatarSeed: friend.avatarSeed,
                              preview: 'Hey',
                            );
                    if (context.mounted) {
                      GoRouter.of(context).push('/chat/${room.roomId}');
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not message: $e')),
                      );
                    }
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.notifications_off_outlined,
                    color: context.ink),
                title: const Text('Mute notifications',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Mute is shipping with notifications v2.'),
                    ),
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.person_remove_alt_1,
                    color: context.ink),
                title: const Text('Remove friend',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await ref.read(repositoryProvider).unfriend(friend.userId);
                  ref.invalidate(myFriendsProvider);
                  ref.invalidate(friendStatusProvider(friend.userId));
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.block,
                    color: Theme.of(context).colorScheme.error),
                title: Text(
                  'Block',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await ref.read(repositoryProvider).blockUser(friend.userId);
                  ref.invalidate(myFriendsProvider);
                  ref.invalidate(myBlocksProvider);
                  ref.invalidate(friendStatusProvider(friend.userId));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteHeart extends ConsumerStatefulWidget {
  const _FavoriteHeart({required this.friend});
  final FriendSummary friend;
  @override
  ConsumerState<_FavoriteHeart> createState() => _FavoriteHeartState();
}

class _FavoriteHeartState extends ConsumerState<_FavoriteHeart> {
  late bool _on = widget.friend.isFavorite;
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _on = !_on;
    });
    try {
      await ref
          .read(repositoryProvider)
          .toggleFriendFavorite(widget.friend.friendshipId);
      ref.invalidate(myFriendsProvider);
    } catch (_) {
      if (mounted) setState(() => _on = !_on);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        _on ? Icons.favorite : Icons.favorite_border,
        color: _on
            ? const Color(0xFF21C76A)
            : context.ink.withOpacity(0.5),
        size: 18,
      ),
      onPressed: _toggle,
      visualDensity: VisualDensity.compact,
    );
  }
}

// =========================================================================
// OUTGOING SHEET
// =========================================================================

class _OutgoingSheet extends ConsumerWidget {
  const _OutgoingSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outgoing =
        ref.watch(outgoingFriendRequestsProvider).valueOrNull ??
            const <FriendRequest>[];
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      expand: false,
      builder: (_, controller) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 14),
              Text(
                'Sent requests',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: outgoing.isEmpty
                    ? Center(
                        child: Text(
                          "No outgoing requests right now.",
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: controller,
                        itemCount: outgoing.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 6),
                        itemBuilder: (ctx, i) {
                          final r = outgoing[i];
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: context.glass(0.9),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                  color: VentlyColors.softMauve
                                      .withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                ProfileAvatar(
                                  avatarSeed: r.otherAvatarSeed,
                                  label: r.otherPseudonym,
                                  size: 38,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        r.otherPseudonym,
                                        style: TextStyle(
                                          color: context.ink,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      Text(
                                        'Sent ${_relative(r.createdAt)}',
                                        style: TextStyle(
                                          color: context.ink
                                              .withOpacity(0.55),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    await ref
                                        .read(repositoryProvider)
                                        .declineFriendRequest(r.friendshipId);
                                    ref.invalidate(
                                        outgoingFriendRequestsProvider);
                                  },
                                  child: const Text(
                                    'Cancel',
                                    style: TextStyle(
                                      color: VentlyColors.berryMagenta,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =========================================================================
// SHARED BITS
// =========================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 30, 30, 30),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(
              color: Color(0xFFFFE3EC),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: VentlyColors.berryMagenta, size: 36),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink.withOpacity(0.66),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        children: List.generate(
          6,
          (_) => Container(
            height: 56,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: context.glass(0.9),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: VentlyColors.softMauve.withOpacity(0.3)),
            ),
          ),
        ),
      ),
    );
  }
}

String _relative(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}
