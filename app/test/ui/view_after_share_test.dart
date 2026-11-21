/// Android, view-after-share lane: a shared photo's View and a tap on a
/// Logged meals card ask the app shell for the meal (ui/meal_reveal.dart).
/// The shell goes to Today, scrolls the meal's card on screen and rings it
/// (History with the meal's day open, for a meal dated another day), and
/// only over itself: a screen open over the tabs, an editor with unsaved
/// changes above all, is never closed or covered for it. The request waits
/// until the user is back on the tabs.
library;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/main.dart'
    show messengerKey, showAppSnackbar, showAppSnackbarWithView;
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/di.dart' show outcomeAnnouncer;
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/meal_reveal.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart'
    show PhotoOutcome, PhotoOutcomeKind;
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:calorie_tracker/ui/widgets/reveal_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

String _clock(int hour) =>
    '${(hour % 12 == 0 ? 12 : hour % 12).toString().padLeft(2, '0')}:00 '
    '${hour < 12 ? 'AM' : 'PM'}';

Meal _meal(int id, String date, int hour, String name) => Meal(
      id: id,
      date: date,
      time: _clock(hour),
      timestamp: '${date}T${hour.toString().padLeft(2, '0')}:00:00',
      source: 'app_photo',
      imageHash: '',
      analysis: {
        'is_food': true,
        'meal_description': name,
        'total_calories': 300 + id,
        'food_items': [
          {'name': name, 'estimated_calories': 300 + id},
        ],
      },
    );

String get _today => isoDate(DateTime.now());

String get _yesterday {
  final now = DateTime.now();
  return isoDate(DateTime(now.year, now.month, now.day - 1));
}

/// Today with [count] meals, 06:00 on, an hour apart: with 14 the last
/// ones lie far below the first screen, so the list has not built them.
FakeDao _day({int count = 14}) {
  final dao = FakeDao();
  for (var i = 1; i <= count; i++) {
    dao.seed(_meal(i, _today, 5 + i, 'Meal $i'));
  }
  return dao;
}

UiServices _services(FakeDao dao, MealReveals reveals) => UiServices(
      dao: dao,
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: FakeSettings(),
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      mealReveals: reveals,
    );

Future<void> _pumpApp(WidgetTester tester, FakeDao dao, MealReveals reveals,
    {bool settle = true}) async {
  await tester
      .pumpWidget(CalorieTrackerApp(services: _services(dao, reveals)));
  if (settle) await tester.pumpAndSettle();
}

/// The tab selected, whether or not a screen covers the tabs.
int _tab(WidgetTester tester) => tester
    .widget<NavigationBar>(find.byType(NavigationBar, skipOffstage: false))
    .selectedIndex;

Finder _navTab(String label) => find.descendant(
    of: find.byType(NavigationBar), matching: find.text(label));

Finder _card(int id) => find.byKey(ValueKey('meal$id'));

/// The ring around meal [id]'s card or row, which must be built.
RevealHighlightState _ring(WidgetTester tester, int id) =>
    tester.state<RevealHighlightState>(
        find.ancestor(of: _card(id), matching: find.byType(RevealHighlight)));

/// Which of meals 1 to 30 have their card's ring lit (of those built).
Set<int> _lit(WidgetTester tester) => {
      for (var id = 1; id <= 30; id++)
        if (_card(id).evaluate().isNotEmpty && _ring(tester, id).lit) id,
    };

/// Whether meal [id]'s card lies wholly on screen, above the tab bar.
bool _onScreen(WidgetTester tester, int id) {
  if (_card(id).evaluate().isEmpty) return false;
  final card = tester.getRect(_card(id));
  final bar = tester.getRect(find.byType(NavigationBar));
  return card.top >= 0 && card.bottom <= bar.top;
}

