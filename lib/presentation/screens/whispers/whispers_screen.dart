import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../data/services/whisper_player.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/sensitive_media_veil.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/verified_badge.dart';
import '../../widgets/whisper_comments_sheet.dart';
import '../../widgets/whisper_mini_player.dart';
import '../../widgets/whisper_share_sheet.dart';

/// Whispers — TikTok/Reels-style vertical audio feed.
///
/// Full-screen pages with autoplay on swipe, tap-to-pause, double-tap
/// rewind/forward (±10s), scrubbable seek bar, infinite pagination,
/// and audio/image preloading for the next cards.
class WhispersScreen extends ConsumerStatefulWidget {
  const WhispersScreen({super.key});

  @override
  ConsumerState<WhispersScreen> createState() => _WhispersScreenState();
}

class _WhispersScreenState extends ConsumerState<WhispersScreen> {
  static const _preloadAhead = 2;
  static const _loadMoreThreshold = 3;

  final PageController _pageController = PageController();
  int _currentIndex = 0;
  String? _deepLinkHandled;
  bool _bootstrapped = false;
  bool _loadingMore = false;
  List<Whisper> _whispers = const [];
  StreamSubscription<ProcessingState>? _completeSub;

  /// Polls media_status while a loaded whisper is still being scanned.
  ///
  /// The scan happens server-side after upload and the row starts `pending`,
  /// which the UI renders as "Checking this image…". Nothing ever re-read it,
  /// so that message was permanent — the image was fine, the client just never
  /// asked again. Runs only while something is actually pending and stops
  /// itself, so a settled feed costs nothing.
  Timer? _mediaStatusPoll;

