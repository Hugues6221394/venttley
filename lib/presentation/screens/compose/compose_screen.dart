import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../animation/widgets/animated_button.dart';
import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../data/services/moderation_service.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/mood_chip.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/vently_premium_background.dart';

class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key, this.queryParams = const {}});

  /// Deep-link query params, e.g. `format=poll`, `category=questions`.
  final Map<String, String> queryParams;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _controller = TextEditingController();
  final _pollQ = TextEditingController();
  final _pollA = TextEditingController();
  final _pollB = TextEditingController();
  String _category = 'confessions';
  String _mood = 'healing';
  bool _busy = false;
  bool _success = false;
  bool _includePoll = false;
  bool _isWhisper = false;
  bool _storyFriendsOnly = true;

  // Optional attached photo. Bytes live in memory until submit; we
  // only upload on send so a discard costs zero network.
  Uint8List? _pendingImageBytes;
  String _pendingImageExt = 'jpg';
  String _pendingImageMime = 'image/jpeg';

  @override
  void initState() {
    super.initState();
    // Reading providers here is safe; WRITING them is not — initState runs
    // during the route's first build and Riverpod throws "tried to modify a
    // provider while the widget tree was building". So: consume the one-shot
    // intents locally, and defer the resets to after the first frame.
    _isWhisper = ref.read(composeStoryModeProvider);
    _includePoll = ref.read(composeIncludePollProvider);
    String? initialCategory = ref.read(composeInitialCategoryProvider);
    String? initialDraft = ref.read(composeInitialDraftProvider);

    // Deep-link query params (/compose?format=poll&category=…) override the
    // sheet-set intents — applied locally, no provider round-trip.
    final q = widget.queryParams;
    if (q.isNotEmpty) {
      if (q['format'] == 'poll') {
        _includePoll = true;
        initialCategory = 'questions';
      }
      final qCategory = q['category'];
      if (qCategory != null && FeedCategories.all.contains(qCategory)) {
        initialCategory = qCategory;
      }
      final qDraft = q['draft'];
      if (qDraft != null && qDraft.isNotEmpty) initialDraft = qDraft;
    }

    if (initialCategory != null &&
        FeedCategories.all.contains(initialCategory)) {
      _category = initialCategory;
    }
    if (initialDraft != null && initialDraft.isNotEmpty) {
      _controller.text = initialDraft;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(composeStoryModeProvider.notifier).state = false;
      ref.read(composeIncludePollProvider.notifier).state = false;
      ref.read(composeInitialCategoryProvider.notifier).state = null;
      ref.read(composeInitialDraftProvider.notifier).state = null;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _pollQ.dispose();
    _pollA.dispose();
    _pollB.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto({required ImageSource source}) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 82,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final ext = picked.path.split('.').last.toLowerCase();
      setState(() {
        _pendingImageBytes = bytes;
        _pendingImageExt = ext == 'jpeg' ? 'jpg' : ext;
        _pendingImageMime = picked.mimeType ?? 'image/jpeg';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not pick image: $e')),
      );
    }
  }

  Future<void> _openPhotoSourceSheet() async {
    final source = await showModalBottomSheet<ImageSource>(
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.photo_library_outlined,
                    color: VentlyColors.berryMagenta),
                title: const Text('Choose from library',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.photo_camera_outlined,
                    color: VentlyColors.berryMagenta),
                title: const Text('Take a photo',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
    if (source != null) await _pickPhoto(source: source);
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _pendingImageBytes == null) return;
    if (_includePoll) {
      if (_pollQ.text.trim().length < 4 ||
          _pollA.text.trim().isEmpty ||
          _pollB.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Add a poll question and two options, or untoggle the poll.'),
          ),
        );
        return;
      }
    }
    setState(() => _busy = true);
    final moderation =
        await ref.read(moderationServiceProvider).review(text);
    if (!mounted) return;
    if (moderation.isBlocked) {
      setState(() => _busy = false);
      _showBlocked(moderation);
      return;
    }
    if (moderation.isWarn) {
      final proceed = await _confirmWarn(moderation);
      if (!proceed) {
        setState(() => _busy = false);
        return;
      }
    }
    final space = ref.read(composeTargetSpaceProvider);
    final tribe = ref.read(composeTargetTribeProvider);
    final effectiveTribeId = space?.tribeId ?? tribe?.tribeId;
    final effectiveTribeSlug = tribe?.slug;
    final persona = ref.read(activePersonaProvider);

    // Upload the attached photo first so we can stamp the post row
    // with a permanent URL. Failed uploads abort the send — we'd
    // rather block than ship a vent with a missing image.
    String? imagePath;
    String? imageUrl;
    if (_pendingImageBytes != null) {
      try {
        final up = await ref.read(repositoryProvider).uploadPostImage(
              bytes: _pendingImageBytes!,
              extension: _pendingImageExt,
              contentType: _pendingImageMime,
            );
        imagePath = up.path;
        imageUrl = up.url;
      } catch (e) {
        if (!mounted) return;
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo upload failed: $e')),
        );
        return;
      }
    }

    final post = await ref.read(repositoryProvider).createPost(
          content: text.isEmpty ? '' : text,
          category: _category,
          mood: _mood,
          tribeId: effectiveTribeId,
          spaceId: space?.spaceId,
          personaId: persona?.personaId,
          isWhisper: _isWhisper,
          imagePath: imagePath,
          imageUrl: imageUrl,
        );
    // Crisis tag — readers see the helpline banner if the safety classifier
    // surfaced self-harm signals. 'high' = Tier-1 keyword match (more
    // confident), 'elevated' = Tier-2 LLM-only signal. Best-effort: the post
    // is already saved, we just decorate it.
    if (moderation.surfaceCrisisHelpline) {
      final level =
          moderation.categories.contains(HazardCategory.selfHarm) &&
                  moderation.reasons.any((r) => r.contains('care about you'))
              ? 'high'
              : 'elevated';
      unawaited(
        ref.read(repositoryProvider).setPostCrisis(post.postId, level),
      );
    }
    if (_includePoll) {
      try {
        await ref.read(repositoryProvider).createPoll(
              postId: post.postId,
              question: _pollQ.text.trim(),
              optionTexts: [_pollA.text.trim(), _pollB.text.trim()],
            );
      } catch (e) {
        // Post landed; poll attach failed. Surface a soft error.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Posted, but poll failed: $e')),
          );
        }
      }
    }
    ref.read(composeTargetTribeProvider.notifier).state = null;
    ref.read(composeTargetSpaceProvider.notifier).state = null;
    ref.read(composeStoryModeProvider.notifier).state = false;
    ref.read(composeIncludePollProvider.notifier).state = false;
    ref.read(composeInitialCategoryProvider.notifier).state = null;
    // Live insertion: bump every feed the new vent might appear in
    // so SpaceHome / Tribe / global Feed pick up the row immediately
    // without waiting for the realtime tick.
    ref.invalidate(feedPostsProvider);
    if (space != null) {
      for (final s in [
        'fresh', 'trending', 'helpful', 'unanswered', 'keeper'
      ]) {
        ref.invalidate(spacePostsProvider(
            SpaceFeedQuery(spaceId: space.spaceId, sort: s)));
      }
      ref.invalidate(spaceByIdProvider(space.spaceId));
      ref.invalidate(spacesByTribeProvider(space.tribeId));
    }
    if (!mounted) return;
    // Success beat: the button morphs to a check for a moment before the
    // route changes, so posting feels acknowledged rather than abrupt.
    setState(() {
      _busy = false;
      _success = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 550));
    if (!mounted) return;
    if (space != null) {
      context.go('/tribe/${space.tribeSlug}/space/${space.spaceId}');
    } else if (effectiveTribeSlug != null) {
      context.go('/tribe/$effectiveTribeSlug');
    } else {
      context.go('/feed');
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tribe == null
            ? (_isWhisper
                ? 'Story posted for 24 hours.'
                : 'Vent posted anonymously.')
            : 'Posted to ${tribe.name}.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_isWhisper) {
      return _buildStoryComposer(context);
    }
    final Tribe? target = ref.watch(composeTargetTribeProvider);
    final personas = ref.watch(myPersonasProvider).valueOrNull ?? const [];
    final activePersona = ref.watch(activePersonaProvider);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/feed'),
        ),
        title: Text(_isWhisper ? 'New Story' : 'New Vent'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _submit,
            child: const Text('Post'),
          ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (target != null)
                  GlassCard(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    borderRadius: 14,
                    child: Row(
                      children: [
                        Icon(Icons.diversity_3,
                            size: 16, color: scheme.primary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Posting in ${target.name}',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: scheme.primary),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => ref
                              .read(composeTargetTribeProvider.notifier)
                              .state = null,
                          tooltip: 'Post to general feed instead',
                        ),
                      ],
                    ),
                  ),
                if (personas.isNotEmpty)
                  GlassCard(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    borderRadius: 14,
                    child: Row(
                      children: [
                        Icon(Icons.theater_comedy_outlined,
                            size: 16, color: scheme.secondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            activePersona == null
                                ? 'Posting as your default handle'
                                : 'Posting as @${activePersona.pseudonym}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.secondary,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _showPersonaPicker(
                              context, personas, activePersona),
                          child: const Text('Switch'),
                        ),
                      ],
                    ),
                  ),
              Row(
                children: [
                  const Text('Category',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final c in FeedCategories.all)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                label: Text(FeedCategories.label(c)),
                                selected: _category == c,
                                onSelected: (_) => setState(() => _category = c),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Mood', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final m in Moods.all)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: ChoiceChip(
                                avatar: Text(Moods.emoji(m)),
                                label: Text(Moods.label(m)),
                                selected: _mood == m,
                                onSelected: (_) => setState(() => _mood = m),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_pendingImageBytes != null)
                _PendingImageChip(
                  bytes: _pendingImageBytes!,
                  onClear: () =>
                      setState(() => _pendingImageBytes = null),
                ),
              Expanded(
                child: GlassCard(
                  padding: const EdgeInsets.all(12),
                  borderRadius: 20,
                  child: TextField(
                    controller: _controller,
                    maxLength: 1000,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: 'Drop the thought. Keep names out, keep it real.',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _openPhotoSourceSheet,
                    icon: Icon(
                      _pendingImageBytes != null
                          ? Icons.image
                          : Icons.image_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                    label: Text(
                        _pendingImageBytes != null ? 'Photo on' : 'Photo'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _includePoll = !_includePoll),
                    icon: Icon(
                      _includePoll ? Icons.poll : Icons.poll_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                    label: Text(_includePoll ? 'Poll on' : 'Poll'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _isWhisper = !_isWhisper),
                    icon: Icon(
                      _isWhisper ? Icons.nightlight : Icons.nightlight_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                    label: Text(_isWhisper ? 'Story - 24h' : '24h Story'),
                  ),
                  const Spacer(),
                  MoodChip(mood: _mood, dense: true),
                ],
              ),
              if (_includePoll)
                GlassCard(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(12),
                  borderRadius: 16,
                  child: Column(
                    children: [
                      TextField(
                        controller: _pollQ,
                        maxLength: 120,
                        decoration: const InputDecoration(
                          labelText: 'Poll question',
                          hintText: 'e.g. Should I text them back?',
                          counterText: '',
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _pollA,
                              maxLength: 60,
                              decoration: const InputDecoration(
                                labelText: 'Option A',
                                counterText: '',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _pollB,
                              maxLength: 60,
                              decoration: const InputDecoration(
                                labelText: 'Option B',
                                counterText: '',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              SafeArea(
                top: false,
                child: AnimatedButton(
                  label: 'Post Anonymously',
                  state: _success
                      ? VentlyButtonState.success
                      : _busy
                          ? VentlyButtonState.loading
                          : VentlyButtonState.idle,
                  onPressed: _submit,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildStoryComposer(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    color: VentlyColors.berryMagenta,
                    onPressed: () => context.go('/feed'),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Venttly',
                    style: TextStyle(
                      color: Color(0xFFB91452),
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    color: context.ink,
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  children: [
                    Container(
                      height: 430,
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xFFFFB8CD),
                            Color(0xFFE56F9B),
                            Color(0xFFBD0E53),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: VentlyColors.berryMagenta.withOpacity(0.20),
                            blurRadius: 24,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: VentlyColors.deepBurgundy.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'LIVE PREVIEW',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Center(
                            child: Container(
                              width: 106,
                              height: 106,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.18),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.22),
                                ),
                              ),
                              child: const Icon(Icons.favorite_rounded,
                                  color: Colors.white, size: 48),
                            ),
                          ),
                          const SizedBox(height: 18),
                          TextField(
                            controller: _controller,
                            maxLength: 220,
                            maxLines: 4,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              height: 1.28,
                            ),
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: 'Share your mood today...',
                              hintStyle: TextStyle(
                                color: Colors.white.withOpacity(0.88),
                                fontWeight: FontWeight.w800,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    GridView.count(
                      crossAxisCount: 2,
                      childAspectRatio: 1.2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _StoryCreateOption(
                          icon: Icons.camera_alt_outlined,
                          label: 'Capture Photo',
                          color: VentlyColors.berryMagenta,
                          onTap: () => _selectStoryPreset(
                            category: 'funny_confessions',
                            mood: 'happy',
                          ),
                        ),
                        _StoryCreateOption(
                          icon: Icons.image_outlined,
                          label: 'Gallery',
                          color: const Color(0xFFF79ABD),
                          onTap: () => _selectStoryPreset(
                            category: 'healing_corner',
                            mood: 'healing',
                          ),
                        ),
                        _StoryCreateOption(
                          icon: Icons.edit_note_rounded,
                          label: 'Text Only',
                          color: const Color(0xFF008F4C),
                          onTap: () => _selectStoryPreset(
                            category: 'late_night',
                            mood: 'overthinking',
                          ),
                        ),
                        _StoryCreateOption(
                          icon: Icons.mic_none_rounded,
                          label: 'Audio Note',
                          color: VentlyColors.berryMagenta,
                          pale: true,
                          onTap: () => _selectStoryPreset(
                            category: 'late_night',
                            mood: 'hopeful',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.74),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: VentlyColors.softMauve.withOpacity(0.38),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.visibility_outlined,
                                  color: VentlyColors.berryMagenta),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Privacy Settings',
                                      style: TextStyle(
                                        color: context.ink,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 15,
                                      ),
                                    ),
                                    Text(
                                      'Friends only',
                                      style: TextStyle(
                                        color: context.ink,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: _storyFriendsOnly,
                                onChanged: (value) =>
                                    setState(() => _storyFriendsOnly = value),
                                activeColor: VentlyColors.berryMagenta,
                              ),
                            ],
                          ),
                          Divider(
                            color: VentlyColors.softMauve.withOpacity(0.22),
                          ),
                          Row(
                            children: [
                              const Icon(Icons.timer_outlined,
                                  color: VentlyColors.berryMagenta),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Story Duration',
                                  style: TextStyle(
                                    color: context.ink,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              const Text(
                                '24 Hours',
                                style: TextStyle(
                                  color: VentlyColors.softMauve,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB91452),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    elevation: 8,
                    shadowColor: VentlyColors.berryMagenta.withOpacity(0.26),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Share to Story',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            SizedBox(width: 8),
                            Icon(Icons.send_rounded, color: Colors.white),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  void _selectStoryPreset({
    required String category,
    required String mood,
  }) {
    setState(() {
      _category = category;
      _mood = mood;
    });
  }

  void _showPersonaPicker(
      BuildContext context, List<Persona> personas, Persona? active) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Post as',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: const Text('Default handle'),
                trailing: active == null ? const Icon(Icons.check) : null,
                onTap: () {
                  ref.read(activePersonaProvider.notifier).state = null;
                  Navigator.pop(ctx);
                },
              ),
              for (final p in personas)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: AnonymousAvatar(
                      seed: p.avatarSeed, label: p.pseudonym, size: 30),
                  title: Text('@${p.pseudonym}'),
                  trailing: active?.personaId == p.personaId
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    ref.read(activePersonaProvider.notifier).state = p;
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBlocked(ModerationResult res) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(Icons.shield_outlined,
                color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('Held back by safety AI'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in res.reasons) Text('• $r'),
            if (res.surfaceCrisisHelpline) ...[
              const SizedBox(height: 12),
              const Text(
                'If you\'re in crisis right now, you\'re not alone:',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              for (final r in kCrisisResources) Text('• ${r.label} — ${r.reach}'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmWarn(ModerationResult res) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: const Text('Heads up'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in res.reasons) Text('• $r'),
                if (res.surfaceCrisisHelpline) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'We care about you. Crisis lines are available 24/7.',
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Edit'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Post anyway'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _StoryCreateOption extends StatelessWidget {
  const _StoryCreateOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.pale = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool pale;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.68),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.38)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: pale ? const Color(0xFFFFEAF1) : color,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: pale ? color : Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ink,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small preview chip rendered above the editor when a photo is
/// staged. Tap "✕" to discard before sending.
class _PendingImageChip extends StatelessWidget {
  const _PendingImageChip({required this.bytes, required this.onClear});
  final Uint8List bytes;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.memory(
              bytes,
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: InkWell(
              onTap: onClear,
              customBorder: const CircleBorder(),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
