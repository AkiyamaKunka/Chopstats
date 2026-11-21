/// The analysis keep-alive (owner decision 9, option 1, 2026-11-20): every
/// analysis the user starts on Android counts from its start to its end,
/// whatever it comes to, so MainActivity's WorkManager job keeps the
/// process running and online exactly that long. A begin never ended would
/// keep the process up for the full cap after the last request settled; an
/// end without its begin could end another request's keep-alive early.
library;

import 'dart:async';
import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/services/analysis_keep_alive.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart'
    show ServerAnalyzer;
import 'package:calorie_tracker/services/nl/executor.dart'
    show DefaultNlExecutor;
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/fakes.dart';

/// MainActivity's side of the channel, as the tests see it: every begin
/// and end in order ([calls]), every call with the resets ([log]), and the
/// requests it holds open for the engine's session.
class _Native {
  final List<String> calls = [];
  final List<String> log = [];
  final Set<int> open = {};

  /// When set, every call fails (MainActivity missing a handler, say).
  bool fail = false;

  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'reset') {
      // AnalysisKeepAlive.drop: every request of this session goes.
      expect(call.arguments, isNull);
      log.add('reset');
      if (fail) throw PlatformException(code: 'unavailable');
      open.clear();
      return true;
    }
    final id = (call.arguments as Map)['id'] as int;
    calls.add('${call.method}:$id');
    log.add('${call.method}:$id');
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

    // A hot restart keeps the engine, and MainActivity's session with it
    // (no configure, no cleanup), while the ids start over at 1 (review
    // DL-3): the last run's request 1, never ended, kept the job up for its
    // full cap with nothing in flight, and this run's request 1 landed on
    // it, a repeated begin with the stale begin's time.
    test('built, it first drops what an earlier run of the engine left open, '
        'before any request of its own', () async {
      native.open.addAll({1, 2}); // the last run's, never ended
      final keep = AnalysisKeepAlive();
      final held = Completer<void>();
      final run = keep.guard(() => held.future);
      await _settle();
      expect(native.log, ['reset', 'begin:1']);
      expect(native.open, {1}, reason: 'only this run\'s own request 1');
      held.complete();
      await run;
      await _settle();
      expect(native.open, isEmpty);
      expect(native.log, ['reset', 'begin:1', 'end:1']);
      // One reset per instance, never again.
      await keep.guard(() async {});
      await _settle();
      expect(native.log.where((c) => c == 'reset'), hasLength(1));
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

    test('a picked photo is kept alive from its queueing to its verdict: '
        'its wait and, inside it, its turn', () async {
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
        {1, 2},
      ]);
      expect(native.calls, ['begin:1', 'begin:2', 'end:2', 'end:1']);
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
      expect(native.calls, ['begin:1', 'begin:2', 'end:2', 'end:1']);
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
        expect(native.calls, ['begin:1', 'begin:2', 'end:2', 'end:1']);
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
      expect(native.calls, ['begin:1', 'begin:2', 'end:2', 'end:1']);
    });

    // Review DL-1: each request's cap (3 minutes) counts from its begin. A
    // photo kept alive by one id from its queueing on spent its cap on the
    // photo ahead (often an automatic one, never kept itself): queued 5 s
    // in behind a 150 s photo, its own 60 s request lost the job at 185 s,
    // mid-request, and the process froze. Its turn is now a request of its
    // own, begun as the turn starts, inside the wait's.
    test('a picked photo queued behind an automatic one: its wait is kept '
        'alive at once, and its turn gets a request of its own as it starts',
        () async {
      final keep = AnalysisKeepAlive();
      final ahead = Completer<void>();
      final openDuringItsTurn = <Set<int>>[];
      var analyses = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = _food
        ..onAnalyze = () async {
          if (analyses++ == 0) {
            await ahead.future;
          } else {
            await _settle();
            openDuringItsTurn.add({...native.open});
          }
        };
      final p = pipeline(analyzer: analyzer, keepAlive: keep);
      final automatic = p.enqueue(_photo(1, deliberate: false));
      await _settle();
      final picked = p.enqueue(_photo(2));
      await _settle();
      expect(native.open, {1}, reason: 'begun at once, while it waits');
      expect(native.calls, ['begin:1'],
          reason: 'its turn has not started: the photo ahead is analyzed');
      ahead.complete();
      await automatic;
      expect((await picked).kind, PhotoOutcomeKind.saved);
      await _settle();
      expect(openDuringItsTurn, [
        {1, 2},
      ], reason: 'its own request from the start of its turn');
      expect(native.calls, ['begin:1', 'begin:2', 'end:2', 'end:1']);
      expect(native.open, isEmpty);
      expect(keep.inFlight.value, isFalse);
    });

    test('photos queued behind one another: each waits under its own id and '
        'is analyzed under another, FIFO, all ended', () async {
      final keep = AnalysisKeepAlive();
      final first = Completer<void>();
      var analyses = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = _food
        ..onAnalyze = () async {
          if (analyses++ == 0) await first.future;
        };
      final dao = FakeDao();
      final p = pipeline(analyzer: analyzer, dao: dao, keepAlive: keep);
      final a = p.enqueue(_photo(1));
      final b = p.enqueue(_photo(2));
      await _settle();
      // A: waited (1) and in its turn (3); B: waiting (2).
      expect(native.calls, ['begin:1', 'begin:2', 'begin:3']);
      expect(native.open, {1, 2, 3});
      first.complete();
      expect((await a).kind, PhotoOutcomeKind.saved);
      expect((await b).kind, PhotoOutcomeKind.saved);
      await _settle();
      expect(native.calls, [
        'begin:1', 'begin:2', 'begin:3', //
        'end:3', 'end:1', // A's turn, then its wait
        'begin:4', 'end:4', 'end:2', // B's turn, then its wait
      ]);
      expect(native.open, isEmpty);
      expect(dao.meals, hasLength(2));
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
      await _until(() => settled.length == 3 && native.calls.length == 12);
      await shares.close();
      await _settle();
      expect(dao.meals, hasLength(3));
      // Each photo: its wait, and inside it its turn.
      expect(native.calls, [
        'begin:1', 'begin:2', 'end:2', 'end:1', //
        'begin:3', 'begin:4', 'end:4', 'end:3', //
        'begin:5', 'begin:6', 'end:6', 'end:5',
      ]);
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

  // The own server's upload key goes only to the host it was saved for
  // (review of PR 74): ServerAnalyzer refuses a key saved for another
  // address before it decodes or sends, and HttpsOnlyServerClient checks
  // every send again, for a request that read its key before the server
  // changed. Either refusal comes back as the request's answer, like any
  // other failure, so the keep-alive request around it ends with it: a
  // refused stale key leaves no job keeping the process up for its cap.
  group('an upload key saved for another server address', () {
    late List<http.BaseRequest> seen;
    setUp(() => seen = []);

    /// The own server on the Claude plan, allowed, its upload key saved at
    /// https://a.example; with [movedTo], the address then moved there, so
    /// the key is a.example's alone.
    Future<AppSettings> ownServer({String? movedTo}) async {
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: _MemoryKeyStore());
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('upload-key');
      await s.setAiConsent('server:claude', granted: true);
      if (movedTo != null) await s.setServerBaseUrl(movedTo);
      return s;
    }

    /// The real analyzer behind its HttpsOnlyServerClient; a request that
    /// got through would be answered with a meal.
    ServerAnalyzer server(AppSettings s,
            {Future<Uint8List?> Function(Uint8List)? normalizer}) =>
        ServerAnalyzer(s,
            normalizer: normalizer ?? (b) async => b,
            sleep: (_) async {},
            client: MockClient((req) async {
              seen.add(req);
              return http.Response(
                  jsonEncode({
                    'is_food': true,
                    'meal_description': 'Ramen',
                    'total_calories': 600,
                  }),
                  200);
            }));

    final jpeg = Uint8List.fromList([1, 2, 3, 4]);

    test('a picked photo: refused before anything is sent; its wait and its '
        'turn both end', () async {
      final keep = AnalysisKeepAlive();
      final s = await ownServer(movedTo: 'https://b.example');
      final p = PhotoPipeline(
          dao: FakeDao(),
          analyzer: server(s),
          keepAlive: keep,
          hasher: (b) async => 'h${b.first}',
          thumbnailer: (_) async => null);
      final outcome = await p.enqueue(_photo(1));
      await _settle();
      expect(outcome.kind, PhotoOutcomeKind.failed);
      expect(outcome.errorKind, AnalysisErrorKind.noServerKey);
      expect(outcome.retryable, isTrue, reason: "kept for this server's key");
      expect(seen, isEmpty);
      expect(native.calls, ['begin:1', 'begin:2', 'end:2', 'end:1']);
      expect(native.open, isEmpty);
      expect(keep.inFlight.value, isFalse);
    });

    test('a typed meal and a Fix meals request: each refused, nothing sent, '
        'each ended', () async {
      final keep = AnalysisKeepAlive();
      final s = await ownServer(movedTo: 'https://b.example');
      final l = AppLocalizationsEn();
      final executor = KeptAliveExecutor(
          DefaultNlExecutor(FakeDao(), server(s), s, l10n: l), keep);
      expect((await executor.describeMeal('a bowl of rice')).error,
          '❌ ${l.errServerKeyOtherHost}');
      expect((await executor.handleText('the rice was 200 g')).single.text,
          '❌ ${l.errServerKeyOtherHost}');
      await _settle();
      expect(seen, isEmpty);
      expect(native.calls, ['begin:1', 'end:1', 'begin:2', 'end:2']);
      expect(native.open, isEmpty);
    });

    test('a leftover estimate: refused before its decode; its request ends',
        () async {
      final keep = AnalysisKeepAlive();
      final s = await ownServer(movedTo: 'https://b.example');
      var decodes = 0;
      final analyzer = server(s, normalizer: (b) async {
        decodes++;
        return b;
      });
      expect(await keep.guard(() => analyzer.leftoverIntent(jpeg, '{}')),
          isNull);
      await _settle();
      expect(decodes, 0);
      expect(seen, isEmpty);
      expect(native.calls, ['begin:1', 'end:1']);
      expect(native.open, isEmpty);
    });

    // The race the client's own check is for: the estimate read its key,
    // then a setup link put another server and its key in place while the
    // photo decoded, so the analyzer's check was already behind it. Its
    // request, built with the previous key for the new host, is refused at
    // the send, and the estimate answers null as for any failed call.
    test('a leftover estimate whose server changed while its photo decoded: '
        'the client refuses the previous key, and its request still ends',
        () async {
      final keep = AnalysisKeepAlive();
      final s = await ownServer();
      var decodes = 0;
      final analyzer = server(s, normalizer: (b) async {
        if (decodes++ == 0) {
          await s.applyServerSetup(
              backend: 'claude', baseUrl: 'https://b.example', key: 'key-b');
        }
        return b;
      });
      expect(await keep.guard(() => analyzer.leftoverIntent(jpeg, '{}')),
          isNull);
      await _settle();
      expect(decodes, 1, reason: "past the analyzer's own check");
      expect(seen, isEmpty, reason: "a.example's key went nowhere");
      expect(native.calls, ['begin:1', 'end:1']);
      expect(native.open, isEmpty);
      expect(keep.inFlight.value, isFalse);

      // The next estimate reads b.example's own key, and goes there.
      await keep.guard(() => analyzer.leftoverIntent(jpeg, '{}'));
      await _settle();
      expect(seen.single.url.host, 'b.example');
      expect(seen.single.headers['X-API-Key'], 'key-b');
      expect(native.calls, ['begin:1', 'end:1', 'begin:2', 'end:2']);
      expect(native.open, isEmpty);
    });
  });
}

class _MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
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