  @override
  void dispose() {
    _mediaStatusPoll?.cancel();
    _completeSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// When a whisper finishes (and loop is off), glide to the next one — the
  /// Reels/TikTok "auto-advance to the next unheard whisper" behaviour.
  void _wireAutoAdvance(WhisperPlayerController controller) {
    if (_completeSub != null) return;
    _completeSub = controller.processingStream.listen((state) {
      if (!mounted) return;
      // Data Saver: never auto-advance — each whisper is a paid download.
      if (ref.read(dataSaverProvider)) return;
      if (state == ProcessingState.completed && !controller.loopEnabled) {
        _advanceToNext();
      }
    });
  }

  void _advanceToNext() {
    final next = _currentIndex + 1;
    if (next >= _whispers.length || !_pageController.hasClients) return;
    _pageController.nextPage(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  /// True only while this shell branch is the visible one.
  ///
  /// StatefulShellRoute.indexedStack keeps every branch mounted — go_router wraps
  /// them in `Offstage(offstage: !isActive, child: TickerMode(enabled: isActive))`
  /// — so this screen is built and alive while the user is on Home. TickerMode is
  /// therefore the honest signal for "am I on screen", and without it the
  /// bootstrap below started audio from a page nobody had opened.
  bool get _onStage => TickerMode.of(context);

  bool _refreshing = false;

  /// Re-enters the feed from the top. `_bootstrapped` is cleared so the existing
  /// autoplay path re-arms on the new first page, and the page controller is sent
  /// home — otherwise the PageView would keep the old index and land mid-list.
  /// Start or stop the pending-media poll to match what is loaded.
  void _syncMediaStatusPoll() {
    final pending = _whispers
        .where((w) => w.mediaStatus == 'pending')
        .map((w) => w.whisperId)
        .toList();
    if (pending.isEmpty) {
      _mediaStatusPoll?.cancel();
      _mediaStatusPoll = null;
      return;
    }
    if (_mediaStatusPoll != null) return;
    // 2.5s is fast enough to feel immediate on a scan that takes a few seconds,
    // and slow enough that a stuck scan is not a hot loop against the API.
    _mediaStatusPoll = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => _pollMediaStatuses(),
    );
  }

  Future<void> _pollMediaStatuses() async {
    final pending = _whispers
        .where((w) => w.mediaStatus == 'pending')
        .map((w) => w.whisperId)
        .toList();
    if (pending.isEmpty) {
      _syncMediaStatusPoll();
      return;
    }
    try {
      final fresh = await ref
          .read(repositoryProvider)
          .whisperMediaStatuses(pending);
      if (!mounted || fresh.isEmpty) return;
      var changed = false;
      final next = [
        for (final w in _whispers)
          if (fresh[w.whisperId] case final String status
              when status != w.mediaStatus)
            (() {
              changed = true;
              return w.copyWith(mediaStatus: status);
            })()
          else
            w,
      ];
      if (!changed) return;
      setState(() => _whispers = next);
      _syncMediaStatusPoll();
    } catch (_) {
      // Transient. The next tick tries again; a permanent failure just leaves
      // the veil up, which is the safe direction for unscanned media.
    }
  }

  Future<void> _refreshFeed() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      _bootstrapped = false;
      await ref.read(whispersFeedProvider.notifier).refresh();
      if (!mounted) return;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      setState(() => _currentIndex = 0);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  bool? _wasOnStage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onStage = _onStage;
    if (onStage == _wasOnStage) return;
    _wasOnStage = onStage;
    if (!onStage) {
      // Clear the bootstrap flag either way, so returning re-runs the existing
      // autoplay path rather than landing on a dead page.
      _bootstrapped = false;
      final active = ref.read(activeWhisperProvider);
      if (active?.startedByUser == true) {
        // The user chose this one: hand off to the mini-player, keep playing.
        return;
      }
      // Autoplayed. Silence it — this is the case that was the reported bug.
      unawaited(_pauseOffStage());
      // Deferred deliberately: didChangeDependencies can run during a build, and
      // mutating a provider then throws "Tried to modify a provider while the
      // widget tree was building" — which cascaded into render assertions and a
      // blank shell.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(activeWhisperProvider.notifier).state = null;
      });
    }
  }

  Future<void> _pauseOffStage() async {
    try {
      final controller = await ref.read(whisperPlayerProvider.future);
      await controller.pause();
    } catch (_) {
      /* nothing playing, or the player is gone */
    }
  }

  /// [byUser] distinguishes a deliberate swipe from the autoplay that fires when
  /// the tab opens. Only the former earns the right to keep playing after the
  /// user leaves — see [ActiveWhisper.startedByUser].
  Future<void> _onPageChanged(
    int index,
    List<Whisper> whispers, {
    bool byUser = false,
  }) async {
    if (!mounted) return;
    // The bootstrap and deep-link paths both run in post-frame callbacks, so
    // re-check here rather than trusting the caller.
    if (!_onStage) return;
    HapticFeedback.lightImpact();
    setState(() => _currentIndex = index);

    if (index >= whispers.length - _loadMoreThreshold) {
      setState(() => _loadingMore = true);
      unawaited(
        ref.read(whispersFeedProvider.notifier).loadMore().whenComplete(() {
          if (mounted) setState(() => _loadingMore = false);
        }),
      );
    }

    if (index >= whispers.length) return;
    final w = whispers[index];

    _precacheAround(context, whispers, index);

    try {
      final controller = await ref.read(whisperPlayerProvider.future);
      _wireAutoAdvance(controller);
      await controller.startPlayback(
        whisperId: w.whisperId,
        url: w.audioUrl,
        // Re-entry (the bootstrap and deep-link paths) resumes; only a
        // deliberate swipe onto a whisper starts it over.
        restart: byUser,
        musicUrl: w.hasMusicBed ? w.musicPreviewUrl : null,
        musicStartMs: w.musicStartMs,
        musicVolume: w.musicVolume,
      );
      if (mounted) {
        // Re-entering the tab replays the current page with byUser false. That
        // must not erase intent the user already expressed for this whisper, or
        // tapping the mini-player to return would silently strip its right to
        // follow them out again.
        final prior = ref.read(activeWhisperProvider);
        final chosen =
            byUser ||
            (prior != null &&
                prior.whisperId == w.whisperId &&
                prior.startedByUser);
        ref.read(activeWhisperProvider.notifier).state = ActiveWhisper(
          whisperId: w.whisperId,
          title: (w.title ?? '').trim().isEmpty ? 'Whisper' : w.title!.trim(),
          author: w.authorDisplayName,
          startedByUser: chosen,
        );
      }
      // Capture this listener (dedup per user; first listen bumps the public
      // plays_count). Every listen is recorded whether or not they like it.
      unawaited(ref.read(repositoryProvider).recordWhisperListen(w.whisperId));

      for (var i = 1; i <= _preloadAhead; i++) {
        final next = index + i;
        if (next < whispers.length) {
          unawaited(controller.preloadUrl(whispers[next].audioUrl));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              UserFriendlyErrors.message(
                e,
                fallback: 'Could not play whisper.',
              ),
            ),
          ),
        );
      }
    }
  }

  void _precacheAround(
    BuildContext context,
    List<Whisper> whispers,
    int index,
  ) {
    for (
      var i = index;
      i <= index + _preloadAhead && i < whispers.length;
      i++
    ) {
      final url = whispers[i].backgroundImageUrl;
      if (url != null && url.isNotEmpty) {
        precacheImage(CachedNetworkImageProvider(url), context);
      }
    }
  }

  void _scrollToDeepLink(List<Whisper> whispers) {
    final targetId = GoRouterState.of(context).uri.queryParameters['whisper'];
    if (targetId == null || targetId.isEmpty) return;
    if (_deepLinkHandled == targetId) return;
    final idx = whispers.indexWhere((w) => w.whisperId == targetId);
    if (idx < 0) return;
    _deepLinkHandled = targetId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_pageController.hasClients) return;
      _pageController.jumpToPage(idx);
      _onPageChanged(idx, whispers);
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(whispersFeedProvider);
    final cat = ref.watch(whispersCategoryProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          feedAsync.when(
            // Never swap content we still have for a skeleton; first load only.
            skipLoadingOnReload: true,
            loading: () => const WhisperFeedSkeleton(),
            error: (e, _) => _WhispersError(
              error: e,
              onRetry: () => ref.read(whispersFeedProvider.notifier).refresh(),
            ),
            data: (whispers) {
              if (whispers.isEmpty) {
                return _WhispersEmpty(
                  category: cat,
                  onClearCategory: cat == null
                      ? null
                      : () =>
                            ref.read(whispersCategoryProvider.notifier).state =
                                null,
                  onComposeSoon: _composeSoonState,
                );
              }

              _whispers = whispers;
              _syncMediaStatusPoll();
              _scrollToDeepLink(whispers);
              if (!_bootstrapped && _onStage) {
                _bootstrapped = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _onPageChanged(_currentIndex, whispers);
                });
              }

              return PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                physics: const ClampingScrollPhysics(),
                allowImplicitScrolling: true,
                itemCount: whispers.length,
                onPageChanged: (i) => _onPageChanged(i, whispers, byUser: true),
                itemBuilder: (ctx, i) {
                  return RepaintBoundary(
                    child: _WhisperPage(
                      key: ValueKey(whispers[i].whisperId),
                      whisper: whispers[i],
                      isActive: i == _currentIndex,
                    ),
                  );
                },
              );
            },
          ),
          if (_loadingMore)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 88,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: _WhispersTopBar(
                activeCategory: cat,
                onPickCategory: _openCategorySheet,
                onCompose: _composeSoonState,
                onRefresh: _refreshFeed,
                refreshing: _refreshing,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _composeSoonState() {
    context.push('/whispers/new');
  }

  void _openCategorySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _CategorySheet(
        active: ref.read(whispersCategoryProvider),
        onPick: (c) {
          ref.read(whispersCategoryProvider.notifier).state = c;
          setState(() {
            _bootstrapped = false;
            _currentIndex = 0;
          });
          if (_pageController.hasClients) {
            _pageController.jumpToPage(0);
          }
          Navigator.pop(ctx);
        },
      ),
    );
  }
}

