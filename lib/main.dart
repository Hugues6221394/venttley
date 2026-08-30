import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/analytics_events.dart';
import 'core/constants.dart';
import 'core/group_invite_links.dart';
import 'core/logger.dart';
import 'core/pii_scrubber.dart';
import 'core/notification_prefs.dart';
import 'core/notification_routing.dart';
import 'core/providers.dart';
import 'data/services/analytics_service.dart';
import 'data/services/push_registration_service.dart';
import 'data/services/schema_ledger_check.dart';
import 'data/services/notifications_service.dart';
import 'data/services/telemetry_service.dart';
import 'presentation/router/app_router.dart';
import 'presentation/theme/app_theme.dart';
import 'presentation/widgets/notification_foreground_listener.dart';
import 'presentation/widgets/vently_premium_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  VentlyConfig.validateBackendConfiguration();

  // Firebase background handlers must be registered before runApp. Preparing
  // is consent-gated and native auto-init remains disabled, so this does not
  // generate a token for new or opted-out users.
  try {
    if (await readNotificationsEnabledPref()) {
      await PushRegistrationService.instance.prepareForConsentedUser();
    }
  } catch (_) {
    Logger.instance.warn('push.consent_restore_failed');
  }

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
  } catch (_) {
    /* keep fallback */
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = VentlyConfig.sentryDsn;
      options.environment = VentlyConfig.env;
      options.release = release;
      options.tracesSampleRate = VentlyConfig.sentryTracesSampleRate;
      options.sendDefaultPii = false; // do not collect SDK-default identifiers
      options.attachScreenshot = false;
      // Defence in depth — strip any PII that slipped into tags or
      // contexts on top of [PiiScrubber] at the Logger boundary.
      options.beforeSend = (event, hint) => _scrubSentryEvent(event);
    },
    appRunner: () {
      TelemetryService.instance.markSentryReady();
      _wireLoggerToSentry();
      runApp(const ProviderScope(child: VentlyApp()));
    },
  );
}

