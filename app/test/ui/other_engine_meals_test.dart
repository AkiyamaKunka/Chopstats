// A meal the background run saves while the app is open (2026-11-28).
//
// The meals-changed signal belongs to one engine, and the background run
// is another: its save reached no listener, so Today kept showing what it
// had loaded until the next return to the app, a tab tap or a save of the
// app's own. On 2026-11-27 the app was opened while a run was analyzing a
// photo, and went on showing 0 kcal.
//
// The run now leaves a note (refresh_signal.dart), and the app looks for
// it: when it returns to the foreground, after each photo of its own scan,
// and every ten seconds while Today is on screen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Directory root;
  var now = DateTime.utc(2026, 11, 27, 14, 24);

  /// One engine's view of the store both engines share (each builds its
  /// own LocalNoBackupStore over the same folder).
  LocalNoBackupStore engineStore() =>
      LocalNoBackupStore(root: () async => root, createMissingDirectory: true);

  setUp(() {
    root = Directory.systemTemp.createTempSync('other_engine_meals');
    now = DateTime.utc(2026, 11, 27, 14, 24);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// The background run saves a meal [later] after the last one.
  Future<void> backgroundSaves({Duration later = const Duration(seconds: 1)}) {
    now = now.add(later);
    return noteMealsChangedForOtherEngine(engineStore(), clock: () => now);
  }

  group('the note and the look', () {
    late int signals;
    OtherEngineMeals app({Duration minGap = Duration.zero}) => OtherEngineMeals(
      store: engineStore(),
      onChanged: () => signals++,
      minGap: minGap,
      clock: () => now,
    );

    setUp(() => signals = 0);

    test('a save by the other engine is noticed once', () async {
      final watch = app();
      await watch.prime();
      expect(await watch.check(), isFalse, reason: 'nothing happened yet');
      await backgroundSaves();
      expect(await watch.check(), isTrue);
      expect(signals, 1);
      expect(await watch.check(), isFalse, reason: 'the same note');
      expect(await watch.check(), isFalse);
      expect(signals, 1, reason: 'one save, one reload');
      await backgroundSaves();
      expect(await watch.check(), isTrue);
      expect(signals, 2);
    });

    test('what was saved before the app started is not news: the screens '
        'load it anyway', () async {
      await backgroundSaves();
      final watch = app();
      await watch.prime();
      expect(await watch.check(), isFalse);
      expect(signals, 0);
    });

    test('a launch that could not prime takes its first look as the '
        'baseline', () async {
      await backgroundSaves();
      final watch = app();
      expect(await watch.check(), isFalse);
      expect(signals, 0);
      await backgroundSaves();
      expect(await watch.check(), isTrue);
      expect(signals, 1);
    });

    // The app's own scan asks after every photo, dozens a second while it
    // walks photos that are already logged.
    test('at most one look every minGap, unless forced', () async {
      final watch = app(minGap: const Duration(seconds: 2));
      await watch.prime();
      expect(await watch.check(), isFalse); // a look: the gap starts here
      await backgroundSaves(later: const Duration(milliseconds: 500));
      expect(await watch.check(), isFalse, reason: 'too soon to look again');
      expect(signals, 0);
      expect(await watch.check(force: true), isTrue);
      expect(signals, 1);
      await backgroundSaves(later: const Duration(seconds: 3));
      expect(await watch.check(), isTrue, reason: 'the gap has passed');
      expect(signals, 2);
    });

    test('looks asked for at once are one look and one signal', () async {
      final watch = app();
      await watch.prime();
      await backgroundSaves();
      final looks = [
        watch.check(force: true),
        watch.check(force: true),
        watch.check(),
      ];
      expect(await Future.wait(looks), [true, true, true]);
      expect(signals, 1);
    });

    test('a store that cannot be read, or a listener that throws: never a '
        'throw, never a signal that was not earned', () async {
      final broken = OtherEngineMeals(
        store: LocalNoBackupStore(
          root: () async => throw const FileSystemException('no folder'),
          createMissingDirectory: false,
        ),
        onChanged: () => signals++,
        minGap: Duration.zero,
      );
      await broken.prime();
      expect(await broken.check(), isFalse);
      expect(signals, 0);
      // Writing where nothing can be written is not a throw either.
      await noteMealsChangedForOtherEngine(broken.store);

      final watch = OtherEngineMeals(
        store: engineStore(),
        onChanged: () => throw StateError('listener'),
        minGap: Duration.zero,
      );
      await watch.prime();
      await backgroundSaves();
      expect(await watch.check(), isTrue);
    });

    test('the note is a time and nothing else', () async {
      await backgroundSaves();
      final file = File(
        '${root.path}/$localStoreDirName/$mealsChangedDocument.json',
      );
      expect(jsonDecode(file.readAsStringSync()), {
        'v': mealsChangedDocumentVersion,
        'at': now.toIso8601String(),
      });
    });

    test(
      'by default it sends this engine\'s own meals-changed signal',
      () async {
        final watch = OtherEngineMeals(store: engineStore());
        await watch.prime();
        final before = mealsChangedSignal.value;
        await backgroundSaves();
        expect(await watch.check(), isTrue);
        expect(mealsChangedSignal.value, before + 1);
      },
    );
  });

  // The run's pipeline, as _runAfterLaunch builds it (production_wiring
  // _test pins the argument): its save hook leaves the note.
  group('the background run\'s pipeline leaves the note', () {
    PhotoPipeline runPipeline(FakeDao dao, FakeAnalyzer analyzer) {
      final store = engineStore();
      return PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        onMealSaved: () =>
            unawaited(noteMealsChangedForOtherEngine(store, clock: () => now)),
        hasher: (b) async => 'hash-${b.join()}',
      );
    }

    IntakePhoto photo(int n) =>
        IntakePhoto(Uint8List.fromList([n, n, n]), 'asset$n', 'IMG_$n.jpg');

    late int signals;
    late OtherEngineMeals app;

    setUp(() async {
      signals = 0;
      app = OtherEngineMeals(
        store: engineStore(),
        onChanged: () => signals++,
        minGap: Duration.zero,
      );
      await app.prime();
    });

    test('a meal saved there is noticed here, once', () async {
      final dao = FakeDao();
      final out = await runPipeline(
        dao,
        FakeAnalyzer()
          ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': true, 'food_items': []},
            isFood: true,
            wall: Duration.zero,
          ),
      ).process(photo(1));
      expect(out.kind, PhotoOutcomeKind.saved);
      await pumpEventQueue();
      // The note is written off the pipeline's path: wait for the file.
      for (var i = 0; i < 200 && !await app.check(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(signals, 1);
      expect(await app.check(), isFalse);
      expect(signals, 1);
    });

    test('a photo that is not food, or a failed one, leaves none', () async {
      final dao = FakeDao();
      await runPipeline(
        dao,
        FakeAnalyzer()
          ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': false},
            isFood: false,
            wall: Duration.zero,
          ),
      ).process(photo(1));
      await runPipeline(
        dao,
        FakeAnalyzer()
          ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'Error contacting the provider (network or service issue).',
            retryable: true,
            wall: Duration.zero,
          ),
      ).process(photo(2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await app.check(), isFalse);
      expect(signals, 0);
      expect(
        File(
          '${root.path}/$localStoreDirName/$mealsChangedDocument.json',
        ).existsSync(),
        isFalse,
      );
    });
  });

  // ui/app.dart: the shell looks at each return to the app and every ten
  // seconds while Today is on screen, and reloads Today once per find.
  group('HomeShell looks for the other engine\'s saves', () {
    late int todayReloads;
    late int looks;

    /// What the next look answers: true is "a new note", and the look
    /// then sends the meals-changed signal, as OtherEngineMeals does.
    late bool found;

    UiServices services({bool hook = true}) => UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: FakeSettings(apiKey: 'k', watcherEnabled: false),
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      // Today asks for the day's activity once per reload.
      garminDaily: (_) async {
        todayReloads++;
        return null;
      },
      mealsChangedElsewhere: hook
          ? () async {
              looks++;
              if (!found) return false;
              found = false;
              signalMealsChanged();
              return true;
            }
          : null,
    );

    setUp(() {
      todayReloads = 0;
      looks = 0;
      found = false;
    });

    Future<void> open(WidgetTester tester, {bool hook = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(services: services(hook: hook)),
        ),
      );
      await tester.pump();
      expect(todayReloads, 1, reason: 'Today\'s first load');
    }

    testWidgets('every ten seconds while Today is on screen; a find reloads '
        'Today once', (tester) async {
      await open(tester);
      await tester.pump(const Duration(seconds: 9));
      expect(looks, 0);
      await tester.pump(const Duration(seconds: 1));
      expect((looks, todayReloads), (1, 1), reason: 'looked, found nothing');
      found = true; // the background run saves a meal
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect((looks, todayReloads), (2, 2));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect((looks, todayReloads), (3, 2), reason: 'reloaded once, not again');
    });

    testWidgets('not from another tab', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await open(tester);
      await tester.tap(find.byIcon(Icons.settings_outlined).first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(looks, 0, reason: 'Settings shows no meals');
    });

    testWidgets('not while the app is in the background; a return looks at '
        'once and starts the ten seconds again', (tester) async {
      await open(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(seconds: 60));
      expect(looks, 0);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(looks, 1, reason: 'the return\'s own look');
      await tester.pump(const Duration(seconds: 10));
      expect(looks, 2);
    });

    testWidgets('a return to the app reloads Today once, whether the look '
        'finds a save or not', (tester) async {
      await open(tester);
      // Nothing was saved meanwhile: the plain reload.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect((looks, todayReloads), (1, 2));
      // The background run saved a meal meanwhile: the signal's reload,
      // and no second one on top of it.
      found = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect((looks, todayReloads), (2, 3));
    });

    testWidgets('a look that never answers does not hold the return\'s '
        'reload', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            services: UiServices(
              dao: FakeDao(),
              analyzer: FakeAnalyzer(),
              executor: FakeExecutor(),
              settings: FakeSettings(apiKey: 'k', watcherEnabled: false),
              picker: FakePicker(),
              requestPhotoPermission: () async => true,
              garminDaily: (_) async {
                todayReloads++;
                return null;
              },
              mealsChangedElsewhere: () => Completer<bool>().future,
            ),
          ),
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(todayReloads, 1, reason: 'still waiting for the look');
      await tester.pump(const Duration(seconds: 2));
      expect(todayReloads, 2);
    });

    // Tests, and the Play build: exactly as before.
    testWidgets('no hook: no timer, and a return reloads Today at once', (
      tester,
    ) async {
      await open(tester, hook: false);
      await tester.pump(const Duration(seconds: 30));
      expect(looks, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(todayReloads, 2, reason: 'in the same turn, as it always was');
    });
  });
}
