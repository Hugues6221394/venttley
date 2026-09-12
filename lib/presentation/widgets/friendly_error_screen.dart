import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/logger.dart';

/// What a person sees when a screen fails to build.
///
/// Flutter's default is the red screen with a stack trace in debug, and a grey
/// void in release. Neither is acceptable here. Venttly is used by people in
/// distress, including thirteen-year-olds, and a wall of yellow-on-red
/// assertion text is frightening in a way an ordinary app's crash is not — it
/// looks like the person broke something, on a platform whose entire promise is
/// that they are safe.
///
/// So every widget error renders this instead: plain language, no stack trace,
/// and a way out. The error itself still goes to the logger and to Sentry, so
/// nothing is hidden from us — only from the person holding the phone.
///
/// In debug the details are available behind a disclosure, because a developer
/// looking at a broken screen does need them; they are simply not the first
/// thing on the page.
class FriendlyErrorScreen extends StatelessWidget {
  const FriendlyErrorScreen({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    // Deliberately does not depend on Theme or any app provider.
    //
    // This widget is the last line of defence, so it has to render even when
    // the failure is in the theme, the router, or a provider — anything it
    // reached into could be the very thing that just broke.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: const Color(0xFFFFF7FA),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      color: Color(0x1FD81B60),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.favorite_rounded,
                      color: Color(0xFFD81B60),
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "This part of Venttly didn't load",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF2A1620),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    // Says whose fault it is, on purpose. Somebody who thinks
                    // they broke it is somebody who stops using the app.
                    "Nothing you did caused this, and nothing you wrote has "
                    "been lost. Go back and try again — we've been told about "
                    "it.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6B5560),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // maybeOf, not of.
                  //
                  // Navigator.of() throws when there is no Navigator above
                  // this context, and ErrorWidget.builder is invoked in
                  // exactly that situation when the failure is at or above the
                  // Navigator itself. Using it here threw "Navigator operation
                  // requested with a context that does not include a
                  // Navigator" from inside the error screen — the one widget
                  // in the app that must never throw, because there is nothing
                  // left to catch it.
                  if (Navigator.maybeOf(context)?.canPop() ?? false)
                    _Button(
                      label: 'Go back',
                      onTap: () => Navigator.maybeOf(context)?.maybePop(),
                    ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 22),
                    ExpansionTile(
                      title: const Text(
                        'Developer details',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF6B5560),
                        ),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '${details.exception}',
                            style: const TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              fontFamily: 'monospace',
                              color: Color(0xFF6B5560),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Material(
        color: const Color(0xFFD81B60),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 14.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Install the app-wide error handling. Call once, before runApp.
///
/// Three separate channels, because Flutter reports failures in three
/// different places and missing any one of them leaves a hole:
///
///   * ErrorWidget.builder — a widget threw during build/layout/paint. This is
///     the one that produces the red screen, and the only one a person sees.
///   * FlutterError.onError — framework errors, including those same build
///     failures, for logging.
///   * PlatformDispatcher.instance.onError — unhandled async errors that never
///     touch the widget tree at all.
void installErrorHandling() {
  final priorOnError = FlutterError.onError;

  ErrorWidget.builder = (FlutterErrorDetails details) {
    // Never let the reporting path throw. If it does we would recurse into
    // the same handler and take the whole app down for a logging failure.
    try {
      log.error(
        'ui.widget_error',
        props: {
          'library': details.library ?? 'unknown',
          // The type only. The full message goes through `error:` below and,
          // in debug, to debugPrint — the PII scrubber redacts long prop
          // strings, which is right for user content and useless for a stack
          // trace. It rendered every one of these as <scrubbed:length=206>,
          // so the failure was logged and still undiagnosable.
          'type': details.exception.runtimeType.toString(),
        },
        error: details.exception,
        stack: details.stack,
      );
      if (kDebugMode) {
        debugPrint('WIDGET ERROR: ${details.exception}');
      }
    } catch (_) {}
    return FriendlyErrorScreen(details: details);
  };

  FlutterError.onError = (FlutterErrorDetails details) {
    try {
      log.error(
        'flutter.error',
        props: {
          'library': details.library ?? 'unknown',
          'error': '${details.exception}',
        },
      );
    } catch (_) {}
    // In debug, always print the full block.
    //
    // Chaining only to priorOnError silenced the console dump, because
    // Sentry's handler reports rather than prints. The result was a log full
    // of "<scrubbed:length=206>" with the actual assertion nowhere — I made
    // the app's own failures harder to read while adding the handler meant to
    // surface them.
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
    // And keep whatever was already installed — Sentry registers here, and
    // replacing it silently would stop crash reporting in release.
    if (priorOnError != null) {
      priorOnError(details);
    } else if (!kDebugMode) {
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    try {
      log.error('async.error', props: {'error': '$error'});
    } catch (_) {}
    // false means "not handled", so Sentry and the platform still see it.
    return false;
  };
}
