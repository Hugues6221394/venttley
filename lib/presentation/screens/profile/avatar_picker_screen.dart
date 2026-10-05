import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/avatar_presets.dart';
import '../../widgets/vently_premium_background.dart';

/// Choosing a face.
///
/// What this replaces: a letter on a colour derived from a hash of a seed. It
/// was the first thing a reader saw beside every vent, and it said nothing
/// about the person — not even that they were a person.
///
/// A picker rather than a builder, deliberately and for now. The layered set
/// that lets somebody change hair, clothes and glasses needs art drawn to a rig
/// (docs/avatar-art-spec.md); this ships the ten characters that already exist
/// so nobody meets the letters, and stores the choice as a config so the
/// builder can extend it without migrating anybody.
class AvatarPickerScreen extends ConsumerStatefulWidget {
  const AvatarPickerScreen({super.key, this.personaId});

  /// When set, the chosen face belongs to that persona rather than the account.
  final String? personaId;

  @override
  ConsumerState<AvatarPickerScreen> createState() => _AvatarPickerScreenState();
}

class _AvatarPickerScreenState extends ConsumerState<AvatarPickerScreen> {
  String? _chosen;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _chosen = AvatarPresets.fromUrl(ref.read(sessionProvider)?.profilePhotoUrl);
  }

  Future<void> _save() async {
    final id = _chosen;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .setAvatarPreset(
            preset: id,
            photoUrl: AvatarPresets.publicUrl(VentlyConfig.supabaseUrl, id),
            personaId: widget.personaId,
          );
      // restore(), not invalidate(). Invalidating rebuilds the controller from
      // the repository's cached user, which is the copy that still has the old
      // avatar on it — the write lands, the database is right, and the profile
      // keeps showing the letter tile.
      await ref.read(sessionProvider.notifier).restore();
      ref.invalidate(myPersonasProvider);
      navigator.pop(true);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t save that. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: VentlyTokens.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Choose your face'),
      ),
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 16),
                child: Text(
                  'Nobody sees your real face here. Pick the one that feels '
                  'like you — you can change it whenever.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                    color: context.ink.withValues(alpha: 0.62),
                  ),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: AvatarPresets.ids.length,
                  itemBuilder: (context, i) {
                    final id = AvatarPresets.ids[i];
                    final selected = _chosen == id;
                    return GestureDetector(
                      key: ValueKey('avatar-$id'),
                      onTap: () => setState(() => _chosen = id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(
                            alpha: selected ? 0.14 : 0.05,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? scheme.primary
                                : scheme.primary.withValues(alpha: 0.12),
                            width: selected ? 2.2 : 1,
                          ),
                        ),
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(6),
                              child: Image.asset(
                                AvatarPresets.asset(id),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                            if (selected)
                              Positioned(
                                right: 8,
                                top: 8,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check_rounded,
                                    size: 15,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: SizedBox(
                  height: 54,
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('avatar-save'),
                    onPressed: _chosen == null || _busy ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: Text(
                      _busy ? 'Saving…' : 'Use this one',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15.5,
                      ),
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
}