// =========================================================================
// TOP BAR
// =========================================================================

class _WhispersTopBar extends StatelessWidget {
  const _WhispersTopBar({
    required this.activeCategory,
    required this.onPickCategory,
    required this.onCompose,
    required this.onRefresh,
    required this.refreshing,
  });
  final String? activeCategory;
  final VoidCallback onPickCategory;
  final VoidCallback onCompose;

  /// Explicit refresh. The feed enters at a random point in the recent unheard
  /// window, so this genuinely reshuffles rather than re-fetching the same list —
  /// but a vertical PageView has no pull-to-refresh, so without a button there
  /// was no way to ask for it.
  final VoidCallback onRefresh;
  final bool refreshing;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.42),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 14),
                SizedBox(width: 6),
                Text(
                  'Whispers',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onPickCategory,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.92),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    activeCategory == null
                        ? 'All'
                        : '#${FeedCategories.label(activeCategory!).replaceAll(' ', '')}',
                    style: const TextStyle(
                      color: VentlyColors.berryMagenta,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: VentlyColors.berryMagenta,
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: refreshing ? null : onRefresh,
            customBorder: const CircleBorder(),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.42),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.refresh_rounded,
                      color: Colors.white,
                      size: 19,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onCompose,
            customBorder: const CircleBorder(),
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: VentlyColors.berryMagenta,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.mic_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// WHISPER PAGE — one full-screen Reels tile
// =========================================================================

class _WhisperPage extends ConsumerStatefulWidget {
  const _WhisperPage({
    super.key,
    required this.whisper,
    required this.isActive,
  });
  final Whisper whisper;
  final bool isActive;

  @override
  ConsumerState<_WhisperPage> createState() => _WhisperPageState();
}

class _WhisperPageState extends ConsumerState<_WhisperPage> {
  bool _flashRewind = false;
  bool _flashForward = false;
  bool _flashPaused = false;

  /// True once the viewer has chosen to see a veiled background.
  ///
  /// Tracked here, not only inside SensitiveMediaVeil, because the pause
  /// overlay below is a later Stack child and therefore sits *above* the veil
  /// in hit-testing. While the media is still covered that overlay has to stay
  /// out of the way, or the tap that should reveal the image pauses the audio
  /// instead — which is precisely what it did.
  bool _mediaRevealed = false;

  /// Whether a veil is still covering this whisper's background.
  bool _mediaIsCovered(Whisper whisper) =>
      whisper.mediaNeedsVeil && !_mediaRevealed;

