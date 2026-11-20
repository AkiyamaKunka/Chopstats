/// The analysis keep-alive (owner decision 9, option 1, 2026-11-20): every
/// analysis the user starts on Android counts from its start to its end,
/// whatever it comes to, so MainActivity's WorkManager job keeps the
/// process running and online exactly that long. A begin never ended would
/// keep the process up for the full cap after the last request settled; an
/// end without its begin could end another request's keep-alive early.
library;

import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/services/analysis_keep_alive.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/fakes.dart';

/// MainActivity's side of the channel, as the tests see it: every call in
/// order, and the requests it holds open.
class _Native {
  final List<String> calls = [];
  final Set<int> open = {};

  /// When set, every call fails (MainActivity missing a handler, say).
  bool fail = false;

  Future<Object?> handle(MethodCall call) async {
    final id = (call.arguments as Map)['id'] as int;
    calls.add('${call.method}:$id');
    if (fail) throw PlatformException(code: 'unavailable');
    switch (call.method) {
      case 'begin':
        expect(open.add(id), isTrue, reason: 'request $id begun twice');
      case 'end':
        expect(open.remove(id), isTrue,
            reason: 'request $id ended, never begun or ended already');
      default:
        fail = true;
        throw MissingPluginException();
    }
    return true;
  }
}

IntakePhoto _photo(int n, {bool deliberate = true}) => IntakePhoto(
    Uint8List.fromList([n, n, n]), 'asset$n', 'IMG_$n.jpg',
    deliberate: deliberate);

const _food = AnalysisOutcome(
    analysis: {'is_food': true, 'meal_description': 'Ramen',
        'total_calories': 600},
    isFood: true,
    wall: Duration.zero);

