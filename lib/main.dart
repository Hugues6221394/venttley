import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/constants.dart';
import 'core/providers.dart';
import 'data/services/telemetry_service.dart';
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

  // Sentry is opt-in: when SENTRY_DSN is empty (the dev default), we run
  // the app directly so we don't ship breadcrumbs to a real project.
  if (VentlyConfig.sentryDsn.isEmpty) {
    runApp(const ProviderScope(child: VentlyApp()));
    return;
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = VentlyConfig.sentryDsn;
      options.environment = VentlyConfig.env;
      options.tracesSampleRate = VentlyConfig.sentryTracesSampleRate;
      options.sendDefaultPii = false; // anonymous app — never ship PII
      options.attachScreenshot = false;
      options.beforeSend = (event, hint) =>
          event.copyWith(user: null, request: null);
    },
    appRunner: () {
      TelemetryService.instance.markSentryReady();
      runApp(const ProviderScope(child: VentlyApp()));
    },
  );
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
      TelemetryService.instance.event('app_open');
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Venttly',
      debugShowCheckedModeBanner: false,
      theme: VentlyTheme.light(),
      darkTheme: VentlyTheme.dark(),
      themeMode: mode,
      routerConfig: router,
    );
  }
}
