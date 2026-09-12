import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/tribes/tribe_settings_screen.dart';

/// Reading the Keeper agreement back in Manage Tribe.
///
/// The agreement is recorded at creation and was, until this, invisible
/// afterwards — the record existed and nobody, including the person who gave
/// it, could see it.
///
/// The case worth protecting is the absent one. Every Tribe created before
/// 20261001090000 has no attestation, because the agreement did not exist to
/// be given, and `my_keeper_attestation` correctly returns nothing for them. A
/// card that filled that gap with a placeholder date, a "not recorded" warning
/// or an error box would be stating something false about a consent — so it
/// renders nothing at all.
void main() {
  Future<void> pumpRecord(
    WidgetTester tester,
    AsyncValue<KeeperAttestation?> state,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myKeeperAttestationProvider('t1').overrideWith((ref) async {
            return state.when(
              data: (value) => value,
              loading: () => Future<KeeperAttestation?>.value(null),
              error: (e, s) => Future<KeeperAttestation?>.error(e, s),
            );
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: KeeperAgreementRecord(tribeId: 't1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a recorded agreement shows who agreed and when', (tester) async {
    await pumpRecord(
      tester,
      AsyncValue.data(
        KeeperAttestation(
          version: 1,
          ageStatus: 'adult',
          // Local, because the card formats in local time and a UTC instant
          // near midnight would otherwise render as the previous day.
          attestedAt: DateTime(2026, 9, 4, 15, 30),
        ),
      ),
    );

    expect(find.text('Keeper agreement'), findsOneWidget);
    expect(
      find.textContaining('18 or over and accepted responsibility'),
      findsOneWidget,
    );
    expect(find.textContaining('4 Sep 2026'), findsOneWidget);
  });

  testWidgets('a Tribe made before the agreement existed shows nothing', (
    tester,
  ) async {
    // Not an error, and not a gap to paper over: there is genuinely no
    // agreement for these Tribes.
    await pumpRecord(tester, const AsyncValue.data(null));

    expect(find.text('Keeper agreement'), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed read stays silent rather than alarming', (
    tester,
  ) async {
    // A receipt is not load-bearing — the agreement is enforced and stored
    // server-side whatever this card does. An error box here would read as
    // "something is wrong with your agreement", which would be false.
    await pumpRecord(
      tester,
      AsyncValue.error(Exception('offline'), StackTrace.empty),
    );

    expect(find.text('Keeper agreement'), findsNothing);
    expect(find.textContaining('Something went wrong'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the date does not misreport a single-digit day or month', (
    tester,
  ) async {
    await pumpRecord(
      tester,
      AsyncValue.data(
        KeeperAttestation(
          version: 1,
          ageStatus: 'adult',
          attestedAt: DateTime(2026, 1, 1, 9),
        ),
      ),
    );
    expect(find.textContaining('1 Jan 2026'), findsOneWidget);
  });

  testWidgets('December does not run off the end of the month table', (
    tester,
  ) async {
    // _months is indexed by month - 1, so month 12 is the last element and an
    // off-by-one here would throw rather than misformat.
    await pumpRecord(
      tester,
      AsyncValue.data(
        KeeperAttestation(
          version: 1,
          ageStatus: 'adult',
          attestedAt: DateTime(2026, 12, 31, 12),
        ),
      ),
    );
    expect(find.textContaining('31 Dec 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