/// Lets the channel's replies and the pipeline's awaits run.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(keepAliveChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Native native;

  setUp(() {
    native = _Native();
    messenger.setMockMethodCallHandler(channel, native.handle);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('AnalysisKeepAlive.guard', () {
    test('begins before the body, ends after it, and hands its value back',
        () async {
      final keep = AnalysisKeepAlive();
      final seen = <String>[];
      final out = await keep.guard(() async {
        await _settle();
        seen.add('body: ${native.open} open, in flight ${keep.inFlight.value}');
        return 42;
      });
      await _settle();
      expect(out, 42);
      expect(seen, ['body: {1} open, in flight true']);
      expect(native.calls, ['begin:1', 'end:1']);
      expect(native.open, isEmpty);
      expect(keep.inFlight.value, isFalse);
      expect(keep.openCount, 0);
    });

    test('a body that fails still ends, and its error comes through',
        () async {
      final keep = AnalysisKeepAlive();
      await expectLater(
          keep.guard<void>(() async => throw StateError('network')),
          throwsStateError);
      // Thrown before the body's first await, too.
      await expectLater(
          keep.guard<int>(() => throw ArgumentError('bad')),
          throwsArgumentError);
      await _settle();
      expect(native.calls, ['begin:1', 'end:1', 'begin:2', 'end:2']);
      expect(native.open, isEmpty);
      expect(keep.inFlight.value, isFalse);
    });

    test('requests overlap: in flight until the last one ends; each id once',
        () async {
      final keep = AnalysisKeepAlive();
      final first = Completer<String>();
      final second = Completer<String>();
      final changes = <bool>[];
      keep.inFlight.addListener(() => changes.add(keep.inFlight.value));
      final a = keep.guard(() => first.future);
      final b = keep.guard(() => second.future);
      await _settle();
      expect(native.open, {1, 2});
      expect(keep.openCount, 2);
      second.complete('b');
      expect(await b, 'b');
      await _settle();
      expect(native.open, {1});
      expect(keep.inFlight.value, isTrue);
      first.complete('a');
      expect(await a, 'a');
      await _settle();
      expect(native.open, isEmpty);
      expect(changes, [true, false]);
      expect(native.calls, ['begin:1', 'begin:2', 'end:2', 'end:1']);
    });

    test('MainActivity missing or failing: the body runs, nothing throws, '
        'and the engine still counts it', () async {
      final keep = AnalysisKeepAlive();
      messenger.setMockMethodCallHandler(channel, null);
      expect(await keep.guard(() async => 'ran'), 'ran');
      native.fail = true;
      messenger.setMockMethodCallHandler(channel, native.handle);
      final held = Completer<void>();
      final run = keep.guard(() => held.future);
      await _settle();
      expect(keep.inFlight.value, isTrue,
          reason: 'Back still keeps the app while it runs');
      held.complete();
      await run;
      await _settle();
      expect(keep.inFlight.value, isFalse);
      expect(native.calls, ['begin:2', 'end:2']);
    });
  });

  group('KeptAliveExecutor', () {
    test('a typed meal (Describe) is kept alive while the model answers',
        () async {
      final keep = AnalysisKeepAlive();
      final inner = FakeExecutor();
      final gate = Completer<void>();
      final executor = KeptAliveExecutor(_HeldExecutor(inner, gate), keep);
      final out = executor.describeMeal('two eggs');
      await _settle();
      expect(native.open, {1});
      gate.complete();
      expect((await out).ok, isTrue);
      await _settle();
      expect(inner.describedTexts, ['two eggs']);
      expect(native.calls, ['begin:1', 'end:1']);
      expect(native.open, isEmpty);
    });

    test('a Fix meals request is kept alive until its writes are done',
        () async {
      final keep = AnalysisKeepAlive();
      final inner = FakeExecutor();
      final gate = Completer<void>();
      final executor = KeptAliveExecutor(_HeldExecutor(inner, gate), keep);
      final out = executor.handleText('the rice was 200 g');
      await _settle();
      expect(native.open, {1});
      gate.complete();
      expect(await out, inner.nextReplies);
      await _settle();
      expect(native.calls, ['begin:1', 'end:1']);
    });

    test('a request that throws still ends', () async {
      final keep = AnalysisKeepAlive();
      final executor = KeptAliveExecutor(_ThrowingExecutor(), keep);
      await expectLater(executor.describeMeal('x'), throwsStateError);
      await expectLater(executor.handleText('x'), throwsStateError);
      await _settle();
      expect(native.calls, ['begin:1', 'end:1', 'begin:2', 'end:2']);
      expect(native.open, isEmpty);
    });

    test("a delete's confirmation sends nothing, so it is not counted",
        () async {
      final inner = FakeExecutor();
      final executor = KeptAliveExecutor(inner, AnalysisKeepAlive());
      expect(await executor.confirmPendingDelete([3]), 'Deleted.');
      await _settle();
      expect(inner.confirmedDeletes, [
        [3],
      ]);
      expect(native.calls, isEmpty);
    });
  });

  group('PhotoPipeline', () {
    PhotoPipeline pipeline(
            {required AnalyzerService analyzer,
            FakeDao? dao,
            AiSendGate? sendGate,
            AnalysisKeepAlive? keepAlive}) =>
        PhotoPipeline(
            dao: dao ?? FakeDao(),
            analyzer: analyzer,
            sendGate: sendGate,
            keepAlive: keepAlive,
            hasher: (b) async => 'h${b.first}',
            thumbnailer: (_) async => null);

    test('a picked photo is kept alive from its queueing to its verdict',
        () async {
      final keep = AnalysisKeepAlive();
      final openDuringAnalysis = <Set<int>>[];
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = _food
        ..onAnalyze = () async {
          await _settle();
          openDuringAnalysis.add({...native.open});
        };
      final dao = FakeDao();
      final p = pipeline(analyzer: analyzer, dao: dao, keepAlive: keep);
      final outcome = await p.enqueue(_photo(1));
      await _settle();
      expect(outcome.kind, PhotoOutcomeKind.saved);
      expect(dao.meals, hasLength(1));
      expect(openDuringAnalysis, [
        {1},
      ]);
      expect(native.calls, ['begin:1', 'end:1']);
      expect(keep.inFlight.value, isFalse);
    });

    test('an automatic photo (Watch Camera Roll) is never kept alive',
        () async {
      final keep = AnalysisKeepAlive();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _food;
      final p = pipeline(analyzer: analyzer, keepAlive: keep);
      final intake = _SinkIntake();
      p.bind(intake);
      expect(await intake.sink!(_photo(1, deliberate: false), null), isTrue);
      expect((await p.enqueue(_photo(2, deliberate: false))).kind,
          PhotoOutcomeKind.saved);
      await _settle();
      expect(native.calls, isEmpty);
    });

    test('a photo the AI consent no longer allows is let go: begun and '
        'ended', () async {
      final keep = AnalysisKeepAlive();
      final analyzer = FakeAnalyzer()
        ..onAnalyze = () async => fail('nothing may be sent');
      final p = pipeline(
          analyzer: analyzer,
          keepAlive: keep,
          sendGate: AiSendGate(allowed: () => false));
      final outcome = await p.enqueue(_photo(1));
      await _settle();
      expect(outcome.reason, notAllowedReason);
      expect(native.calls, ['begin:1', 'end:1']);
      expect(native.open, isEmpty);
    });

    for (final (name, result) in const [
      (
        'a transient failure (released)',
        AnalysisOutcome(
            error: 'Network error', retryable: true, wall: Duration.zero),
      ),
      (
        'a permanent failure',
        AnalysisOutcome(error: 'Bad request', wall: Duration.zero),
      ),
      ('not food', AnalysisOutcome(analysis: {'is_food': false},
          wall: Duration.zero)),
    ]) {
      test('$name: begun and ended', () async {
        final keep = AnalysisKeepAlive();
        final analyzer = FakeAnalyzer()..nextPhotoOutcome = result;
        final p = pipeline(analyzer: analyzer, keepAlive: keep);
        final outcome = await p.enqueue(_photo(1));
        await _settle();
        expect(outcome.kind, isNot(PhotoOutcomeKind.saved));
        expect(native.calls, ['begin:1', 'end:1']);
        expect(keep.inFlight.value, isFalse);
      });
    }

    test('an analyzer that throws is contained, and the photo still ends',
        () async {
      final keep = AnalysisKeepAlive();
      final analyzer = FakeAnalyzer()
        ..onAnalyze = () async => throw StateError('socket closed');
      final p = pipeline(analyzer: analyzer, keepAlive: keep);
      final outcome = await p.enqueue(_photo(1));
      await _settle();
      expect(outcome.kind, PhotoOutcomeKind.failed);
      expect(outcome.errorKind, isNot(AnalysisErrorKind.none));
      expect(native.calls, ['begin:1', 'end:1']);
    });

    test('a picked photo queued behind an automatic one is kept alive while '
        'it waits: the photo ahead must finish for its turn to come',
        () async {
      final keep = AnalysisKeepAlive();
      final ahead = Completer<void>();
      var analyses = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = _food
        ..onAnalyze = () async {
          if (analyses++ == 0) await ahead.future;
        };
      final p = pipeline(analyzer: analyzer, keepAlive: keep);
      final automatic = p.enqueue(_photo(1, deliberate: false));
      await _settle();
      final picked = p.enqueue(_photo(2));
      await _settle();
      expect(native.open, {1}, reason: 'begun at once, while it waits');
      ahead.complete();
      await automatic;
      expect((await picked).kind, PhotoOutcomeKind.saved);
      await _settle();
      expect(native.calls, ['begin:1', 'end:1']);
    });

    test('a share: each photo kept alive for its own turn, none left open',
        () async {
      final keep = AnalysisKeepAlive();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _food;
      final dao = FakeDao();
      final p = pipeline(analyzer: analyzer, dao: dao, keepAlive: keep);
      // A saved photo is settled at its save and again as its turn ends;
      // the share intake ignores the second call.
      final settled = <int>{};
      final shares = StreamController<IntakePhoto>();
      p.bindStream(shares.stream);
      for (var n = 1; n <= 3; n++) {
        shares.add(IntakePhoto(Uint8List.fromList([n, n]), 'share$n',
            'IMG_S$n.jpg',
            deliberate: true, onSettled: () => settled.add(n)));
      }
      await _until(() => settled.length == 3 && native.calls.length == 6);
      await shares.close();
      await _settle();
      expect(dao.meals, hasLength(3));
      expect(native.calls,
          ['begin:1', 'end:1', 'begin:2', 'end:2', 'begin:3', 'end:3']);
      expect(native.open, isEmpty);
      expect(keep.inFlight.value, isFalse);
    });

    test('without a keep-alive (iPhone, the background run) nothing is sent',
        () async {
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _food;
      final p = pipeline(analyzer: analyzer);
      expect((await p.enqueue(_photo(1))).kind, PhotoOutcomeKind.saved);
      await _settle();
      expect(native.calls, isEmpty);
    });
  });
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    expect(DateTime.now().isBefore(deadline), isTrue,
        reason: 'never reached the expected state');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// [inner], answering only once [gate] completes: the request in flight.
class _HeldExecutor implements NlExecutor {
  _HeldExecutor(this.inner, this.gate);
  final FakeExecutor inner;
  final Completer<void> gate;

  @override
  Future<DescribeOutcome> describeMeal(String text) async {
    await gate.future;
    return inner.describeMeal(text);
  }

  @override
  Future<List<NlReply>> handleText(String userText) async {
    await gate.future;
    return inner.handleText(userText);
  }

  @override
  Future<String> confirmPendingDelete(List<int> mealIds) =>
      inner.confirmPendingDelete(mealIds);
}

class _ThrowingExecutor implements NlExecutor {
  @override
  Future<DescribeOutcome> describeMeal(String text) async =>
      throw StateError('boom');

  @override
  Future<List<NlReply>> handleText(String userText) async =>
      throw StateError('boom');

  @override
  Future<String> confirmPendingDelete(List<int> mealIds) async => '';
}

/// Hands the test the sink `bind()` attaches (the watcher's path).
class _SinkIntake implements PhotoIntake {
  Future<bool> Function(IntakePhoto, DateTime?)? sink;
  @override
  Stream<IntakePhoto> get photos => const Stream.empty();
  @override
  void attachSink(Future<bool> Function(IntakePhoto, DateTime?)? s) =>
      sink = s;
  @override
  Future<DateTime?> backfillScan(
          {int lookbackDays = 0,
          DateTime? since,
          bool Function()? shouldContinue,
          Future<void> Function(DateTime safeFrontier)? onCovered,
          bool newestDayFirst = false}) async =>
      null;
  @override
  Future<void> lateImportScan({bool Function()? shouldContinue}) async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