/// [ms] milliseconds of frames: long enough for the reveal to scroll and
/// light the ring, short of the ring's own time (pumpAndSettle would run
/// it to its end).
Future<void> _frames(WidgetTester tester, [int ms = 800]) async {
  for (var t = 0; t < ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('from another tab: Today, the card scrolled on screen and '
      'ringed, then the ring goes', (tester) async {
    final dao = _day();
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);
    await tester.tap(_navTab('Settings'));
    await tester.pumpAndSettle();
    expect(_tab(tester), 3);
    expect(_onScreen(tester, 14), isFalse);

    reveals.request(const MealReveal(14));
    await _frames(tester);

    expect(_tab(tester), 0, reason: 'Today');
    expect(_onScreen(tester, 14), isTrue,
        reason: 'the newest meal, far down the list, is brought up');
    expect(_lit(tester), {14}, reason: 'that card, and only that one');
    expect(reveals.waiting, isNull, reason: 'taken');

    await tester.pumpAndSettle();
    expect(_lit(tester), isEmpty, reason: 'the ring goes after its time');
    expect(_onScreen(tester, 14), isTrue);
  });

  testWidgets('an early meal is scrolled back up to', (tester) async {
    final dao = _day();
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);
    reveals.request(const MealReveal(14));
    await tester.pumpAndSettle();
    expect(_onScreen(tester, 1), isFalse, reason: 'scrolled away from it');

    reveals.request(const MealReveal(1));
    await _frames(tester);
    expect(_onScreen(tester, 1), isTrue);
    expect(_lit(tester), {1});
  });

  testWidgets('a second ask for the same meal lights its ring again',
      (tester) async {
    final dao = _day(count: 3);
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);
    reveals.request(const MealReveal(2));
    await tester.pumpAndSettle();
    expect(_lit(tester), isEmpty);
    reveals.request(const MealReveal(2));
    await _frames(tester);
    expect(_lit(tester), {2});
  });

  testWidgets('an editor with unsaved changes stays open and unasked; the '
      'meal is shown once the user is back on the tabs', (tester) async {
    final dao = _day(count: 3);
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);
    await tester.tap(_card(1));
    await tester.pumpAndSettle();
    expect(find.byType(MealEditorScreen), findsOneWidget);
    await tester.enterText(find.byKey(const Key('editorCalories')), '650');
    await tester.pump();
    expect(reveals.canShowNow, isFalse,
        reason: 'View is not offered over the editor');

    reveals.request(const MealReveal(3));
    await tester.pumpAndSettle();
    expect(find.byType(MealEditorScreen), findsOneWidget,
        reason: 'never closed for it');
    expect(find.byKey(const Key('discardChangesDialog')), findsNothing,
        reason: 'nor its discard question asked');
    expect(find.text('650'), findsOneWidget, reason: 'the typing is kept');
    expect(reveals.waiting, const MealReveal(3), reason: 'still waiting');

    // The user leaves the editor themselves: Back asks, Discard.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discardChangesDiscard')));
    await _frames(tester);
    expect(find.byType(MealEditorScreen), findsNothing);
    expect(_tab(tester), 0);
    expect(_lit(tester), {3}, reason: 'shown on the way back');
    expect(reveals.waiting, isNull);
  });

  testWidgets('a meal dated another day: History, with that day open on it',
      (tester) async {
    final dao = _day(count: 2)..seed(_meal(20, _yesterday, 23, 'Late snack'));
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);

    reveals.request(const MealReveal(20));
    await _frames(tester);
    expect(_tab(tester), 1, reason: 'History');
    final day = tester.widget<DayDetailScreen>(find.byType(DayDetailScreen));
    expect(day.date, _yesterday);
    expect(_lit(tester), {20});

    // Back lands on History, as from any day it opens.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DayDetailScreen), findsNothing);
    expect(_tab(tester), 1);
  });

  testWidgets('where the meal is dated now: one moved to another day since '
      'opens that day', (tester) async {
    final dao = _day(count: 2);
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);
    await dao.updateMealFields(2, date: _yesterday);

    reveals.request(const MealReveal(2));
    await tester.pumpAndSettle();
    expect(tester.widget<DayDetailScreen>(find.byType(DayDetailScreen)).date,
        _yesterday);
  });

  testWidgets('a meal that is gone: Today, nothing ringed', (tester) async {
    final dao = _day(count: 2);
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);
    await tester.tap(_navTab('History'));
    await tester.pumpAndSettle();

    reveals.request(const MealReveal(29));
    await _frames(tester);
    expect(_tab(tester), 0);
    expect(_lit(tester), isEmpty);
    expect(find.byType(DayDetailScreen), findsNothing);
  });

  testWidgets('a request that waited too long is not shown on the way back',
      (tester) async {
    var now = DateTime.now();
    final dao = _day(count: 3);
    final reveals = MealReveals(clock: () => now);
    await _pumpApp(tester, dao, reveals);
    await tester.tap(_navTab('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('historyDay$_today')));
    await tester.pumpAndSettle();
    expect(find.byType(DayDetailScreen), findsOneWidget);

    reveals.request(const MealReveal(3));
    await tester.pumpAndSettle();
    expect(find.byType(DayDetailScreen), findsOneWidget);
    now = now.add(MealReveals.waitLimit + const Duration(seconds: 1));
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(find.byType(DayDetailScreen), findsNothing);
    expect(_tab(tester), 1, reason: 'left where the user was');
    expect(_lit(tester), isEmpty);
  });

  testWidgets('View is offered only while the shell is on top',
      (tester) async {
    final dao = _day(count: 2);
    final reveals = MealReveals();
    expect(reveals.canShowNow, isFalse, reason: 'no shell yet');
    await _pumpApp(tester, dao, reveals);
    expect(reveals.canShowNow, isTrue);
    await tester.tap(_card(1));
    await tester.pumpAndSettle();
    expect(reveals.canShowNow, isFalse, reason: 'the editor is open');
    await tester.binding.handlePopRoute(); // nothing typed: no question
    await tester.pumpAndSettle();
    expect(reveals.canShowNow, isTrue);
  });

  group("end to end, from the pipeline's verdict (main.dart's messages)", () {
    PhotoOutcome shared(int mealId) => PhotoOutcome(
        PhotoOutcomeKind.saved, 'Meal logged: Meal $mealId',
        detail: 'Meal $mealId — ~${300 + mealId} kcal',
        mealName: 'Meal $mealId',
        kcal: '${300 + mealId}',
        mealId: mealId,
        mealDate: _today,
        analysis: {'is_food': true, 'meal_description': 'Meal $mealId'},
        shared: true);

    void Function(PhotoOutcome) announcer(MealReveals reveals) =>
        outcomeAnnouncer(
            l10n: AppLocalizationsEn.new,
            notify: showAppSnackbar,
            reveals: reveals,
            notifyView: showAppSnackbarWithView);

    Future<void> drain(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    }

    testWidgets('logged while on Settings: the message has View, and View '
        'goes to the meal', (tester) async {
      final dao = _day();
      final reveals = MealReveals();
      await tester.pumpWidget(CalorieTrackerApp(
          services: _services(dao, reveals), messengerKey: messengerKey));
      await tester.pumpAndSettle();
      await tester.tap(_navTab('Settings'));
      await tester.pumpAndSettle();

      announcer(reveals)(shared(14));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Meal logged: Meal 14 — ~314 kcal'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'View'));
      await _frames(tester);
      expect(_tab(tester), 0);
      expect(_onScreen(tester, 14), isTrue);
      expect(_lit(tester), {14});
      await drain(tester);
    });

    testWidgets('logged while an editor is open: the plain message, and the '
        'editor is left alone', (tester) async {
      final dao = _day(count: 3);
      final reveals = MealReveals();
      await tester.pumpWidget(CalorieTrackerApp(
          services: _services(dao, reveals), messengerKey: messengerKey));
      await tester.pumpAndSettle();
      await tester.tap(_card(1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('editorCalories')), '650');
      await tester.pump();

      announcer(reveals)(shared(3));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Meal logged: Meal 3 — ~303 kcal'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'View'), findsNothing);
      expect(reveals.waiting, isNull, reason: 'nothing asked for');
      await drain(tester);
      expect(find.byType(MealEditorScreen), findsOneWidget);
      expect(find.text('650'), findsOneWidget);
    });
  });

  testWidgets('a request made before the shell is up (a cold start from a '
      'card) is shown once it is', (tester) async {
    final dao = _day();
    final reveals = MealReveals()..request(const MealReveal(12));
    await _pumpApp(tester, dao, reveals, settle: false);
    await _frames(tester);
    expect(_tab(tester), 0);
    expect(_onScreen(tester, 12), isTrue);
    expect(_lit(tester), {12});
  });
}
