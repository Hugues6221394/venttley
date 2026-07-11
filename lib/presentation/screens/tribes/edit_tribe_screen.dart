import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';

class EditTribeScreen extends ConsumerStatefulWidget {
  const EditTribeScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<EditTribeScreen> createState() => _EditTribeScreenState();
}

class _EditTribeScreenState extends ConsumerState<EditTribeScreen> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _avatarUrl;
  late final TextEditingController _bannerUrl;
  bool _private = false;
  bool _hydrated = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _desc = TextEditingController();
    _avatarUrl = TextEditingController();
    _bannerUrl = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _avatarUrl.dispose();
    _bannerUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tribeAsync = ref.watch(tribeBySlugProvider(widget.slug));
    final tribe = tribeAsync.valueOrNull;
    final me = ref.watch(sessionProvider);

    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: tribeAsync.isLoading
            ? const Center(child: CircularProgressIndicator())
            : const Center(child: Text('Tribe not found')),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(tribe.name)),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Only the Plug of a Tribe can edit its settings.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
    }
    if (!_hydrated) {
      _name.text = tribe.name;
      _desc.text = tribe.description ?? '';
      _avatarUrl.text = tribe.avatarUrl ?? '';
      _bannerUrl.text = tribe.bannerUrl ?? '';
      _private = tribe.isPrivate;
      _hydrated = true;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Tribe settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Plugz can soften their tribe over time. Changes apply immediately.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'Tribe name',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            maxLength: 200,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'What is this Tribe a sanctuary for?',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _avatarUrl,
            decoration: const InputDecoration(
              labelText: 'Avatar image URL',
              hintText: 'https://… (square image)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bannerUrl,
            decoration: const InputDecoration(
              labelText: 'Banner image URL',
              hintText: 'https://… (wide image)',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            value: _private,
            onChanged: (v) => setState(() => _private = v),
            title: const Text('Private Tribe'),
            subtitle: const Text(
              'Only members can see posts. Existing members keep access.',
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _saving ? null : () => _save(tribe.tribeId),
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save changes'),
          ),
        ],
      ),
    );
  }

  Future<void> _save(String tribeId) async {
    final name = _name.text.trim();
    if (name.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a name with at least 3 characters.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).updateTribe(
            tribeId: tribeId,
            name: name,
            description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
            isPrivate: _private,
            avatarUrl: _avatarUrl.text.trim(),
            bannerUrl: _bannerUrl.text.trim(),
          );
      ref.invalidate(tribesProvider);
      ref.invalidate(tribeBySlugProvider(widget.slug));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved.')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
