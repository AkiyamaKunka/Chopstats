// The background-run diagnostics record (2026-10-18): one entry per run,
// rewritten at every step, so a run iOS kills still says how far it got.
import 'dart:convert';

import 'package:calorie_tracker/services/photo/background_runs.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs([Map<String, Object> initial = const {}]) {
  SharedPreferences.setMockInitialValues(initial);
  return SharedPreferences.getInstance();
}

List<Map<String, dynamic>> _stored(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(backgroundRunsPrefsKey)!) as List)
        .cast<Map<String, dynamic>>();

void main() {
  final t0 = DateTime.utc(2026, 10, 18, 3, 0, 0);

  test('begin writes the entry at once: boot, start, platform, watermark',
      () async {
    final prefs = await _prefs();
    final watermark = DateTime.utc(2026, 10, 11, 2, 26);
    await BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0)
        .begin(watermarkBefore: watermark);
    final runs = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey));
    expect(runs, hasLength(1));
    final r = runs.single;
    expect(r.start, t0);
    expect(r.end, isNull, reason: 'not finished — yet, or ever');
    expect(r.platform, 'ios');
    expect(r.stage, BackgroundRunStage.boot);
    expect(r.watermarkBefore, watermark);
    expect(r.watermarkAfter, watermark, reason: 'nothing moved it yet');
  });

  test('the boot before Dart (iOS native launch stamp) is kept, through '
      'every later write; none is stored without one', () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
    await rec.begin(bootLead: const Duration(milliseconds: 1750));
    await rec.offered();
    await rec.finish(BackgroundStop.done);
    expect(decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
        .single
        .bootMs, 1750);
    expect(_stored(prefs).single['boot_ms'], 1750);
    for (final lead in [null, Duration.zero]) {
      final p = await _prefs();
      await BackgroundRunRecorder(p, platform: 'android', clock: () => t0)
          .begin(bootLead: lead);
      expect(_stored(p).single.containsKey('boot_ms'), isFalse);
      expect(decodeBackgroundRuns(p.getString(backgroundRunsPrefsKey))
          .single
          .bootMs, isNull);
    }
  });

  test('a run the OS kills keeps the last step it wrote (no final write)',
      () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
    await rec.begin();
    await rec.stage(BackgroundRunStage.settings);
    await rec.stage(BackgroundRunStage.scan);
    await rec.listed(3);
    await rec.offered();
    await rec.processed(saved: true, released: false);
    await rec.checkpoint(DateTime.utc(2026, 10, 18, 2, 50));
    await rec.offered(); // photo 2 is mid-analysis when iOS expires the run
    // ... and nothing more: the process is gone. A fresh read (the app's
    // engine, later) sees exactly that.
    final r = (await readBackgroundRuns(prefs: () async => prefs)).single;
    expect(r.finished, isFalse);
    expect(r.stage, BackgroundRunStage.photo);
    expect((r.enumerated, r.offered, r.analyzed, r.saved, r.released),
        (3, 2, 1, 1, 0));
    expect(r.watermarkAfter, DateTime.utc(2026, 10, 18, 2, 50));
    expect(r.stopReason, isNull);
  });

  test('finish stamps the end, the reason and the final watermark; a second '
      'finish and later steps change nothing', () async {
    final prefs = await _prefs();
    var now = t0;
    final rec = BackgroundRunRecorder(prefs, platform: 'android',
        clock: () => now);
    await rec.begin();
    await rec.releasedUnprocessed(2);
    now = t0.add(const Duration(seconds: 14));
    await rec.finish(BackgroundStop.budget,
        watermarkAfter: DateTime.utc(2026, 10, 18, 2, 0));
    await rec.finish(BackgroundStop.done);
    await rec.stage(BackgroundRunStage.photo);
    final r = rec.current!;
    expect(r.end, t0.add(const Duration(seconds: 14)));
    expect(r.stage, BackgroundRunStage.done);
    expect(r.stopReason, BackgroundStop.budget);
    expect(r.released, 2);
    expect(r.watermarkAfter, DateTime.utc(2026, 10, 18, 2, 0));
    expect(decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
        .single
        .stopReason, BackgroundStop.budget);
  });

  test('newest first, and only the last 20 are kept', () async {
    final prefs = await _prefs();
    for (var i = 0; i < 23; i++) {
      final rec = BackgroundRunRecorder(prefs,
          platform: 'ios', clock: () => t0.add(Duration(minutes: 30 * i)));
      await rec.begin();
      await rec.finish(BackgroundStop.done);
    }
    final runs = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey));
    expect(runs, hasLength(backgroundRunsKept));
    expect(runs.first.start, t0.add(const Duration(minutes: 30 * 22)));
    expect(runs.last.start, t0.add(const Duration(minutes: 30 * 3)));
  });

  test('counts and timestamps only: the stored keys are pinned, and an error '
      'is its class name, never its message', () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
    await rec.begin();
    // A message can carry anything — a server address, a key prefix.
    final error = PlatformException(
        code: '-25308', message: 'https://my-server.example/?key=abc');
    await rec.finish(BackgroundStop.error(error));
    final entry = _stored(prefs).single;
    expect(entry.keys.toSet(), {
      'start', 'end', 'platform', 'stage', 'enumerated', 'offered',
      'analyzed', 'saved', 'released', 'stop', 'wm_before', 'wm_after',
    });
    expect(entry['stop'], 'error:PlatformException');
    expect(prefs.getString(backgroundRunsPrefsKey), isNot(contains('http')));
    expect(prefs.getString(backgroundRunsPrefsKey), isNot(contains('key=')));
  });

  // 2026-11-28 (iOS): photos the scan listed and did not read again
  // because a meal already names each one. Written only when there are
  // any, so an entry without them is what every earlier version wrote,
  // and what an earlier version reads from a newer entry is unchanged.
  test('photos already logged and not read again: "known", only when above '
      '0; an older entry reads as 0', () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
    await rec.begin();
    await rec.listed(5);
    await rec.alreadyLogged(0);
    expect(_stored(prefs).single.containsKey('known'), isFalse);
    await rec.alreadyLogged(3);
    await rec.alreadyLogged(1); // a second pass of the same scan
    expect(_stored(prefs).single['known'], 4);
    final r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
        .single;
    expect((r.enumerated, r.alreadyLogged, r.offered), (5, 4, 0));
    // Every other step keeps it.
    await rec.offered();
    await rec.finish(BackgroundStop.done);
    expect(rec.current!.alreadyLogged, 4);
    // An entry written before the count existed, and junk in its place.
    final old = jsonEncode([
      {'start': t0.toIso8601String(), 'stage': 'done', 'enumerated': 5},
      {'start': t0.toIso8601String(), 'known': -2},
      {'start': t0.toIso8601String(), 'known': 'three'},
    ]);
    expect([for (final e in decodeBackgroundRuns(old)) e.alreadyLogged],
        [0, 0, 0]);
  });

  // 2026-11-28: a run said how many photos it left for later, never why.
  // On 2026-11-27 the phone could not answer "why was nothing logged".
  group('why photos were left for later', () {
    test('each one is counted under its reason, and the reasons add up to '
        '"left for later"', () async {
      final prefs = await _prefs();
      final rec =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await rec.begin();
      await rec.processed(
          saved: false, released: true, left: BackgroundLeft.busy);
      await rec.processed(
          saved: false, released: true, left: BackgroundLeft.busy);
      await rec.processed(
          saved: false, released: true, left: BackgroundLeft.unreachable);
      // A caller that does not say why: still counted, as another reason.
      await rec.processed(saved: false, released: true);
      // A photo that got its verdict was not left, whatever is handed in.
      await rec.processed(
          saved: true, released: false, left: BackgroundLeft.busy);
      await rec.releasedUnprocessed(3);
      await rec.releasedUnprocessed(0);
      await rec.cutOff(BackgroundLeft.deadline);
      final r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect(r.left, {
        BackgroundLeft.busy: 2,
        BackgroundLeft.unreachable: 1,
        BackgroundLeft.other: 1,
        BackgroundLeft.notOffered: 3,
        BackgroundLeft.deadline: 1,
      });
      expect(r.released, 8);
      expect(r.left.values.fold<int>(0, (a, b) => a + b), r.released);
      expect((r.analyzed, r.saved), (5, 1),
          reason: 'the cut photo and the ones not started were never '
              'processed');
      expect(BackgroundLeft.all.toSet(), hasLength(6));
      expect(BackgroundLeft.all, containsAll(r.left.keys));
    });

    // The stored format stays readable both ways: the key is there only
    // when a run left something, every older key keeps its meaning, and
    // an older version ignores the new one.
    test('stored as "left", only when there is something to say', () async {
      final prefs = await _prefs();
      final rec =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await rec.begin();
      await rec.processed(saved: true, released: false);
      expect(_stored(prefs).single.containsKey('left'), isFalse);
      await rec.processed(
          saved: false, released: true, left: BackgroundLeft.busy);
      await rec.finish(BackgroundStop.done);
      final entry = _stored(prefs).single;
      expect(entry['left'], {'busy': 1});
      expect(entry.keys.toSet(), {
        'start', 'end', 'platform', 'stage', 'enumerated', 'offered',
        'analyzed', 'saved', 'released', 'stop', 'wm_before', 'wm_after',
        'left',
      });
      expect((entry['analyzed'], entry['saved'], entry['released']),
          (2, 1, 1));
    });

    test('an entry from before reads as no reasons; junk is dropped; a '
        'reason a later version adds is kept', () {
      List<Map<String, int>> leftOf(Object? left) => [
            for (final r in decodeBackgroundRuns(jsonEncode([
              {
                'start': t0.toIso8601String(),
                'released': 2,
                'left': ?left,
              },
            ])))
              r.left,
          ];
      expect(leftOf(null), [isEmpty]);
      for (final junk in ['busy', 3, ['busy'], true]) {
        expect(leftOf(junk), [isEmpty], reason: '$junk');
      }
      expect(
          leftOf({
            'busy': 0,
            'unreachable': -1,
            'deadline': 'two',
            'not_offered': 1.5,
            '': 4,
            'x' * 25: 4,
            'a_later_reason': 2,
            'other': 1,
          }),
          [
            {'a_later_reason': 2, 'other': 1},
          ]);
      // The count keeps its own word either way.
      expect(
          decodeBackgroundRuns(jsonEncode([
            {'start': t0.toIso8601String(), 'released': 2, 'left': 'junk'},
          ])).single.released,
          2);
    });

    // RunInFlight.abandon says why at the deadline, moments before
    // finishWithinGrant finishes the entry; nothing waits for its write.
    test('a cut said just before the entry is finished is in the final '
        'entry, and nothing said after it is', () async {
      final prefs = await _prefs();
      final rec =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await rec.begin();
      await rec.offered();
      final said = rec.cutOff(BackgroundLeft.preparing); // not awaited
      await rec.finish(BackgroundStop.budget);
      await said;
      var r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect(r.stopReason, BackgroundStop.budget);
      expect((r.offered, r.analyzed, r.released), (1, 0, 1));
      expect(r.left, {BackgroundLeft.preparing: 1});
      await rec.cutOff(BackgroundLeft.busy);
      await rec.releasedUnprocessed(2);
      r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect(r.left, {BackgroundLeft.preparing: 1});
      expect(r.released, 1);
    });

    // Review, 2026-11-28: the photo the deadline cut off can still report
    // (its answer lands while it is being released, or on Android during
    // the summary's re-arm). The run then said "left for later" for it as
    // well, and the entry showed two photos: released 2, {deadline: 1,
    // other: 1}.
    test('the photo the deadline cut off is counted once: its own "left for '
        'later", coming after the cut, is the same photo', () async {
      final prefs = await _prefs();
      final rec =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await rec.begin();
      expect(rec.photoInFlight, isFalse, reason: 'none handed over yet');
      await rec.offered();
      expect(rec.photoInFlight, isTrue);
      await rec.cutOff(BackgroundLeft.deadline);
      expect(rec.photoInFlight, isFalse, reason: 'the cut has counted it');
      await rec.processed(saved: false, released: true);
      var r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect((r.offered, r.analyzed, r.released), (1, 0, 1));
      expect(r.left, {BackgroundLeft.deadline: 1});
      // The next photo is another photo, counted as before.
      await rec.offered();
      expect(rec.photoInFlight, isTrue);
      await rec.processed(
          saved: false, released: true, left: BackgroundLeft.busy);
      expect(rec.photoInFlight, isFalse, reason: 'its verdict is counted');
      r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect((r.offered, r.analyzed, r.released), (2, 1, 2));
      expect(r.left,
          {BackgroundLeft.deadline: 1, BackgroundLeft.busy: 1});
    });

    // A cut the deadline counted and then found was none: the photo's
    // meal had been saved already (RunInFlight.abandon).
    test('a cut taken back leaves no trace, and the photo\'s own verdict '
        'then counts', () async {
      final prefs = await _prefs();
      final rec =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await rec.begin();
      await rec.processed(
          saved: false, released: true, left: BackgroundLeft.deadline);
      await rec.offered();
      await rec.cutOff(BackgroundLeft.deadline);
      expect(rec.current!.left, {BackgroundLeft.deadline: 2});
      await rec.cutWithdrawn();
      expect(rec.current!.left, {BackgroundLeft.deadline: 1},
          reason: 'the earlier photo\'s stays');
      expect(rec.current!.released, 1);
      expect(rec.photoInFlight, isTrue, reason: 'not counted any more');
      await rec.processed(saved: true, released: false);
      await rec.cutWithdrawn(); // nothing to take back: nothing changes
      final r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect((r.offered, r.analyzed, r.saved, r.released), (1, 2, 1, 1));
      expect(r.left, {BackgroundLeft.deadline: 1});
      // The only photo left for a reason: the reason goes with it.
      final only =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await only.begin();
      await only.offered();
      await only.cutOff(BackgroundLeft.busy);
      await only.cutWithdrawn();
      expect(only.current!.left, isEmpty);
      expect(_stored(prefs).first.containsKey('left'), isFalse);
    });

    // The verdict that comes after the cut can also keep the photo: a meal
    // committed just before the deadline, or a reservation the database
    // answers "already logged" once the cut is said. Counted on top of the
    // cut, that photo read as left for later and as processed.
    test('a verdict that keeps the cut-off photo takes the cut back: the '
        'photo is processed, not left', () async {
      final prefs = await _prefs();
      final rec =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await rec.begin();
      await rec.offered();
      await rec.processed(
          saved: false, released: true, left: BackgroundLeft.busy);
      await rec.offered();
      await rec.cutOff(BackgroundLeft.deadline);
      await rec.processed(saved: true, released: false);
      expect(rec.photoInFlight, isFalse);
      var r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect((r.offered, r.analyzed, r.saved, r.released), (2, 2, 1, 1));
      expect(r.left, {BackgroundLeft.busy: 1},
          reason: 'the earlier photo\'s stays');
      await rec.cutWithdrawn(); // taken back already: nothing changes
      r = decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey))
          .single;
      expect((r.analyzed, r.released), (2, 1));
      // "Already logged" saves nothing, and keeps the photo all the same.
      final only =
          BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0);
      await only.begin();
      await only.offered();
      await only.cutOff(BackgroundLeft.preparing);
      await only.processed(saved: false, released: false);
      r = only.current!;
      expect((r.offered, r.analyzed, r.saved, r.released), (1, 1, 0, 0));
      expect(r.left, isEmpty);
      expect(_stored(prefs).first.containsKey('left'), isFalse);
    });
  });

  test('a damaged store reads as what it can: bad entries skipped, bad JSON '
      'empty, and a new run still records', () async {
    expect(decodeBackgroundRuns('not json'), isEmpty);
    expect(decodeBackgroundRuns('{"a":1}'), isEmpty);
    final mixed = jsonEncode([
      {'start': t0.toIso8601String(), 'stage': 'scan', 'offered': -4},
      {'start': 'yesterday'},
      42,
      {'start': t0.toIso8601String(), 'stage': 'from-the-future'},
    ]);
    final runs = decodeBackgroundRuns(mixed);
    expect(runs, hasLength(2));
    expect(runs.first.stage, BackgroundRunStage.scan);
    expect(runs.first.offered, 0, reason: 'a negative count is not a count');
    expect(runs.last.stage, BackgroundRunStage.boot);

    final prefs = await _prefs({backgroundRunsPrefsKey: 'not json'});
    await BackgroundRunRecorder(prefs, platform: 'ios', clock: () => t0)
        .begin();
    expect(decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey)),
        hasLength(1));
  });

  test('nothing is written before begin', () async {
    final prefs = await _prefs();
    final rec = BackgroundRunRecorder(prefs, platform: 'ios');
    await rec.offered();
    await rec.finish(BackgroundStop.done);
    expect(prefs.getString(backgroundRunsPrefsKey), isNull);
  });

  test('readBackgroundRuns: an unreadable store is an empty history',
      () async {
    expect(
        await readBackgroundRuns(prefs: () async => throw StateError('no')),
        isEmpty);
  });

  // 2026-10-19: the Settings 后台扫描 row says when the runs show no
  // progress — and never for a quiet stretch with no photos.
  group('backgroundScanLooksStuck', () {
    final now = DateTime.utc(2026, 10, 19, 12);
    BackgroundRunRecord run(Duration ago,
            {int offered = 0,
            int analyzed = 0,
            int saved = 0,
            int released = 0,
            String? stop = BackgroundStop.done,
            DateTime? before,
            DateTime? after}) =>
        BackgroundRunRecord(
          start: now.subtract(ago),
          end: stop == null ? null : now.subtract(ago),
          platform: 'ios',
          stage: stop == null
              ? BackgroundRunStage.photo
              : BackgroundRunStage.done,
          offered: offered,
          analyzed: analyzed,
          saved: saved,
          released: released,
          stopReason: stop,
          watermarkBefore: before,
          watermarkAfter: after ?? before,
        );
    const h = Duration(hours: 1);

    test('the 3 newest runs each took a photo and finished none', () {
      final hung = [
        for (final ago in [1, 2, 3]) run(h * ago, offered: 1, stop: null),
      ];
      expect(backgroundScanLooksStuck(hung, now: now), isTrue);
      expect(backgroundScanLooksStuck(hung.take(2).toList(), now: now),
          isFalse, reason: 'two is not a pattern yet');
      expect(
          backgroundScanLooksStuck(
              [run(h, offered: 1, analyzed: 1), ...hung.skip(1)], now: now),
          isFalse,
          reason: 'the newest run finished its photo');
      expect(
          backgroundScanLooksStuck([
            run(h, offered: 1, stop: BackgroundStop.budget),
            ...hung.skip(1),
          ], now: now),
          isTrue,
          reason: 'out of time on it is no progress either');
    });

    test('a quiet week with no new photos is never stuck', () {
      final wm = DateTime.utc(2026, 10, 12);
      final quiet = [
        for (var i = 1; i <= 20; i++)
          run(h * (8 * i), offered: 1, analyzed: 1, before: wm),
      ];
      expect(backgroundScanLooksStuck(quiet, now: now), isFalse);
    });

    test('runs keep starting but none made progress for 2 days', () {
      final dying = [
        run(h * 2, stop: null), // killed at boot: nothing offered
        run(h * 10, stop: 'error:PlatformException'),
        run(h * 30, offered: 1, analyzed: 1, released: 1),
        run(h * 60, stop: null),
      ];
      expect(backgroundScanLooksStuck(dying, now: now), isTrue);
      expect(backgroundScanLooksStuck(dying.take(3).toList(), now: now),
          isFalse, reason: 'the record does not reach back 2 days');
      expect(
          backgroundScanLooksStuck(
              [run(h, saved: 1, offered: 1, analyzed: 1), ...dying],
              now: now),
          isFalse,
          reason: 'a meal saved is progress');
      expect(
          backgroundScanLooksStuck([
            run(h,
                before: DateTime.utc(2026, 10, 18),
                after: DateTime.utc(2026, 10, 19)),
            ...dying
          ], now: now),
          isFalse,
          reason: 'a watermark moved is progress');
      expect(
          backgroundScanLooksStuck(
              [dying.first, dying.last], now: now),
          isFalse,
          reason: 'fewer than 3 runs in 2 days: not "keep starting"');
    });

    // 2026-10-19: the hint says opening the app catches up — and kept
    // saying it after the app had, until a background run made progress.
    test('a watermark moved past where the newest run left it (the app '
        'caught up) clears both signs, until later runs show them again', () {
      final wm = DateTime.utc(2026, 10, 11, 2, 26);
      final hung = [
        for (final ago in [1, 2, 3])
          run(h * ago, offered: 1, stop: null, before: wm),
      ];
      expect(backgroundScanLooksStuck(hung, now: now, watermark: wm), isTrue,
          reason: 'nothing moved it since');
      expect(
          backgroundScanLooksStuck(hung,
              now: now, watermark: DateTime.utc(2026, 10, 19, 11)),
          isFalse);
      final dying = [
        run(h * 2, stop: null, before: wm),
        run(h * 10, stop: 'error:PlatformException', before: wm),
        run(h * 20, stop: null, before: wm),
        run(h * 60, stop: null, before: wm),
      ];
      expect(backgroundScanLooksStuck(dying, now: now, watermark: wm), isTrue);
      expect(
          backgroundScanLooksStuck(dying,
              now: now, watermark: wm.add(const Duration(seconds: 1))),
          isFalse);
      // The next runs start from the moved watermark and hang again.
      final moved = DateTime.utc(2026, 10, 19, 11);
      final again = [
        for (final ago in [1, 2, 3])
          run(Duration(minutes: 10 * ago),
              offered: 1, stop: null, before: moved),
        ...hung,
      ];
      expect(backgroundScanLooksStuck(again, now: now, watermark: moved),
          isTrue);
    });

    test('runs a guard stopped (no key, paused…) are not "stuck": opening '
        'the app would not fix them', () {
      final guarded = [
        for (var i = 1; i <= 6; i++)
          run(h * (12 * i), stop: BackgroundStop.noKey),
      ];
      expect(backgroundScanLooksStuck(guarded, now: now), isFalse);
    });
  });
}
