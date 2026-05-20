import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../data/services/identity_service.dart';
import '../../../data/services/supabase_backend.dart'
    show InvalidCredentialsException;
import '../../widgets/vently_logo.dart';

/// Returning-user entry: sign in with username + password, or recover with
/// the 12-word phrase.
class RecoverScreen extends ConsumerStatefulWidget {
  const RecoverScreen({super.key});

  @override
  ConsumerState<RecoverScreen> createState() => _RecoverScreenState();
}

enum _Mode { signIn, phrase }

class _RecoverScreenState extends ConsumerState<RecoverScreen> {
  _Mode _mode = _Mode.signIn;
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _phrase = TextEditingController();
  bool _loading = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    () async {
      final last = await ref.read(repositoryProvider).identity.lastUsername();
      if (last != null && mounted) _username.text = last;
    }();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).signIn(
            username: _username.text.trim(),
            password: _password.text,
          );
      if (!mounted) return;
      context.go('/feed');
    } on InvalidCredentialsException catch (e) {
      setState(() => _error = e.toString());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _recover() async {
    final username = _username.text.trim();
    final phrase = _phrase.text.trim();
    final words = phrase
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (!IdentityService.usernamePattern.hasMatch(username)) {
      setState(() => _error = 'Enter your username (3–20 chars).');
      return;
    }
    if (words.length != 12) {
      setState(() => _error =
          'Recovery phrase is 12 words — you have ${words.length}.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = await ref.read(sessionProvider.notifier).recoverWithPhrase(
            username: username,
            phrase: phrase,
          );
      if (!mounted) return;
      if (user == null) {
        setState(
          () => _error =
              "That phrase doesn't unlock this sanctuary. Double-check the words.",
        );
        return;
      }
      context.go('/feed');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            children: [
              const Center(child: VentlyLogo(size: 36)),
              const SizedBox(height: 24),
              _ModeSwitch(
                mode: _mode,
                onChanged: (m) => setState(() {
                  _mode = m;
                  _error = null;
                }),
              ),
              const SizedBox(height: 20),
              if (_mode == _Mode.signIn) ..._signInForm(scheme)
              else ..._phraseForm(scheme),
              const SizedBox(height: 16),
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.error.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: scheme.error.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_outlined,
                          color: scheme.error, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style:
                                TextStyle(color: scheme.error, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loading
                    ? null
                    : (_mode == _Mode.signIn ? _signIn : _recover),
                child: _loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : Text(_mode == _Mode.signIn
                        ? 'Enter the Circle'
                        : 'Restore my sanctuary'),
              ),
              const SizedBox(height: 24),
              Center(
                child: TextButton(
                  onPressed: () => context.go('/onboarding/identity'),
                  child: const Text('Start a new identity instead →'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _signInForm(ColorScheme scheme) {
    return [
      Text('Welcome back',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text(
        'Sign in to your sanctuary with your username and password.',
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onSurface.withOpacity(0.65)),
      ),
      const SizedBox(height: 18),
      TextField(
        controller: _username,
        decoration: const InputDecoration(
          hintText: 'Username',
          prefixIcon: Icon(Icons.person_outline),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _password,
        obscureText: !_showPassword,
        decoration: InputDecoration(
          hintText: 'Password',
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            icon: Icon(_showPassword ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
      ),
    ];
  }

  List<Widget> _phraseForm(ColorScheme scheme) {
    return [
      Text('Restore from phrase',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text(
        'Enter your username and the 12 words you saved when you joined.',
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onSurface.withOpacity(0.65)),
      ),
      const SizedBox(height: 18),
      TextField(
        controller: _username,
        decoration: const InputDecoration(
          hintText: 'Username',
          prefixIcon: Icon(Icons.person_outline),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _phrase,
        minLines: 3,
        maxLines: 4,
        textCapitalization: TextCapitalization.none,
        decoration: const InputDecoration(
          hintText: 'twelve words from when you joined, separated by spaces',
          prefixIcon: Icon(Icons.vpn_key_outlined),
        ),
      ),
    ];
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});
  final _Mode mode;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget seg(_Mode m, String label) {
      final selected = mode == m;
      return Expanded(
        child: InkWell(
          onTap: () => onChanged(m),
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? scheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : scheme.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          seg(_Mode.signIn, 'Sign in'),
          seg(_Mode.phrase, 'Recover with phrase'),
        ],
      ),
    );
  }
}
