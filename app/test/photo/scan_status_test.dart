// What Today's "Checking photos" row is told (2026-11-28).
//
// On 2026-11-27 Today read "0 kcal" for a 40-second visit while the
// catch-up was working through a day's photos, and a photo the server
// refused three times was dropped until the next scan without a word.
// PhotoScanStatus is what the row shows: these pin when it appears, how it
// counts, what stays behind as "not checked yet", and that a scan with
// nothing to check shows nothing.
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/photo/scan_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the row would show, as one line.
String shown(PhotoScanStatus s) => switch (s.phase) {
      PhotoScanPhase.idle => 'idle',
      PhotoScanPhase.checking => 'checking ${s.current}/${s.total}',
      PhotoScanPhase.waiting => 'waiting ${s.waitingCount}'
          '${s.waitingKind == null ? '' : ' ${s.waitingKind!.name}'}',
    };

void main() {
  late PhotoScanStatus status;
  late List<String> heard;

  setUp(() {
    status = PhotoScanStatus();
    heard = [];
    status.addListener(() => heard.add(shown(status)));
  });

  test('nothing is shown before a scan, nor for a scan with nothing to check',
      () {
    expect(shown(status), 'idle');
    status.begin().end();
    expect(heard, isEmpty, reason: 'no listener is woken for nothing');
  });

  test('a scan that only walks photos checked before shows nothing: the '
      'estimate alone never brings the row up', () {
    // The watcher thought a and b unchecked; the ledger knew both.
    final scan = status.begin(expected: ['a', 'b']);
    expect(shown(status), 'idle');
    status.finished('a', ScanVerdict.none);
    status.passed('a');
    status.finished('b', ScanVerdict.none);
    status.passed('b');
    scan.end();
    expect(shown(status), 'idle');
    expect(heard, isEmpty, reason: 'the row never appeared');
  });

  test('the row appears when the first unchecked photo is sent, counts as '
      'photos finish, and goes when the scan ends', () {
    final scan = status.begin(expected: ['a', 'b', 'c']);
    status.checking('a');
    expect(shown(status), 'checking 1/3');
    status.finished('a', ScanVerdict.checked);
    expect(shown(status), 'checking 2/3',
        reason: 'the next one is on its way while its bytes are read');
    status.passed('a');
    status.checking('b');
    expect(shown(status), 'checking 2/3');
    // Not food is a photo checked, like a meal.
    status.finished('b', ScanVerdict.checked);
    status.checking('c');
    expect(shown(status), 'checking 3/3');
    status.finished('c', ScanVerdict.checked);
    expect(shown(status), 'idle',
        reason: 'nothing left to check, though the scan still walks the '
            'older photos of the window');
    expect(status.checkedCount, 3);
    scan.end();
    expect(shown(status), 'idle');
    expect(status.checkedCount, 3,
        reason: 'what the row says for a moment after the scan');
  });

  test('a photo the estimate counted for nothing leaves the total, and one '
      'it missed joins it', () {
    final scan = status.begin(expected: ['a', 'b', 'c']);
    status.checking('a');
    expect(shown(status), 'checking 1/3');
    // b was logged in an earlier session: the ledger says so.
    status.finished('a', ScanVerdict.checked);
    status.finished('b', ScanVerdict.none);
    expect(shown(status), 'checking 2/2');
    // z lies behind the watermark and has no verdict all the same.
    status.checking('z');
    expect(shown(status), 'checking 2/3');
    status.finished('z', ScanVerdict.checked);
    // c could not be read: the scan passes it.
    status.passed('c');
    expect(shown(status), 'idle');
    scan.end();
  });

  test('a photo let go because it could not be sent stays behind as not '
      'checked yet, with why', () {
    final scan = status.begin(expected: ['a', 'b']);
    status.checking('a');
    status.finished('a', ScanVerdict.waiting,
        kind: AnalysisErrorKind.serverBusy);
    expect(shown(status), 'checking 2/2',
        reason: 'the scan goes on with the next photo');
    status.checking('b');
    status.finished('b', ScanVerdict.checked);
    expect(shown(status), 'waiting 1 serverBusy');
    expect(status.checkedCount, 1, reason: 'a is not among the checked');
    scan.end();
    expect(shown(status), 'waiting 1 serverBusy',
        reason: 'it stays after the scan: this is what used to be silent');
  });

  test('a photo another run holds waits without a reason; the newest '
      'reason is the one given', () {
    final scan = status.begin(expected: ['a', 'b', 'c']);
    status.finished('a', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    status.finished('b', ScanVerdict.waiting,
        kind: AnalysisErrorKind.serverBusy);
    status.finished('c', ScanVerdict.waiting);
    scan.end();
    expect(status.waitingCount, 3);
    expect(status.waitingKind, AnalysisErrorKind.serverBusy);

    final lone = PhotoScanStatus();
    lone.begin(expected: ['x']).end();
    lone.finished('x', ScanVerdict.waiting);
    expect(lone.phase, PhotoScanPhase.waiting);
    expect(lone.waitingKind, isNull);
  });

  test('the next scan of the whole window takes the waiting photos up '
      'again: straight to checking, and gone once they have a verdict', () {
    final first = status.begin(expected: ['a', 'b']);
    status.finished('a', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    status.finished('b', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    first.end();
    expect(shown(status), 'waiting 2 network');

    // Retry: the catch-up lists both again.
    final retry = status.begin(expected: ['a', 'b'], wholeWindow: true);
    expect(shown(status), 'checking 1/2',
        reason: 'known unchecked: the row does not wait for the first send');
    status.checking('a');
    status.finished('a', ScanVerdict.checked);
    status.checking('b');
    status.finished('b', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    retry.end();
    expect(shown(status), 'waiting 1 network');
  });

  test('a waiting photo the whole window no longer lists is forgotten '
      '(deleted, or out of the lookback window); a narrower scan forgets '
      'nothing', () {
    status.finished('gone', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    expect(shown(status), 'waiting 1 network');
    // A new photo arrives: the live watcher's scan lists only that one.
    final live = status.begin(expected: ['new']);
    expect(shown(status), 'waiting 1 network');
    status.checking('new');
    expect(shown(status), 'checking 1/1');
    status.finished('new', ScanVerdict.checked);
    live.end();
    expect(shown(status), 'waiting 1 network');

    status.begin(expected: const [], wholeWindow: true).end();
    expect(shown(status), 'idle');

    // Forgotten without a word: the scan that no longer lists it shows
    // nothing for the photos it only expects.
    status.finished('gone too', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    final later = status.begin(expected: ['x'], wholeWindow: true);
    expect(shown(status), 'idle');
    later.end();
  });

  test('a verdict from elsewhere settles a waiting photo (the user picked '
      'it in the add flow)', () {
    status.finished('a', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    status.finished('b', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    heard.clear();
    status.settled('a');
    expect(shown(status), 'waiting 1 network');
    status.settled('never-seen');
    expect(heard, ['waiting 1 network'], reason: 'one change, one notice');
    status.settled('b');
    expect(shown(status), 'idle');

    // One a running scan has not reached yet leaves its count.
    final scan = status.begin(expected: ['x', 'y', 'z']);
    status.checking('x');
    expect(shown(status), 'checking 1/3');
    status.settled('z');
    expect(shown(status), 'checking 1/2');
    scan.end();
  });

  test('a waiting photo whose next turn ends with nothing to count (found '
      'logged by another run of the app, held back by a pause) waits no '
      'longer', () {
    final first = status.begin(expected: ['a']);
    status.finished('a', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    first.end();
    expect(shown(status), 'waiting 1 network');
    // A scan of less than the window (the live watcher's) meets it again,
    // so nothing but the photo's own turn can settle it.
    final next = status.begin(expected: ['a']);
    expect(shown(status), 'waiting 1 network');
    status.finished('a', ScanVerdict.none);
    next.end();
    expect(shown(status), 'idle');
    expect(status.waitingCount, 0);
  });

  test('a photo whose turn ends without a send counts as the scan goes on: '
      'one decided on the phone brings the row up, and one another run '
      'holds is "not checked yet" only once the scan is over', () {
    final scan = status.begin(expected: ['a', 'b']);
    // Not food by the phone's own check: a verdict, and nothing sent.
    status.finished('a', ScanVerdict.checked);
    expect(shown(status), 'checking 2/2');
    scan.end();

    final other = PhotoScanStatus();
    final held = other.begin(expected: ['a', 'b']);
    // Another run of the app has it.
    other.finished('a', ScanVerdict.waiting);
    expect(shown(other), 'checking 2/2',
        reason: 'no Retry while the scan is still going');
    held.end();
    expect(shown(other), 'waiting 1');
  });

  test('the photo being checked stays so when another photo\'s turn ends',
      () {
    final scan = status.begin(expected: ['a', 'b']);
    status.checking('a');
    status.finished('b', ScanVerdict.none);
    expect(shown(status), 'checking 1/1');
    status.finished('a', ScanVerdict.checked);
    expect(shown(status), 'idle');
    scan.end();
  });

  test('a photo is counted once in a round, however many of its scans list '
      'it: the one being checked, and one let go that a later scan of the '
      'round lists and sends again', () {
    final catchUp = status.begin(expected: ['a', 'p']);
    status.checking('a');
    // The live watcher's scan lists a too, beside a new photo.
    final live = status.begin(expected: ['a', 'n']);
    expect(shown(status), 'checking 1/3', reason: 'a, p and n');
    status.finished('a', ScanVerdict.checked);
    status.checking('p');
    status.finished('p', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    expect(shown(status), 'checking 3/3', reason: 'n is left');
    // Let go, so unread: a third scan lists p again ...
    final again = status.begin(expected: ['p']);
    expect(shown(status), 'checking 3/3', reason: 'p is not counted twice');
    // ... and sends it.
    status.checking('p');
    expect(status.total, 3, reason: 'a done, p being checked, n to come');
    status.finished('p', ScanVerdict.checked);
    status.checking('n');
    status.finished('n', ScanVerdict.checked);
    catchUp.end();
    live.end();
    again.end();
    expect(shown(status), 'idle');
    expect(status.checkedCount, 3);
  });

  test('a second scan of the whole window that begins while the first is '
      'still running takes up what the first let go: to be checked again, '
      'not among the checked', () {
    final first = status.begin(expected: ['a', 'p'], wholeWindow: true);
    status.checking('a');
    status.finished('a', ScanVerdict.checked);
    status.checking('p');
    status.finished('p', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    expect(status.checkedCount, 1);
    // A return to the app starts another catch-up before this one is over.
    final second = status.begin(expected: ['p'], wholeWindow: true);
    expect(shown(status), 'checking 2/2');
    expect(status.checkedCount, 1);
    expect(status.waitingCount, 0);
    // The visit ends before p's turn: it is neither checked nor waiting.
    first.end();
    second.end();
    expect(shown(status), 'idle');
    expect(status.checkedCount, 1,
        reason: 'what "1 photo checked." says, not 2');
  });

  test('ending a scan twice ends it once: the other scans of the round go '
      'on', () {
    final one = status.begin(expected: ['x']);
    final other = status.begin(expected: ['y']);
    status.checking('x');
    status.finished('x', ScanVerdict.checked);
    expect(shown(status), 'checking 2/2');
    one.end();
    one.end();
    expect(shown(status), 'checking 2/2',
        reason: 'the other scan still has y to check');
    other.end();
    expect(shown(status), 'idle');
  });

  test('scans that overlap are one round: the row counts their photos '
      'together and goes when the last one ends', () {
    final catchUp = status.begin(expected: ['a', 'b']);
    status.checking('a');
    // A photo arrives meanwhile: the live watcher's scan.
    final live = status.begin(expected: ['c']);
    expect(shown(status), 'checking 1/3');
    status.finished('a', ScanVerdict.checked);
    status.checking('b');
    status.finished('b', ScanVerdict.checked);
    catchUp.end();
    expect(shown(status), 'checking 3/3',
        reason: 'the other scan still has c to check');
    status.checking('c');
    status.finished('c', ScanVerdict.checked);
    live.end();
    expect(shown(status), 'idle');
    expect(status.checkedCount, 3);

    // The next round starts its count afresh.
    final next = status.begin(expected: ['d']);
    status.checking('d');
    expect(shown(status), 'checking 1/1');
    status.finished('d', ScanVerdict.checked);
    next.end();
    expect(status.checkedCount, 1);
  });

  test('the catch-up holds the row until it ends: on its last count while '
      'the window scan walks older photos and the late-import pass reads '
      'the history, then on with the photos imported late', () {
    // foregroundCatchUp: one scan around both parts.
    final round = status.begin(untilEnd: true);
    final window = status.begin(expected: ['a'], wholeWindow: true);
    expect(shown(status), 'idle', reason: 'nothing found yet');
    status.checking('a');
    status.finished('a', ScanVerdict.checked);
    expect(shown(status), 'checking 1/1',
        reason: 'the last photo it expected is done, the catch-up is not');
    window.end();
    expect(shown(status), 'checking 1/1');
    // The late-import pass found two glasses photos.
    final late = status.begin(expected: ['g1', 'g2']);
    expect(shown(status), 'checking 2/3');
    status.checking('g1');
    status.finished('g1', ScanVerdict.checked);
    status.checking('g2');
    status.finished('g2', ScanVerdict.checked);
    late.end();
    expect(shown(status), 'checking 3/3');
    round.end();
    expect(shown(status), 'idle');
    expect(status.checkedCount, 3);
    expect(heard.where((h) => h == 'idle'), hasLength(1),
        reason: 'the row came once and went once: ${heard.join(', ')}');
  });

  test('without that hold the row goes after the last photo a scan '
      'expected (the live watcher, the switch\'s first sweep)', () {
    final scan = status.begin(expected: ['a'], wholeWindow: true);
    status.checking('a');
    status.finished('a', ScanVerdict.checked);
    expect(shown(status), 'idle');
    scan.end();
  });

  test('a catch-up that checks nothing shows nothing, however long it '
      'holds', () {
    final round = status.begin(untilEnd: true);
    final window = status.begin(expected: ['a'], wholeWindow: true);
    status.finished('a', ScanVerdict.none);
    window.end();
    expect(shown(status), 'idle');
    round.end();
    round.end(); // a second end does nothing
    expect(heard, isEmpty);
    final next = status.begin(expected: ['b']);
    status.checking('b');
    status.finished('b', ScanVerdict.checked);
    expect(shown(status), 'idle',
        reason: 'the double end left no hold behind');
    next.end();
  });

  test('nor does a catch-up whose photo was sent and ended with nothing '
      'to count (a pause every photo shares came on with it): not "1 of 0" '
      'until the catch-up is over', () {
    final round = status.begin(untilEnd: true);
    final window = status.begin(expected: ['a'], wholeWindow: true);
    status.checking('a');
    expect(shown(status), 'checking 1/1');
    status.finished('a', ScanVerdict.none);
    expect(shown(status), 'idle');
    window.end();
    expect(shown(status), 'idle');
    round.end();
    expect(status.checkedCount, 0);
  });

  test('reset forgets everything, and the photo still in flight then is '
      'not reported any more (Watch Camera Roll switched off)', () {
    final scan = status.begin(expected: ['a', 'b']);
    status.finished('a', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    status.checking('b');
    expect(shown(status), 'checking 2/2');
    status.reset();
    expect(shown(status), 'idle');
    // b's answer comes back as a failure after the switch.
    status.finished('b', ScanVerdict.waiting,
        kind: AnalysisErrorKind.network);
    scan.end();
    expect(shown(status), 'idle',
        reason: 'a Retry would do nothing with the watcher off');
    expect(status.waitingCount, 0);

    // Switched on again: the next scan reports as usual.
    final again = status.begin(expected: ['c']);
    status.checking('c');
    expect(shown(status), 'checking 1/1');
    again.end();
  });

  test('after a reset the scans still running say nothing more, and leave '
      'nothing behind for the next round', () {
    final scan = status.begin(expected: ['a', 'b', 'c', 'z']);
    status.checking('a');
    status.finished('a', ScanVerdict.checked);
    status.checking('b');
    expect(shown(status), 'checking 2/4');
    status.reset();
    expect(shown(status), 'idle');
    expect(status.checkedCount, 0,
        reason: 'no "1 photo checked." after a switch-off');
    // b's answer arrives. c had been read and looked up before the
    // switch, and its send starts after it.
    status.finished('b', ScanVerdict.checked);
    status.checking('c');
    expect(shown(status), 'idle');
    status.finished('c', ScanVerdict.checked);
    expect(shown(status), 'idle');

    // Switched on again before that scan is over: a new sweep begins.
    final again = status.begin(expected: ['d']);
    expect(shown(status), 'idle',
        reason: 'the estimate alone brings no row up');
    // d gets its verdict on the phone: nothing is sent for it.
    status.finished('d', ScanVerdict.checked);
    expect(shown(status), 'idle',
        reason: 'neither b, in flight at the switch, nor z, which the old '
            'scan never reached, is left to wait for');
    expect(status.checkedCount, 1);
    scan.end();
    again.end();
  });

  test('listeners hear a change of what is shown, and nothing else', () {
    final scan = status.begin(expected: ['a', 'b']);
    expect(heard, isEmpty, reason: 'nothing shown yet');
    status.checking('a');
    status.checking('a'); // told twice: one change
    status.passed('a'); // not expected any more: nothing moves
    expect(heard, ['checking 1/2']);
    status.finished('a', ScanVerdict.checked);
    status.finished('b', ScanVerdict.none);
    scan.end();
    expect(heard, ['checking 1/2', 'checking 2/2', 'idle']);
  });

  test('ids that name no photo are ignored', () {
    final scan = status.begin(expected: ['', 'a']);
    status.checking('');
    status.finished('', ScanVerdict.waiting);
    expect(shown(status), 'idle');
    status.checking('a');
    expect(shown(status), 'checking 1/1');
    scan.end();
  });
}
