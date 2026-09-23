import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/presentation/widgets/username_availability.dart';

/// Telling somebody their username is taken while they type it.
///
/// Until now the only answer came from the insert failing — after picking a
/// password, agreeing to two policies and pressing the button.
///
/// Uniqueness itself is not this widget's job and never was:
/// users_pseudonym_lower_unique guarantees it, and 0050 proves the lookup
/// agrees with that index about case. What is tested here is the behaviour
/// around the lookup, which is where this kind of feature goes wrong.
class _FakeRepo extends VentlyRepository {
  _FakeRepo({this.taken = const {}, this.fail = false, this.delay})
    : super(forceMock: true);

  final Set<String> taken;
  final bool fail;
  final Duration? delay;
  final List<String> asked = [];

  @override
  Future<bool> usernameAvailable(String username) async {
    asked.add(username);
    if (delay != null) await Future<void>.delayed(delay!);
    if (fail) throw StateError('offline');
    return !taken.contains(username.toLowerCase());
  }
}

UsernameAvailability _subject(_FakeRepo repo) {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  // listen, not read. The provider is autoDispose, and a bare read leaves it
  // with no subscribers — so Riverpod tears it down immediately and dispose()
  // cancels the debounce before it can fire. In the app a built widget is
  // watching it, which is the case being modelled here.
  container.listen(usernameAvailabilityProvider, (_, __) {});
  return container.read(usernameAvailabilityProvider);
}

void main() {
  test('a free name reads free, a taken one reads taken', () async {
    final repo = _FakeRepo(taken: {'takenname'});
    final subject = _subject(repo);

    subject.check('freename');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(subject.status, UsernameStatus.free);

    subject.check('TakenName');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      subject.status,
      UsernameStatus.taken,
      reason: 'the index is on lower(), so the answer must not be case aware',
    );
  });

  test('a malformed handle is not sent to the server', () async {
    // There is no point asking about something the insert would reject
    // anyway, and every keystroke of "a" and "ab" would be a round trip.
    final repo = _FakeRepo();
    final subject = _subject(repo);

    subject.check('ab');
    subject.check('has spaces');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(subject.status, UsernameStatus.malformed);
    expect(repo.asked, isEmpty);
  });

  test('typing quickly asks once, about the last thing typed', () async {
    final repo = _FakeRepo();
    final subject = _subject(repo);

    for (final part in ['sar', 'sara', 'sarah', 'sarahj']) {
      subject.check(part);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(repo.asked, ['sarahj'], reason: 'the rest were still being typed');
  });

  test('a late answer about an old name is discarded', () async {
    // The reply for "slowname" lands after the user has moved on. Showing it
    // would label the new handle with a verdict about the old one.
    final repo = _FakeRepo(
      taken: {'slowname'},
      delay: const Duration(milliseconds: 400),
    );
    final subject = _subject(repo);

    subject.check('slowname');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    subject.check('newname');
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(subject.describes, 'newname');
    expect(subject.status, UsernameStatus.free);
  });

  test('a failed lookup is not reported as taken', () async {
    // Telling somebody a name is gone when the network merely blinked is the
    // one wrong answer this can give, because they will pick another name
    // they did not want.
    final repo = _FakeRepo(fail: true);
    final subject = _subject(repo);

    subject.check('goodname');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(subject.status, UsernameStatus.unknown);
    expect(subject.status, isNot(UsernameStatus.taken));
  });
}
