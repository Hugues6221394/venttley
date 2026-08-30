import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/avatar/avatar_design.dart';
import '../../widgets/anonymous_avatar.dart';

/// Avatar Builder — composes a v2 avatar_seed from six axes
/// (silhouette / palette / hair / accessory / aura / outfit). Saves through
/// the `update_user_avatar` RPC. Real profile photos are handled separately
/// from the main Profile screen so anonymous personas stay abstract.
///
/// Reachable both standalone (`/profile/avatar`, edits the signed-in
/// user) and as a sheet for personas via [openAvatarBuilder].
class AvatarBuilderScreen extends ConsumerStatefulWidget {
  const AvatarBuilderScreen({
    super.key,
    this.initialSeed,
    this.persistAsMine = true,
    this.title = 'Edit avatar',
  });

  /// Initial seed (own user's or a persona's). When null, starts from
  /// a freshly-randomised v2 design.
  final String? initialSeed;

  /// When true, save persists via the user's update_user_avatar RPC.
  /// When false (persona case), the builder returns the seed to the
  /// caller via Navigator.pop and doesn't write anywhere.
  final bool persistAsMine;
  final String title;

  @override
  ConsumerState<AvatarBuilderScreen> createState() =>
      _AvatarBuilderScreenState();
}

class _AvatarBuilderScreenState extends ConsumerState<AvatarBuilderScreen> {
  late AvatarDesign _design;
  late final AvatarDesign _initial;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // For /profile/avatar (no explicit initialSeed) we fall back to
    // the signed-in user's current avatar so the builder starts on
    // "where they already are" rather than a random throw.
    final seed = widget.initialSeed ?? ref.read(sessionProvider)?.avatarSeed;
    _design =
        AvatarDesign.tryParse(seed) ??
        _randomDesign(math.Random(seed.hashCode));
    _initial = _design;
  }

  AvatarDesign _randomDesign(math.Random r) => AvatarDesign(
    silhouette:
        AvatarSilhouette.values[r.nextInt(AvatarSilhouette.values.length)],
    palette: AvatarPalette.values[r.nextInt(AvatarPalette.values.length)],
    hair: AvatarHair.values[r.nextInt(AvatarHair.values.length)],
    accessory: AvatarAccessory.values[r.nextInt(AvatarAccessory.values.length)],
    aura: AvatarAura.values[r.nextInt(AvatarAura.values.length)],
    outfit: AvatarOutfit.values[r.nextInt(AvatarOutfit.values.length)],
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final seed = _design.toSeed();
    try {
      if (widget.persistAsMine) {
        await ref.read(repositoryProvider).updateMyAvatar(seed);
        // Refresh the session-bound AppUser so every avatar in the app
        // re-renders with the new look immediately.
        await ref.read(sessionProvider.notifier).restore();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Avatar updated.')));
          context.pop();
        }
      } else {
        if (mounted) context.pop(seed);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider);
    final label = me?.anonymousPseudonym ?? 'You';
    final dirty = _design.toSeed() != _initial.toSeed();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Randomise',
            icon: const Icon(Icons.casino_outlined),
            onPressed: () {
              setState(() => _design = _randomDesign(math.Random()));
            },
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton(
            onPressed: (_saving || !dirty) ? null : _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    widget.persistAsMine ? 'Save avatar' : 'Use this avatar',
                  ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        children: [
          // Big live preview
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: AnonymousAvatar(
                seed: _design.toSeed(),
                label: label,
                size: 156,
                animate: true,
              ),
            ),
          ),

          _AxisPicker<AvatarSilhouette>(
            title: 'Silhouette',
            current: _design.silhouette,
            values: AvatarSilhouette.values,
            labels: {for (final v in AvatarSilhouette.values) v: v.label},
            previewFor: (v) => _design.copyWith(silhouette: v).toSeed(),
            previewLabel: label,
            onPick: (v) =>
                setState(() => _design = _design.copyWith(silhouette: v)),
          ),
          _AxisPicker<AvatarPalette>(
            title: 'Palette',
            current: _design.palette,
            values: AvatarPalette.values,
            labels: {for (final v in AvatarPalette.values) v: v.label},
            previewFor: (v) => _design.copyWith(palette: v).toSeed(),
            previewLabel: label,
            onPick: (v) =>
                setState(() => _design = _design.copyWith(palette: v)),
          ),
          _AxisPicker<AvatarHair>(
            title: 'Hair',
            current: _design.hair,
            values: AvatarHair.values,
            labels: {for (final v in AvatarHair.values) v: v.label},
            previewFor: (v) => _design.copyWith(hair: v).toSeed(),
            previewLabel: label,
            onPick: (v) => setState(() => _design = _design.copyWith(hair: v)),
          ),
          _AxisPicker<AvatarAccessory>(
            title: 'Accessory',
            current: _design.accessory,
            values: AvatarAccessory.values,
            labels: {for (final v in AvatarAccessory.values) v: v.label},
            previewFor: (v) => _design.copyWith(accessory: v).toSeed(),
            previewLabel: label,
            onPick: (v) =>
                setState(() => _design = _design.copyWith(accessory: v)),
          ),
          _AxisPicker<AvatarAura>(
            title: 'Aura',
            current: _design.aura,
            values: AvatarAura.values,
            labels: {for (final v in AvatarAura.values) v: v.label},
            previewFor: (v) => _design.copyWith(aura: v).toSeed(),
            previewLabel: label,
            onPick: (v) => setState(() => _design = _design.copyWith(aura: v)),
          ),
          _AxisPicker<AvatarOutfit>(
            title: 'Outfit',
            current: _design.outfit,
            values: AvatarOutfit.values,
            labels: {for (final v in AvatarOutfit.values) v: v.label},
            previewFor: (v) => _design.copyWith(outfit: v).toSeed(),
            previewLabel: label,
            onPick: (v) =>
                setState(() => _design = _design.copyWith(outfit: v)),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Text(
              'Avatars stay playful and abstract. Profile photos are optional from your profile.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withOpacity(0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AxisPicker<T extends Enum> extends StatelessWidget {
  const _AxisPicker({
    required this.title,
    required this.current,
    required this.values,
    required this.labels,
    required this.previewFor,
    required this.previewLabel,
    required this.onPick,
  });

  final String title;
  final T current;
  final List<T> values;
  final Map<T, String> labels;
  final String Function(T) previewFor;
  final String previewLabel;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface.withOpacity(0.6),
              ),
            ),
          ),
          SizedBox(
            height: 86,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: values.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final v = values[i];
                final selected = v == current;
                return GestureDetector(
                  onTap: () => onPick(v),
                  child: Column(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected
                                ? scheme.primary
                                : scheme.outline.withOpacity(0.3),
                            width: selected ? 2.5 : 1.2,
                          ),
                        ),
                        padding: const EdgeInsets.all(3),
                        child: AnonymousAvatar(
                          seed: previewFor(v),
                          label: previewLabel,
                          size: 56,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        labels[v] ?? v.name,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w500,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurface.withOpacity(0.75),
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
  }
}

/// Convenience entry point for the persona create/edit flow. Pushes the
/// builder as a full-screen route, returns the chosen seed (or null on
/// cancel).
Future<String?> openAvatarBuilderForPersona(
  BuildContext context, {
  String? initialSeed,
}) async {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => AvatarBuilderScreen(
        initialSeed: initialSeed,
        persistAsMine: false,
        title: 'Persona avatar',
      ),
      fullscreenDialog: true,
    ),
  );
}
