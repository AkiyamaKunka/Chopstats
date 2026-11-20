// Q1 and Q9 (QA 2026-11-19): a shared photo was lost when its engine went
// mid-analysis (Back finished the activity, or the app was killed in the
// middle of a batch). Its copy was deleted as its bytes were read, and its
// ledger row stayed 'processing' until a launch 20 minutes later failed it.
//
// Now the copy is kept until the photo is settled (IntakePhoto.onSettled:
// its meal or failure written, or the photo let go), and the launch sweep
// releases a deliberate row its engine left (fails one older than 20
// minutes, which a deliberate add reclaims), so the next start offers the
// photo again through the normal path: the consent question once for the
// batch, the md5 ledger keeping it to one meal. A photo whose copy is gone
// is not offered again; released, it is free for a share again, and for
// the camera-roll scan if it is also in the library.
//
// Each "run" below is one engine, wired as di.dart wires the share path:
// the launch sweep first, then share intake → consent gate → pipeline, on
// a real SQLite ledger and a real share folder. An engine that dies is
// simply never touched again: no cancel, no cleanup, its analysis never
// answers.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/ai_consent.dart' show allAiConsentRoutes;
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart'
    show originalBytesMd5;
import 'package:calorie_tracker/services/photo/share_intake.dart';
import 'package:calorie_tracker/ui/ai_consent.dart'
    show SharedPhotoConsentGate, aiConsentNeeded;
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ui/fakes.dart' show FakeAnalyzer, FakeDao, FakeSettings;
import 'share_intake_test.dart' show FakeShareSource;
import 'watcher_test.dart' show FakePhotoLibrary;

const _meal = AnalysisOutcome(
    analysis: {
      'is_food': true,
      'meal_description': 'Beef noodles',
      'total_calories': 620,
    },
    isFood: true,
    wall: Duration.zero);

/// One engine's share path.
class _Run {
  _Run._(this.dao, this.intake, this.gate, this.pipeline, this.source,
      this.notices);

  final SqfliteMealsDao dao;
  final ShareIntake intake;
  final SharedPhotoConsentGate gate;
  final PhotoPipeline pipeline;
  final FakeShareSource source;
  final List<PhotoOutcome> notices;

  /// di.dart's order: the launch sweep, before anything reserves, then the
  /// share stream bound through the consent gate. [clock] is this start's
  /// own: how old the copies left in the folder look to share intake, and
  /// the rows left in the ledger to the launch sweep.
  static Future<_Run> start(Database db, String folder,
      {required FakeSettings settings,
      required FakeAnalyzer analyzer,
      List<String> launch = const [],
      DateTime Function()? clock,
      Future<Uint8List?> Function(Uint8List)? thumbnailer}) async {
    final dao = SqfliteMealsDao(db, clock: clock);
    await dao.reclaimStaleProcessing();
    final source = FakeShareSource()..initial = launch;
    final intake = ShareIntake(
        source: source,
        library: FakePhotoLibrary(),
        readBytes: (path) async {
          try {
            return await File(path).readAsBytes();
          } catch (_) {
            return null;
          }
        },
        // The production cleanup: a real delete.
        sharedFolder: () async => folder,
        recheckAfter: const Duration(milliseconds: 50),
        clock: clock);
    final gate = SharedPhotoConsentGate(settings);
    final notices = <PhotoOutcome>[];
    final pipeline = PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        notify: notices.add,
        // As aiSendGateFor: the consent read again at the send.
        sendGate: AiSendGate(allowed: () => !aiConsentNeeded(settings)),
        hasher: (bytes) async => originalBytesMd5(bytes),
        thumbnailer: thumbnailer ?? (_) async => null);
    pipeline.bindStream(gate.gate(intake.photos(), deliveries: intake));
    return _Run._(dao, intake, gate, pipeline, source, notices);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late Directory cache;
  late String folder;

  setUp(() async {
    db = await openAppDatabase(path: inMemoryDatabasePath);
    cache = Directory.systemTemp.createTempSync('share_resume_');
    folder = '${cache.path}/$androidShareFolderName';
    Directory(folder).createSync(recursive: true);
  });
  tearDown(() async {
    await db.close();
    cache.deleteSync(recursive: true);
  });

