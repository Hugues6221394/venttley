import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/onboarding/policy_consent_screen.dart';
import 'package:vently_app/presentation/screens/onboarding/policy_reader_screen.dart';
import 'package:vently_app/presentation/widgets/policy_body.dart';

PolicyDocument _doc(String kind, {String version = '2026-09-07'}) =>
    PolicyDocument(
      kind: kind,
      version: version,
      title: kind == 'terms'
          ? 'Venttly Terms & Conditions'
          : 'Venttly Privacy Policy',
      summary: 'First published version.',
      bodyMarkdown: '# ${kind == 'terms' ? 'Terms' : 'Privacy'}\n\nBody text.',
      effectiveAt: DateTime.utc(2026, 9, 7),
    );

class _FakeRepository extends VentlyRepository {
  _FakeRepository({
    this.current = const PolicyBundle(),
    this.outstanding = const PolicyBundle(),
    this.acceptThrows,
  }) : super(forceMock: true);

  PolicyBundle current;
  PolicyBundle outstanding;
  Object? acceptThrows;

  final List<({String terms, String privacy})> accepted = [];

  @override
  Future<PolicyBundle> currentPolicies() async => current;

  @override
  Future<PolicyBundle> myOutstandingPolicies() async => outstanding;

  @override
  Future<void> acceptPolicies({
    required String termsVersion,
    required String privacyVersion,
  }) async {
    if (acceptThrows != null) throw acceptThrows!;
    accepted.add((terms: termsVersion, privacy: privacyVersion));
    outstanding = const PolicyBundle();
  }
}

