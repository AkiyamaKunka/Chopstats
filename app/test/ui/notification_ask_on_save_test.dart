/// Android 13+'s notification permission after the first meal saved, by
/// any path (review 2026-11-19, R2/R3): Describe, Enter manually, a
/// refused photo's Log manually and My usual foods save without the photo
/// pipeline, so its hook never asked, and the daily summary — on by
/// default — was dropped by the OS every night. Driven through the real
/// shell, with the trigger on the meals-changed signal as di.dart puts it
/// (production_wiring_test pins that line).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/report/notification_permission.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  late int requests;
  VoidCallback? trigger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = 0;
    debugRequestNotificationPermission = () async {
      requests++;
      return false;
    };
  });

  tearDown(() {
    debugRequestNotificationPermission = null;
    final t = trigger;
    if (t != null) mealsChangedSignal.removeListener(t);
    trigger = null;
  });

  /// The trigger as di.dart wires it.
  void wireAsDiDart(BaseFakeDao dao, FakeSettings settings) {
    final t = trigger = () => unawaited(
      askNotificationPermissionAfterMealSaved(
        notifies: () => settings.summaryEnabled || settings.watcherEnabled,
        hasMeal: () async => (await dao.backupCounts()).meals > 0,
      ),
    );
    mealsChangedSignal.addListener(t);
  }

  Future<void> boot(WidgetTester tester, UiServices services) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    wireAsDiDart(
      services.dao as BaseFakeDao,
      services.settings as FakeSettings,
    );
    await tester.pumpWidget(CalorieTrackerApp(services: services));
    await tester.pumpAndSettle();
  }

  Future<void> openSheetAndTap(WidgetTester tester, String row) async {
    await tester.tap(find.byKey(const Key('addMealFab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(row)));
    await tester.pumpAndSettle();
  }

  Future<void> enterManually(WidgetTester tester, {String kcal = '650'}) async {
    await openSheetAndTap(tester, 'addManually');
    await tester.enterText(find.byKey(const Key('editorCalories')), kcal);
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
  }

  final android = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets('Enter manually → Save asks once', (tester) async {
    final dao = FakeDao();
    await boot(tester, makeServices(dao: dao, settings: FakeSettings()));
    expect(requests, 0, reason: 'never at launch');
    await enterManually(tester);
    expect(dao.saved, hasLength(1));
    expect(requests, 1);
  }, variant: android);

  testWidgets('Describe → preview → Save asks once', (tester) async {
    final dao = FakeDao();
    await boot(tester, makeServices(dao: dao, settings: FakeSettings()));
    await openSheetAndTap(tester, 'addFromText');
    await tester.enterText(
      find.byKey(const Key('addTextField')),
      'beef noodle soup',
    );
    await tester.tap(find.byKey(const Key('addTextSend')));
    await tester.pumpAndSettle();
    expect(requests, 0, reason: 'the preview saved nothing yet');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    expect(dao.saved.single.source, MealSource.manualText);
    expect(requests, 1);
  }, variant: android);

  testWidgets('a photo the AI refused → Log manually → Save asks once', (
    tester,
  ) async {
    final dao = FakeDao();
    await boot(
      tester,
      makeServices(
        dao: dao,
        settings: FakeSettings(),
        picker: FakePicker()
          ..photos = [
            IntakePhoto(
              Uint8List.fromList(List.filled(16, 3)),
              'a0',
              'a0.jpg',
              capturedAt: DateTime.now(),
            ),
          ],
        processPhoto: (_) async =>
            const PhotoOutcome(PhotoOutcomeKind.skipped, 'not food'),
      ),
    );
    await openSheetAndTap(tester, 'addFromPhotos');
    await tester.tap(find.byKey(const Key('recentPhoto0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logManuallyButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editorCalories')), '420');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    // The save makes the meal's thumbnail from the photo: real decoding.
    for (
      var i = 0;
      i < 100 && find.byKey(const Key('addMealFab')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(dao.saved, hasLength(1));
    expect(requests, 1);
  }, variant: android);

  testWidgets('My usual foods → one tap asks once', (tester) async {
    final dao = FakeDao();
    final now = DateTime.now();
    for (final (id, daysAgo) in [(10, 3), (11, 5)]) {
      dao.seed(
        foodMeal(
          id: id,
          date: isoDate(now.subtract(Duration(days: daysAgo))),
          description: 'Greek yogurt',
          items: [foodItem('Greek yogurt', 150, p: 8, c: 12, f: 4)],
        ),
      );
    }
    // As di.dart builds it: a log signals the meals changed.
    final usual = await makeUsualFoods(
      dao,
      clock: DateTime.now,
      signal: mealsChangedSignal,
    );
    await boot(
      tester,
      makeServices(dao: dao, settings: FakeSettings(), usualFoods: usual),
    );
    await openSheetAndTap(tester, 'addUsual');
    expect(requests, 0);
    await tester.tap(find.text('Greek yogurt').first);
    await tester.pumpAndSettle();
    expect(
      dao.meals.where((m) => m.source == MealSource.appRepeat),
      hasLength(1),
    );
    expect(requests, 1);
  }, variant: android);

  testWidgets('a second save asks nothing more', (tester) async {
    final dao = FakeDao();
    await boot(tester, makeServices(dao: dao, settings: FakeSettings()));
    await enterManually(tester);
    await enterManually(tester, kcal: '300');
    expect(dao.saved, hasLength(2));
    expect(requests, 1, reason: 'two denials would be permanent');
  }, variant: android);

  testWidgets('an add screen left without saving asks nothing', (tester) async {
    final dao = FakeDao();
    await boot(tester, makeServices(dao: dao, settings: FakeSettings()));
    await openSheetAndTap(tester, 'addManually');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('discardChangesDialog')),
      findsNothing,
      reason: 'nothing typed, nothing to discard',
    );
    expect(dao.saved, isEmpty);
    expect(requests, 0, reason: 'no meal was saved');
  }, variant: android);

  testWidgets('with the summary and the watcher off nothing is asked', (
    tester,
  ) async {
    final dao = FakeDao();
    await boot(
      tester,
      makeServices(
        dao: dao,
        settings: FakeSettings(summaryEnabled: false, watcherEnabled: false),
      ),
    );
    await enterManually(tester);
    expect(dao.saved, hasLength(1));
    expect(requests, 0);
  }, variant: android);

  testWidgets(
    'iOS asks nothing (it asks at start, as before)',
    (tester) async {
      final dao = FakeDao();
      await boot(tester, makeServices(dao: dao, settings: FakeSettings()));
      await enterManually(tester);
      expect(dao.saved, hasLength(1));
      expect(requests, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
