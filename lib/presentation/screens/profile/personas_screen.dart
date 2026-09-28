import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// Everything a person can do to a persona they made.
///
/// The profile card could only create them. A name you cannot change and a
/// face you cannot give it is not an identity, it is a typo you have to live
/// with — so this screen renames, re-photographs and deletes.
class PersonasScreen extends ConsumerWidget {
  const PersonasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(myPersonasProvider);
    final active = ref.watch(activePersonaProvider);

    return Scaffold(
      backgroundColor: VentlyTokens.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Personas'),
      ),
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: personas.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const _Problem(),
            data: (list) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              children: [
                Text(
                  'A persona is another name to post under. Your account stays '
                  'yours; only the name and face on the post change.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: context.ink.withOpacity(0.62),
                  ),
                ),
                const SizedBox(height: 18),
                for (final p in list) ...[
                  _PersonaRow(
                    persona: p,
                    isActive: active?.personaId == p.personaId,
                  ),
                  const SizedBox(height: 10),
                ],
                if (list.isEmpty) ...[
                  const SizedBox(height: 30),
                  Center(
                    child: Text(
                      'No personas yet.',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.5),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                const SizedBox(height: 6),
                SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    key: const ValueKey('persona-create'),
                    onPressed: () => _edit(context, ref, null),
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text(
                      'New persona',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem();

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      'Couldn’t load your personas.',
      style: TextStyle(color: context.ink.withOpacity(0.6)),
    ),
  );
}

class _PersonaRow extends ConsumerWidget {
  const _PersonaRow({required this.persona, required this.isActive});

  final Persona persona;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: context.isDark
          ? Theme.of(context).colorScheme.surface
          : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey('persona-row-${persona.personaId}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => _edit(context, ref, persona),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(
            children: [
              ProfileAvatar(
                avatarSeed: persona.avatarSeed,
                label: persona.pseudonym,
                profilePhotoUrl: persona.profilePhotoUrl,
                size: 48,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            persona.pseudonym,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: context.ink,
                            ),
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: VentlyColors.berryMagenta,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: const Text(
                              'In use',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if ((persona.bio ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        persona.bio!.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: context.ink.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: ValueKey('persona-menu-${persona.personaId}'),
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: context.ink.withOpacity(0.5),
                ),
                onSelected: (v) async {
                  if (v == 'use') {
                    ref.read(activePersonaProvider.notifier).state = persona;
                  } else if (v == 'stop') {
                    ref.read(activePersonaProvider.notifier).state = null;
                  } else if (v == 'edit') {
                    await _edit(context, ref, persona);
                  } else if (v == 'delete') {
                    await _delete(context, ref, persona);
                  }
                },
                itemBuilder: (_) => [
                  if (!isActive)
                    const PopupMenuItem(
                      value: 'use',
                      child: Text('Post as this persona'),
                    )
                  else
                    const PopupMenuItem(
                      value: 'stop',
                      child: Text('Stop using it'),
                    ),
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Delete',
                      style: TextStyle(color: VentlyColors.berryMagenta),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _delete(
  BuildContext context,
  WidgetRef ref,
  Persona persona,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete ${persona.pseudonym}?'),
      // Said plainly, because it is the one thing people ask about: deleting
      // the name does not delete what was written under it.
      content: const Text(
        'The name and picture go. Anything you already posted under it stays '
        'where it is, still anonymous.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep it'),
        ),
        TextButton(
          key: const ValueKey('persona-delete-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text(
            'Delete',
            style: TextStyle(color: VentlyColors.berryMagenta),
          ),
        ),
      ],
    ),
  );
  if (ok != true) return;

  try {
    await ref.read(repositoryProvider).deletePersona(persona.personaId);
    if (ref.read(activePersonaProvider)?.personaId == persona.personaId) {
      ref.read(activePersonaProvider.notifier).state = null;
    }
    ref.invalidate(myPersonasProvider);
    messenger.showSnackBar(
      SnackBar(content: Text('${persona.pseudonym} deleted.')),
    );
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Couldn’t delete that. Try again.')),
    );
  }
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref,
  Persona? persona,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PersonaEditor(persona: persona),
  );
}

class _PersonaEditor extends ConsumerStatefulWidget {
  const _PersonaEditor({this.persona});
  final Persona? persona;