  // Real file and database I/O completes outside the microtask queue: wait
  // in real time for what a test expects.
  Future<void> until(bool Function() done, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await pumpEventQueue(times: 50);
  }

  /// A photo as MainActivity copies it: a folder of its own in the share
  /// folder. [n] makes the bytes, so the md5, its own.
  File copy(int n, {String? name}) =>
      File('$folder/u$n-${DateTime.now().microsecondsSinceEpoch}/'
          '${name ?? 'IMG_$n.jpg'}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(
            List<int>.generate(256, (i) => (i * 31 + n * 7) & 0xFF));

  String md5Of(File f) => originalBytesMd5(f.readAsBytesSync());

  Future<int> mealCount() async => (await db.query('meals')).length;

  List<File> leftInFolder() => [
        for (final e in Directory(folder).listSync(recursive: true))
          if (e is File) e,
      ];

  /// An analyzer whose every call is counted and, while [hold] is set,
  /// never answers: the request was sent, the reply never comes back to a
  /// living engine.
  ({FakeAnalyzer analyzer, List<int> calls}) analyzer(
      {Completer<void>? hold, AnalysisOutcome outcome = _meal}) {
    final calls = <int>[];
    final a = FakeAnalyzer()
      ..nextPhotoOutcome = outcome
      ..onAnalyze = () async {
        calls.add(calls.length + 1);
        if (hold != null) await hold.future;
      };
    return (analyzer: a, calls: calls);
  }

  DateTime Function() later(Duration by) =>
      () => DateTime.now().add(by);

  test('keep until written: the copy stays while the photo is analyzed, and '
      'goes as soon as its meal is written, before its thumbnail', () async {
    final photo = copy(1);
    final hash = md5Of(photo);
    final reply = Completer<void>();
    final thumb = Completer<Uint8List?>();
    final a = analyzer(hold: reply);
    final run = await _Run.start(db, folder,
        settings: FakeSettings(),
        analyzer: a.analyzer,
        launch: [photo.path],
        thumbnailer: (_) => thumb.future);
    await until(() => a.calls.isNotEmpty, 'the photo sent');
    expect(photo.existsSync(), isTrue,
        reason: 'read and sent, but no verdict written yet');
    expect((await run.dao.photoStatus(hash))?.status,
        IngestionStatus.processing);
    expect(run.intake.photosPending.value, isTrue,
        reason: 'Back at the root moves the app to the back meanwhile '
            '(SharedPhotosBackGuard)');

    reply.complete();
    await until(() => !photo.existsSync(), 'the copy deleted');
    expect(await mealCount(), 1);
    expect((await run.dao.photoStatus(hash))?.status, IngestionStatus.saved);
    expect(run.intake.photosPending.value, isFalse,
        reason: 'its meal is written: Back is Android\'s own again');
    expect(thumb.isCompleted, isFalse,
        reason: 'gone with the meal row, not after the thumbnail');
    thumb.complete(null);
    await until(() => run.notices.isNotEmpty, 'the meal announced');
    expect(run.notices.single.kind, PhotoOutcomeKind.saved);
    expect(leftInFolder(), isEmpty);
  });