  Future<void> _togglePause() async {
    HapticFeedback.mediumImpact();
    try {
      final controller = await ref.read(whisperPlayerProvider.future);
      if (!controller.isActiveWhisper(widget.whisper.whisperId)) {
        await controller.startPlayback(
          whisperId: widget.whisper.whisperId,
          url: widget.whisper.audioUrl,
          musicUrl: widget.whisper.hasMusicBed
              ? widget.whisper.musicPreviewUrl
              : null,
          musicStartMs: widget.whisper.musicStartMs,
          musicVolume: widget.whisper.musicVolume,
        );
        return;
      }
      await controller.togglePause();
      if (!mounted) return;
      setState(() => _flashPaused = !controller.isPlaying);
      if (_flashPaused) {
        await Future<void>.delayed(const Duration(milliseconds: 650));
        if (mounted) setState(() => _flashPaused = false);
      }
    } catch (_) {}
  }

  Future<void> _rewind() async {
    HapticFeedback.selectionClick();
    try {
      final controller = await ref.read(whisperPlayerProvider.future);
      await controller.rewind(seconds: 10);
      if (!mounted) return;
      setState(() => _flashRewind = true);
      await Future<void>.delayed(const Duration(milliseconds: 550));
      if (mounted) setState(() => _flashRewind = false);
    } catch (_) {}
  }

  Future<void> _forward() async {
    HapticFeedback.selectionClick();
    try {
      final controller = await ref.read(whisperPlayerProvider.future);
      await controller.forward(seconds: 10);
      if (!mounted) return;
      setState(() => _flashForward = true);
      await Future<void>.delayed(const Duration(milliseconds: 550));
      if (mounted) setState(() => _flashForward = false);
    } catch (_) {}
  }

  void _onDoubleTapDown(TapDownDetails details, double width) {
    final x = details.localPosition.dx;
    if (x < width * 0.33) {
      _rewind();
    } else if (x > width * 0.67) {
      _forward();
    } else {
      _togglePause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final whisper = widget.whisper;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          fit: StackFit.expand,
          children: [
            if (whisper.backgroundImageUrl != null &&
                whisper.backgroundImageUrl!.isNotEmpty)
              SensitiveMediaVeil(
                veiled: whisper.mediaNeedsVeil,
                pending: whisper.mediaStatus == 'pending',
                onRevealed: () => setState(() => _mediaRevealed = true),
                borderRadius: 0,
                child: CachedNetworkImage(
                  imageUrl: whisper.backgroundImageUrl!,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 180),
                  placeholder: (_, __) =>
                      Container(color: context.ink.withOpacity(0.4)),
                  errorWidget: (_, __, ___) =>
                      Container(color: context.ink.withOpacity(0.4)),
                ),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      VentlyColors.berryMagenta.withOpacity(0.9),
                      context.ink,
                    ],
                  ),
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x44000000), Color(0xAA000000)],
                ),
              ),
            ),
            if (!_mediaIsCovered(whisper))
              Positioned(
                left: 0,
                right: 72,
                top: 56,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _togglePause,
                  onDoubleTapDown: (d) =>
                      _onDoubleTapDown(d, constraints.maxWidth - 72),
                ),
              ),
            if (_flashPaused)
              const Center(
                child: Icon(
                  Icons.pause_rounded,
                  color: Colors.white70,
                  size: 72,
                ),
              ),
            if (_flashRewind)
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 48),
                  child: _SkipFlash(icon: Icons.replay_10_rounded),
                ),
              ),
            if (_flashForward)
              const Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: EdgeInsets.only(right: 48),
                  child: _SkipFlash(icon: Icons.forward_10_rounded),
                ),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 70, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    _AudioCard(whisper: whisper, isActive: widget.isActive),
                    const SizedBox(height: 14),
                    _CaptionBlock(whisper: whisper),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 100,
              child: _ActionRail(whisper: whisper),
            ),
          ],
        );
      },
    );
  }
}

class _SkipFlash extends StatelessWidget {
  const _SkipFlash({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 36),
    );
  }
}

class _AudioCard extends ConsumerWidget {
  const _AudioCard({required this.whisper, required this.isActive});
  final Whisper whisper;
  final bool isActive;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerAsync = ref.watch(whisperPlayerProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.32)),
      ),
      child: playerAsync.when(
        loading: () => _StaticAudioCard(whisper: whisper),
        error: (_, __) => _StaticAudioCard(whisper: whisper),
        data: (controller) => _LiveAudioPlayer(
          whisper: whisper,
          isActive: isActive,
          controller: controller,
        ),
      ),
    );
  }
}

