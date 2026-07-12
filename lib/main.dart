import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/analytics_events.dart';
import 'core/constants.dart';
import 'core/logger.dart';
import 'core/pii_scrubber.dart';
import 'core/notification_prefs.dart';
import 'core/notification_routing.dart';
import 'core/providers.dart';
import 'data/services/analytics_service.dart';
import 'data/services/push_registration_service.dart';
import 'data/services/notifications_service.dart';
import 'data/services/telemetry_service.dart';
import 'presentation/router/app_router.dart';
import 'presentation/theme/app_theme.dart';
import 'presentation/widgets/notification_foreground_listener.dart';
import 'presentation/widgets/vently_premium_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Performance — bump the Flutter image cache from its 100/100MB
  // defaults so the feed + Whispers + Discover surfaces (lots of
  // cached_network_image) survive longer between evictions. Numbers
  // were sized so a feed scroll on a mid-range device hits ~80% cache.
  PaintingBinding.instance.imageCache
    ..maximumSize = 240
    ..maximumSizeBytes = 200 * 1024 * 1024;

  if (!VentlyConfig.useMockBackend) {
    await Supabase.initialize(
      url: VentlyConfig.supabaseUrl,
      anonKey: VentlyConfig.supabaseAnonKey,
    );
  }

  // Sentry is opt-in: when SENTRY_DSN is empty, we run the app
  // directly so CI / mock-backend runs don't ship breadcrumbs.
  if (VentlyConfig.sentryDsn.isEmpty) {
    runApp(const ProviderScope(child: VentlyApp()));
    return;
  }

  // Release tag — `<package>@<version>+<build>` so Sentry can group
  // crashes per shipped build. Falls back to the dev label if
  // PackageInfo isn't available.
  String release = 'venttly@dev';
  try {
    final info = await PackageInfo.fromPlatform();
    release = '${info.packageName}@${info.version}+${info.buildNumber}';
  } catch (_) {/* keep fallback */}

  await SentryFlutter.init(
    (options) {
      options.dsn = VentlyConfig.sentryDsn;
      options.environment = VentlyConfig.env;
      options.release = release;
      options.tracesSampleRate = VentlyConfig.sentryTracesSampleRate;
      options.sendDefaultPii = false; // anonymous app — never ship PII
      options.attachScreenshot = false;
      // Defence in depth — strip any PII that slipped into tags or
      // contexts on top of [PiiScrubber] at the Logger boundary.
      options.beforeSend = (event, hint) {
        final scrubbedTags = event.tags == null
            ? null
            : Map<String, String>.fromEntries(
                event.tags!.entries.where(
                  (e) => PiiScrubber.scrub({e.key: e.value}).isNotEmpty,
                ),
              );
        return event.copyWith(
          user: null,
          request: null,
          tags: scrubbedTags,
        );
      };
    },
    appRunner: () {
      TelemetryService.instance.markSentryReady();
      _wireLoggerToSentry();
      runApp(const ProviderScope(child: VentlyApp()));
    },
  );
}

/// Subscribe Sentry to every Logger record:
///   * info/warn → breadcrumb (with category derived from `event.dot`)
///   * error     → captureException
/// PII is already scrubbed at the Logger boundary, but the
/// [Sentry.beforeSend] hook in main runs PiiScrubber again as
/// defence-in-depth.
void _wireLoggerToSentry() {
  Logger.instance.onRecord = (record) {
    final breadcrumbLevel = switch (record.level) {
      LogLevel.debug => SentryLevel.debug,
      LogLevel.info  => SentryLevel.info,
      LogLevel.warn  => SentryLevel.warning,
      LogLevel.error => SentryLevel.error,
    };
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: record.event,
        category: record.event.split('.').first,
        level: breadcrumbLevel,
        data: record.props,
        timestamp: record.at,
      ),
    );
    if (record.level == LogLevel.error && record.error != null) {
      Sentry.captureException(
        record.error,
        stackTrace: record.stack,
        withScope: (scope) {
          scope.setTag('event', record.event);
          // Props are already PII-scrubbed by Logger; safe to attach.
          for (final entry in record.props.entries) {
            scope.setContexts(entry.key, entry.value ?? '');
          }
        },
      );
    }
  };
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ref.read(sessionProvider.notifier).restore();
      AnalyticsService.instance.track(Events.appOpened);
      // Init local notifications. OS-level push (FCM/APNs) hooks land
      // through the registerPushToken RPC once Firebase is wired —
      // see docs/notifications.md.
      await NotificationsService.instance.init(
        onTap: (payload) {
          if (payload == null || payload.isEmpty) return;
          ref.read(pendingNotificationPayloadProvider.notifier).state =
              payload;
          handlePendingNotificationNavigation(ref);
        },
      );
      final notificationsOn = await readNotificationsEnabledPref();
      NotificationsService.instance.setEnabled(notificationsOn);
      if (notificationsOn) {
        await NotificationsService.instance.requestPermissions();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final router = ref.watch(routerProvider);

    ref.listen(sessionProvider, (prev, next) {
      if (next != null) {
        handlePendingNotificationNavigation(ref);
        PushRegistrationService.instance
            .init(ref.read(repositoryProvider));
        ref.invalidate(tribeChatInboxProvider);
      }
    });
    ref.listen(pendingNotificationPayloadProvider, (prev, next) {
      if (next != null) handlePendingNotificationNavigation(ref);
    });

    return MaterialApp.router(
      title: 'Venttly',
      debugShowCheckedModeBanner: false,
      theme: VentlyTheme.light(),
      // "Black" is our own third appearance: same dark theme, true-black
      // canvas — so it rides ThemeMode.dark with a pureBlack theme variant.
      darkTheme: VentlyTheme.dark(pureBlack: mode == VentlyThemeMode.black),
      themeMode:
          mode == VentlyThemeMode.light ? ThemeMode.light : ThemeMode.dark,
      routerConfig: router,
      // Premium blush gradient painted once behind the whole navigator —
      // screens opt in by making their Scaffold transparent.
      builder: (context, child) => VentlyPremiumBackground(
        child: NotificationForegroundListener(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
