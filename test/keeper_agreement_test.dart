import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/core/tribe_category_labels.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/tribe/tribe_management.dart';
import 'package:vently_app/presentation/screens/tribes/create_tribe_screen.dart';

/// The Keeper agreement on step 3 of Create a Tribe.
///
/// Before this, the 18+ rule had no visible presence in the flow at all. It is
/// checked on the server and asked about before the form opens, but for adults
/// — nearly everyone who gets here — that check passes in silence, so nobody
/// was ever shown the rule, told what keeping a Tribe commits them to, or
/// asked to agree to it. There was no answer to "when did this keeper accept
/// responsibility for this space".
///
/// Two things have to hold for the tick to mean anything:
///   1. it is not pre-ticked, and Create does not work without it
///   2. what it records reaches the server
///
/// The second is the one that rots quietly: the checkbox keeps working, the
/// parameter stops being sent, and the consent becomes decoration.
class _RecordingRepository extends VentlyRepository {
  _RecordingRepository() : super(forceMock: true);

  bool? sawAttested;
  int? sawVersion;

  @override
  Future<Tribe> createTribe({
    required String name,
    required String category,
    String? description,
    bool isPrivate = false,
    List<String> tags = const [],
    String? visibility,
    String? welcomeMessage,
    TribeGovernanceSettings settings = const TribeGovernanceSettings(),
    List<TribeRuleItem> rules = const [],
    required String idempotencyKey,
    required bool keeperAttested,
    required int attestationVersion,
  }) async {
    sawAttested = keeperAttested;
    sawVersion = attestationVersion;
    throw Exception('stop here — the call itself is what is under test');
  }
}

/// Must match _KeeperAgreement.agreementText. Duplicated rather than imported
/// because the widget is private; if the two drift, the semantics assertions
/// below fail, which is the intended alarm.
const agreementLabel =
    "I'm 18 or over, and I accept responsibility for this Tribe — "
    "I'll uphold Venttly's Community Guidelines and act on reports about it.";

void main() {
  Future<void> pumpForm(WidgetTester tester, VentlyRepository repo) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          // Pinned so the form does not depend on a live category table.
          tribeCategoriesProvider.overrideWith(
            (ref) async => const [
              TribeCategory(key: 'support', label: 'Support'),
            ],
          ),
        ],
        // The gate is deliberately not in the way here: this is about the
        // agreement, and TribeCreationGate has its own tests.
        child: const MaterialApp(home: CreateTribeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Taps the agreement sentence, scrolling it into view first.
  ///
  /// The card is the last thing on a scrolling step, so in the default
  /// 800x600 test window it sits below the fold and a tap at its centre lands
  /// outside the viewport instead of on the InkWell.
  Future<void> tapAgreement(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// Walks step 1 → 3, which is where the agreement lives.
  Future<void> reachReview(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextField).first,
      'Consent Check Tribe',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets('the agreement is visible on the review step, and unticked', (
    tester,
  ) async {
    await pumpForm(tester, _RecordingRepository());
    await reachReview(tester);

    expect(find.text('Keeper confirmation'), findsOneWidget);
    // The age rule is stated on screen, which is the thing that was missing.
    expect(find.textContaining('18 and over'), findsOneWidget);
    expect(find.textContaining("I'm 18 or over"), findsOneWidget);
    // Never pre-ticked. A pre-ticked consent is not a consent.
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
  });

  testWidgets('Create Tribe does nothing until the agreement is ticked', (
    tester,
  ) async {
    final repo = _RecordingRepository();
    await pumpForm(tester, repo);
    await reachReview(tester);

    final create = find.widgetWithText(FilledButton, 'Create Tribe');
    expect(create, findsOneWidget);
    expect(
      tester.widget<FilledButton>(create).onPressed,
      isNull,
      reason: 'the footer ignored canAdvance on the last step before this',
    );

    // Pressing it must not reach the repository either — a disabled-looking
    // button that still fires is the worse version of this bug.
    await tester.tap(create, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(repo.sawAttested, isNull);
  });

  testWidgets('ticking it enables Create and sends the agreement', (
    tester,
  ) async {
    final repo = _RecordingRepository();
    await pumpForm(tester, repo);
    await reachReview(tester);

    await tapAgreement(tester, find.textContaining("I'm 18 or over"));
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

    final create = find.widgetWithText(FilledButton, 'Create Tribe');
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);

    // The footer is pinned, so this one needs no scrolling.
    await tester.tap(create);
    await tester.pumpAndSettle();

    // The whole point: what was ticked is what gets sent. The server defaults
    // p_keeper_attested to FALSE and refuses, so a call that forgets this
    // parameter fails loudly rather than recording a consent nobody gave.
    expect(repo.sawAttested, isTrue);
    expect(repo.sawVersion, 1);
  });

  testWidgets('the whole sentence is the tap target, not just the box', (
    tester,
  ) async {
    // The checkbox is the smallest thing on the screen and the one thing that
    // has to be tapped, so the text toggles it too.
    await pumpForm(tester, _RecordingRepository());
    await reachReview(tester);

    await tapAgreement(tester, find.textContaining('Community Guidelines'));
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });

  testWidgets('the form renders with the semantics tree enabled', (
    tester,
  ) async {
    // A guard on the render-tree shape, not on the agreement.
    //
    // Quiet Mornings rendered blank for a stretch, and the cause was a
    // '!semantics.parentDataDirty' assertion firing tens of thousands of times
    // and aborting the paint. It only happened with the semantics tree turned
    // on — which VoiceOver does, and which `idb ui describe-all` does, and
    // which nothing in this suite did. So the app painted correctly under test
    // and was blank for anybody using a screen reader.
    //
    // It no longer reproduces on either simulator. The likely cause is the two
    // Material widgets since added inside GlassCard and VentlyPremiumBackground
    // for the ink-splash fix, which changed the render tree around exactly
    // these surfaces — but that is a plausible mechanism, not a proven one, so
    // this holds the door shut rather than trusting the explanation.
    //
    // CreateTribeScreen is the cheap way to cover it: it puts GlassCard inside
    // VentlyPremiumBackground, which is the nesting that changed.
    // Disposed explicitly at the end of the body, not via addTearDown: the
    // framework verifies no handle is outstanding *before* tear-downs run.
    final handle = tester.ensureSemantics();

    await pumpForm(tester, _RecordingRepository());
    await reachReview(tester);

    // Painted, not merely built: a widget whose paint was aborted still
    // reports its text to the finder, which is precisely how the blank screen
    // went unnoticed.
    expect(find.text('Keeper confirmation'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // And the agreement is a real semantics node with its own boundary. This
    // caught a second bug on device: without container: true the node merged
    // upward and VoiceOver announced one checkbox spanning the whole step.
    final node = tester.getSemantics(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == agreementLabel,
      ),
    );
    expect(node.label, agreementLabel);
    expect(node.hasFlag(SemanticsFlag.hasCheckedState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isChecked), isFalse);

    handle.dispose();
  });
}