class _StaticAudioCard extends StatelessWidget {
  const _StaticAudioCard({required this.whisper});
  final Whisper whisper;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.play_arrow_rounded,
            color: VentlyColors.berryMagenta,
            size: 30,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            'Loading audio…',
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
        Text(
          _formatSecs(whisper.audioDurationSeconds),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// Real-time player UI — scrubbable seek bar + play/pause (Reels-style).
class _LiveAudioPlayer extends StatefulWidget {
  const _LiveAudioPlayer({
    required this.whisper,
    required this.isActive,
    required this.controller,
  });
  final Whisper whisper;
  final bool isActive;
  final WhisperPlayerController controller;

  @override
  State<_LiveAudioPlayer> createState() => _LiveAudioPlayerState();
}

class _LiveAudioPlayerState extends State<_LiveAudioPlayer> {
  bool _seeking = false;
  double _seekValue = 0;
  double _speed = 1.0;
  bool _loop = false;

  @override
  void initState() {
    super.initState();
    _speed = widget.controller.playbackSpeed;
    _loop = widget.controller.loopEnabled;
  }

  Future<void> _cycleSpeed() async {
    HapticFeedback.selectionClick();
    final next = await widget.controller.cycleSpeed();
    if (mounted) setState(() => _speed = next);
  }

  Future<void> _toggleLoop() async {
    HapticFeedback.selectionClick();
    final on = await widget.controller.toggleLoop();
    if (mounted) setState(() => _loop = on);
  }

  Future<void> _togglePlay() async {
    try {
      if (!widget.controller.isActiveWhisper(widget.whisper.whisperId)) {
        await widget.controller.startPlayback(
          whisperId: widget.whisper.whisperId,
          url: widget.whisper.audioUrl,
          musicUrl: widget.whisper.hasMusicBed
              ? widget.whisper.musicPreviewUrl
              : null,
          musicStartMs: widget.whisper.musicStartMs,
          musicVolume: widget.whisper.musicVolume,
        );
      } else {
        await widget.controller.togglePause();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              UserFriendlyErrors.message(e, fallback: 'Could not play audio.'),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalSecs = widget.whisper.audioDurationSeconds;
    // The active/inactive branch sits INSIDE the stream on purpose. It used to
    // return early, outside any subscription, so when the media finished loading
    // nothing rebuilt this widget — the row stayed on a static play button until
    // some unrelated frame happened to repaint it.
    return StreamBuilder<PlayerState>(
      stream: widget.controller.stateStream,
      builder: (ctx, stateSnap) {
        final playing = stateSnap.data?.playing ?? false;
        final processing = stateSnap.data?.processingState;

        final isThisActive =
            widget.isActive &&
            widget.controller.isActiveWhisper(widget.whisper.whisperId);

        if (!isThisActive) {
          return _StaticPausedRow(
            whisper: widget.whisper,
            onPlay: _togglePlay,
            loading:
                widget.isActive &&
                widget.controller.isLoadingWhisper(widget.whisper.whisperId),
          );
        }

        return StreamBuilder<Duration>(
          stream: widget.controller.positionStream,
          builder: (ctx, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            // Use the REAL loaded audio duration when available — the stored
            // metadata (audioDurationSeconds) can be shorter than the file,
            // which made the timer run past the end (e.g. 1:12 over 1:03).
            final realTotalMs = widget.controller.duration?.inMilliseconds ?? 0;
            final totalMs = (realTotalMs > 0 ? realTotalMs : totalSecs * 1000)
                .clamp(1, 1 << 30);
            // Clamp the displayed position so it never exceeds the total.
            final posMs = pos.inMilliseconds.clamp(0, totalMs);
            final progress = _seeking
                ? _seekValue
                : (posMs / totalMs).clamp(0.0, 1.0);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    InkWell(
                      onTap: _togglePlay,
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child:
                            processing == ProcessingState.loading ||
                                processing == ProcessingState.buffering
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: VentlyColors.berryMagenta,
                                ),
                              )
                            : Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: VentlyColors.berryMagenta,
                                size: 30,
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _WaveformProgress(progress: progress),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                _formatDuration(Duration(milliseconds: posMs)),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                Icons.equalizer_rounded,
                                color: Colors.white.withOpacity(0.78),
                                size: 11,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                WhisperVoiceFilters.label(
                                  widget.whisper.voiceFilter,
                                ),
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.85),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                _formatDuration(
                                  Duration(milliseconds: totalMs),
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: progress,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white.withOpacity(0.28),
                    onChangeStart: (_) => setState(() => _seeking = true),
                    onChanged: (v) => setState(() {
                      _seeking = true;
                      _seekValue = v;
                    }),
                    onChangeEnd: (v) async {
                      final ms = (totalMs * v).round();
                      await widget.controller.seek(Duration(milliseconds: ms));
                      if (mounted) setState(() => _seeking = false);
                    },
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _PlaybackChip(
                      label:
                          '${_speed == _speed.roundToDouble() ? _speed.toStringAsFixed(0) : _speed}×',
                      icon: Icons.speed_rounded,
                      active: _speed != 1.0,
                      onTap: _cycleSpeed,
                    ),
                    const SizedBox(width: 8),
                    _PlaybackChip(
                      label: _loop ? 'Loop' : 'Once',
                      icon: _loop
                          ? Icons.repeat_on_rounded
                          : Icons.repeat_rounded,
                      active: _loop,
                      onTap: _toggleLoop,
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PlaybackChip extends StatelessWidget {
  const _PlaybackChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withOpacity(0.28)
              : Colors.black.withOpacity(0.28),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? Colors.white.withOpacity(0.55)
                : Colors.white.withOpacity(0.18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaticPausedRow extends StatelessWidget {
  const _StaticPausedRow({
    required this.whisper,
    required this.onPlay,
    this.loading = false,
  });
  final Whisper whisper;
  final VoidCallback onPlay;

  /// Media is still downloading. Shows a spinner instead of a play button that
  /// would do nothing, and swallows the tap so it cannot queue a second load.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InkWell(
          onTap: loading ? null : onPlay,
          customBorder: const CircleBorder(),
          child: Container(
            width: 50,
            height: 50,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: VentlyColors.berryMagenta,
                    ),
                  )
                : const Icon(
                    Icons.play_arrow_rounded,
                    color: VentlyColors.berryMagenta,
                    size: 30,
                  ),
          ),
        ),
        const SizedBox(width: 14),
        const Expanded(child: _WaveformProgress(progress: 0)),
        const SizedBox(width: 8),
        Text(
          _formatSecs(whisper.audioDurationSeconds),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// Static waveform pattern that fills with magenta up to [progress].
class _WaveformProgress extends StatelessWidget {
  const _WaveformProgress({required this.progress});
  final double progress;

  static const _heights = <double>[
    10,
    18,
    14,
    24,
    18,
    28,
    16,
    20,
    14,
    24,
    18,
    12,
    22,
    16,
    24,
    18,
    14,
    22,
    16,
    26,
    14,
    18,
    12,
    24,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: LayoutBuilder(
        builder: (_, constraints) {
          final filledBars = (_heights.length * progress).round().clamp(
            0,
            _heights.length,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _heights.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: _heights[i],
                      decoration: BoxDecoration(
                        color: i < filledBars
                            ? Colors.white
                            : Colors.white.withOpacity(0.32),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

String _formatSecs(int secs) {
  final mm = (secs ~/ 60);
  final ss = (secs % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

String _formatDuration(Duration d) {
  final mm = d.inMinutes;
  final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

class _CaptionBlock extends StatelessWidget {
  const _CaptionBlock({required this.whisper});
  final Whisper whisper;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (whisper.authorId != null)
              UserProfileLink(
                userId: whisper.authorId!,
                pseudonym: whisper.authorPseudonym.replaceFirst('@', ''),
                displayName: whisper.authorDisplayName,
                avatarSeed: whisper.authorAvatarSeed,
                profilePhotoUrl: whisper.authorProfilePhotoUrl,
                size: 32,
              )
            else
              ProfileAvatar(
                avatarSeed: whisper.authorAvatarSeed,
                label: whisper.authorDisplayName,
                profilePhotoUrl: whisper.authorProfilePhotoUrl,
                size: 32,
              ),
            const SizedBox(width: 8),
            if (whisper.authorId != null)
              InkWell(
                onTap: () => context.push('/user/${whisper.authorId}'),
                child: Text(
                  whisper.authorDisplayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
              )
            else
              Text(
                whisper.authorDisplayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            if (whisper.authorIsVerified) ...[
              const SizedBox(width: 4),
              const VerifiedBadge(size: 14, color: Colors.white),
            ],
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.22),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '#${FeedCategories.label(whisper.category).replaceAll(' ', '')}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 10.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (whisper.title != null && whisper.title!.isNotEmpty)
          Text(
            whisper.title!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              height: 1.3,
              color: Colors.white,
            ),
          ),
        if (whisper.description != null && whisper.description!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            whisper.description!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}

class _ActionRail extends ConsumerStatefulWidget {
  const _ActionRail({required this.whisper});
  final Whisper whisper;
  @override
  ConsumerState<_ActionRail> createState() => _ActionRailState();
}

class _ActionRailState extends ConsumerState<_ActionRail> {
  String? _myReaction;
  int _totalReactions = 0;
  late bool _saved = widget.whisper.savedByMe;
  bool _busy = false;
  bool _saveBusy = false;

  @override
  void initState() {
    super.initState();
    _myReaction = widget.whisper.myReaction;
    _totalReactions = widget.whisper.likesCount;
  }

  Future<void> _openReactionPicker() async {
    if (_busy) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: VentlyColors.berryMagenta.withOpacity(0.22),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final key in PostReactions.all)
                  InkWell(
                    onTap: () => Navigator.of(ctx).pop(key),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        PostReactions.emoji(key),
                        style: const TextStyle(fontSize: 26),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null) return;

    final prevReaction = _myReaction;
    final prevTotal = _totalReactions;
    setState(() {
      _busy = true;
      if (_myReaction == picked) {
        _myReaction = null;
        _totalReactions = (_totalReactions - 1).clamp(0, 1 << 30);
      } else {
        if (_myReaction == null) _totalReactions += 1;
        _myReaction = picked;
      }
    });
    HapticFeedback.lightImpact();

    try {
      final result = await ref
          .read(repositoryProvider)
          .reactToWhisper(widget.whisper.whisperId, picked);
      if (!mounted) return;
      setState(() {
        _myReaction = result;
        if (result == null && prevReaction != null) {
          _totalReactions = prevTotal - 1;
        } else if (result != null && prevReaction == null) {
          _totalReactions = prevTotal + 1;
        }
      });
      ref.invalidate(whispersFeedProvider);
      ref.invalidate(myWhispersProvider);
    } catch (_) {
      if (mounted) {
        setState(() {
          _myReaction = prevReaction;
          _totalReactions = prevTotal;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleSave() async {
    if (_saveBusy) return;
    final wasSaved = _saved;
    setState(() {
      _saveBusy = true;
      _saved = !_saved;
    });
    try {
      final nowSaved = await ref
          .read(repositoryProvider)
          .toggleWhisperSave(widget.whisper.whisperId);
      if (!mounted) return;
      setState(() => _saved = nowSaved);
      ref.invalidate(whispersFeedProvider);
      ref.invalidate(mySavedWhispersProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(nowSaved ? 'Whisper saved' : 'Removed from saved'),
          action: nowSaved
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () async {
                    await ref
                        .read(repositoryProvider)
                        .toggleWhisperSave(widget.whisper.whisperId);
                    ref.invalidate(whispersFeedProvider);
                    ref.invalidate(mySavedWhispersProvider);
                    if (mounted) setState(() => _saved = false);
                  },
                )
              : null,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _saved = wasSaved);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              UserFriendlyErrors.message(
                e,
                fallback: 'Could not save whisper.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saveBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.read(repositoryProvider);
    final me = ref.watch(sessionProvider) ?? repository.currentUser;
    final isMine = widget.whisper.ownedBy(
      me?.userId ?? repository.authenticatedUserId,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          icon: _myReaction == null ? Icons.favorite_border : null,
          emoji: _myReaction != null ? PostReactions.emoji(_myReaction!) : null,
          label: _short(_totalReactions),
          color: _myReaction != null ? VentlyColors.berryMagenta : Colors.white,
          onTap: isMine ? null : _openReactionPicker,
        ),
        const SizedBox(height: 14),
        _RailButton(
          icon: Icons.mode_comment_outlined,
          label: _short(widget.whisper.commentsCount),
          color: Colors.white,
          onTap: () => showWhisperCommentsSheet(context, ref, widget.whisper),
        ),
        const SizedBox(height: 14),
        _RailButton(
          icon: Icons.ios_share,
          label: 'Share',
          color: Colors.white,
          onTap: () => showWhisperShareSheet(context, widget.whisper),
        ),
        const SizedBox(height: 14),
        _RailButton(
          icon: _saved ? Icons.bookmark : Icons.bookmark_border,
          label: _saved ? 'Saved' : 'Save',
          color: _saved ? VentlyColors.berryMagenta : Colors.white,
          onTap: _toggleSave,
        ),
        const SizedBox(height: 14),
        _RailButton(
          icon: Icons.more_horiz,
          label: 'More',
          color: Colors.white,
          onTap: () => _openWhisperMenu(isMine),
        ),
      ],
    );
  }

  void _openWhisperMenu(bool isMine) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMine) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit title & description'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openEditWhisperDialog();
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: VentlyColors.berryMagenta,
                ),
                title: const Text(
                  'Delete whisper',
                  style: TextStyle(color: VentlyColors.berryMagenta),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteWhisper();
                },
              ),
            ] else
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report whisper'),
                onTap: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Reported. Thanks for the heads up.'),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditWhisperDialog() async {
    final titleCtl = TextEditingController(text: widget.whisper.title ?? '');
    final descCtl = TextEditingController(
      text: widget.whisper.description ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit whisper'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtl,
                maxLength: 80,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Title',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtl,
                maxLines: 3,
                maxLength: 280,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Description',
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Audio recordings can\'t be edited — only the text.',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .editWhisper(
            whisperId: widget.whisper.whisperId,
            title: titleCtl.text.trim().isEmpty ? null : titleCtl.text.trim(),
            description: descCtl.text.trim().isEmpty
                ? null
                : descCtl.text.trim(),
          );
      if (!mounted) return;
      if (ok) {
        ref.invalidate(whispersFeedProvider);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Whisper updated')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendly(e))));
    }
  }

  Future<void> _confirmDeleteWhisper() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this whisper?'),
        content: const Text('This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: VentlyColors.berryMagenta,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .deleteWhisper(widget.whisper.whisperId);
      if (!mounted) return;
      if (ok) {
        ref.invalidate(whispersFeedProvider);
        ref.invalidate(myWhispersProvider);
        ref.invalidate(popularWhispersProvider);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Whisper deleted')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendly(e))));
    }
  }

  String _friendly(Object e) => UserFriendlyErrors.message(
    e,
    fallback: 'Something went wrong. Try again.',
  );

  static String _short(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    this.icon,
    this.emoji,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData? icon;
  final String? emoji;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.42),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: emoji != null
                ? Text(emoji!, style: const TextStyle(fontSize: 22))
                : Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// CATEGORY SHEET
// =========================================================================

class _CategorySheet extends StatelessWidget {
  const _CategorySheet({required this.active, required this.onPick});
  final String? active;
  final ValueChanged<String?> onPick;
  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      expand: false,
      builder: (_, controller) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 14),
              Center(
                child: Text(
                  'Whisper categories',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  controller: controller,
                  children: [
                    _CategoryRow(
                      label: 'All categories',
                      selected: active == null,
                      onTap: () => onPick(null),
                    ),
                    for (final c in FeedCategories.all)
                      _CategoryRow(
                        label: FeedCategories.label(c),
                        selected: active == c,
                        onTap: () => onPick(c),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: VentlyColors.berryMagenta,
      ),
      title: Text(
        label,
        style: TextStyle(color: context.ink, fontWeight: FontWeight.w800),
      ),
      onTap: onTap,
    );
  }
}

// =========================================================================
// ERROR STATE (dark surface)
// =========================================================================

class _WhispersError extends StatelessWidget {
  const _WhispersError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VentlyTokens.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 44,
              color: Colors.white.withOpacity(0.9),
            ),
            const SizedBox(height: VentlyTokens.s12),
            const Text(
              'Whispers unavailable',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 17,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              UserFriendlyErrors.message(error),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.72),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: VentlyTokens.s16),
            FilledButton.icon(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: VentlyColors.berryMagenta,
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text(
                'Try again',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// EMPTY STATE
// =========================================================================

class _WhispersEmpty extends ConsumerWidget {
  const _WhispersEmpty({
    required this.category,
    required this.onClearCategory,
    required this.onComposeSoon,
  });
  final String? category;
  final VoidCallback? onClearCategory;
  final VoidCallback onComposeSoon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posts =
        (ref.watch(homeDiscoveryPostsProvider).valueOrNull ?? const <Post>[])
            .where((post) => !post.isWhisper)
            .take(3)
            .toList();
    final people =
        (ref.watch(friendSuggestionsProvider).valueOrNull ??
                const <FriendSuggestion>[])
            .take(8)
            .toList();

    return SafeArea(
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 60, 28, 26),
            sliver: SliverToBoxAdapter(
              child: Column(
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.14),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withOpacity(0.22)),
                    ),
                    child: const Icon(
                      Icons.graphic_eq_rounded,
                      color: Colors.white,
                      size: 42,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    category == null
                        ? 'Be the first voice today'
                        : 'No whispers in this category yet',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    category == null
                        ? 'Until a new voice arrives, keep exploring real conversations and people from the community.'
                        : 'Try All, record your own, or explore the conversations below.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.72),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: onComposeSoon,
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    icon: const Icon(Icons.mic_rounded, size: 18),
                    label: const Text(
                      'Record a Whisper',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  if (onClearCategory != null) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: onClearCategory,
                      style: TextButton.styleFrom(
                        foregroundColor: VentlyColors.berryMagenta,
                      ),
                      child: const Text(
                        'Show all categories',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (posts.isNotEmpty) ...[
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 4),
                child: Text(
                  'Conversations for you',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: posts.length,
              itemBuilder: (context, index) {
                final post = posts[index];
                return PostCard(
                  post: post,
                  onTap: () =>
                      context.push('/post/${post.postId}', extra: post),
                  onComment: () =>
                      context.push('/post/${post.postId}', extra: post),
                  onShare: () => context.push('/post/${post.postId}/share'),
                );
              },
            ),
          ],
          if (people.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'People worth hearing',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 88,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: people.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 16),
                        itemBuilder: (context, index) {
                          final person = people[index];
                          return InkWell(
                            onTap: () => context.push('/user/${person.userId}'),
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 72,
                              child: Column(
                                children: [
                                  ProfileAvatar(
                                    avatarSeed: person.avatarSeed,
                                    label: person.pseudonym,
                                    profilePhotoUrl: person.profilePhotoUrl,
                                    showVerifiedBadge: person.isVerified,
                                    size: 52,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '@${person.pseudonym}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 116)),
        ],
      ),
    );
  }
}

// _RecordSoonSheet was removed when the real recorder shipped — the
// + button on the Whispers screen now routes directly to
// /whispers/new (see CreateWhisperScreen).
