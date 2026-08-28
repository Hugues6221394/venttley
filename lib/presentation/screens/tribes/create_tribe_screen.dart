import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/vently_premium_background.dart';
import '../../../core/user_friendly_errors.dart';

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
  bool _customMode = false;
  String _visibility = 'public';
  bool _joinApproval = false;
  bool _useSafetyTemplate = true;
  bool _submitting = false;
  Uint8List? _avatarBytes;
  Uint8List? _bannerBytes;
  String _avatarExtension = 'jpg';
  String _bannerExtension = 'jpg';

  static const _options = <(String key, String label, IconData icon)>[
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

  @override
  void dispose() {
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
      context.go('/tribe/${tribe.slug}/manage/settings');
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
      _toast('Could not open this image: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(
          'Create a Tribe',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: VentlyPremiumBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            _CreationMedia(
              avatarBytes: _avatarBytes,
              bannerBytes: _bannerBytes,
              onAvatar: () => _pickImage(banner: false),
              onBanner: () => _pickImage(banner: true),
            ),
            const SizedBox(height: 16),
            Text(
              'Set a clear identity, access level, and safety baseline before the doors open.',
              style: TextStyle(color: scheme.onSurface.withOpacity(0.7)),
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
                for (final (key, label, icon) in _options)
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
            const SizedBox(height: 18),
            Text(
              'Visibility',
              style: TextStyle(color: context.ink, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'public', label: Text('Public')),
                ButtonSegment(value: 'private', label: Text('Private')),
                ButtonSegment(value: 'invite_only', label: Text('Invite')),
              ],
              selected: {_visibility},
              onSelectionChanged: (value) =>
                  setState(() => _visibility = value.first),
            ),
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _joinApproval,
              onChanged: (value) => setState(() => _joinApproval = value),
              title: const Text('Approve new members'),
              subtitle: const Text('Review requests before membership starts'),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _useSafetyTemplate,
              onChanged: (value) => setState(() => _useSafetyTemplate = value),
              title: const Text('Start with safety rules'),
              subtitle: const Text(
                'Respect, privacy, and anti-harassment baseline',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_rounded),
              label: const Text('Create Tribe'),
            ),
          ],
        ),
      ),
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