  test('the engine died after the request was sent, before the meal was '
      'saved (Q9): the next start sends the photo again and logs it once',
      () async {
    final photo = copy(1);
    final hash = md5Of(photo);
    final settings = FakeSettings();
    // Run 1: analyzing when Back finished the activity. Its reply never
    // reaches a living engine.
    final first = analyzer(hold: Completer<void>());
    final run1 = await _Run.start(db, folder,
        settings: settings, analyzer: first.analyzer, launch: [photo.path]);
    await until(() => first.calls.isNotEmpty, 'the request sent');
    expect((await run1.dao.photoStatus(hash))?.status,
        IngestionStatus.processing);
    expect(photo.existsSync(), isTrue, reason: 'kept: no verdict written');

    // Run 2, a minute later: the launch sweep releases the row run 1
    // left, the start-up sweep offers the copy, and its deliberate add
    // reserves it afresh.
    final second = analyzer();
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        clock: later(const Duration(minutes: 1)));
    await until(() => !photo.existsSync(), 'the photo logged at last');
    expect(second.calls, [1], reason: 'sent once more, once');
    expect(await mealCount(), 1);
    final row = await run2.dao.photoStatus(hash);
    expect(row?.status, IngestionStatus.saved);
    expect(row?.mealId, isNotNull);
    expect(run2.notices.map((o) => o.kind), [PhotoOutcomeKind.saved]);
    expect(leftInFolder(), isEmpty);
  });

  test('the next start 25 minutes later: the stale row is failed, and the '
      'kept copy reclaims it: sent again once, logged once', () async {
    final photo = copy(1);
    final hash = md5Of(photo);
    final settings = FakeSettings();
    final first = analyzer(hold: Completer<void>());
    await _Run.start(db, folder,
        settings: settings, analyzer: first.analyzer, launch: [photo.path]);
    await until(() => first.calls.isNotEmpty, 'the request sent');

    // Past the sweep's 20 minutes, short of the 30 after which any add
    // reclaims a 'processing' row: only the failed row lets the copy in.
    final second = analyzer();
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        clock: later(const Duration(minutes: 25)));
    await until(() => !photo.existsSync(), 'the photo logged at last');
    expect(second.calls, [1]);
    expect(await mealCount(), 1);
    final row = await run2.dao.photoStatus(hash);
    expect(row?.status, IngestionStatus.saved);
    expect(row?.mealId, isNotNull);
    expect(run2.notices.map((o) => o.kind), [PhotoOutcomeKind.saved]);
  });

  test('killed in the middle of a batch (Q1): the photo in flight, the one '
      'read ahead and the unread ones come back, with one question for the '
      'batch, each logged once', () async {
    final photos = [for (var n = 1; n <= 4; n++) copy(n)];
    final hashes = [for (final p in photos) md5Of(p)];
    final settings = FakeSettings();
    final first = analyzer(hold: Completer<void>());
    await _Run.start(db, folder,
        settings: settings,
        analyzer: first.analyzer,
        launch: [for (final p in photos) p.path]);
    await until(() => first.calls.isNotEmpty, 'photo 1 sent');
    // At most one read ahead, and no copy deleted: none has a verdict.
    expect([for (final p in photos) p.existsSync()], [true, true, true, true]);

    // The app is killed. By the next start the user had turned sharing
    // off, so the batch is asked about first — once.
    settings.aiConsent = {};
    final second = analyzer();
    var asks = 0;
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        clock: later(const Duration(minutes: 3)));
    run2.gate.attach(() async {
      asks++;
      settings.aiConsent = {...allAiConsentRoutes};
      return true;
    });
    await until(() => leftInFolder().isEmpty, 'the batch logged');
    expect(asks, 1, reason: 'one question for the batch');
    expect(run2.intake.asksAlone(1), isTrue,
        reason: 'no share being made now: a question of its own');
    expect(second.calls, hasLength(4));
    expect(await mealCount(), 4);
    for (final h in hashes) {
      expect((await run2.dao.photoStatus(h))?.status, IngestionStatus.saved);
    }
  });

  test('a resumed batch answered Not now: nothing is sent, its copies go, '
      'and the photo that was in flight keeps no verdict', () async {
    final photos = [copy(1), copy(2)];
    final hashes = [for (final p in photos) md5Of(p)];
    final settings = FakeSettings();
    final first = analyzer(hold: Completer<void>());
    await _Run.start(db, folder,
        settings: settings,
        analyzer: first.analyzer,
        launch: [for (final p in photos) p.path]);
    await until(() => first.calls.isNotEmpty, 'photo 1 sent');

    settings.aiConsent = {}; // Stop Sharing, then the app was killed
    final second = analyzer();
    final notSent = <int>[];
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        clock: later(const Duration(minutes: 3)));
    run2.gate.attach(() async {
      // As the shell's dialog: the line is worded at the answer.
      notSent.add(run2.gate.declineOpenQuestion());
      return false;
    });
    await until(() => leftInFolder().isEmpty, 'the copies deleted');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notSent, [2]);
    expect(second.calls, isEmpty, reason: 'nothing sent without consent');
    expect(await mealCount(), 0);
    expect(await run2.dao.photoStatus(hashes[0]), isNull,
        reason: 'released at the start; nothing sent since (the send gate '
            'holds the camera-roll scan without consent as well)');
    expect(await run2.dao.photoStatus(hashes[1]), isNull);
  });

  test('copy missing at the next start: the row is released, nothing is '
      'sent, and sharing the photo again logs it', () async {
    final photo = copy(1);
    final bytes = photo.readAsBytesSync();
    final hash = md5Of(photo);
    final settings = FakeSettings();
    final first = analyzer(hold: Completer<void>());
    await _Run.start(db, folder,
        settings: settings, analyzer: first.analyzer, launch: [photo.path]);
    await until(() => first.calls.isNotEmpty, 'the request sent');
    // Its copy is gone (a build that deleted it as it read it, a cleared
    // cache), then the engine dies.
    photo.parent.deleteSync(recursive: true);

    final second = analyzer();
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        clock: later(const Duration(minutes: 1)));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await run2.dao.photoStatus(hash), isNull,
        reason: 'released: a deliberate add takes it at once (the '
            'camera-roll scan and Photo Coverage too, but only for a photo '
            'also in the library: not this one)');
    expect(run2.intake.arrivedDelivery, 0, reason: 'nothing to offer again');
    expect(second.calls, isEmpty);
    expect(run2.notices, isEmpty);
    expect(await mealCount(), 0);

    // The user shares it again.
    final again = File('$folder/again/IMG_1.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    run2.source.controller.add([again.path]);
    await until(() => !again.existsSync(), 'the share again logged');
    expect(second.calls, [1]);
    expect(await mealCount(), 1);
    expect((await run2.dao.photoStatus(hash))?.status, IngestionStatus.saved);
  });

  test('a next start more than a day later: the copy is deleted unread and '
      'the row, stale, is failed', () async {
    final photo = copy(1);
    final hash = md5Of(photo);
    final settings = FakeSettings();
    final first = analyzer(hold: Completer<void>());
    await _Run.start(db, folder,
        settings: settings, analyzer: first.analyzer, launch: [photo.path]);
    await until(() => first.calls.isNotEmpty, 'the request sent');

    final second = analyzer();
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        clock: later(ShareIntake.strandedMaxAge + const Duration(hours: 1)));
    await until(() => !photo.existsSync(), 'the stale copy deleted');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(second.calls, isEmpty, reason: 'logged days late it would '
        'surprise, and could land on the wrong day');
    expect((await run2.dao.photoStatus(hash))?.status, IngestionStatus.failed);
    expect(await mealCount(), 0);
  });

  test('duplicate safety: a photo whose meal was written as its engine '
      'stopped, its copy still there, is not logged or sent again', () async {
    final photo = copy(1);
    final bytes = photo.readAsBytesSync();
    final hash = md5Of(photo);
    final settings = FakeSettings();
    final first = analyzer();
    final run1 = await _Run.start(db, folder,
        settings: settings, analyzer: first.analyzer, launch: [photo.path]);
    await until(() => run1.notices.isNotEmpty, 'the meal logged');
    expect(await mealCount(), 1);
    // The engine stopped between the meal's commit and the copy's delete:
    // the copy is still there at the next start.
    File(photo.path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    final second = analyzer();
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        clock: later(const Duration(minutes: 1)));
    await until(() => !File(photo.path).existsSync(), 'the copy settled');
    await until(() => run2.notices.isNotEmpty, 'the verdict said');
    expect(second.calls, isEmpty, reason: 'the ledger answers before any '
        'upload');
    expect(await mealCount(), 1, reason: 'never a second meal');
    expect(run2.notices.single.kind,
        anyOf(PhotoOutcomeKind.duplicate, PhotoOutcomeKind.alreadyTracked));
    expect((await run2.dao.photoStatus(hash))?.status, IngestionStatus.saved);
  });

  test('duplicate safety: the photo the next start offers again and the same '
      'photo shared again meanwhile make one meal', () async {
    final photo = copy(1);
    final bytes = photo.readAsBytesSync();
    final settings = FakeSettings();
    final first = analyzer(hold: Completer<void>());
    await _Run.start(db, folder,
        settings: settings, analyzer: first.analyzer, launch: [photo.path]);
    await until(() => first.calls.isNotEmpty, 'the request sent');

    // The next start, launched by sharing the same photo again: its new
    // copy is the launch share, the old one the start-up batch.
    final again = File('$folder/again/IMG_1.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    final second = analyzer();
    final run2 = await _Run.start(db, folder,
        settings: settings,
        analyzer: second.analyzer,
        launch: [again.path],
        clock: later(const Duration(minutes: 1)));
    await until(() => leftInFolder().isEmpty, 'both copies settled');
    await until(() => run2.notices.length >= 2, 'both verdicts said');
    expect(second.calls, [1], reason: 'one upload for the one photo');
    expect(await mealCount(), 1);
    expect(run2.notices.map((o) => o.kind).toList()..sort(
            (a, b) => a.index.compareTo(b.index)),
        [PhotoOutcomeKind.saved, PhotoOutcomeKind.duplicate]);
  });

  group('who settles a shared photo', () {
    IntakePhoto shared(void Function() settled, {int delivery = 1}) =>
        IntakePhoto(Uint8List.fromList([1, 2, 3]), '', 'IMG_1.jpg',
            deliberate: true, shareDelivery: delivery, onSettled: settled);

    test('the pipeline, once each verdict is reached: saved, not food, a '
        'transient failure, not allowed', () async {
      final outcomes = [
        _meal,
        const AnalysisOutcome(
            analysis: {'is_food': false}, isFood: false, wall: Duration.zero),
        const AnalysisOutcome(
            error: 'Network error', retryable: true, wall: Duration.zero),
      ];
      for (final outcome in outcomes) {
        var settled = 0;
        final controller = StreamController<IntakePhoto>();
        final pipeline = PhotoPipeline(
            dao: FakeDao(),
            analyzer: FakeAnalyzer()..nextPhotoOutcome = outcome,
            hasher: (b) async => 'h${outcome.hashCode}',
            thumbnailer: (_) async => null);
        pipeline.bindStream(controller.stream);
        controller.add(shared(() => settled++));
        await pumpEventQueue(times: 50);
        // A save settles as its meal row is written and again once
        // process() returns; the share intake acts on the first call only.
        expect(settled, outcome == _meal ? 2 : 1,
            reason: '${outcome.analysis ?? outcome.error}');
        await pipeline.dispose();
      }
      // The recipient was not allowed at the photo's turn: let go unsent.
      var settled = 0;
      final controller = StreamController<IntakePhoto>();
      final analyzerCalls = <int>[];
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()
            ..onAnalyze = () async => analyzerCalls.add(1),
          sendGate: AiSendGate(allowed: () => false),
          hasher: (b) async => 'h',
          thumbnailer: (_) async => null);
      pipeline.bindStream(controller.stream);
      controller.add(shared(() => settled++));
      await pumpEventQueue(times: 50);
      expect(settled, 1);
      expect(analyzerCalls, isEmpty);
      await pipeline.dispose();
    });

    test('the pipeline does not settle a photo still being analyzed',
        () async {
      var settled = 0;
      final reply = Completer<void>();
      final controller = StreamController<IntakePhoto>();
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()..onAnalyze = () => reply.future,
          hasher: (b) async => 'h',
          thumbnailer: (_) async => null);
      pipeline.bindStream(controller.stream);
      controller.add(shared(() => settled++));
      await pumpEventQueue(times: 50);
      expect(settled, 0);
      reply.complete();
      await pumpEventQueue(times: 50);
      expect(settled, 1);
      await pipeline.dispose();
    });

    test('the consent gate, for a photo it drops: Not now, a share already '
        'declined, a dialog that failed; never for one it passes', () async {
      final settings = FakeSettings()..aiConsent = {};
      final gate = SharedPhotoConsentGate(settings);
      final controller = StreamController<IntakePhoto>();
      final passed = <IntakePhoto>[];
      final sub = gate.gate(controller.stream).listen(passed.add);
      final settled = <String>[];
      var answer = 0;
      gate.attach(() async {
        answer++;
        if (answer == 1) return false; // Not now
        if (answer == 2) throw StateError('no navigator');
        settings.aiConsent = {...allAiConsentRoutes};
        return true;
      });
      controller
        ..add(shared(() => settled.add('a'), delivery: 1))
        ..add(shared(() => settled.add('a2'), delivery: 1))
        ..add(shared(() => settled.add('b'), delivery: 2))
        ..add(shared(() => settled.add('c'), delivery: 3));
      await pumpEventQueue(times: 100);
      expect(settled, ['a', 'a2', 'b'],
          reason: 'Not now, its share, the failed dialog');
      expect(passed, hasLength(1), reason: 'c was allowed');
      await sub.cancel();
    });
  });
}