  @override
  ConsumerState<_PersonaEditor> createState() => _PersonaEditorState();
}

class _PersonaEditorState extends ConsumerState<_PersonaEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.persona?.pseudonym ?? '',
  );
  late final TextEditingController _bio = TextEditingController(
    text: widget.persona?.bio ?? '',
  );
  late String? _photoUrl = widget.persona?.profilePhotoUrl;
  late String _seed =
      widget.persona?.avatarSeed ??
      'persona-${DateTime.now().millisecondsSinceEpoch}';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  bool get _isNew => widget.persona == null;

  /// Null when the name is usable. Mirrors the two check constraints on the
  /// column rather than guessing at them.
  String? get _nameProblem {
    final n = _name.text.trim();
    if (n.isEmpty) return null; // nothing typed yet is not an error
    if (n.length < 2) return 'A bit longer than that';
    return null;
  }

  bool get _canSave {
    final n = _name.text.trim();
    return !_busy && n.length >= 2 && RegExp(r'^[A-Za-z0-9_]+$').hasMatch(n);
  }

  Future<void> _pickPhoto() async {
    final persona = widget.persona;
    if (persona == null) {
      // A picture needs something to belong to, and the row does not exist
      // until the name is saved.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Save the persona first, then add a picture.'),
        ),
      );
      return;
    }
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 900,
      maxHeight: 900,
      imageQuality: 82,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .uploadPersonaPhoto(
            personaId: persona.personaId,
            bytes: bytes,
            extension: picked.path.split('.').last,
          );
      ref.invalidate(myPersonasProvider);
      final fresh = await ref.read(myPersonasProvider.future);
      if (!mounted) return;
      setState(() {
        _photoUrl = fresh
            .where((p) => p.personaId == persona.personaId)
            .firstOrNull
            ?.profilePhotoUrl;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That picture didn’t upload.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removePhoto() async {
    final persona = widget.persona;
    if (persona == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).removePersonaPhoto(persona.personaId);
      ref.invalidate(myPersonasProvider);
      if (mounted) setState(() => _photoUrl = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider);
      final bio = _bio.text.trim();
      if (_isNew) {
        await repo.createPersona(
          pseudonym: name,
          avatarSeed: _seed,
          bio: bio.isEmpty ? null : bio,
        );
      } else {
        await repo.updatePersona(
          personaId: widget.persona!.personaId,
          pseudonym: name,
          avatarSeed: _seed,
          bio: bio.isEmpty ? null : bio,
          clearBio: bio.isEmpty,
        );
      }
      ref.invalidate(myPersonasProvider);
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('personas_pseudonym')
                ? 'That name can only use letters, numbers and _'
                : 'Couldn’t save that. Try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isNew ? 'New persona' : 'Edit persona',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: context.ink,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  ProfileAvatar(
                    avatarSeed: _seed,
                    label: _name.text.isEmpty ? 'P' : _name.text,
                    profilePhotoUrl: _photoUrl,
                    size: 62,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey('persona-photo'),
                          onPressed: _busy ? null : _pickPhoto,
                          icon: const Icon(Icons.image_outlined, size: 17),
                          label: Text(
                            _photoUrl == null ? 'Add picture' : 'Change',
                          ),
                        ),
                        if (_photoUrl != null)
                          TextButton(
                            onPressed: _busy ? null : _removePhoto,
                            child: const Text('Remove'),
                          )
                        else
                          TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _seed =
                                        'persona-${DateTime.now().microsecondsSinceEpoch}';
                                  }),
                            icon: const Icon(Icons.casino_outlined, size: 17),
                            label: const Text('Shuffle avatar'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('persona-name'),
                controller: _name,
                maxLength: 24,
                // The database only accepts letters, numbers and underscores,
                // and it says so by rejecting the save. Typing a space used to
                // get all the way to "Couldn't save that. Try again." — so the
                // rule is enforced at the keyboard and written on the field.
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
                ],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'What should this one be called?',
                  helperText: 'Letters, numbers and _ — no spaces',
                  errorText: _nameProblem,
                ),
              ),
              TextField(
                key: const ValueKey('persona-bio'),
                controller: _bio,
                maxLength: 120,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  hintText: 'Optional',
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  key: const ValueKey('persona-save'),
                  onPressed: _canSave ? _save : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: VentlyColors.berryMagenta,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    _isNew ? 'Create' : 'Save',
                    style: const TextStyle(fontWeight: FontWeight.w800),
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
