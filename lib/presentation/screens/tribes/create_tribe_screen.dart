import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';

class CreateTribeScreen extends ConsumerStatefulWidget {
  const CreateTribeScreen({super.key});

  @override
  ConsumerState<CreateTribeScreen> createState() => _CreateTribeScreenState();
}

class _CreateTribeScreenState extends ConsumerState<CreateTribeScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  String _category = 'interest_group';
  bool _private = false;
  bool _submitting = false;

  static const _options = <(String key, String label, IconData icon)>[
    ('campus',          'Campus',     Icons.school_outlined),
    ('city',            'City',       Icons.location_city_outlined),
    ('interest_group',  'Interest',   Icons.interests_outlined),
    ('hobby',           'Hobby',      Icons.palette_outlined),
    ('support',         'Support',    Icons.favorite_outline),
    ('venting',         'Venting',    Icons.bedtime_outlined),
  ];

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.length < 3) {
      _toast('Pick a name with at least 3 characters.');
      return;
    }
    setState(() => _submitting = true);
    try {
      final tribe = await ref.read(repositoryProvider).createTribe(
            name: name,
            category: _category,
            description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
            isPrivate: _private,
          );
      ref.invalidate(tribesProvider);
      if (!mounted) return;
      context.go('/tribe/${tribe.slug}');
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Create a Tribe')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'A Tribe is a small sanctuary you keep open for others. Be a soft host — set a clear vibe, welcome new members.',
            style: TextStyle(color: scheme.onSurface.withOpacity(0.7)),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Tribe name',
              hintText: 'e.g. Quiet Mornings, Kigali Lo-Fi',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            maxLength: 160,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'What is this Tribe a sanctuary for?',
            ),
          ),
          const SizedBox(height: 20),
          const Text('Category',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (key, label, icon) in _options)
                ChoiceChip(
                  selected: _category == key,
                  onSelected: (_) => setState(() => _category = key),
                  avatar: Icon(icon, size: 14, color: scheme.primary),
                  label: Text(label),
                ),
            ],
          ),
          const SizedBox(height: 20),
          SwitchListTile.adaptive(
            value: _private,
            onChanged: (v) => setState(() => _private = v),
            title: const Text('Private Tribe'),
            subtitle: const Text(
              'Only members can see posts. Joining stays free for v1.',
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Open my Tribe'),
          ),
        ],
      ),
    );
  }
}
