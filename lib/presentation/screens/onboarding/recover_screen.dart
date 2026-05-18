import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/vently_logo.dart';

class RecoverScreen extends StatefulWidget {
  const RecoverScreen({super.key});
  @override
  State<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends State<RecoverScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: VentlyLogo(size: 36)),
              const SizedBox(height: 32),
              Text(
                'Welcome back',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your Secret Recovery Key to access your sanctuary. Zero PII, total privacy.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.65),
                ),
              ),
              const SizedBox(height: 24),
              Text('Secret Key',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  hintText: 'Enter your Secret Key',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Recovery flow ready when wired to live Supabase.')),
                  );
                },
                child: const Text('Enter the Circle'),
              ),
              const SizedBox(height: 16),
              const Row(children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text('OR'),
                ),
                Expanded(child: Divider()),
              ]),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Scan Sync QR'),
              ),
              const Spacer(),
              Center(
                child: Text.rich(
                  TextSpan(
                    text: 'Lost your key? ',
                    style: TextStyle(
                      color: scheme.onSurface.withOpacity(0.65),
                    ),
                    children: [
                      TextSpan(
                        text: 'Create a new identity',
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go('/onboarding/identity'),
                child: const Text('Start fresh →'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
