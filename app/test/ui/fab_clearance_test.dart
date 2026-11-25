// The end of a list clears its floating button on a page with no tab bar
// (1.8.0 release candidate, device check 2026-11-24). The button floats
// above the system's bottom inset, while the list ran under that inset with
// only the bare clearance: with Android's 3-button navigation (a 48 dp
// bar) Edit meal's last kept note, its ×, and the end of a landed answer
// lay 18 dp under Save, and a day's last meal row lay under its + button.
// Gesture navigation (a 24 dp inset) left them 6 dp clear.
import 'dart:math' show max;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/meal_correction.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Finder _key(String k) => find.byKey(Key(k));

/// The bottom insets this runs at, in dp: Android's 3-button bar, its
/// gesture handle, and none (a phone with no bar, or the keyboard up).
const _insets = [('3-button navigation', 48.0), ('gesture navigation', 24.0),
    ('no bottom inset', 0.0)];

/// A 1080 x 2400 phone at 420 dpi (411 x 914 dp) whose system bar at the
/// bottom is [bar] dp tall, with a keyboard [keyboard] dp tall up. As a
/// device reports them: the bar is view padding, and padding is what the
/// keyboard leaves of it.
void _phone(WidgetTester tester, {required double bar, double keyboard = 0}) {
  const dpr = 2.625;
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = dpr;
  tester.view.viewPadding = FakeViewPadding(top: 24 * dpr, bottom: bar * dpr);
  tester.view.padding = FakeViewPadding(
      top: 24 * dpr, bottom: max(0.0, bar - keyboard) * dpr);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
  addTearDown(tester.view.reset);
}

/// Scrolls [scrollable] to its very end: a lazy list's extent grows as the
/// children at its end are built.
Future<void> _toEnd(WidgetTester tester, Finder scrollable) async {
  final position = tester.state<ScrollableState>(scrollable).position;
  var extent = -1.0;
  for (var i = 0; i < 40 && position.maxScrollExtent != extent; i++) {
    extent = position.maxScrollExtent;
    position.jumpTo(extent);
    await tester.pump();
  }
  expect(position.pixels, position.maxScrollExtent);
}

Finder _scrollableIn(Type screen) => find
    .descendant(of: find.byType(screen), matching: find.byType(Scrollable))
    .first;

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );

Meal _meal(int id, {List<Object?>? notes}) => Meal(
      id: id,
      date: '2026-11-24',
      time: '12:30 PM',
      timestamp: '2026-11-24T12:30:00.000',
      source: MealSource.appPhoto,
      imageHash: 'h$id',
      analysis: {
        'is_food': true,
        'meal_description': 'Braised pork with rice',
        'total_calories': 660,
        'total_protein_g': 32,
        'total_carbs_g': 70,
        'total_fat_g': 26,
        'food_items': const [
          {
            'name': 'Steamed rice (~200 g)',
            'estimated_calories': 260,
            'protein_g': 5,
            'carbs_g': 57,
            'fat_g': 0.5,
          },
          {
            'name': 'Braised pork (~120 g)',
            'estimated_calories': 400,
            'protein_g': 27,
            'carbs_g': 13,
            'fat_g': 25.5,
          },
        ],
        kUserNotesKey: ?notes,
      },
    );

Future<FakeExecutor> _openEditor(WidgetTester tester, Meal meal) async {
  final dao = FakeDao()..seed(meal);
  final executor = FakeExecutor();
  await tester.pumpWidget(_host(MealEditorScreen(
    dao: dao,
    meal: dao.meals.first,
    now: () => DateTime(2026, 11, 24, 19, 5),
    settings: FakeSettings(apiKey: 'k'),
    noteCorrector: executor,
  )));
  await tester.pumpAndSettle();
  return executor;
}

void main() {
  group('Edit meal: the note section ends clear of Save', () {
    for (final (name, bar) in _insets) {
      testWidgets('the last kept note and its × ($name)', (tester) async {
        _phone(tester, bar: bar);
        await _openEditor(
            tester,
            _meal(1, notes: const [
              {'text': 'only half the rice', 'at': '2026-11-20T12:00:00.000Z'},
              {'text': 'the pork was lean', 'at': '2026-11-21T12:00:00.000Z'},
            ]));
        await _toEnd(tester, _scrollableIn(MealEditorScreen));
        final save = tester.getRect(_key('saveMealButton'));
        expect(tester.getRect(_key('mealNoteSaved1')).bottom,
            lessThanOrEqualTo(save.top),
            reason: 'the last kept note lies under Save');
        expect(tester.getRect(_key('mealNoteRemove1')).bottom,
            lessThanOrEqualTo(save.top),
            reason: "the last note's × lies under Save");
      });

      testWidgets("an answer's card, landed at the form's end ($name)",
          (tester) async {
        _phone(tester, bar: bar);
        final executor = await _openEditor(tester, _meal(1));
        executor.nextNoteOutcome = MealNoteOutcome(
            reply: MealCorrected(const MealCorrectionProposal(
          changed: {
            0: MealCorrectionItem(
                name: 'Steamed rice (~100 g)',
                calories: 130,
                protein: 2.5,
                carbs: 28.5,
                fat: 0.3),
          },
          reason: 'Halved the rice; the pork is as before.',
        )));
        await tester.enterText(_key('mealNoteField'), 'only half the rice');
        await tester.pump();
        // The send key, as on a phone: no keyboard is shown here.
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(_key('mealNoteChanges'), findsOneWidget);
        await _toEnd(tester, _scrollableIn(MealEditorScreen));
        expect(tester.getRect(_key('mealNoteChanges')).bottom,
            lessThanOrEqualTo(tester.getRect(_key('saveMealButton')).top),
            reason: "the card's end lies under Save");
      });
    }

    testWidgets('with the keyboard up, the end clears Save over the keyboard',
        (tester) async {
      _phone(tester, bar: 48, keyboard: 300);
      await _openEditor(
          tester,
          _meal(1, notes: const [
            {'text': 'only half the rice', 'at': '2026-11-20T12:00:00.000Z'},
          ]));
      await _toEnd(tester, _scrollableIn(MealEditorScreen));
      final save = tester.getRect(_key('saveMealButton'));
      // Save floats over the keyboard, which takes the bar's inset.
      expect(save.bottom, lessThanOrEqualTo(914.3 - 300));
      expect(tester.getRect(_key('mealNoteRemove0')).bottom,
          lessThanOrEqualTo(save.top));
    });
  });

  group("a day's page: the last meal ends clear of the + button", () {
    for (final (name, bar) in _insets) {
      testWidgets(name, (tester) async {
        _phone(tester, bar: bar);
        final dao = FakeDao();
        for (var id = 1; id <= 12; id++) {
          dao.seed(_meal(id));
        }
        await tester.pumpWidget(_host(DayDetailScreen(
          dao: dao,
          date: '2026-11-24',
          now: () => DateTime(2026, 11, 24, 20),
        )));
        await tester.pumpAndSettle();
        await _toEnd(tester, _scrollableIn(DayDetailScreen));
        final rows = find.byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('mealRow'));
        expect(rows, findsWidgets);
        final lastBottom = rows
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)).bottom)
            .reduce(max);
        expect(lastBottom,
            lessThanOrEqualTo(tester.getRect(_key('addMealToDay')).top),
            reason: 'the last meal row lies under the + button');
      });
    }
  });
}
