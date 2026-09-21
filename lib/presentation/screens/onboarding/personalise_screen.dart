import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/profile_banner_editor.dart';

/// The optional last step of signing up: a face, a backdrop, a way back in.
///
/// It sits *after* account creation rather than inside the identity form, and
/// that ordering is the whole design. Uploading a photo needs a session, and a
/// recovery email is a write against a row that does not exist until the
/// account does. Folding either into the handle-and-password screen would mean
/// holding image bytes and an address in memory across a network call that can
/// fail, then deciding what to do with them when it does.
///
/// Everything here is skippable, and the skip is a real button rather than a
/// greyed-out "later" — the anonymous flow exists so that someone can be here
/// without giving anything up, and a personalisation step that feels mandatory
/// quietly undoes that.
class PersonaliseScreen extends ConsumerStatefulWidget {
  const PersonaliseScreen({super.key});

  @override
  ConsumerState<PersonaliseScreen> createState() => _PersonaliseScreenState();
}

class _PersonaliseScreenState extends ConsumerState<PersonaliseScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _emailError;

  // What has actually landed on the server, so the summary at the bottom
  // reports state rather than intent.
  bool _photoSaved = false;
  bool _bannerSaved = false;
  String? _recoverySaved;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _pickPhoto() async {
    if (_busy) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.path.split('.').last.toLowerCase();
      await ref
          .read(repositoryProvider)
          .uploadMyProfilePhoto(
            bytes: bytes,
            extension: ext.isEmpty ? 'jpg' : ext,
            contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
          );
      await ref.read(sessionProvider.notifier).restore();
      if (mounted) setState(() => _photoSaved = true);
    } catch (_) {
      // The scan pipeline can reject an image, and so can a flaky upload.
      // Neither is a reason to strand someone on the last step of signing up.
      _toast("Couldn't use that photo. You can add one later from Settings.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickBanner() async {
    if (_busy) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 900,
      imageQuality: 80,
    );
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    final me = ref.read(sessionProvider);
    final framed = await showProfileBannerEditor(
      context,
      bytes: bytes,
      initialOffset: 0.5,
      avatarSeed: me?.avatarSeed ?? '',
      avatarLabel: me?.displayName ?? '',
      avatarPhotoUrl: me?.profilePhotoUrl,
      saveLabel: 'Use this',
    );
    if (framed == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final ext = picked.path.split('.').last.toLowerCase();
      await ref
          .read(repositoryProvider)
          .uploadMyProfileBanner(
            bytes: bytes,
            extension: ext.isEmpty ? 'jpg' : ext,
            contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
            offset: framed.offset,
          );
      await ref.read(sessionProvider.notifier).restore();
      if (mounted) setState(() => _bannerSaved = true);
    } catch (_) {
      _toast("Couldn't use that background. You can add one later.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveRecoveryEmail() async {
    if (_busy) return;
    final value = _email.text.trim();
    if (value.isEmpty) {
      setState(() => _emailError = null);
      return;
    }
    // Deliberately loose. The server sends a code to whatever is entered, and
    // an address that does not receive it is the only proof that matters; a
    // stricter pattern here only rejects valid addresses nobody predicted.
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
      setState(() => _emailError = 'That does not look like an email address.');
      return;
    }

    setState(() {
      _busy = true;
      _emailError = null;
    });
    try {
      final masked = await ref.read(repositoryProvider).setRecoveryEmail(value);
      if (mounted) {
        setState(() => _recoverySaved = masked ?? value);
        _toast('Check $value for a confirmation code, then confirm it in Settings.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _emailError = "Couldn't save that address. Try again later from Settings.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    // A typed but unsaved address is the likeliest way to leave here thinking
    // recovery is set up when it is not, so save it on the way out.
    if (_email.text.trim().isNotEmpty && _recoverySaved == null) {
      await _saveRecoveryEmail();
      if (_emailError != null) return;
    }
    if (mounted) context.go('/feed');
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _busy ? null : () => context.go('/feed'),
            child: const Text('Skip'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            Text(
              'Make it yours',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'All optional. You are already signed in, and none of this is '
              'needed to use Venttly.',
              style: TextStyle(color: context.inkMuted, height: 1.45),
            ),
            const SizedBox(height: 28),

            _BannerAndAvatar(
              me: me,
              busy: _busy,
              onPickPhoto: _pickPhoto,
              onPickBanner: _pickBanner,
            ),

            const SizedBox(height: 28),

            _SectionCard(
              title: 'A way back in',
              body:
                  'Your recovery phrase is the only way into this account if '
                  'you lose your password. A recovery email is a second one. '
                  'We only ever use it to get you back in.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.email],
                    decoration: InputDecoration(
                      labelText: 'Recovery email (optional)',
                      hintText: 'you@example.com',
                      errorText: _emailError,
                      suffixIcon: _recoverySaved != null
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : null,
                    ),
                    onSubmitted: (_) => _saveRecoveryEmail(),
                  ),
                  if (_recoverySaved != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Saved. We sent a code to confirm it — until you confirm '
                      'it in Settings, it cannot be used to recover the account.',
                      style: TextStyle(fontSize: 12, color: context.inkMuted),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 32),

            FilledButton(
              onPressed: _busy ? null : _finish,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Text(
                      'Enter Venttly',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                _summary(),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.inkMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _summary() {
    final done = <String>[
      if (_photoSaved) 'photo',
      if (_bannerSaved) 'background',
      if (_recoverySaved != null) 'recovery email',
    ];
    if (done.isEmpty) return 'You can add all of this later from Settings.';
    return 'Saved: ${done.join(', ')}. The rest can wait.';
  }
}

/// The banner with the avatar sitting on it, both tappable.
///
/// Shown together because that is how they appear on a profile, and choosing a
/// background without seeing what the avatar does to it is how you end up with
/// a face centred on someone's head.
class _BannerAndAvatar extends StatelessWidget {
  const _BannerAndAvatar({
    required this.me,
    required this.busy,
    required this.onPickPhoto,
    required this.onPickBanner,
  });

  final dynamic me;
  final bool busy;
  final VoidCallback onPickPhoto;
  final VoidCallback onPickBanner;

  @override
  Widget build(BuildContext context) {
    final bannerUrl = me?.profileBannerUrl as String?;
    final photoUrl = me?.profilePhotoUrl as String?;

    return SizedBox(
      height: 190,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onTap: busy ? null : onPickBanner,
            child: Container(
              height: 140,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                color: VentlyColors.softMauve.withValues(alpha: 0.25),
                image: bannerUrl != null
                    ? DecorationImage(
                        image: NetworkImage(bannerUrl),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: bannerUrl == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            color: context.inkMuted,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Add a background',
                            style: TextStyle(
                              color: context.inkMuted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
            ),
          ),
          Positioned(
            left: 24,
            bottom: 0,
            child: GestureDetector(
              onTap: busy ? null : onPickPhoto,
              child: Stack(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.surface,
                    ),
                    child: ProfileAvatar(
                      avatarSeed: (me?.avatarSeed as String?) ?? '',
                      label: (me?.displayName as String?) ?? '',
                      profilePhotoUrl: photoUrl,
                      size: 84,
                    ),
                  ),
                  Positioned(
                    right: 2,
                    bottom: 2,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: VentlyColors.berryMagenta,
                      ),
                      child: const Icon(
                        Icons.camera_alt_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.body,
    required this.child,
  });

  final String title;
  final String body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 16,
              color: context.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              color: context.inkMuted,
              height: 1.45,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
