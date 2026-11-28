// Today's "Checking photos" row, fed by the real watcher and the real
// photo pipeline (2026-11-28).
//
// The incident: the owner opened the app at 22:24 with a day's photos
// unchecked. The catch-up worked through them one at a time, Today showed
// "0 kcal" and nothing else, a photo the busy server refused was dropped
// until the next scan without a word, and the owner left after 40 s. These
// run that scan on fakes of the library, the ledger and the model
// (test/support/photo_scan_rig.dart) and pin what the row is told: when it
// comes up, what it counts, what stays behind as not checked yet, and that
// a scan with nothing to check, or a photo that is simply not food, says
// nothing.
import 'dart:async';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/scan_status.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/photo_scan_rig.dart';
import '../ui/fakes.dart' show FakeDao;
import 'watcher_test.dart' show FakeAsset, FakePhotoLibrary;

void main() {
  group('a catch-up over a day\'s backlog', () {
    test('the row comes up with the first photo sent, counts each one as '
        'it finishes, and goes when nothing is left; a photo that is not '
        'food is one checked', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.photo('breakfast', 1, yesterdayAt(8)),
        rig.photo('chat', 2, yesterdayAt(10)),
        rig.photo('lunch', 3, yesterdayAt(12)),
      ];
      rig.analyzer.script[1] = (_) => foodReply('Oatmeal', 300);
      rig.analyzer.script[3] = (_) => foodReply('Noodles', 650);
      await rig.catchUp();

      expect(rig.row,
          ['checking 1/3', 'checking 2/3', 'checking 3/3', 'idle']);
      expect(rig.status.checkedCount, 3);
      expect(rig.status.waitingCount, 0,
          reason: 'not food is a verdict, not a photo waiting');
      expect(rig.dao.meals.map((m) => m.analysis['meal_description']),
          ['Oatmeal', 'Noodles']);
    });

    test('photos logged before are not counted, and a scan that finds '
        'nothing unchecked shows nothing at all', () async {
      // An earlier session logged yesterday's lunch and found the
      // screenshot not food; its catch-up moved the watermark over both.
      final dao = FakeLedger()
        ..loggedMeal('lunch', 'hash-3')
        ..ledger['hash-2'] = IngestionStatus.skipped;
      final rig = PhotoScanRig(dao: dao, checkedThrough: () => yesterdayAt(12));
      rig.library.assets = [
        rig.photo('chat', 2, yesterdayAt(10)),
        rig.photo('lunch', 3, yesterdayAt(12)),
      ];
      await rig.catchUp();
      expect(rig.offered, containsAll(['chat', 'lunch']),
          reason: 'the scan reads the window, as before');
      expect(rig.analyzer.sent, isEmpty);
      expect(rig.row, isEmpty, reason: 'the row never came up');

      // The same when no watermark is stored: the estimate then lists the
      // screenshot (no meal names it), and the ledger answers for it.
      final unmarked = PhotoScanRig(
          dao: FakeLedger()
            ..loggedMeal('lunch', 'hash-3')
            ..ledger['hash-2'] = IngestionStatus.skipped);
      unmarked.library.assets = [
        unmarked.photo('chat', 2, yesterdayAt(10)),
        unmarked.photo('lunch', 3, yesterdayAt(12)),
      ];
      await unmarked.catchUp();
      expect(unmarked.analyzer.sent, isEmpty);
      expect(unmarked.row, isEmpty);
    });

    test('the count is of the photos taken since the last one known '
        'checked: the earlier ones are read, and not counted', () async {
      final dao = FakeLedger()
        ..ledger['hash-1'] = IngestionStatus.skipped
        ..ledger['hash-2'] = IngestionStatus.skipped;
      final rig = PhotoScanRig(
          dao: dao, checkedThrough: () => twoDaysAgoAt(20));
      rig.library.assets = [
        rig.photo('old1', 1, twoDaysAgoAt(9)),
        rig.photo('old2', 2, twoDaysAgoAt(20)),
        rig.photo('new1', 3, yesterdayAt(12)),
        rig.photo('new2', 4, yesterdayAt(13)),
      ];
      await rig.catchUp();
      expect(rig.row, ['checking 1/2', 'checking 2/2', 'idle']);
      expect(rig.analyzer.sent, [3, 4]);
    });
  });

  group('what the count leaves out', () {
    test('a photo a meal already names, though it was taken after one still '
        'unchecked and no watermark covers either', () async {
      // The user picked the 13:00 photo by hand; the 12:00 one was never
      // checked.
      final rig = PhotoScanRig(dao: FakeLedger()..loggedMeal('picked', 'hash-2'));
      rig.library.assets = [
        rig.photo('unchecked', 1, yesterdayAt(12)),
        rig.photo('picked', 2, yesterdayAt(13)),
      ];
      await rig.catchUp();
      expect(rig.row, ['checking 1/1', 'idle']);
      expect(rig.analyzer.sent, [1]);
    });

    test('a photo that cannot be read now: the scan passes it, the count '
        'drops it, and it is not "not checked yet" (no send failed)',
        () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.photo('a', 1, yesterdayAt(8)),
        FakeAsset('unreadable', 'IMG_x.HEIC', yesterdayAt(9), null),
        rig.photo('c', 3, yesterdayAt(10)),
      ];
      await rig.catchUp();
      expect(rig.row,
          ['checking 1/3', 'checking 2/3', 'checking 2/2', 'idle']);
      expect(rig.status.waitingCount, 0);
      expect(rig.status.checkedCount, 2);
    });

    test('that photo also when it is the last one the catch-up reaches: '
        'the row does not hold "2 of 2" for it until the catch-up is over',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.photo('a', 1, yesterdayAt(8)),
        FakeAsset('unreadable', 'IMG_x.HEIC', yesterdayAt(9), null),
      ];
      await foregroundCatchUp(rig.intake, loadPrefs: () async => prefs);
      expect(rig.row,
          ['checking 1/2', 'checking 2/2', 'checking 1/1', 'idle']);
      expect(rig.status.checkedCount, 1);
    });
  });

  group('the estimate of what looks unchecked', () {
    // It only words the row's count. Whatever it cannot find out, the scan
    // goes on, and the photos are counted as if nothing were known.
    test('survives a watermark that cannot be read and a meals lookup that '
        'fails', () async {
      final dao = FakeLedger()
        ..onLoggedAssetIds = (() => throw StateError('database is locked'));
      final rig = PhotoScanRig(
          dao: dao, checkedThrough: () => throw StateError('preferences'));
      rig.library.assets = [
        rig.photo('a', 1, yesterdayAt(8)),
        rig.photo('b', 2, yesterdayAt(9)),
      ];
      await rig.catchUp();
      expect(dao.onLoggedAssetIds, isNull, reason: 'the lookup was asked');
      expect(rig.row, ['checking 1/2', 'checking 2/2', 'idle']);
      expect(rig.analyzer.sent, [1, 2]);
    });
  });

  group('photos that could not be sent', () {
    test('a photo the busy server refused stays behind as not checked yet, '
        'with why; the next catch-up takes it up, and it is sent once more',
        () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.photo('breakfast', 1, yesterdayAt(8)),
        rig.photo('lunch', 2, yesterdayAt(12)),
      ];
      rig.analyzer.script[1] = (_) => foodReply('Oatmeal', 300);
      rig.analyzer.script[2] = (_) => serverBusyReply;
      await rig.catchUp();
      expect(rig.row, [
        'checking 1/2',
        'checking 2/2',
        'waiting 1 serverBusy',
      ]);
      expect(rig.dao.meals, hasLength(1));
      expect(rig.dao.ledger.containsKey('hash-2'), isFalse,
          reason: 'released, so a later scan may send it again');

      // Retry: the same catch-up again, and the server has time now.
      rig.row.clear();
      rig.rowAtRead.clear();
      rig.analyzer.script[2] = (_) => foodReply('Noodles', 650);
      await rig.catchUp();
      expect(rig.row, ['checking 1/1', 'idle']);
      expect(rig.rowAtRead, ['checking 1/1'],
          reason: 'known unchecked: the row says checking before the '
              'photo is even read, not "not checked yet" with a Retry');
      expect(rig.analyzer.sent, [1, 2, 2]);
      expect(rig.dao.meals, hasLength(2));
      expect(rig.status.waitingCount, 0);
    });

    test('a waiting photo deleted from the library meanwhile is forgotten '
        'by the next catch-up', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [rig.photo('lunch', 2, yesterdayAt(12))];
      rig.analyzer.script[2] = (_) => unreachableReply;
      await rig.catchUp();
      expect(rig.row.last, 'waiting 1 network');
      rig.library.assets = [];
      await rig.catchUp();
      expect(rig.row.last, 'idle');
      expect(rig.analyzer.sent, [2]);
    });

    // "Forgotten" is for a scan that would have listed the photo. Those
    // that would not cannot say it is gone.
    test('a listing that hit the library\'s cap forgets no waiting photo: it '
        'hides the window\'s oldest ones', () async {
      final library = ScriptedLibrary();
      final rig = PhotoScanRig(library: library);
      library.assets = [rig.photo('lunch', 2, yesterdayAt(12))];
      rig.analyzer.script[2] = (_) => unreachableReply;
      await rig.catchUp();
      expect(shownOf(rig.status), 'waiting 1 network');
      // So many newer images since that the listing is full before it
      // reaches the photo.
      library
        ..assets = []
        ..capped = true;
      await expectLater(
          rig.catchUp(), throwsA(isA<BackfillWindowTruncated>()));
      expect(shownOf(rig.status), 'waiting 1 network');
    });

    test('nor does a scan of less than the whole window: one that starts '
        'from a watermark, or is asked for fewer days', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [rig.photo('lunch', 2, twoDaysAgoAt(12))];
      rig.analyzer.script[2] = (_) => unreachableReply;
      await rig.catchUp();
      expect(shownOf(rig.status), 'waiting 1 network');
      // Both list from later than the photo.
      await rig.intake.backfillScan(since: yesterdayAt(0));
      expect(shownOf(rig.status), 'waiting 1 network');
      await rig.intake.backfillScan(lookbackDays: 1);
      expect(shownOf(rig.status), 'waiting 1 network');
      expect(rig.analyzer.sent, [2], reason: 'neither one listed it');
    });

    test('a waiting photo taken before the last one known checked (imported '
        'late, or one the background run\'s mark passed over) is taken up '
        'by the next catch-up straight away all the same', () async {
      // Everything up to last night is known checked. This photo is older,
      // and this session let it go.
      final rig = PhotoScanRig(checkedThrough: () => yesterdayAt(23));
      rig.library.assets = [rig.photo('late', 2, twoDaysAgoAt(19))];
      rig.analyzer.script[2] = (_) => unreachableReply;
      await rig.catchUp();
      expect(shownOf(rig.status), 'waiting 1 network');

      rig.row.clear();
      rig.rowAtRead.clear();
      rig.analyzer.script.remove(2);
      await rig.catchUp();
      expect(rig.rowAtRead, ['checking 1/1'],
          reason: 'its date says checked, this session knows better: the '
              'row does not go away and come back as the photo is read');
      expect(rig.row, ['checking 1/1', 'idle']);
    });

    test('an unreachable server: every photo waits, and the reason is the '
        'network one', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.photo('a', 1, yesterdayAt(8)),
        rig.photo('b', 2, yesterdayAt(9)),
        rig.photo('c', 3, yesterdayAt(10)),
      ];
      for (final n in [1, 2, 3]) {
        rig.analyzer.script[n] = (_) => unreachableReply;
      }
      await rig.catchUp();
      expect(rig.row.last, 'waiting 3 network');
      expect(rig.status.checkedCount, 0);
      expect(rig.dao.meals, isEmpty);
    });

    test('a photo another run of the app is still analyzing waits too, '
        'with no reason to give', () async {
      // The background run reserved it and has not answered yet.
      final dao = FakeLedger()..ledger['hash-1'] = IngestionStatus.processing;
      final rig = PhotoScanRig(dao: dao);
      rig.library.assets = [rig.photo('lunch', 1, yesterdayAt(12))];
      await rig.catchUp();
      expect(rig.analyzer.sent, isEmpty);
      expect(rig.row, ['waiting 1']);
      expect(rig.status.waitingKind, isNull);
    });

    test('a pause every photo shares is not a photo waiting: the scan does '
        'not run then, a Retry could do nothing, and Settings says why',
        () async {
      final rig = PhotoScanRig();
      rig.library.assets = [rig.photo('a', 1, yesterdayAt(8))];
      rig.analyzer.script[1] = (_) => const AnalysisOutcome(
          error: 'Analysis paused (quota) — retrying later.',
          retryable: true,
          wall: Duration.zero);
      await rig.catchUp();
      expect(rig.outcomes.single.$2.errorKind, AnalysisErrorKind.quotaPaused);
      expect(rig.status.phase, PhotoScanPhase.idle);
      expect(rig.status.waitingCount, 0);
    });

    test('a waiting photo the user then picks by hand waits no longer',
        () async {
      final rig = PhotoScanRig();
      final lunch = rig.photo('lunch', 2, yesterdayAt(12));
      rig.library.assets = [lunch];
      rig.analyzer.script[2] = (_) => unreachableReply;
      await rig.catchUp();
      expect(rig.row.last, 'waiting 1 network');

      // Log › From recent photos: a deliberate add of the same photo.
      rig.analyzer.script[2] = (_) => foodReply('Noodles', 650);
      final picked = await rig.pipeline.enqueue(IntakePhoto(
          lunch.bytes!, 'lunch', lunch.name,
          capturedAt: lunch.createDateTime, deliberate: true));
      expect(picked.kind, PhotoOutcomeKind.saved);
      expect(rig.row.last, 'idle');
    });
  });

  group('a visit that ends mid-scan', () {
    test('photos the scan did not reach are neither checked nor waiting, '
        'and the next visit\'s scan counts them', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        for (var n = 1; n <= 4; n++) rig.photo('p$n', n, yesterdayAt(8 + n)),
      ];
      var open = true;
      rig.analyzer.onSend = (n) async {
        if (n == 2) open = false; // the user leaves during the second photo
      };
      await rig.catchUp(shouldContinue: () => open);
      expect(rig.analyzer.sent, [1, 2]);
      // The two it leaves unread drop out of the count as it passes them,
      // in the same turn: the row goes.
      expect(rig.row, [
        'checking 1/4',
        'checking 2/4',
        'checking 3/4',
        'checking 3/3',
        'idle',
      ]);
      expect(rig.status.waitingCount, 0);
      expect(rig.status.checkedCount, 2);

      rig.row.clear();
      open = true;
      await rig.catchUp(shouldContinue: () => open);
      expect(rig.analyzer.sent, [1, 2, 3, 4], reason: 'each photo once');
      expect(rig.row, ['checking 1/2', 'checking 2/2', 'idle']);
    });
  });

  group('the live watcher', () {
    test('a photo that arrives while the app is open is counted like one '
        'of a catch-up', () async {
      final now = DateTime.now();
      final rig = PhotoScanRig(clock: () => now);
      await rig.intake.start();
      rig.library.assets = [
        rig.photo('new', 1, now.add(const Duration(seconds: 5))),
      ];
      rig.analyzer.script[1] = (_) => foodReply('Noodles', 650);
      rig.library.changeListener!();
      await _until(() => rig.row.isNotEmpty && rig.row.last == 'idle');
      expect(rig.row, ['checking 1/1', 'idle']);
      expect(rig.dao.meals, hasLength(1));
    });

    test('two photos that arrive together are counted together', () async {
      final now = DateTime.now();
      final rig = PhotoScanRig(clock: () => now);
      await rig.intake.start();
      rig.library.assets = [
        rig.photo('new1', 1, now.add(const Duration(seconds: 5))),
        rig.photo('new2', 2, now.add(const Duration(seconds: 9))),
      ];
      rig.library.changeListener!();
      await _until(() => rig.row.isNotEmpty && rig.row.last == 'idle');
      expect(rig.row, ['checking 1/2', 'checking 2/2', 'idle']);
    });

    test('each of its scans is a round of its own: a photo that arrives '
        'later is counted from one again', () async {
      final now = DateTime.now();
      final rig = PhotoScanRig(clock: () => now);
      await rig.intake.start();
      final first = rig.photo('new1', 1, now.add(const Duration(seconds: 5)));
      rig.library.assets = [first];
      rig.library.changeListener!();
      await _until(() => rig.row.isNotEmpty && rig.row.last == 'idle');
      expect(rig.row, ['checking 1/1', 'idle']);

      rig.row.clear();
      rig.library.assets = [
        first,
        rig.photo('new2', 2, now.add(const Duration(seconds: 9))),
      ];
      rig.library.changeListener!();
      await _until(() => rig.row.isNotEmpty && rig.row.last == 'idle');
      expect(rig.row, ['checking 1/1', 'idle'],
          reason: 'not "2 of 2": the first scan\'s round is over');
      expect(rig.status.checkedCount, 1,
          reason: 'what "1 photo checked." counts');
    });

    test('a photo it let go that another run of the app has logged since '
        'waits no longer once its next scan meets it', () async {
      final now = DateTime.now();
      final dao = FakeLedger();
      final rig = PhotoScanRig(clock: () => now, dao: dao);
      await rig.intake.start();
      rig.library.assets = [
        rig.photo('new', 1, now.add(const Duration(seconds: 5))),
      ];
      rig.analyzer.script[1] = (_) => unreachableReply;
      rig.library.changeListener!();
      await _until(() => rig.row.isNotEmpty && rig.row.last != 'checking 1/1');
      expect(rig.row, ['checking 1/1', 'waiting 1 network']);

      // The background run got through to the server, and logged it.
      dao.loggedMeal('new', 'hash-1');
      rig.library.changeListener!();
      await _until(() => rig.row.last == 'idle');
      expect(rig.analyzer.sent, [1], reason: 'found logged, not sent again');
      expect(rig.status.waitingCount, 0);
    });

    // Before 2026-11-28 each pass of a catch-up took its own "still on"
    // mark as it began: a switch-off during the newest day's pass ended
    // that pass, and the window pass, begun after it, sent the rest.
    test('switching Watch Camera Roll off during the newest day\'s pass ends '
        'the whole catch-up: the window pass sends nothing more', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.photo('old-photo', 1, twoDaysAgoAt(9)),
        rig.photo('photo-10', 2, yesterdayAt(10)),
        rig.photo('lunch-12', 3, yesterdayAt(12)),
      ];
      await rig.intake.start();
      rig.analyzer.onSend = (n) async {
        if (n == 2) await rig.intake.stop();
      };
      await rig.catchUp();
      expect(rig.offered, ['photo-10'],
          reason: 'nothing more is read or sent once the user switched it '
              'off');
      expect(rig.reads, ['photo-10']);
      expect(rig.row.last, 'idle');
    });

    test('switching Watch Camera Roll off clears the row', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [rig.photo('a', 1, yesterdayAt(8))];
      rig.analyzer.script[1] = (_) => unreachableReply;
      await rig.intake.start();
      await rig.catchUp();
      expect(rig.row.last, 'waiting 1 network');
      await rig.intake.stop();
      expect(rig.row.last, 'idle');
    });
  });

  group('switching Watch Camera Roll off before a scan\'s first read', () {
    // A scan waits twice before it reads a photo: for the library's
    // listing, and (for the row) for the meals' answer to what looks
    // unchecked. The live scan used to take its "still on" mark only as
    // the reads began, so a switch-off during either wait sent the photo
    // all the same, and raised "Checking 1 photo" with the watcher off.
    test('while a live scan works out what looks unchecked: nothing is '
        'read or sent, and no row comes up', () async {
      final now = DateTime.now();
      final dao = FakeLedger();
      final rig = PhotoScanRig(clock: () => now, dao: dao);
      await rig.intake.start();
      rig.library.assets = [
        rig.photo('new', 1, now.add(const Duration(seconds: 5))),
      ];
      rig.analyzer.script[1] = (_) => foodReply('Noodles', 650);
      dao.onLoggedAssetIds = rig.intake.stop;
      rig.library.changeListener!();
      await pumpEventQueue();
      expect(dao.onLoggedAssetIds, isNull, reason: 'the scan got that far');
      expect(rig.reads, isEmpty);
      expect(rig.analyzer.sent, isEmpty);
      expect(rig.row, isEmpty);
      expect(rig.dao.meals, isEmpty);
    });

    test('while a live scan lists the library: the same', () async {
      final now = DateTime.now();
      final library = ScriptedLibrary();
      final rig = PhotoScanRig(clock: () => now, library: library);
      await rig.intake.start();
      library.assets = [
        rig.photo('new', 1, now.add(const Duration(seconds: 5))),
      ];
      library.onListed = rig.intake.stop;
      library.changeListener!();
      await pumpEventQueue();
      expect(library.onListed, isNull, reason: 'the scan got that far');
      expect(rig.reads, isEmpty);
      expect(rig.analyzer.sent, isEmpty);
      expect(rig.row, isEmpty);
    });

    test('while a catch-up lists the library: the same', () async {
      final library = ScriptedLibrary();
      final rig = PhotoScanRig(library: library);
      await rig.intake.start();
      library.assets = [rig.photo('lunch', 1, yesterdayAt(12))];
      library.onListed = rig.intake.stop;
      await rig.catchUp();
      expect(library.onListed, isNull, reason: 'the scan got that far');
      expect(rig.reads, isEmpty);
      expect(rig.analyzer.sent, isEmpty);
      expect(rig.row, isEmpty);
    });

    // stop() clears the row, and the photo in flight then ends unreported
    // (scan_status_test: reset). A scan the switch had reached before its
    // first read used to open its round on the row all the same, after
    // the reset, and so undid it: the photo in flight came back as "1
    // photo is not checked yet", with a Retry that does nothing while the
    // watcher is off.
    test('such a live scan opens no round on the row: the photo a catch-up '
        'still has in flight ends unreported', () async {
      final now = DateTime.now();
      final dao = FakeLedger();
      final rig = PhotoScanRig(clock: () => now, dao: dao);
      await rig.intake.start();
      final lunch = rig.photo('lunch', 2, yesterdayAt(12));
      rig.library.assets = [lunch];
      rig.analyzer.script[2] = (_) => unreachableReply;
      final answer = Completer<void>();
      rig.analyzer.onSend = (_) => answer.future;
      final catchUp = rig.catchUp();
      await _until(() => rig.analyzer.sent.isNotEmpty);
      expect(rig.row, ['checking 1/1']);

      // A photo arrives, and the switch goes off while its scan works out
      // what looks unchecked.
      rig.library.assets = [
        lunch,
        rig.photo('new', 1, now.add(const Duration(seconds: 5))),
      ];
      dao.onLoggedAssetIds = rig.intake.stop;
      rig.library.changeListener!();
      await pumpEventQueue();
      expect(dao.onLoggedAssetIds, isNull, reason: 'the scan got that far');
      expect(shownOf(rig.status), 'idle');

      // The server could not be reached for the photo in flight.
      answer.complete();
      await catchUp;
      await pumpEventQueue();
      expect(shownOf(rig.status), 'idle');
      expect(rig.status.waitingCount, 0);
      expect(rig.analyzer.sent, [2], reason: 'the new photo was not sent');
    });

    test('nor does such a catch-up: the photo the live watcher still has '
        'in flight ends unreported', () async {
      final now = DateTime.now();
      final dao = FakeLedger();
      final rig = PhotoScanRig(clock: () => now, dao: dao);
      await rig.intake.start();
      final fresh = rig.photo('new', 1, now.add(const Duration(seconds: 5)));
      rig.library.assets = [fresh];
      rig.analyzer.script[1] = (_) => unreachableReply;
      final answer = Completer<void>();
      rig.analyzer.onSend = (_) => answer.future;
      rig.library.changeListener!();
      await _until(() => rig.analyzer.sent.isNotEmpty);
      expect(rig.row, ['checking 1/1']);

      // A catch-up starts, and the switch goes off while it works out
      // what looks unchecked.
      rig.library.assets = [rig.photo('lunch', 2, yesterdayAt(12)), fresh];
      dao.onLoggedAssetIds = rig.intake.stop;
      await rig.catchUp();
      expect(dao.onLoggedAssetIds, isNull, reason: 'the scan got that far');
      expect(shownOf(rig.status), 'idle');

      answer.complete();
      await pumpEventQueue();
      expect(shownOf(rig.status), 'idle');
      expect(rig.status.waitingCount, 0);
      expect(rig.reads, ['new'], reason: 'the catch-up read nothing');
      expect(rig.analyzer.sent, [1]);
    });
  });

  // With no photo access at launch the live watcher does not start. Once
  // access is granted (Android does not restart the app for that) the
  // catch-ups scan all the same, and the row reports them. stop() used to
  // return at once then: the row kept "1 photo is not checked yet" with a
  // Retry that did nothing, and a catch-up in progress sent the rest of
  // its window.
  group('switching Watch Camera Roll off when the live watcher never '
      'started', () {
    test('clears the row', () async {
      final rig = PhotoScanRig();
      rig.library.permissionGranted = false;
      await rig.intake.start(); // refused: no live watcher
      expect(rig.library.changeListener, isNull);
      rig.library.assets = [rig.photo('lunch', 1, yesterdayAt(12))];
      rig.analyzer.script[1] = (_) => unreachableReply;
      await rig.catchUp();
      expect(shownOf(rig.status), 'waiting 1 network');
      await rig.intake.stop();
      expect(shownOf(rig.status), 'idle');
      expect(rig.status.waitingCount, 0);
    });

    test('ends a catch-up in progress: nothing more is read or sent',
        () async {
      final rig = PhotoScanRig();
      rig.library.permissionGranted = false;
      await rig.intake.start(); // refused: no live watcher
      rig.library.assets = [
        rig.photo('breakfast', 1, yesterdayAt(8)),
        rig.photo('lunch', 2, yesterdayAt(12)),
      ];
      rig.analyzer.onSend = (n) async {
        if (n == 1) await rig.intake.stop();
      };
      await rig.catchUp();
      expect(rig.reads, ['breakfast']);
      expect(rig.analyzer.sent, [1]);
      expect(shownOf(rig.status), 'idle');
    });
  });

  group('photos imported late (the change history)', () {
    late Directory root;
    setUp(() =>
        root = Directory.systemTemp.createTempSync('scan_status_late'));
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('the late-import pass counts its photos too', () async {
      final history = FakePhotoChangeSource();
      final rig = PhotoScanRig(
          lookbackDays: 7,
          lateImports: LateImportCursor(
              source: history,
              store: LocalNoBackupStore(
                  root: () async => root, createMissingDirectory: true)));
      await rig.intake.lateImportScan(); // the cursor starts from here
      // Glasses photos taken two days ago, imported just now: no scan by
      // date lists them behind the watermark, the history does.
      final g1 = rig.photo('g1', 1, twoDaysAgoAt(19));
      final g2 = rig.photo('g2', 2, twoDaysAgoAt(19, 5));
      rig.library.assets = [g1, g2];
      var reported = false;
      history.onInsertedImagesSince = (token, _, _, _) {
        final first = !reported;
        reported = true;
        return InsertedImages(PhotoChangeStatus.ok,
            token: first ? history.nextToken() : token,
            deviceTag: history.deviceTag,
            ids: [
              if (first) ...[
                InsertedImage('g1', created: g1.createDateTime),
                InsertedImage('g2', created: g2.createDateTime),
              ],
            ]);
      };
      rig.analyzer.script[1] = (_) => foodReply('Dumplings', 500);
      await rig.intake.lateImportScan();
      expect(rig.row, ['checking 1/2', 'checking 2/2', 'idle']);
      expect(rig.analyzer.sent, [1, 2]);
    });

    test('a late-import pass counts its photos though every one lies '
        'behind the last photo known checked, and is a round of its own',
        () async {
      final history = FakePhotoChangeSource();
      // Everything up to last night is known checked.
      final rig = PhotoScanRig(
          lookbackDays: 7,
          checkedThrough: () => yesterdayAt(23),
          lateImports: LateImportCursor(
              source: history,
              store: LocalNoBackupStore(
                  root: () async => root, createMissingDirectory: true)));
      await rig.intake.lateImportScan(); // the cursor starts from here
      final g1 = rig.photo('g1', 1, twoDaysAgoAt(19));
      final g2 = rig.photo('g2', 2, twoDaysAgoAt(19, 5));
      final g3 = rig.photo('g3', 3, twoDaysAgoAt(20));
      // What the history reports next, once.
      var imported = <FakeAsset>[g1, g2];
      history.onInsertedImagesSince = (token, _, _, _) {
        final batch = imported;
        imported = [];
        return InsertedImages(PhotoChangeStatus.ok,
            token: batch.isEmpty ? token : history.nextToken(),
            deviceTag: history.deviceTag,
            ids: [
              for (final a in batch)
                InsertedImage(a.id, created: a.createDateTime),
            ]);
      };
      rig.library.assets = [g1, g2];
      await rig.intake.lateImportScan();
      expect(rig.row, ['checking 1/2', 'checking 2/2', 'idle'],
          reason: 'both are counted from the start: their dates, behind '
              'the mark, say nothing about a photo imported late');

      // One more arrives later: a new round, counted from one.
      rig.row.clear();
      rig.library.assets = [g1, g2, g3];
      imported = [g3];
      await rig.intake.lateImportScan();
      expect(rig.row, ['checking 1/1', 'idle'],
          reason: 'not "3 of 3": the first pass\'s round is over');
      expect(rig.status.checkedCount, 1);
    });

    test('the app\'s catch-up is one round: the row comes with the first '
        'photo and stays, through the late-import pass, until the catch-up '
        'is over', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final history = FakePhotoChangeSource();
      final rig = PhotoScanRig(
          lookbackDays: 7,
          lateImports: LateImportCursor(
              source: history,
              store: LocalNoBackupStore(
                  root: () async => root, createMissingDirectory: true)));
      await rig.intake.lateImportScan(); // the cursor starts from here
      // An earlier catch-up covered everything up to yesterday morning.
      await prefs.setString(backgroundWatermarkPrefsKey,
          yesterdayAt(9).toUtc().toIso8601String());
      final lunch = rig.photo('lunch', 1, yesterdayAt(12));
      final glasses = rig.photo('glasses', 2, twoDaysAgoAt(19));
      rig.library.assets = [lunch];
      rig.analyzer.script[1] = (_) => foodReply('Noodles', 650);
      rig.analyzer.script[2] = (_) => foodReply('Dumplings', 500);
      // The Meta AI app imports the glasses photo while the lunch photo is
      // being checked: only the history lists it.
      rig.analyzer.onSend = (n) async {
        if (n == 1) rig.library.assets = [lunch, glasses];
      };
      var reported = false;
      history.onInsertedImagesSince = (token, _, _, _) {
        final first = !reported && rig.library.assets.length == 2;
        if (first) reported = true;
        return InsertedImages(PhotoChangeStatus.ok,
            token: first ? history.nextToken() : token,
            deviceTag: history.deviceTag,
            ids: [
              if (first)
                InsertedImage('glasses', created: glasses.createDateTime),
            ]);
      };

      await foregroundCatchUp(rig.intake, loadPrefs: () async => prefs);
      expect(rig.analyzer.sent, [1, 2]);
      expect(rig.row, ['checking 1/1', 'checking 2/2', 'idle'],
          reason: 'it did not go away after the lunch photo and come back '
              'for the glasses photo');
      expect(rig.status.checkedCount, 2);
    });

    // The round is held until the catch-up ends. Left open (the caller's
    // shouldContinue threw as the catch-up asked whether to go on to the
    // late imports), it held the row on "1 of 1" for the rest of the
    // session, and every later scan counted on from there.
    test('the catch-up\'s round ends however the catch-up ends', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final rig = PhotoScanRig();
      rig.library.assets = [rig.photo('lunch', 1, yesterdayAt(12))];
      var asked = 0;
      await expectLater(
          foregroundCatchUp(rig.intake,
              loadPrefs: () async => prefs,
              // Yes before the photo is read; then it fails.
              shouldContinue: () =>
                  ++asked == 1 || (throw StateError('lifecycle probe'))),
          throwsStateError);
      expect(rig.analyzer.sent, [1]);
      expect(rig.row, ['checking 1/1', 'idle']);
    });
  });

  test('cachedBackgroundWatermark reads the stored mark as this engine '
      'holds it, and nothing when none is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(cachedBackgroundWatermark(prefs), isNull);
    final mark = yesterdayAt(12, 30);
    await prefs.setString(
        backgroundWatermarkPrefsKey, mark.toUtc().toIso8601String());
    expect(cachedBackgroundWatermark(prefs), mark);
    await prefs.setString(backgroundWatermarkPrefsKey, 'junk');
    expect(cachedBackgroundWatermark(prefs), isNull);
  });
}

