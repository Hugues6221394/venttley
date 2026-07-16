import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

class EditTribeScreen extends ConsumerStatefulWidget {
  const EditTribeScreen({
    super.key,
    required this.slug,
    this.focusWelcome = false,
  });
  final String slug;
  final bool focusWelcome;

  @override
  ConsumerState<EditTribeScreen> createState() => _EditTribeScreenState();
}

class _EditTribeScreenState extends ConsumerState<EditTribeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _category = TextEditingController();
  final _tags = TextEditingController();
  final _welcome = TextEditingController();
  final _welcomeFocus = FocusNode();
  final _picker = ImagePicker();
  String visibility = 'public';
  String? avatarUrl;
  String? bannerUrl;
  bool hydrated = false;
  bool saving = false;
  bool uploadingAvatar = false;
  bool uploadingBanner = false;
  bool welcomeFocusRequested = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _category.dispose();
    _tags.dispose();
    _welcome.dispose();
    _welcomeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tribe = ref.watch(tribeBySlugProvider(widget.slug)).valueOrNull;
    final me = ref.watch(sessionProvider);
    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (me?.userId != tribe.keeperId) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Edit identity')),
        body: const Center(child: Text('Only the Plug can edit this Tribe.')),
      );
    }
    if (!hydrated) {
      _name.text = tribe.name;
      _description.text = tribe.description ?? '';
      _category.text = tribe.category;
      _tags.text = tribe.tags.join(', ');
      _welcome.text = tribe.welcomeMessage ?? '';
      visibility = tribe.visibility;
      avatarUrl = tribe.avatarUrl;
      bannerUrl = tribe.bannerUrl;
      hydrated = true;
    }
    if (widget.focusWelcome && !welcomeFocusRequested) {
      welcomeFocusRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _welcomeFocus.requestFocus();
      });
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Edit identity',
            style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          TextButton(
            onPressed: saving ? null : () => _save(tribe.tribeId),
            child: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save',
                    style: TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
            children: [
              _MediaEditor(
                avatarUrl: avatarUrl,
                bannerUrl: bannerUrl,
                uploadingAvatar: uploadingAvatar,
                uploadingBanner: uploadingBanner,
                onAvatar: () => _pickMedia(tribe.tribeId, banner: false),
                onBanner: () => _pickMedia(tribe.tribeId, banner: true),
              ),
              const SizedBox(height: 18),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionTitle(
                      icon: Icons.badge_outlined,
                      title: 'Community identity',
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _name,
                      maxLength: 50,
                      textCapitalization: TextCapitalization.words,
                      validator: (value) {
                        final length = value?.trim().length ?? 0;
                        if (length < 3 || length > 50) {
                          return 'Use 3 to 50 characters.';
                        }
                        return null;
                      },
                      decoration: const InputDecoration(
                        labelText: 'Tribe name',
                        prefixIcon: Icon(Icons.groups_2_outlined),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _description,
                      maxLength: 500,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'What does this community hold space for?',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _welcome,
                      focusNode: _welcomeFocus,
                      maxLength: 240,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Welcome message',
                        hintText: 'Shown when a member first joins',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionTitle(
                      icon: Icons.travel_explore_rounded,
                      title: 'Discovery',
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _category,
                      maxLength: 40,
                      validator: (value) => (value?.trim().length ?? 0) < 2
                          ? 'Add a category.'
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Primary category',
                        prefixIcon: Icon(Icons.category_outlined),
                        hintText: 'Mental Health, Campus, Faith...',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _tags,
                      decoration: const InputDecoration(
                        labelText: 'Tags',
                        prefixIcon: Icon(Icons.tag_rounded),
                        hintText: 'support, healing, late night',
                        helperText: 'Up to 8, separated by commas',
                      ),
                      validator: (value) => _parseTags(value ?? '').length > 8
                          ? 'Use no more than 8 tags.'
                          : null,
                    ),
                    const SizedBox(height: 18),
                    Text('Visibility',
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w900,
                        )),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'public',
                          icon: Icon(Icons.public_rounded),
                          label: Text('Public'),
                        ),
                        ButtonSegment(
                          value: 'private',
                          icon: Icon(Icons.lock_outline_rounded),
                          label: Text('Private'),
                        ),
                        ButtonSegment(
                          value: 'invite_only',
                          icon: Icon(Icons.mail_outline_rounded),
                          label: Text('Invite'),
                        ),
                      ],
                      selected: {visibility},
                      onSelectionChanged: (next) =>
                          setState(() => visibility = next.first),
                      showSelectedIcon: false,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (visibility) {
                        'public' => 'Anyone can discover the Tribe.',
                        'private' => 'Only approved members can view content.',
                        _ =>
                          'People need an invitation before requesting access.',
                      },
                      style: TextStyle(
                        color: context.ink.withOpacity(0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: saving ? null : () => _save(tribe.tribeId),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Save identity',
                      style: TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickMedia(String tribeId, {required bool banner}) async {
    final image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 84,
      maxWidth: banner ? 2048 : 1024,
      maxHeight: banner ? 1152 : 1024,
    );
    if (image == null || !mounted) return;
    setState(() {
      if (banner) {
        uploadingBanner = true;
      } else {
        uploadingAvatar = true;
      }
    });
    try {
      final bytes = await image.readAsBytes();
      if (bytes.length > 8 * 1024 * 1024) {
        throw const FormatException('Choose an image smaller than 8 MB.');
      }
      final extension = image.name.contains('.')
          ? image.name.split('.').last.toLowerCase()
          : 'jpg';
      final upload = await ref.read(repositoryProvider).uploadTribeAvatar(
            tribeId: tribeId,
            bytes: bytes,
            extension: extension,
            contentType: _contentType(extension),
          );
      if (!mounted) return;
      setState(() {
        if (banner) {
          bannerUrl = upload.url;
        } else {
          avatarUrl = upload.url;
        }
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not upload image: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          uploadingAvatar = false;
          uploadingBanner = false;
        });
      }
    }
  }

  Future<void> _save(String tribeId) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      await ref.read(repositoryProvider).updateTribeConfiguration(
            tribeId: tribeId,
            name: _name.text.trim(),
            description: _sanitizeMarkdown(_description.text),
            category: _category.text.trim(),
            tags: _parseTags(_tags.text),
            visibility: visibility,
            avatarUrl: avatarUrl ?? '',
            bannerUrl: bannerUrl ?? '',
            welcomeMessage: _welcome.text.trim(),
            settings: TribeGovernanceSettings.fromJson(
              ref
                  .read(tribeBySlugProvider(widget.slug))
                  .valueOrNull
                  ?.managementSettings,
            ),
          );
      ref.invalidate(tribeBySlugProvider(widget.slug));
      ref.invalidate(tribesIKeepProvider);
      ref.invalidate(tribeManagementProvider(tribeId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tribe identity saved.')),
      );
      context.pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $error')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  static List<String> _parseTags(String value) => value
      .split(',')
      .map((tag) => tag.trim().toLowerCase())
      .where((tag) => tag.length >= 2)
      .toSet()
      .take(8)
      .toList(growable: false);

  static String _sanitizeMarkdown(String value) => value
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .trim();

  static String _contentType(String extension) => switch (extension) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'heic' || 'heif' => 'image/heic',
        _ => 'image/jpeg',
      };
}

