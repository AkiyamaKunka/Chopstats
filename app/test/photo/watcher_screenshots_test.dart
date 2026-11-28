// The app's catch-up checks the newest day's other photos before its
// screenshots (2026-11-28).
//
// On 2026-11-27 a 40-second visit spent its model calls on the pictures
// taken before the lunch photo, oldest first and screenshots included, and
// ended before the lunch photo's turn. Each unchecked picture costs one
// model call (10 to 15 s on a Claude plan), so the order decides what a
// short visit reaches.
//
// What must still hold, and is pinned here on the real watcher, the real
// pipeline and the in-memory ledger (test/support/photo_scan_rig.dart):
//   - every image is checked exactly once, also when the visit ends
//     mid-scan and the next scan, or the next session, takes over;
//   - no watermark passes a screenshot that was not checked, however many
//     photos taken after it were;
//   - the leftover check still finds a meal photographed before its
//     leftovers.
// And what no longer holds, pinned too so that nobody finds it by
// surprise: a meal the scan logs from a screenshot is not there yet when
// leftovers photographed after it are checked in the same visit.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/photo_scan_rig.dart';
import '../ui/fakes.dart' show FakeDao;
import 'watcher_test.dart' show FakeAsset, bytesOf;

void main() {
  group('the order of a catch-up', () {
    test('the newest day\'s other photos go before its screenshots, each '
        'group in shooting order; older days keep strict shooting order',
        () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.screenshot('old-shot', 1, twoDaysAgoAt(8)),
        rig.photo('old-photo', 2, twoDaysAgoAt(9)),
        rig.screenshot('shot-9', 3, yesterdayAt(9)),
        rig.photo('photo-10', 4, yesterdayAt(10)),
        rig.screenshot('shot-11', 5, yesterdayAt(11)),
        rig.photo('lunch-12', 6, yesterdayAt(12)),
      ];
      await rig.catchUp();
      expect(rig.offered, [
        'photo-10',
        'lunch-12',
        'shot-9',
        'shot-11',
        'old-shot',
        'old-photo',
      ]);
      expect(rig.reads, rig.offered, reason: 'each original read once');
    });

    test('a short visit reaches the lunch photo: two model calls, not four',
        () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.screenshot('shot-9', 1, yesterdayAt(9)),
        rig.screenshot('shot-10', 2, yesterdayAt(10)),
        rig.photo('breakfast', 3, yesterdayAt(8)),
        rig.screenshot('shot-11', 4, yesterdayAt(11)),
        rig.photo('lunch', 5, yesterdayAt(12)),
      ];
      rig.analyzer.script[3] = (_) => foodReply('Oatmeal', 300);
      rig.analyzer.script[5] = (_) => foodReply('Noodles', 650);
      // The visit lasts two model calls.
      var calls = 0;
      rig.analyzer.onSend = (_) async => calls++;
      await rig.catchUp(shouldContinue: () => calls < 2);
      expect(rig.dao.meals.map((m) => m.analysis['meal_description']),
          ['Oatmeal', 'Noodles']);
      expect(rig.analyzer.sent, [3, 5]);
    });

    test('a library that marks no screenshots, a day of screenshots only, '
        'and a scan that is not the app\'s catch-up keep strict order',
        () async {
      // Nothing marked (a maker's folder Android cannot tell apart).
      final unmarked = PhotoScanRig();
      unmarked.library.assets = [
        for (final (id, n, h) in [('a', 1, 9), ('b', 2, 10), ('c', 3, 11)])
          FakeAsset(id, 'IMG_$id.jpg', yesterdayAt(h), bytesOf(n)),
      ];
      await unmarked.catchUp();
      expect(unmarked.offered, ['a', 'b', 'c']);

      final onlyShots = PhotoScanRig();
      onlyShots.library.assets = [
        onlyShots.screenshot('s1', 1, yesterdayAt(9)),
        onlyShots.screenshot('s2', 2, yesterdayAt(10)),
      ];
      await onlyShots.catchUp();
      expect(onlyShots.offered, ['s1', 's2']);

      // The background run (and the switch's first sweep) never ask for
      // the newest day first.
      final strict = PhotoScanRig();
      strict.library.assets = [
        strict.screenshot('shot-9', 1, yesterdayAt(9)),
        strict.photo('photo-10', 2, yesterdayAt(10)),
      ];
      await strict.intake.backfillScan();
      expect(strict.offered, ['shot-9', 'photo-10']);
    });
  });

  group('every image is still checked exactly once', () {
    /// Two days ago, checked by an earlier scan of this session; then a
    /// day of two screenshots and two photos.
    Future<PhotoScanRig> midDay({FakeDao? dao, ScriptedAnalyzer? analyzer}) async {
      final rig = PhotoScanRig(dao: dao, analyzer: analyzer);
      rig.library.assets = [
        rig.screenshot('old-shot', 1, twoDaysAgoAt(8)),
        rig.photo('old-photo', 2, twoDaysAgoAt(9)),
      ];
      return rig;
    }

    void addYesterday(PhotoScanRig rig) => rig.library.assets = [
          ...rig.library.assets,
          rig.screenshot('shot-9', 3, yesterdayAt(9)),
          rig.photo('photo-10', 4, yesterdayAt(10)),
          rig.screenshot('shot-11', 5, yesterdayAt(11)),
          rig.photo('lunch-12', 6, yesterdayAt(12)),
        ];

    test('a visit that ends after the photos leaves the frontier in front '
        'of the first unchecked screenshot, and the next scan checks the '
        'screenshots and moves it to the end', () async {
      final rig = await midDay();
      expect(await rig.catchUp(), twoDaysAgoAt(9));
      addYesterday(rig);

      // The visit lasts two model calls: the two photos.
      var open = true;
      rig.analyzer.onSend = (n) async {
        if (n == 6) open = false;
      };
      final covered = <DateTime>[];
      final frontier = await rig.catchUp(
          shouldContinue: () => open, onCovered: (f) async => covered.add(f));
      expect(rig.analyzer.sent, [2, 1, 4, 6]);
      expect(frontier, twoDaysAgoAt(9),
          reason: 'lunch-12 was checked, but nothing may pass shot-9');
      expect(covered, isEmpty,
          reason: 'no checkpoint is offered for a photo checked ahead of '
              'an unchecked screenshot');

      open = true;
      covered.clear();
      final after = await rig.catchUp(
          shouldContinue: () => open, onCovered: (f) async => covered.add(f));
      expect(rig.analyzer.sent, [2, 1, 4, 6, 3, 5],
          reason: 'each image went to the model exactly once');
      expect(after, yesterdayAt(12));
      expect(rig.reads.toSet().length, rig.reads.length,
          reason: 'no original was read twice in this session');
    });

    test('the watermark the app persists never passes an unchecked '
        'screenshot (foregroundCatchUp, interrupted)', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      DateTime? mark() =>
          readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));
      final rig = await midDay();
      await foregroundCatchUp(rig.intake, loadPrefs: () async => prefs);
      expect(mark(), twoDaysAgoAt(9));
      addYesterday(rig);

      var open = true;
      rig.analyzer.onSend = (n) async {
        if (n == 6) open = false;
      };
      await foregroundCatchUp(rig.intake,
          loadPrefs: () async => prefs, shouldContinue: () => open);
      expect(rig.analyzer.sent, [2, 1, 4, 6]);
      expect(mark(), twoDaysAgoAt(9),
          reason: 'a background run starting from the watermark must still '
              'list both screenshots');

      open = true;
      await foregroundCatchUp(rig.intake,
          loadPrefs: () async => prefs, shouldContinue: () => open);
      expect(mark(), yesterdayAt(12));
      expect(rig.analyzer.sent, [2, 1, 4, 6, 3, 5]);
    });

    test('the next session offers the whole window again, and the ledger '
        'answers for what the interrupted visit checked: one model call per '
        'image in all', () async {
      final first = await midDay();
      addYesterday(first);
      first.analyzer.script[6] = (_) => foodReply('Noodles', 650);
      var open = true;
      first.analyzer.onSend = (n) async {
        if (n == 6) open = false;
      };
      await first.catchUp(shouldContinue: () => open);
      expect(first.analyzer.sent, [4, 6],
          reason: 'the visit ended on the lunch photo');

      // The process ended. A fresh start: nothing is "seen", the ledger
      // and the meals are what is left.
      final second =
          PhotoScanRig(dao: first.dao, analyzer: first.analyzer);
      second.library.assets = [
        for (final a in first.library.assets)
          a is ScreenshotAsset
              ? second.screenshot(a.id, a.bytes!.first, a.createDateTime)
              : second.photo(a.id, a.bytes!.first, a.createDateTime),
      ];
      first.analyzer.onSend = null;
      await second.catchUp();
      expect(second.offered, [
        'photo-10',
        'lunch-12',
        'shot-9',
        'shot-11',
        'old-shot',
        'old-photo',
      ]);
      expect(first.analyzer.sent, [4, 6, 3, 5, 1, 2],
          reason: 'photo-10 and lunch-12 were answered by the ledger');
      expect(first.analyzer.sent.toSet().length, 6);
      expect(second.dao.meals, hasLength(1), reason: 'no meal logged twice');
      expect(
          [
            for (final (id, o) in second.outcomes)
              if (o.kind == PhotoOutcomeKind.alreadyTracked) id,
          ],
          ['photo-10', 'lunch-12']);
    });

    test('a screenshot the model could not be reached for is tried once per '
        'scan, and halts the frontier until it has a verdict', () async {
      final rig = await midDay();
      await rig.catchUp();
      addYesterday(rig);
      rig.analyzer.script[3] = (_) => unreachableReply;
      final frontier = await rig.catchUp();
      expect(rig.analyzer.sent, [2, 1, 4, 6, 3, 5],
          reason: 'shot-9 was not sent again by the window pass');
      expect(frontier, twoDaysAgoAt(9));

      rig.analyzer.script.remove(3);
      expect(await rig.catchUp(), yesterdayAt(12));
      expect(rig.analyzer.sent, [2, 1, 4, 6, 3, 5, 3]);
    });

    test('switching Watch Camera Roll off during the first pass ends the '
        'whole scan: neither the screenshots nor the window pass follow',
        () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.photo('old-photo', 1, twoDaysAgoAt(9)),
        rig.screenshot('shot-9', 2, yesterdayAt(9)),
        rig.photo('photo-10', 3, yesterdayAt(10)),
        rig.photo('lunch-12', 4, yesterdayAt(12)),
      ];
      await rig.intake.start();
      rig.analyzer.onSend = (n) async {
        if (n == 3) await rig.intake.stop();
      };
      await rig.catchUp();
      expect(rig.offered, ['photo-10'],
          reason: 'nothing more is sent once the user switched it off');
    });
  });

  group('the automatic leftover check', () {
    test('still finds a meal photographed before its leftovers, with '
        'screenshots taken before, between and after them', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.screenshot('shot-11', 1, yesterdayAt(11)),
        rig.photo('meal', 2, yesterdayAt(12)),
        rig.screenshot('shot-12', 3, yesterdayAt(12, 30)),
        rig.photo('leftovers', 4, yesterdayAt(13)),
        rig.screenshot('shot-14', 5, yesterdayAt(14)),
      ];
      rig.analyzer.script[2] = (_) => foodReply('Rice bowl', 800);
      rig.analyzer.script[4] = (recent) {
        final at = recent
            .indexWhere((m) => m['meal_description'] == 'Rice bowl');
        return at < 0
            ? foodReply('Half a rice bowl', 400)
            : leftoverReply(index: at, left: 0.5);
      };
      await rig.catchUp();

      expect(rig.analyzer.sent, [2, 4, 1, 3, 5]);
      expect(rig.analyzer.recentSeen[4], ['Rice bowl'],
          reason: 'the meal was logged before its leftovers were checked');
      final kinds = {for (final (id, o) in rig.outcomes) id: o.kind};
      expect(kinds['meal'], PhotoOutcomeKind.saved);
      expect(kinds['leftovers'], PhotoOutcomeKind.leftoverApplied);
      expect(rig.dao.meals, hasLength(1),
          reason: 'deducted from the meal, not logged as a second one');
      expect(rig.dao.meals.single.analysis['total_calories'], 400);
    });

    // A limit of the new order, known and accepted (the comment in
    // LibraryPhotoIntake.backfillScan). Before it, the screenshot went
    // first and the deduction was made.
    test('KNOWN LIMIT: a meal the scan logs from a screenshot is not there '
        'yet when leftovers photographed after it are checked in the same '
        'visit; they are logged as a meal of their own', () async {
      final rig = PhotoScanRig();
      rig.library.assets = [
        rig.screenshot('order', 1, yesterdayAt(12)),
        rig.photo('leftovers', 2, yesterdayAt(13)),
      ];
      rig.analyzer.script[1] = (_) => foodReply('Delivery rice bowl', 800);
      rig.analyzer.script[2] = (recent) => recent.isEmpty
          ? foodReply('Half a rice bowl', 400)
          : leftoverReply(index: 0, left: 0.5);
      await rig.catchUp();
      expect(rig.analyzer.sent, [2, 1]);
      expect(rig.analyzer.recentSeen[2], isEmpty);
      expect(rig.dao.meals.map((m) => m.analysis['meal_description']),
          ['Half a rice bowl', 'Delivery rice bowl']);

      // A screenshot an earlier scan already checked is found as before.
      final earlier = PhotoScanRig();
      earlier.library.assets = [
        earlier.screenshot('order', 1, yesterdayAt(12)),
      ];
      earlier.analyzer.script[1] = (_) => foodReply('Delivery rice bowl', 800);
      earlier.analyzer.script[2] = rig.analyzer.script[2]!;
      await earlier.catchUp();
      earlier.library.assets = [
        ...earlier.library.assets,
        earlier.photo('leftovers', 2, yesterdayAt(13)),
      ];
      await earlier.catchUp();
      expect(earlier.analyzer.recentSeen[2], ['Delivery rice bowl']);
      expect(earlier.dao.meals, hasLength(1));
      expect(earlier.dao.meals.single.analysis['total_calories'], 400);
    });
  });

  test('the row counts a day of photos and screenshots as one scan', () async {
    final rig = PhotoScanRig();
    rig.library.assets = [
      rig.screenshot('shot-9', 1, yesterdayAt(9)),
      rig.photo('lunch', 2, yesterdayAt(12)),
      rig.screenshot('shot-13', 3, yesterdayAt(13)),
    ];
    rig.analyzer.script[2] = (_) => foodReply('Noodles', 650);
    await rig.catchUp();
    expect(rig.row, ['checking 1/3', 'checking 2/3', 'checking 3/3', 'idle']);
    expect(rig.dao.meals.single.source, MealSource.appWatch);
  });
}
