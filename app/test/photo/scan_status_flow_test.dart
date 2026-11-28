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
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:calorie_tracker/services/photo/scan_status.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/photo_scan_rig.dart';
import '../ui/fakes.dart' show FakeDao;
import 'watcher_test.dart' show FakeAsset;

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

/// The in-memory ledger with an earlier session's work in it.
class FakeLedger extends FakeDao {
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
