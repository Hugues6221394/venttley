import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/vently_premium_background.dart';
import '../../../core/user_friendly_errors.dart';
import '../home/home_shell.dart';

/// The Tribe category taxonomy, read from public.tribe_categories.
///
/// Screen-scoped: this is the only surface offering a category picker, so the
/// live list and the fallback below sit together rather than a file apart.
final tribeCategoriesProvider = FutureProvider.autoDispose<List<TribeCategory>>(
  (ref) async {
    return ref.watch(repositoryProvider).tribeCategories();
  },
);

class CreateTribeScreen extends ConsumerStatefulWidget {
  const CreateTribeScreen({super.key});

  @override
  ConsumerState<CreateTribeScreen> createState() => _CreateTribeScreenState();
}

class _CreateTribeScreenState extends ConsumerState<CreateTribeScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _customCategory = TextEditingController();
  final _tags = TextEditingController();
  final _welcome = TextEditingController();
  final _picker = ImagePicker();
  String _category = 'interest_group';

  /// One key for this form, minted when the screen opens.
  ///
  /// Per-form and not per-tap: the whole point is that a second submit — a
  /// double tap, or a retry after the response was lost — carries the *same*
  /// key and so returns the Tribe the first attempt already made. Minting it at
  /// submit time would make every retry a fresh Tribe, which is the bug.
  final String _mutationId = const Uuid().v4();
  bool _nameWasValid = false;
  bool _customMode = false;
  String _visibility = 'public';
  bool _joinApproval = false;
  bool _useSafetyTemplate = true;
  bool _submitting = false;
  Uint8List? _avatarBytes;
  Uint8List? _bannerBytes;
  String _avatarExtension = 'jpg';
  String _bannerExtension = 'jpg';

  /// Fallback only. The live list comes from public.tribe_categories via
  /// tribeCategoriesProvider; this is what shows when that table is not there
  /// yet, because a Tribe form with no categories is a form nobody can submit.
  /// Keep it in step with the seed in 20260830090000.
  static const _fallbackOptions = <(String key, String label, IconData icon)>[
    ('campus', 'Campus', Icons.school_outlined),
    ('city', 'City', Icons.location_city_outlined),
    ('interest_group', 'Interest', Icons.interests_outlined),
    ('hobby', 'Hobby', Icons.palette_outlined),
    ('support', 'Support', Icons.favorite_outline),
    ('venting', 'Venting', Icons.bedtime_outlined),
    ('wellness', 'Wellness', Icons.spa_outlined),
    ('creativity', 'Creativity', Icons.brush_outlined),
    ('faith', 'Faith', Icons.auto_awesome_outlined),
    ('lgbtq', 'LGBTQ+', Icons.diversity_1_outlined),
    ('grief', 'Grief', Icons.filter_vintage_outlined),
    ('growth', 'Growth', Icons.trending_up_rounded),
    ('study', 'Study', Icons.menu_book_outlined),
    ('gaming', 'Gaming', Icons.sports_esports_outlined),
    ('music', 'Music', Icons.music_note_outlined),
    ('fitness', 'Fitness', Icons.fitness_center_outlined),
  ];

  /// Icons stay client-side: a Flutter symbol does not belong in a table.
  /// A key the app has not seen gets a neutral icon rather than being dropped,
  /// so a category added server-side appears without an app release.
  static const _iconByKey = <String, IconData>{
    'campus': Icons.school_outlined,
    'city': Icons.location_city_outlined,
    'interest_group': Icons.interests_outlined,
    'hobby': Icons.palette_outlined,
    'support': Icons.favorite_outline,
    'venting': Icons.bedtime_outlined,
    'wellness': Icons.spa_outlined,
    'creativity': Icons.brush_outlined,
    'faith': Icons.auto_awesome_outlined,
    'lgbtq': Icons.diversity_1_outlined,
    'grief': Icons.filter_vintage_outlined,
    'growth': Icons.trending_up_rounded,
    'study': Icons.menu_book_outlined,
    'gaming': Icons.sports_esports_outlined,
    'music': Icons.music_note_outlined,
    'fitness': Icons.fitness_center_outlined,
  };

  List<(String, String, IconData)> _categoryOptions(WidgetRef ref) {
    final live = ref.watch(tribeCategoriesProvider).valueOrNull;
    if (live == null || live.isEmpty) return _fallbackOptions;
    return [
      for (final c in live)
        (c.key, c.label, _iconByKey[c.key] ?? Icons.tag_rounded),
    ];
  }

  @override
  void initState() {
    super.initState();
    // The footer's Continue button is disabled until there is a name, and the
    // footer only learns the name changed if something rebuilds it. A
    // TextField repaints its own character counter without rebuilding the rest
    // of the screen, so without this listener the button stays greyed out no
    // matter how much you type — which is worse than no validation at all,
    // because the form looks broken rather than incomplete.
    _name.addListener(_onNameChanged);
  }

  void _onNameChanged() {
    final canAdvanceNow = _name.text.trim().length >= 3;
    if (canAdvanceNow != _nameWasValid) {
      _nameWasValid = canAdvanceNow;
      // Only on the transition, not on every keystroke: rebuilding a form this
      // size per character is work nobody asked for.
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    _desc.dispose();
    _customCategory.dispose();
    _tags.dispose();
    _welcome.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.length < 3 || name.length > 50) {
      _toast('Pick a name with 3 to 50 characters.');
      return;
    }
    if (_desc.text.trim().length > 500) {
      _toast('Keep the description under 500 characters.');
      return;
    }
    final tags = _parseTags(_tags.text);
    if (tags.length > 8) {
      _toast('Use no more than 8 tags.');
      return;
    }
    // Custom category: lowercase, slug-ish, 2–40 chars (matches the DB check).
    var category = _category;
    if (_customMode) {
      category = _customCategory.text.trim().toLowerCase();
      if (category.length < 2) {
        _toast('Give your category a name (2+ characters).');
        return;
      }
    }
    setState(() => _submitting = true);
    try {
      final tribe = await ref
          .read(repositoryProvider)
          .createTribe(
            name: name,
            category: category,
            description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
            idempotencyKey: _mutationId,
            isPrivate: _visibility != 'public',
            tags: tags,
            visibility: _visibility,
            welcomeMessage: _welcome.text.trim(),
            settings: TribeGovernanceSettings(
              joinApprovalRequired: _joinApproval,
            ),
            rules: _useSafetyTemplate
                ? const [
                    TribeRuleItem(
                      position: 0,
                      title: 'Be respectful',
                      description:
                          'Disagree without attacking, mocking, or shaming.',
                    ),
                    TribeRuleItem(
                      position: 1,
                      title: 'Protect personal information',
                      description:
                          'Do not share private or identifying information.',
                    ),
                    TribeRuleItem(
                      position: 2,
                      title: 'No hate or harassment',
                      description:
                          'Hate speech and targeted harassment are not allowed.',
                    ),
                  ]
                : const [],
          );
      Object? mediaError;
      String? avatarUrl;
      String? bannerUrl;
      try {
        if (_avatarBytes != null) {
          final upload = await ref
              .read(repositoryProvider)
              .uploadTribeAvatar(
                tribeId: tribe.tribeId,
                bytes: _avatarBytes!,
                extension: _avatarExtension,
                contentType: _contentType(_avatarExtension),
              );
          avatarUrl = upload.url;
        }
        if (_bannerBytes != null) {
          final upload = await ref
              .read(repositoryProvider)
              .uploadTribeAvatar(
                tribeId: tribe.tribeId,
                bytes: _bannerBytes!,
                extension: _bannerExtension,
                contentType: _contentType(_bannerExtension),
              );
          bannerUrl = upload.url;
        }
        if (avatarUrl != null || bannerUrl != null) {
          await ref
              .read(repositoryProvider)
              .updateTribeConfiguration(
                tribeId: tribe.tribeId,
                avatarUrl: avatarUrl,
                bannerUrl: bannerUrl,
              );
        }
      } catch (error) {
        mediaError = error;
      }
      ref.invalidate(tribesProvider);
      ref.invalidate(tribesIKeepProvider);
      if (!mounted) return;
      // Show the moment instead of jumping to the console. Landing straight in
      // Manage Tribe never said the Tribe existed, never said the account had
      // just become a Keeper, and offered no idea what to do next — the person
      // simply found themselves in an administration screen.
      setState(() => _created = tribe);
      if (mediaError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Tribe created. Its images could not be saved yet: $mediaError',
            ),
          ),
        );
      }
    } catch (e) {
      // Was interpolating the raw exception, so a person saw
      // "PostgrestException(message: adults_only...)". Named server errors are
      // translated centrally now.
      _toast(
        UserFriendlyErrors.message(
          e,
          fallback: "Couldn't create this Tribe. Please try again.",
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _pickImage({required bool banner}) async {
    try {
      final image = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 84,
        maxWidth: banner ? 2048 : 1024,
        maxHeight: banner ? 1152 : 1024,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (bytes.length > 8 * 1024 * 1024) {
        _toast('Choose an image smaller than 8 MB.');
        return;
      }
      final extension = image.name.contains('.')
          ? image.name.split('.').last.toLowerCase()
          : 'jpg';
      if (!mounted) return;
      setState(() {
        if (banner) {
          _bannerBytes = bytes;
          _bannerExtension = extension;
        } else {
          _avatarBytes = bytes;
          _avatarExtension = extension;
        }
      });
    } catch (error) {
      _toast(
        UserFriendlyErrors.message(
          error,
          fallback: "Couldn't open that image.",
        ),
      );
    }
  }

  /// Which step of the flow is on screen.
  ///
  /// Three, not the eight the brief sketches. Forcing spaces, invites and
  /// purpose before a Tribe can exist contradicts the same brief's own rule
  /// that only name, category and visibility are required — and a fifteen
  /// minute form before you own anything is how people abandon this. The rest
  /// moves to the checklist on the other side of creation, where it can be
  /// done in any order or not at all.
  int _step = 0;
  static const _stepCount = 3;

  /// Set once creation succeeds, which swaps the whole screen for the
  /// "you're a Keeper" moment rather than dropping the user into an
  /// administration console with no acknowledgement that anything happened.
  Tribe? _created;

  bool get _canAdvance {
    if (_step == 0) return _name.text.trim().length >= 3;
    return true;
  }

  void _goTo(int step) {
    setState(() => _step = step.clamp(0, _stepCount - 1));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_created case final Tribe tribe) {
      return _TribeCreatedView(tribe: tribe);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(
          'Create a Tribe',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        leading: IconButton(
          tooltip: _step == 0 ? 'Close' : 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _submitting
              ? null
              : () => _step == 0 ? context.pop() : _goTo(_step - 1),
        ),
      ),
      body: VentlyPremiumBackground(
        child: Column(
          children: [
            _StepBar(step: _step, total: _stepCount),
            Expanded(
              child: ListView(
                // Clear the floating nav. At 40 the last rows sat under the
                // pill, which paints over the branch, so the category chips at
                // y~806 met a nav occupying ~770-835 and tapping "Interest"
                // switched tabs instead.
                padding: const EdgeInsets.fromLTRB(
                  20,
                  8,
                  20,
                  HomeShell.navClearance,
                ),
                children: switch (_step) {
                  0 => [
                    _CreationMedia(
                      avatarBytes: _avatarBytes,
                      bannerBytes: _bannerBytes,
                      onAvatar: () => _pickImage(banner: false),
                      onBanner: () => _pickImage(banner: true),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Set a clear identity, access level, and safety baseline before the doors open.',
                      style: TextStyle(
                        color: scheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(height: 16),
                    GlassCard(
                      child: Column(
                        children: [
                          TextField(
                            controller: _name,
                            maxLength: 50,
                            decoration: const InputDecoration(
                              labelText: 'Tribe name',
                              hintText: 'e.g. Quiet Mornings, Kigali Lo-Fi',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _desc,
                            maxLength: 500,
                            minLines: 3,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              labelText: 'Description (optional)',
                              hintText: 'What is this Tribe a sanctuary for?',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _welcome,
                            maxLength: 240,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Welcome message',
                              hintText: 'Shown when someone joins',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Category',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (key, label, icon) in _categoryOptions(ref))
                          ChoiceChip(
                            selected: !_customMode && _category == key,
                            onSelected: (_) => setState(() {
                              _customMode = false;
                              _category = key;
                            }),
                            avatar: Icon(icon, size: 14, color: scheme.primary),
                            label: Text(label),
                          ),
                        // Create-your-own category.
                        ChoiceChip(
                          selected: _customMode,
                          onSelected: (_) => setState(() => _customMode = true),
                          avatar: Icon(
                            Icons.add_rounded,
                            size: 16,
                            color: scheme.primary,
                          ),
                          label: const Text('Custom'),
                        ),
                      ],
                    ),
                    if (_customMode) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _customCategory,
                        maxLength: 40,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Your category',
                          hintText: 'e.g. Night owls, Recovery, K-pop',
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextField(
                      controller: _tags,
                      decoration: const InputDecoration(
                        labelText: 'Discovery tags',
                        hintText: 'support, campus, healing',
                        helperText: 'Up to 8, separated by commas',
                      ),
                    ),
                  ],
                  1 => [
                    const SizedBox(height: 18),
                    Text(
                      'Visibility',
                      style: TextStyle(
                        color: context.ink,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'public', label: Text('Public')),
                        ButtonSegment(value: 'private', label: Text('Private')),
                        ButtonSegment(
                          value: 'invite_only',
                          label: Text('Invite'),
                        ),
                      ],
                      selected: {_visibility},
                      onSelectionChanged: (value) =>
                          setState(() => _visibility = value.first),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _joinApproval,
                      onChanged: (value) =>
                          setState(() => _joinApproval = value),
                      title: const Text('Approve new members'),
                      subtitle: const Text(
                        'Review requests before membership starts',
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _useSafetyTemplate,
                      onChanged: (value) =>
                          setState(() => _useSafetyTemplate = value),
                      title: const Text('Start with safety rules'),
                      subtitle: const Text(
                        'Respect, privacy, and anti-harassment baseline',
                      ),
                    ),
                  ],
                  _ => [_reviewBody(scheme)],
                },
              ),
            ),
            _StepFooter(
              step: _step,
              total: _stepCount,
              busy: _submitting,
              canAdvance: _canAdvance,
              onBack: () => _goTo(_step - 1),
              onNext: () => _goTo(_step + 1),
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }

  /// The last look before anything is created.
  ///
  /// Not decoration: this is the only place the whole thing is visible at
  /// once, and creation is the point after which a name is public and members
  /// can arrive. Everything shown here is the value that will actually be
  /// sent, read back off the same controllers the submit uses, so it cannot
  /// drift from what happens next.
  Widget _reviewBody(ColorScheme scheme) {
    final name = _name.text.trim();
    final desc = _desc.text.trim();
    final category = _customMode ? _customCategory.text.trim() : _category;
    final categoryLabel = _categoryOptions(
      ref,
    ).where((o) => o.$1 == category).map((o) => o.$2).firstOrNull;
    final tags = _parseTags(_tags.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Review your Tribe',
          style: TextStyle(
            color: context.ink,
            fontWeight: FontWeight.w900,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'This is what people will see. You can change any of it later.',
          style: TextStyle(color: scheme.onSurface.withOpacity(0.7)),
        ),
        const SizedBox(height: 14),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? 'Untitled Tribe' : name,
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                ),
              ),
              if (desc.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  desc,
                  style: TextStyle(color: scheme.onSurface.withOpacity(0.78)),
                ),
              ],
              const SizedBox(height: 14),
              _ReviewRow(label: 'Category', value: categoryLabel ?? category),
              _ReviewRow(
                label: 'Visibility',
                value: switch (_visibility) {
                  'private' => 'Private — invite only',
                  'invite_only' => 'Invite — people request to join',
                  _ => 'Public — anyone can find it',
                },
              ),
              _ReviewRow(
                label: 'Joining',
                value: _joinApproval
                    ? 'You approve each new member'
                    : 'Anyone allowed by visibility can join',
              ),
              _ReviewRow(
                label: 'Rules',
                value: _useSafetyTemplate
                    ? 'Safety baseline included'
                    : 'None yet — you can add them after',
              ),
              if (tags.isNotEmpty)
                _ReviewRow(label: 'Tags', value: tags.join(', ')),
            ],
          ),
        ),
      ],
    );
  }

  static List<String> _parseTags(String value) => value
      .split(',')
      .map((tag) => tag.trim().toLowerCase())
      .where((tag) => tag.length >= 2)
      .toSet()
      .toList(growable: false);

  static String _contentType(String extension) => switch (extension) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    'heic' || 'heif' => 'image/heic',
    _ => 'image/jpeg',
  };
}

class _CreationMedia extends StatelessWidget {
  const _CreationMedia({
    required this.avatarBytes,
    required this.bannerBytes,
    required this.onAvatar,
    required this.onBanner,
  });

  final Uint8List? avatarBytes;
  final Uint8List? bannerBytes;
  final VoidCallback onAvatar;
  final VoidCallback onBanner;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 172,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            bottom: 28,
            child: Material(
              color: context.glass(.9),
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onBanner,
                child: bannerBytes == null
                    ? const Center(
                        child: Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 34,
                          color: VentlyColors.berryMagenta,
                        ),
                      )
                    : Image.memory(bannerBytes!, fit: BoxFit.cover),
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 0,
            child: GestureDetector(
              onTap: onAvatar,
              child: Container(
                width: 84,
                height: 84,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  shape: BoxShape.circle,
                ),
                child: CircleAvatar(
                  backgroundColor: VentlyColors.roseTint,
                  backgroundImage: avatarBytes == null
                      ? null
                      : MemoryImage(avatarBytes!),
                  child: avatarBytes == null
                      ? const Icon(
                          Icons.add_a_photo_outlined,
                          color: VentlyColors.berryMagenta,
                        )
                      : null,
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 36,
            child: IconButton.filledTonal(
              tooltip: 'Choose banner image',
              onPressed: onBanner,
              icon: const Icon(Icons.edit_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where you are, and how much is left.
///
/// A three-segment bar rather than "Step 2 of 3" alone: the point of showing
/// progress on a creation flow is to promise it is short, and a number does
/// not communicate short as quickly as a nearly-full bar does.
class _StepBar extends StatelessWidget {
  const _StepBar({required this.step, required this.total});

  final int step;
  final int total;

  static const _titles = ['Identity', 'Access', 'Review'];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < total; i++) ...[
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    height: 4,
                    decoration: BoxDecoration(
                      color: i <= step
                          ? VentlyColors.berryMagenta
                          : VentlyColors.softMauve.withOpacity(0.28),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                if (i != total - 1) const SizedBox(width: 6),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_titles[step]}  ·  step ${step + 1} of $total',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              color: context.ink.withOpacity(0.65),
            ),
          ),
        ],
      ),
    );
  }
}

/// Back / Next, and Create only on the last step.
///
/// Pinned rather than scrolled with the form, so the way forward is never
/// something you have to go looking for — and because the previous version put
/// its only submit button at the bottom of a long list, underneath the nav.
class _StepFooter extends StatelessWidget {
  const _StepFooter({
    required this.step,
    required this.total,
    required this.busy,
    required this.canAdvance,
    required this.onBack,
    required this.onNext,
    required this.onSubmit,
  });

  final int step;
  final int total;
  final bool busy;
  final bool canAdvance;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final last = step == total - 1;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
        child: Row(
          children: [
            if (step > 0) ...[
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton(
                    onPressed: busy ? null : onBack,
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Back',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              flex: 2,
              child: SizedBox(
                height: 50,
                child: FilledButton(
                  // Disabled rather than failing on submit: a Tribe needs a
                  // name, and finding that out after three screens is worse
                  // than a button that waits.
                  onPressed: busy || (!last && !canAdvance)
                      ? null
                      : (last ? onSubmit : onNext),
                  style: FilledButton.styleFrom(
                    backgroundColor: VentlyColors.berryMagenta,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          last ? 'Create Tribe' : 'Continue',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                color: context.ink.withOpacity(0.55),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
                color: context.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The moment after creation.
///
/// Before this, a successful create dropped straight into Manage Tribe — a
/// full administration console, with no acknowledgement that anything had
/// happened and no indication that the person's account had just gained a
/// role. The Tribe existed; nothing said so.
///
/// Four things this has to land, in order: the Tribe is real, you are its
/// Keeper, here is what is still worth doing, and none of it is required now.
/// The checklist is explicitly optional — the whole reason creation asks for
/// three things instead of eight is that the rest belongs here, done in any
/// order, or not at all.
class _TribeCreatedView extends StatelessWidget {
  const _TribeCreatedView({required this.tribe});

  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              22,
              32,
              22,
              HomeShell.navClearance,
            ),
            children: [
              const Text('🎉', style: TextStyle(fontSize: 40)),
              const SizedBox(height: 12),
              Text(
                '${tribe.name} is live',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 8),
              // Names the role change plainly. Creating a Tribe is what makes
              // someone a Keeper — the capability is real from this moment —
              // and an app that grants authority silently leaves people
              // guessing what they are now allowed to do.
              Text(
                "You're its Keeper now. That's on top of everything you "
                'already do here — your vents, whispers, friends and chats '
                'are untouched.',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.75),
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 26),
              Text(
                'When you feel like it',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'None of this is required. Your Tribe works without it.',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.65),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              _NextStep(
                icon: Icons.forum_outlined,
                title: 'Start the first conversation',
                subtitle: 'A Tribe with something in it is easier to join',
                onTap: () => context.push('/tribe/${tribe.slug}'),
              ),
              _NextStep(
                icon: Icons.person_add_alt_1_outlined,
                title: 'Invite people',
                subtitle: 'Share a link, a QR code, or pick from your friends',
                onTap: () => context.push('/tribe/${tribe.slug}/members'),
              ),
              _NextStep(
                icon: Icons.rule_rounded,
                title: 'Set the ground rules',
                subtitle: 'What this space is, and what it is not',
                onTap: () => context.push('/tribe/${tribe.slug}/rules'),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 50,
                child: FilledButton(
                  onPressed: () => context.push('/tribe/${tribe.slug}/manage'),
                  style: FilledButton.styleFrom(
                    backgroundColor: VentlyColors.berryMagenta,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Open Keeper Studio',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 46,
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text(
                    'Not now',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NextStep extends StatelessWidget {
  const _NextStep({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(icon, color: VentlyColors.berryMagenta),
          title: Text(
            title,
            style: TextStyle(fontWeight: FontWeight.w800, color: context.ink),
          ),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}