SentryEvent _scrubSentryEvent(SentryEvent event) {
  final tags = <String, String>{};
  for (final entry
      in event.tags?.entries ??
          const Iterable<MapEntry<String, String>>.empty()) {
    final scrubbed = PiiScrubber.scrub({entry.key: entry.value});
    final value = scrubbed[entry.key];
    if (value != null) tags[entry.key] = value.toString();
  }
  final breadcrumbs = event.breadcrumbs
      ?.map(
        (breadcrumb) => breadcrumb.copyWith(
          message: breadcrumb.message == null
              ? null
              : PiiScrubber.scrubText(breadcrumb.message!),
          data: breadcrumb.data == null
              ? null
              : PiiScrubber.scrub(Map<String, Object?>.from(breadcrumb.data!)),
        ),
      )
      .toList();
  final exceptions = event.exceptions
      ?.map(
        (exception) => exception.copyWith(
          value: exception.value == null
              ? null
              : PiiScrubber.scrubText(exception.value!),
          throwable: exception.throwable == null
              ? null
              : PiiScrubber.scrubError(exception.throwable),
        ),
      )
      .toList();
  final eventMessage = event.message;
  final message = eventMessage?.copyWith(
    formatted: PiiScrubber.scrubText(eventMessage.formatted),
    template: eventMessage.template == null
        ? null
        : PiiScrubber.scrubText(eventMessage.template!),
    params: eventMessage.params
        ?.map((value) => PiiScrubber.scrubText(value.toString()))
        .toList(),
  );

  // Build a clean event instead of copyWith: Sentry's nullable copyWith fields
  // cannot clear an existing user or request once one has been attached.
  return SentryEvent(
    eventId: event.eventId,
    timestamp: event.timestamp,
    modules: event.modules,
    tags: tags,
    fingerprint: event.fingerprint,
    breadcrumbs: breadcrumbs,
    exceptions: exceptions,
    threads: event.threads,
    sdk: event.sdk,
    platform: event.platform,
    logger: event.logger,
    serverName: event.serverName,
    release: event.release,
    dist: event.dist,
    environment: event.environment,
    message: message,
    transaction: event.transaction,
    throwable: event.throwable == null
        ? null
        : PiiScrubber.scrubError(event.throwable),
    level: event.level,
    culprit: event.culprit == null
        ? null
        : PiiScrubber.scrubText(event.culprit!),
    contexts: event.contexts,
    debugMeta: event.debugMeta,
    type: event.type,
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
      LogLevel.info => SentryLevel.info,
      LogLevel.warn => SentryLevel.warning,
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

class _VentlyAppState extends ConsumerState<VentlyApp>
    with WidgetsBindingObserver {
  /// Presence heartbeat — stamps users.last_seen_at every ~60s while the
  /// app is foregrounded so peers see Online / Active recently (0114).
  Timer? _presenceTimer;
  StreamSubscription<Uri>? _appLinkSubscription;
  StreamSubscription<AuthState>? _authSubscription;
  String? _pendingDeepLinkPath;

  /// Throttles the unanswered-alert poll. Resume fires on every task-switch,
  /// and a security question re-asked every time you glance at another app is
  /// a question that stops being read.
  DateTime? _lastSecurityCheck;

  static const String _securityCheckRoute = '/security-check';

  void _handleAppLink(Uri uri) {
    final path = groupInvitePathFromUri(uri);
    if (path == null) return;
    if (ref.read(sessionProvider) == null) {
      _pendingDeepLinkPath = path;
      return;
    }
    _pendingDeepLinkPath = null;
    ref.read(routerProvider).go(path);
  }

  void _flushPendingDeepLink() {
    final path = _pendingDeepLinkPath;
    if (path == null || ref.read(sessionProvider) == null) return;
    _pendingDeepLinkPath = null;
    ref.read(routerProvider).go(path);
  }

  /// Restore the session without letting a transport failure end the launch.
  ///
  /// restore() rethrows anything that is not a recognised missing column, and
  /// this call was awaited bare at startup — so a 401 took the app down before
  /// it drew a frame. Seen for real: a simulator whose clock had drifted
  /// answered PGRST303 "JWT issued at future" and the process died with "Lost
  /// connection to device". A launch crash is the worst failure this app can
  /// have; someone opening it to write something hard does not get a second
  /// attempt at reaching for help.
  ///
  /// One retry, because the causes are overwhelmingly transient — clock skew,
  /// a token refreshing, a network still coming up — and they clear in
  /// seconds. If it fails twice the session stays unset and the router sends
  /// them to sign-in, which is a truthful outcome rather than a dead app.
  Future<void> _restoreSessionSafely() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await ref.read(sessionProvider.notifier).restore();
        return;
      } catch (error, stack) {
        final lastTry = attempt == 1;
        Logger.instance.warn(
          'session.restore_failed',
          props: {'attempt': attempt + 1, 'giving_up': lastTry},
          error: error,
          stack: lastTry ? stack : null,
        );
        if (lastTry) return;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
      }
    }
  }

  void _startPresenceHeartbeat() {
    _presenceTimer?.cancel();
    if (ref.read(sessionProvider) == null) return;
    unawaited(_touchLastSeenSafely());
    _presenceTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_touchLastSeenSafely()),
    );
  }

  Future<void> _touchLastSeenSafely() async {
    try {
      await ref.read(repositoryProvider).touchLastSeen();
    } catch (_) {
      // Presence is best-effort. Offline transitions, expired sessions, and
      // temporary clock skew must never become uncaught app exceptions.
      Logger.instance.warn('presence.heartbeat_failed');
    }
    await _verifyDeviceSessionSafely();
  }

  /// Notice a session that was revoked from another device.
  ///
  /// Deleting the GoTrue session stops the refresh token, but the access token
  /// already in memory stays valid until it expires — up to an hour. Riding the
  /// existing 60s presence heartbeat closes that gap: "sign this device out"
  /// takes effect within a minute instead of within an hour.
  ///
  /// Only an explicit false signs out. A network error must never eject
  /// someone from their own account.
  Future<void> _verifyDeviceSessionSafely() async {
    if (ref.read(sessionProvider) == null) return;
    bool alive;
    try {
      alive = await ref.read(repositoryProvider).touchDeviceSession();
    } catch (_) {
      Logger.instance.warn('security.session_check_failed');
      return;
    }
    if (alive || !mounted || ref.read(sessionProvider) == null) return;

    Logger.instance.info('security.session_revoked_remotely');
    _stopPresenceHeartbeat();
    try {
      await ref.read(sessionProvider.notifier).logout();
    } catch (_) {
      Logger.instance.warn('security.revoked_signout_failed');
    }
  }

  /// Bind this installation to the session that just started.
  ///
  /// Runs on sign-in and on every cold start, because a session can outlive the
  /// app process and would otherwise never appear in the user's device list.
  Future<void> _registerDeviceSafely(String userId) async {
    try {
      final identity = await ref.read(deviceIdentityServiceProvider).read();
      if (!mounted || ref.read(sessionProvider)?.userId != userId) return;

      final registration = await ref
          .read(repositoryProvider)
          .registerDeviceSession(
            deviceId: identity.deviceId,
            deviceName: identity.deviceName,
            deviceType: identity.deviceType,
            osName: identity.osName,
            osVersion: identity.osVersion,
            appVersion: identity.appVersion,
          );

      if (registration == null || !mounted) return;
      if (ref.read(sessionProvider)?.userId != userId) return;

      // The user previously told us this device was not them. Honour that
      // now rather than waiting for the next heartbeat.
      if (registration.isBlocked) {
        Logger.instance.info('security.blocked_device_signed_out');
        _stopPresenceHeartbeat();
        await ref.read(sessionProvider.notifier).logout();
        return;
      }

      // The server scored this sign-in high enough to want an answer. Ask now,
      // while the user still remembers whether they just did something unusual.
      if (registration.needsConfirmation) {
        Logger.instance.info('security.login_challenge_raised');
        _openSecurityCheck();
      }
    } catch (_) {
      // Never block sign-in on this. A device that fails to register is
      // invisible in the session list, which is a worse list — not a worse
      // login.
      Logger.instance.warn('security.device_register_failed');
    }
  }

  /// Catch up on prompts raised while the app was closed.
  ///
  /// The sign-in worth asking about is usually the one the user was not
  /// present for, so registration alone is not enough — that path only fires
  /// for the session being opened right now.
  Future<void> _checkSecurityAlertsSafely() async {
    if (ref.read(sessionProvider) == null) return;
    final now = DateTime.now();
    final last = _lastSecurityCheck;
    if (last != null && now.difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _lastSecurityCheck = now;

    try {
      final alerts = await ref
          .read(repositoryProvider)
          .myUnresolvedSecurityAlerts();
      if (alerts.isEmpty || !mounted) return;
      if (ref.read(sessionProvider) == null) return;
      _openSecurityCheck();
    } catch (_) {
      // A failed check must not surface as an error. The notification row and
      // the email are the durable channels; this is the convenient one.
      _lastSecurityCheck = null;
      Logger.instance.warn('security.alert_check_failed');
    }
  }

  /// Never stack the prompt on top of itself — a resume while the user is
  /// already answering would push a second copy over the first.
  void _openSecurityCheck() {
    final router = ref.read(routerProvider);
    final location = router.routerDelegate.currentConfiguration.uri.path;
    if (location == _securityCheckRoute) return;
    router.push(_securityCheckRoute);
  }

  void _stopPresenceHeartbeat() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

  void _handleRemoteNotificationOpen(Map<String, dynamic> data) {
    final payload = NotificationPayload.fromFcmData(data);
    if (payload == null) {
      // Deliberately do not log attacker-controlled payload values.
      Logger.instance.warn('push.notification_route_rejected');
      return;
    }
    ref.read(pendingNotificationPayloadProvider.notifier).state = payload;
    handlePendingNotificationNavigation(ref);
  }

  Future<void> _startPushForSession(String userId) async {
    if (!await readNotificationsEnabledPref()) return;
    if (!mounted || ref.read(sessionProvider)?.userId != userId) return;
    await PushRegistrationService.instance.startForSession(
      ref.read(repositoryProvider),
      sessionKey: userId,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPresenceHeartbeat();
      final session = ref.read(sessionProvider);
      if (session != null) {
        unawaited(_startPushForSession(session.userId));
        unawaited(_checkSecurityAlertsSafely());
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopPresenceHeartbeat();
      // Audio previews are foreground-only. This also covers an interrupted
      // story transition and prevents a clip continuing behind another app.
      unawaited(ref.read(musicPlaybackProvider).stop());
      unawaited(AnalyticsService.instance.track(Events.appBackgrounded));
    }
  }

  @override
  void dispose() {
    _stopPresenceHeartbeat();
    _appLinkSubscription?.cancel();
    _authSubscription?.cancel();
    PushRegistrationService.instance.setNotificationOpenedHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushRegistrationService.instance.setNotificationOpenedHandler(
      _handleRemoteNotificationOpen,
    );
    _appLinkSubscription = AppLinks().uriLinkStream.listen(
      _handleAppLink,
      onError: (Object error, StackTrace stack) =>
          Logger.instance.warn('app_link.invalid', error: error, stack: stack),
    );
    if (!VentlyConfig.useMockBackend) {
      _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen(
        (data) {
          if (data.event == AuthChangeEvent.signedIn) {
            unawaited(_restoreSessionSafely());
          }
        },
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _restoreSessionSafely();
      AnalyticsService.instance.track(Events.appOpened);
      // Ask the database what it has actually run. Advisory and unawaited: a
      // database behind the build degrades features, and blocking startup on it
      // would turn a cosmetic gap into an outage.
      if (!VentlyConfig.useMockBackend) {
        unawaited(
          SchemaLedgerCheck(
            Supabase.instance.client,
          ).report().catchError((_) {}),
        );
      }
      // Foreground alerts stay on the existing Supabase realtime path. FCM is
      // used for background delivery and tap routing only, avoiding duplicate
      // alerts while the app is open.
      await NotificationsService.instance.init(
        onTap: (payload) {
          if (payload == null || payload.isEmpty) return;
          ref.read(pendingNotificationPayloadProvider.notifier).state = payload;
          handlePendingNotificationNavigation(ref);
        },
      );
      final notificationsOn = await readNotificationsEnabledPref();
      NotificationsService.instance.setEnabled(notificationsOn);
      if (notificationsOn) {
        final session = ref.read(sessionProvider);
        if (session == null) {
          await PushRegistrationService.instance.detachSession();
        } else {
          await _startPushForSession(session.userId);
        }
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
        _flushPendingDeepLink();
        unawaited(_startPushForSession(next.userId));
        unawaited(_registerDeviceSafely(next.userId));
        ref.invalidate(tribeChatInboxProvider);
        _startPresenceHeartbeat();
      } else {
        unawaited(PushRegistrationService.instance.detachSession());
        _stopPresenceHeartbeat();
        // The next account to sign in on this handset gets its own check
        // rather than inheriting this one's throttle window.
        _lastSecurityCheck = null;
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
      themeMode: mode == VentlyThemeMode.light
          ? ThemeMode.light
          : ThemeMode.dark,
      routerConfig: router,
      // Premium blush gradient painted once behind the whole navigator —
      // screens opt in by making their Scaffold transparent.
      builder: (context, child) => VentlyPremiumBackground(
        child: NotificationForegroundListener(
          router: router,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Converts the only public custom scheme Venttly currently supports into an
/// internal route. Keeping this parser strict prevents arbitrary deep links
/// from bypassing the router's normal navigation and authentication rules.
String? groupInvitePathFromUri(Uri uri) {
  return groupInviteRouteFromUri(uri);
}