class _MediaEditor extends StatelessWidget {
  const _MediaEditor({
    required this.avatarUrl,
    required this.bannerUrl,
    required this.uploadingAvatar,
    required this.uploadingBanner,
    required this.onAvatar,
    required this.onBanner,
  });
  final String? avatarUrl;
  final String? bannerUrl;
  final bool uploadingAvatar;
  final bool uploadingBanner;
  final VoidCallback onAvatar;
  final VoidCallback onBanner;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            children: [
              InkWell(
                onTap: uploadingBanner ? null : onBanner,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                child: SizedBox(
                  height: 132,
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(20)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (bannerUrl?.isNotEmpty == true)
                          Image.network(
                            bannerUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const _MediaPlaceholder(banner: true),
                          )
                        else
                          const _MediaPlaceholder(banner: true),
                        Container(color: Colors.black.withOpacity(.18)),
                        Center(
                          child: _EditMediaButton(
                            loading: uploadingBanner,
                            icon: Icons.image_outlined,
                            label: 'Change banner',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 54),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  'Images are compressed before upload.',
                  style: TextStyle(
                    color: context.ink.withOpacity(.52),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            left: 18,
            top: 98,
            child: InkWell(
              onTap: uploadingAvatar ? null : onAvatar,
              customBorder: const CircleBorder(),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      shape: BoxShape.circle,
                    ),
                    child: TribeAvatar(avatarUrl: avatarUrl, size: 82),
                  ),
                  Positioned(
                    right: -2,
                    bottom: 2,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        color: VentlyColors.berryMagenta,
                        shape: BoxShape.circle,
                      ),
                      child: uploadingAvatar
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.edit_rounded,
                              color: Colors.white, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.banner});
  final bool banner;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: VentlyColors.softMauve.withOpacity(.45),
      alignment: Alignment.center,
      child: Icon(
        banner ? Icons.landscape_outlined : Icons.groups_2_outlined,
        color: VentlyColors.berryMagenta,
        size: 34,
      ),
    );
  }
}

class _EditMediaButton extends StatelessWidget {
  const _EditMediaButton({
    required this.loading,
    required this.icon,
    required this.label,
  });
  final bool loading;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.58),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 7),
          Text(label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              )),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: VentlyColors.berryMagenta, size: 20),
        const SizedBox(width: 8),
        Text(title,
            style: TextStyle(
              color: context.ink,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            )),
      ],
    );
  }
}