/// A library that can be told its listing hit the query's cap, and that
/// runs a hook once, as it lists.
class ScriptedLibrary extends FakePhotoLibrary {
  /// The listing is full: there may be older images it does not show.
  bool capped = false;

  /// Awaited in the next listing, before it answers; then forgotten.
  Future<void> Function()? onListed;

  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(DateTime cutoff,
      {int limit = 500}) async {
    final listed = await super.imagesCreatedAfter(cutoff, limit: limit);
    final hook = onListed;
    onListed = null;
    await hook?.call();
    return capped ? LibraryListing(listed, listed: limit) : listed;
  }
}

/// The in-memory ledger with an earlier session's work in it.
class FakeLedger extends FakeDao {
  /// Awaited in the next loggedAssetIds, before it answers; then forgotten.
  Future<void> Function()? onLoggedAssetIds;

  @override
  Future<Set<String>> loggedAssetIds(List<String> assetIds) async {
    final hook = onLoggedAssetIds;
    onLoggedAssetIds = null;
    await hook?.call();
    return super.loggedAssetIds(assetIds);
  }

  /// A meal an earlier scan logged from the library photo [assetId].
  void loggedMeal(String assetId, String hash) {
    final at = yesterdayAt(12);
    final date = '${at.year.toString().padLeft(4, '0')}-'
        '${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
    seed(Meal(
      id: nextId++,
      date: date,
      time: '12:00 PM',
      timestamp: '${date}T12:00:00',
      source: MealSource.appWatch,
      imageHash: hash,
      fileId: assetId,
      analysis: const {
        'is_food': true,
        'meal_description': 'Lunch',
        'total_calories': 600,
      },
    ));
    ledger[hash] = IngestionStatus.saved;
  }
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'timed out');
}
