import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/constants.dart';
import 'core/providers.dart';
import 'presentation/router/app_router.dart';
import 'presentation/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!VentlyConfig.useMockBackend) {
    await Supabase.initialize(
      url: VentlyConfig.supabaseUrl,
      anonKey: VentlyConfig.supabaseAnonKey,
    );
  }
  runApp(const ProviderScope(child: VentlyApp()));
}

class VentlyApp extends ConsumerStatefulWidget {
  const VentlyApp({super.key});

  @override
  ConsumerState<VentlyApp> createState() => _VentlyAppState();
}

class _VentlyAppState extends ConsumerState<VentlyApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sessionProvider.notifier).restore();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Vently',
      debugShowCheckedModeBanner: false,
      theme: VentlyTheme.light(),
      darkTheme: VentlyTheme.dark(),
      themeMode: mode,
      routerConfig: router,
    );
  }
}