Future<GoRouter> _pumpConsent(
  WidgetTester tester,
  _FakeRepository repo,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const PolicyConsentScreen()),
      GoRoute(
        path: '/feed',
        builder: (_, __) => const Scaffold(body: Text('the feed')),
      ),
      GoRoute(
        path: '/legal/terms',
        builder: (_, __) => const PolicyReaderScreen(kind: 'terms'),
      ),
      GoRoute(
        path: '/legal/privacy',
        builder: (_, __) => const PolicyReaderScreen(kind: 'privacy'),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('the signup consent step', () {
    // Source assertions, matching this repository's contract-test style. The
    // signup screen cannot be pumped in isolation — it drives
    // SessionController.register against Supabase — so what is asserted here
    // is the shape of the code that decides whether an account can be made.
    final identity = File(
      'lib/presentation/screens/onboarding/identity_screen.dart',
    ).readAsStringSync();

    test('both boxes start unticked and neither is pre-filled', () {
      // A pre-ticked consent box is not consent. If either default ever flips
      // to true, every account created afterwards carries a record of an
      // agreement nobody made.
      expect(identity, contains('bool _agreedTerms = false;'));
      expect(identity, contains('bool _acknowledgedPrivacy = false;'));
      expect(identity, isNot(contains('_agreedTerms = true;')));
      expect(identity, isNot(contains('_acknowledgedPrivacy = true;')));
    });

    test('submit refuses to register until both are ticked', () {
      // The guard has to sit before `register`, or the account exists before
      // anybody agreed to anything.
      final guard = identity.indexOf(
        'if (!_agreedTerms || !_acknowledgedPrivacy)',
      );
      final register = identity.indexOf('.register(');
      expect(guard, greaterThan(-1));
      expect(register, greaterThan(-1));
      expect(
        guard,
        lessThan(register),
        reason: 'the consent check must run before the account is created',
      );
    });

    test('submit refuses when the documents could not be loaded', () {
      // Otherwise somebody ticks two boxes for documents the app never had,
      // and the acceptance names a version that was never rendered.
      final guard = identity.indexOf('if (terms == null || privacy == null)');
      expect(guard, greaterThan(-1));
      expect(guard, lessThan(identity.indexOf('.register(')));
    });

    test('the versions handed to the server are the ones that were rendered', () {
      // Not re-fetched at submit time, and not hardcoded. This is what makes
      // the record evidence rather than decoration.
      expect(identity, contains('termsVersion: terms.version'));
      expect(identity, contains('privacyVersion: privacy.version'));
      expect(
        identity,
        contains('ref.read(currentPoliciesProvider).valueOrNull'),
      );
    });

    test('the provider is watched, so the documents actually load', () {
      // `read` alone never starts a FutureProvider's request, which would
      // leave the versions null at submit and block every signup.
      expect(identity, contains('ref.watch(currentPoliciesProvider)'));
    });
  });

  group('the consent gate in the router', () {
    final router = File(
      'lib/presentation/router/app_router.dart',
    ).readAsStringSync();

    test('legal routes survive having no session', () {
      // The signup screen links straight to these. Without the exemption they
      // redirect to /onboarding and the consent links are dead — which would
      // mean asking somebody to agree to something they cannot read.
      expect(router, contains("path.startsWith('/legal')"));
      expect(
        router,
        contains('if (session == null && !onboardingRoute && !legalRoute)'),
      );
    });

    test('an unknown answer does not lock anybody out', () {
      // valueOrNull is null while loading and when the fetch failed. Both
      // must fall through rather than redirect: consent is enforced by the
      // acceptance row being server-only, not by this gate being airtight.
      expect(
        router,
        contains('ref.read(outstandingPoliciesProvider).valueOrNull'),
      );
      expect(router, contains('outstanding != null && !outstanding.isEmpty'));
    });
  });

  group('PolicyConsentScreen', () {
    testWidgets('will not accept until every outstanding box is ticked', (
      tester,
    ) async {
      final repo = _FakeRepository(
        current: PolicyBundle(terms: _doc('terms'), privacy: _doc('privacy')),
        outstanding: PolicyBundle(
          terms: _doc('terms'),
          privacy: _doc('privacy'),
        ),
      );
      await _pumpConsent(tester, repo);

      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();

      expect(repo.accepted, isEmpty);
      expect(find.text('Please tick each document to continue.'), findsOne);

      // One of two is not enough.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();
      expect(repo.accepted, isEmpty);

      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();

      expect(repo.accepted, hasLength(1));
      expect(repo.accepted.single.terms, '2026-09-07');
      expect(repo.accepted.single.privacy, '2026-09-07');
      expect(find.text('the feed'), findsOne);
    });

    testWidgets('only the outstanding document is asked for', (tester) async {
      // A material Terms change must not make somebody re-acknowledge a
      // Privacy Policy that did not move.
      final repo = _FakeRepository(
        current: PolicyBundle(
          terms: _doc('terms', version: '2027-01-01'),
          privacy: _doc('privacy'),
        ),
        outstanding: PolicyBundle(terms: _doc('terms', version: '2027-01-01')),
      );
      await _pumpConsent(tester, repo);

      expect(find.byType(Checkbox), findsOne);
      expect(find.textContaining('Terms & Conditions'), findsWidgets);
      expect(find.text('Our Terms has been updated'), findsOne);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();

      // Both versions are still named in the call — the RPC records the
      // current pair, and a document already accepted still has to be
      // identified.
      expect(repo.accepted.single.terms, '2027-01-01');
      expect(repo.accepted.single.privacy, '2026-09-07');
    });

    testWidgets('a stale version is explained, not retried silently', (
      tester,
    ) async {
      final repo = _FakeRepository(
        current: PolicyBundle(terms: _doc('terms'), privacy: _doc('privacy')),
        outstanding: PolicyBundle(
          terms: _doc('terms'),
          privacy: _doc('privacy'),
        ),
        acceptThrows: Exception('policy_version_stale'),
      );
      await _pumpConsent(tester, repo);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('These documents were just updated'),
        findsOne,
      );
      expect(find.text('the feed'), findsNothing);
    });

    testWidgets('there is no way past this screen without agreeing', (
      tester,
    ) async {
      final repo = _FakeRepository(
        current: PolicyBundle(terms: _doc('terms'), privacy: _doc('privacy')),
        outstanding: PolicyBundle(
          terms: _doc('terms'),
          privacy: _doc('privacy'),
        ),
      );
      await _pumpConsent(tester, repo);

      // No skip, no "later", and no back arrow — the screen is reached by
      // redirect, so a pop would land nowhere and a skip would make the whole
      // record meaningless.
      expect(find.text('Skip'), findsNothing);
      expect(find.text('Later'), findsNothing);
      expect(find.text('Not now'), findsNothing);
      expect(find.byType(BackButton), findsNothing);
    });
  });

  group('PolicyReaderScreen', () {
    testWidgets('renders the document and names its version', (tester) async {
      // The version is on screen because "which version did I agree to" is
      // the question the acceptance record exists to answer, and a reader
      // that hides its own version cannot be checked against it.
      final repo = _FakeRepository(
        current: PolicyBundle(terms: _doc('terms'), privacy: _doc('privacy')),
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const PolicyReaderScreen(kind: 'terms'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Version 2026-09-07'), findsOne);
      expect(find.byType(PolicyBody), findsOne);
    });

    testWidgets('a document that will not load offers no way to agree', (
      tester,
    ) async {
      final repo = _FakeRepository(current: const PolicyBundle());
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const PolicyReaderScreen(kind: 'privacy'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('could not load'), findsOne);
      expect(find.text('Try again'), findsOne);
      expect(find.textContaining('Continue anyway'), findsNothing);
    });
  });

  group('PolicyBody', () {
    testWidgets('strips emphasis markers instead of printing them', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PolicyBody(
              markdown: '# Title\n\n'
                  'A **bold** word and an _italic_ one.\n\n'
                  '- first item\n'
                  '- second item\n',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Title'), findsOne);
      // The rendered text must not still contain the syntax.
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(texts, contains('A bold word and an italic one.'));
      expect(texts, isNot(contains('**')));
      expect(texts, isNot(contains('_italic_')));
      expect(texts, contains('first item'));
      expect(texts, contains('second item'));
    });

    testWidgets('a hard-wrapped paragraph reflows into one block', (
      tester,
    ) async {
      // The documents are wrapped at the author's column width. Rendering
      // each source line as its own paragraph would break mid-sentence at
      // whatever width the author happened to use.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PolicyBody(
              markdown: 'One sentence that the author\n'
                  'wrapped across two lines.\n',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(
        texts,
        contains('One sentence that the author wrapped across two lines.'),
      );
    });
  });
}
