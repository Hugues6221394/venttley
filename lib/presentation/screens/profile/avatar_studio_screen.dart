import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/avatar/avatar_look.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/avatar_baker.dart';
import '../../widgets/avatar_look_view.dart';
import '../../widgets/vently_premium_background.dart';

/// Building a face, rather than being assigned one.
///
/// What this replaces: six abstract axes — silhouette, palette, aura — that
/// composed a coloured blob. A blob is not a person, and the point of an
/// avatar beside a vent is that somebody is talking.
///
/// Every choice is previewed on the whole avatar rather than as a swatch,
/// because "which of these twelve hairstyles suits me" is not a question you
/// can answer from a picture of hair.
class AvatarStudioScreen extends ConsumerStatefulWidget {
  const AvatarStudioScreen({super.key, this.personaId});

  /// When set, the face belongs to that persona rather than the account.
  final String? personaId;

  @override
  ConsumerState<AvatarStudioScreen> createState() => _AvatarStudioScreenState();
}

enum _Part { skin, hair, beard, outfit }

class _AvatarStudioScreenState extends ConsumerState<AvatarStudioScreen> {
  AvatarLook _look = AvatarLook.starting;
  AvatarLook? _opened;
  _Part _part = _Part.skin;
  bool _saving = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final config = await ref
        .read(repositoryProvider)
        .myAvatarConfig(personaId: widget.personaId);
    if (!mounted) return;
    final look = AvatarLook.tryParse(config);
    setState(() {
      _look = look ?? AvatarLook.starting;
      _opened = _look;
      _loading = false;
    });
  }

  bool get _changed => _opened != null && _look != _opened;

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      final png = await AvatarBaker.bake(_look);
      await ref
          .read(repositoryProvider)
          .setCustomAvatar(
            config: _look.toConfig(),
            png: png,
            personaId: widget.personaId,
          );
      // restore(), not invalidate(). Invalidating rebuilds the controller from
      // the repository's cached user, which is the copy that still has the old
      // avatar on it — the write lands, the database is right, and the profile
      // keeps showing the face they just replaced.
      await ref.read(sessionProvider.notifier).restore();
      ref.invalidate(myPersonasProvider);
      navigator.pop(true);
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t save that. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    // The preview takes what is left after the controls, so a small phone
    // shrinks the face instead of pushing the save button off the screen.
    final preview = (media.height * 0.26).clamp(132.0, 208.0);
    return Scaffold(
      backgroundColor: VentlyTokens.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Design your avatar'),
        actions: [
          TextButton(
            key: const ValueKey('avatar-studio-presets'),
            onPressed: () => context.push(
              widget.personaId == null
                  ? '/avatar'
                  : '/avatar?persona=${widget.personaId}',
            ),
            child: const Text('Ready-made'),
          ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _Preview(look: _look, size: preview),
                    const SizedBox(height: 10),
                    _PartTabs(
                      value: _part,
                      onChanged: (p) => setState(() => _part = p),
                    ),
                    Expanded(child: _options()),
                    _SaveBar(
                      busy: _saving,
                      enabled: _changed && !_saving,
                      onSave: _save,
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _options() {
    switch (_part) {
      case _Part.skin:
        return _Choices(
          key: const ValueKey('avatar-choices-skin'),
          look: _look,
          ids: AvatarLayers.skins,
          selected: _look.skin,
          preview: (id) => _look.copyWith(skin: id),
          onTap: (id) => setState(() => _look = _look.copyWith(skin: id)),
        );
      case _Part.hair:
        return _Choices(
          key: const ValueKey('avatar-choices-hair'),
          look: _look,
          ids: AvatarLayers.hair,
          selected: _look.hair,
          allowNone: true,
          noneLabel: 'Bald',
          palette: AvatarPalettes.hair,
          tint: _look.hairTint,
          onTint: (t) => setState(() => _look = _look.copyWith(hairTint: t)),
          preview: (id) => id == null
              ? _look.copyWith(clearHair: true)
              : _look.copyWith(hair: id),
          onTap: (id) => setState(
            () => _look = id == null
                ? _look.copyWith(clearHair: true)
                : _look.copyWith(hair: id),
          ),
        );
      case _Part.beard:
        return _Choices(
          key: const ValueKey('avatar-choices-beard'),
          look: _look,
          ids: AvatarLayers.beards,
          selected: _look.beard,
          allowNone: true,
          noneLabel: 'Clean',
          preview: (id) => id == null
              ? _look.copyWith(clearBeard: true)
              : _look.copyWith(beard: id),
          onTap: (id) => setState(
            () => _look = id == null
                ? _look.copyWith(clearBeard: true)
                : _look.copyWith(beard: id),
          ),
          // No colour row of its own: a beard is the same hair, and letting
          // somebody set them apart mostly produces mistakes.
        );
      case _Part.outfit:
        return _Choices(
          key: const ValueKey('avatar-choices-outfit'),
          look: _look,
          ids: AvatarLayers.tops,
          selected: _look.top,
          palette: AvatarPalettes.garment,
          tint: _look.topTint,
          onTint: (t) => setState(() => _look = _look.copyWith(topTint: t)),
          preview: (id) => _look.copyWith(top: id),
          onTap: (id) => setState(() => _look = _look.copyWith(top: id!)),
        );
    }
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.look, required this.size});

  final AvatarLook look;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary.withValues(alpha: 0.18),
              scheme.primary.withValues(alpha: 0.05),
            ],
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: AvatarLookView(look: look, size: size),
      ),
    );
  }
}

