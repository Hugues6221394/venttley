import 'package:flutter/material.dart';
import '../../../core/user_friendly_errors.dart';
import '../../widgets/profile_banner_editor.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/tagged_text.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/profile_avatar.dart';

/// Edit Profile — the single place a member curates their public identity:
/// display name, stable username, profile picture, pronouns, public bio and
/// city. Everything here
/// is written straight to the DB via [SessionController.updateProfile]; there
/// is no local stub state.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController _username;
  late final TextEditingController _displayName;
  late final TextEditingController _bio;
  late final TextEditingController _city;
  late final TextEditingController _customPronouns;

  /// The preset pronoun options; `null` selection means "use the custom field".
  static const _presets = ['she/her', 'he/him', 'they/them'];
  String? _selectedPreset;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final me = ref.read(sessionProvider);
    _username = TextEditingController(text: me?.anonymousPseudonym ?? '');
    _displayName = TextEditingController(text: me?.displayName ?? '');
    _bio = TextEditingController(text: me?.bio ?? '');
    _city = TextEditingController(text: me?.homeCity ?? '');
    final p = (me?.pronouns ?? '').trim();
    if (p.isEmpty) {
      _selectedPreset = null;
      _customPronouns = TextEditingController();
    } else if (_presets.contains(p)) {
      _selectedPreset = p;
      _customPronouns = TextEditingController();
    } else {
      _selectedPreset = null;
      _customPronouns = TextEditingController(text: p);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _bio.dispose();
    _city.dispose();
    _customPronouns.dispose();
    super.dispose();
  }

  String get _pronounsValue {
    if (_selectedPreset != null) return _selectedPreset!;
    return _customPronouns.text.trim();
  }

  Future<void> _save() async {
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    // context.push() placed this page on the root Navigator, so a Navigator
    // pop (same as the AppBar back button) returns to the profile reliably —
    // GoRouter.pop() no-ops here inside the stateful shell.
    final navigator = Navigator.of(context);
    final me = ref.read(sessionProvider);
    if (me == null) return;

    final displayName = _displayName.text.trim();
    if (displayName.isEmpty || displayName.length > 50) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Display name must be 1–50 characters.')),
      );
      return;
    }

    final newPronouns = _pronounsValue;
    final newBio = _bio.text.trim();

    setState(() => _saving = true);
    try {
      await ref
          .read(sessionProvider.notifier)
          .updateProfile(
            displayName: displayName == me.displayName ? null : displayName,
            bio: newBio.isEmpty ? null : newBio,
            clearBio: newBio.isEmpty,
            pronouns: newPronouns.isEmpty ? null : newPronouns,
            clearPronouns: newPronouns.isEmpty,
            homeCity: _city.text.trim().isEmpty ? null : _city.text.trim(),
          );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: scheme.primary,
          content: const Text('Profile updated.'),
        ),
      );
      navigator.maybePop();
    } catch (e) {
      if (!mounted) return;
      // Surface the RPC's friendly message (e.g. "That username is taken.").
      final msg = e.toString().replaceFirst('Exception: ', '');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            msg.contains('taken')
                ? 'That username is taken.'
                : msg.length > 120
                ? 'Could not save profile. Please try again.'
                : msg,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final me = ref.watch(sessionProvider);
    if (me == null) {
      return const Scaffold(body: Center(child: Text('Not signed in')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'Save',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 116),
        children: [
          // --- Profile picture ---------------------------------------------
          Center(
            child: Column(
              children: [
                ProfileAvatar(
                  avatarSeed: me.avatarSeed,
                  label: me.displayName,
                  profilePhotoUrl: me.profilePhotoUrl,
                  size: 96,
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: () => context.push('/profile/avatar'),
                  icon: const Icon(Icons.camera_alt_rounded, size: 18),
                  label: const Text('Change profile picture'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // --- Background image --------------------------------------------
          // Here as well as in the avatar sheet, because this is where someone
          // goes when they want to change how their profile looks. An option
          // that only exists behind a long-press on the avatar is an option
          // most people never find.
          _Section(
            title: 'Background image',
            subtitle:
                'The strip behind your avatar on your public profile. Visible '
                'to everyone who opens it.',
            child: _BackgroundRow(me: me),
          ),

          // --- Public identity ---------------------------------------------
          _Section(
            title: 'Display name',
            subtitle:
                'Your readable anonymous persona name. It does not need to be unique.',
            child: TextField(
              controller: _displayName,
              maxLength: 50,
              textCapitalization: TextCapitalization.words,
              decoration: _dec(scheme, hint: 'Midnight Soul'),
            ),
          ),

          _Section(
            title: 'Username',
            subtitle:
                'Your stable identifier for sign-in, mentions, search and links.',
            child: TextField(
              controller: _username,
              readOnly: true,
              enableInteractiveSelection: true,
              decoration: _dec(
                scheme,
                prefix: '@',
                hint: 'yourhandle',
              ).copyWith(suffixIcon: const Icon(Icons.lock_outline)),
            ),
          ),

          // --- Pronouns -----------------------------------------------------
          _Section(
            title: 'Pronouns',
            subtitle: 'Shown on your public profile. Optional.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in _presets)
                      ChoiceChip(
                        label: Text(p),
                        selected: _selectedPreset == p,
                        onSelected: (_) => setState(() {
                          _selectedPreset = _selectedPreset == p ? null : p;
                          if (_selectedPreset != null) _customPronouns.clear();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _customPronouns,
                  maxLength: 30,
                  onChanged: (v) {
                    if (v.trim().isNotEmpty && _selectedPreset != null) {
                      setState(() => _selectedPreset = null);
                    }
                  },
                  decoration: _dec(
                    scheme,
                    hint: 'Or type your own (e.g. ze/zir)',
                  ),
                ),
              ],
            ),
          ),

          // --- Bio ----------------------------------------------------------
          _Section(
            title: 'Bio',
            subtitle: 'A short public intro. Up to 160 characters. Tag with @.',
            child: TagAutocomplete(
              controller: _bio,
              child: TextField(
                controller: _bio,
                maxLength: 160,
                maxLines: 3,
                decoration: _dec(
                  scheme,
                  hint: 'What do you want people to know?',
                ),
              ),
            ),
          ),

          // --- City ---------------------------------------------------------
          _Section(
            title: 'City',
            subtitle: 'Used for your local feed. Optional.',
            child: TextField(
              controller: _city,
              maxLength: 60,
              decoration: _dec(scheme, hint: 'e.g. Kigali'),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _dec(ColorScheme scheme, {String? hint, String? prefix}) {
    return InputDecoration(
      hintText: hint,
      prefixText: prefix,
      counterText: '',
      filled: true,
      fillColor: scheme.surface.withOpacity(0.6),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary.withOpacity(0.2)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        borderRadius: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 8),
                child: Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withOpacity(0.6),
                  ),
                ),
              )
            else
              const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// Background image control on the Edit Profile form.
///
/// Shows the current background as a live thumbnail rather than a text row, so
/// the state of the setting is the setting: you can see at a glance whether you
/// have one and how it is framed. Tapping opens the same editor the avatar sheet
/// uses — one implementation, two doors.
class _BackgroundRow extends ConsumerStatefulWidget {
  const _BackgroundRow({required this.me});
  final AppUser me;

  @override
  ConsumerState<_BackgroundRow> createState() => _BackgroundRowState();
}

class _BackgroundRowState extends ConsumerState<_BackgroundRow> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      await ref.read(sessionProvider.notifier).restore();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(
              e,
              fallback: "Couldn't update your background.",
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 900,
      imageQuality: 80,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    final framed = await showProfileBannerEditor(
      context,
      bytes: bytes,
      initialOffset: 0.5,
      avatarSeed: widget.me.avatarSeed,
      avatarLabel: widget.me.displayName,
      avatarPhotoUrl: widget.me.profilePhotoUrl,
      saveLabel: 'Use this',
    );
    if (framed == null) return;
    final ext = picked.path.split('.').last.toLowerCase();
    await _run(
      () => ref
          .read(repositoryProvider)
          .uploadMyProfileBanner(
            bytes: bytes,
            extension: ext.isEmpty ? 'jpg' : ext,
            contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
            offset: framed.offset,
          ),
      'Background updated.',
    );
  }

  Future<void> _reposition() async {
    final result = await showProfileBannerEditor(
      context,
      imageUrl: widget.me.profileBannerUrl,
      initialOffset: widget.me.profileBannerOffset,
      avatarSeed: widget.me.avatarSeed,
      avatarLabel: widget.me.displayName,
      avatarPhotoUrl: widget.me.profilePhotoUrl,
      saveLabel: 'Save position',
    );
    if (result == null) return;
    await _run(
      () =>
          ref.read(repositoryProvider).setMyProfileBannerOffset(result.offset),
      'Position saved.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.me.profileBannerUrl?.trim() ?? '';
    final has = url.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 96,
            child: has
                ? CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    alignment: Alignment(
                      0,
                      widget.me.profileBannerOffset * 2 - 1,
                    ),
                    placeholder: (_, __) =>
                        const ColoredBox(color: VentlyColors.roseTint),
                    errorWidget: (_, __, ___) =>
                        const ColoredBox(color: VentlyColors.roseTint),
                  )
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: VentlyColors.roseTint.withOpacity(0.6),
                      border: Border.all(
                        color: VentlyColors.berryMagenta.withOpacity(0.18),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'No background yet',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                          color: context.ink.withOpacity(0.55),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.image_outlined, size: 17),
                label: Text(has ? 'Replace' : 'Add'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
            if (has) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _reposition,
                  icon: const Icon(Icons.open_with_rounded, size: 17),
                  label: const Text('Move'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => ref
                              .read(repositoryProvider)
                              .removeMyProfileBanner(),
                          'Background removed.',
                        ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  label: const Text('Remove'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: VentlyColors.dangerRed,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