class _PartTabs extends StatelessWidget {
  const _PartTabs({required this.value, required this.onChanged});

  final _Part value;
  final ValueChanged<_Part> onChanged;

  static const _labels = {
    _Part.skin: 'Skin',
    _Part.hair: 'Hair',
    _Part.beard: 'Beard',
    _Part.outfit: 'Outfit',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final part in _Part.values)
            Expanded(
              child: GestureDetector(
                key: ValueKey('avatar-tab-${part.name}'),
                onTap: () => onChanged(part),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: value == part
                        ? scheme.primary.withValues(alpha: 0.16)
                        : scheme.primary.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: value == part
                          ? scheme.primary.withValues(alpha: 0.65)
                          : Colors.transparent,
                      width: 1.4,
                    ),
                  ),
                  child: Text(
                    _labels[part]!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: value == part
                          ? scheme.primary
                          : context.ink.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A colour row and a grid of whole-avatar previews.
class _Choices extends StatelessWidget {
  const _Choices({
    super.key,
    required this.look,
    required this.ids,
    required this.selected,
    required this.preview,
    required this.onTap,
    this.allowNone = false,
    this.noneLabel = 'None',
    this.palette,
    this.tint,
    this.onTint,
  });

  final AvatarLook look;
  final List<String> ids;
  final String? selected;
  final AvatarLook Function(String? id) preview;
  final void Function(String? id) onTap;
  final bool allowNone;
  final String noneLabel;
  final Map<String, Color>? palette;
  final String? tint;
  final ValueChanged<String>? onTint;

  @override
  Widget build(BuildContext context) {
    final entries = <String?>[if (allowNone) null, ...ids];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (palette != null && onTint != null)
          _Swatches(palette: palette!, value: tint, onChanged: onTint!),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final id = entries[i];
              final isSelected = id == selected;
              return _Tile(
                id: id,
                label: id == null ? noneLabel : null,
                look: preview(id),
                selected: isSelected,
                onTap: () => onTap(id),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.id,
    required this.label,
    required this.look,
    required this.selected,
    required this.onTap,
  });

  final String? id;
  final String? label;
  final AvatarLook look;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      key: ValueKey('avatar-option-${id ?? 'none'}'),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: selected ? 0.14 : 0.05),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.primary.withValues(alpha: 0.12),
            width: selected ? 2.2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            fit: StackFit.expand,
            children: [
              AvatarLookView(look: look, size: c.maxWidth),
              if (label != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    color: Colors.black.withValues(alpha: 0.42),
                    child: Text(
                      label!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
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

class _Swatches extends StatelessWidget {
  const _Swatches({
    required this.palette,
    required this.value,
    required this.onChanged,
  });

  final Map<String, Color> palette;
  final String? value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 54,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        children: [
          for (final entry in palette.entries)
            GestureDetector(
              key: ValueKey('avatar-tint-${entry.key}'),
              onTap: () => onChanged(entry.key),
              child: Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: entry.value,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: value == entry.key
                        ? scheme.primary
                        : context.ink.withValues(alpha: 0.18),
                    width: value == entry.key ? 3 : 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.busy,
    required this.enabled,
    required this.onSave,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: SizedBox(
        height: 54,
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('avatar-studio-save'),
          onPressed: enabled ? onSave : null,
          style: FilledButton.styleFrom(
            backgroundColor: VentlyColors.berryMagenta,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
          ),
          child: Text(
            busy ? 'Saving…' : 'Save this face',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
          ),
        ),
      ),
    );
  }
}
