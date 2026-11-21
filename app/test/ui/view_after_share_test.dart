/// Android, view-after-share lane: a shared photo's View and a tap on a
/// Logged meals card ask the app shell for the meal (ui/meal_reveal.dart).
/// The shell goes to Today, scrolls the meal's card on screen and rings it
/// (History with the meal's day open, for a meal dated another day), and a
/// screen reader is told which meal it is. The screens open over the tabs
/// that Back would close without asking are closed for it. An editor with
/// unsaved changes is never closed or covered for it, nor is a dialog or
/// sheet, and nothing moves while a text field has the focus: the request
/// waits until that ends, for a minute at most.
library;

import 'dart:async' show unawaited;

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

/// A context in the shell, over which the test opens what the app would.
BuildContext _shell(WidgetTester tester) =>
    tester.element(find.byType(NavigationBar, skipOffstage: false));

/// History, then today's day: a screen over the tabs with nothing to lose.
Future<void> _openToday(WidgetTester tester) async {
  await tester.tap(_navTab('History'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('historyDay$_today')));
  await tester.pumpAndSettle();
  expect(find.byType(DayDetailScreen), findsOneWidget);
}

/// The live region that tells a screen reader which meal the reveal
/// brought on screen, if there is one.
String? _said(WidgetTester tester) {
  final f = find.byKey(const Key('revealAnnouncement'));
  if (f.evaluate().isEmpty) return null;
  final node = tester.getSemantics(f);
  expect(node.flagsCollection.isLiveRegion, isTrue);
  return node.label;
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
    await _openToday(tester);
    await tester.tap(_card(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editorCalories')), '650');
    await tester.pump();

    reveals.request(const MealReveal(3));
    await tester.pumpAndSettle();
    expect(find.byType(MealEditorScreen), findsOneWidget);
    expect(reveals.waiting, const MealReveal(3));
    now = now.add(MealReveals.waitLimit + const Duration(seconds: 1));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discardChangesDiscard')));
    await _frames(tester);
    expect(find.byType(MealEditorScreen), findsNothing);
    expect(find.byType(DayDetailScreen), findsOneWidget,
        reason: 'left where the user was: nothing closed for it');
    expect(_tab(tester), 1);
    expect(_lit(tester), isEmpty);
    expect(reveals.waiting, isNull);
  });

  testWidgets('View is offered while the shell could go there at once: '
      'over a screen with nothing to lose, not while typing or with '
      'unsaved changes or a question open', (tester) async {
    final dao = _day(count: 2);
    final reveals = MealReveals();
    expect(reveals.canShowNow, isFalse, reason: 'no shell yet');
    await _pumpApp(tester, dao, reveals);
    expect(reveals.canShowNow, isTrue);
    await tester.tap(_card(1));
    await tester.pumpAndSettle();
    expect(find.byType(MealEditorScreen), findsOneWidget);
    expect(reveals.canShowNow, isTrue,
        reason: 'an editor only opened: Back would close it unasked');
    await tester.showKeyboard(find.byKey(const Key('editorCalories')));
    await tester.pump();
    expect(reveals.canShowNow, isFalse, reason: 'typing');
    await tester.enterText(find.byKey(const Key('editorCalories')), '650');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(reveals.canShowNow, isFalse, reason: 'unsaved changes');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('discardChangesDialog')), findsOneWidget);
    expect(reveals.canShowNow, isFalse, reason: 'a question is open');
    await tester.tap(find.byKey(const Key('discardChangesDiscard')));
    await tester.pumpAndSettle();
    expect(reveals.canShowNow, isTrue);
  });

  // Review of PR 80: any screen over the tabs held the request, one with
  // nothing to lose too: the message had no View, a card tap did nothing
  // visible, and the meal was shown minutes later on the way back.
  group('screens over the tabs', () {
    testWidgets('one with nothing to lose (a History day) is closed, and '
        'the meal shown at once', (tester) async {
      final dao = _day();
      final reveals = MealReveals();
      await _pumpApp(tester, dao, reveals);
      await _openToday(tester);
      expect(reveals.canShowNow, isTrue);

      reveals.request(const MealReveal(14));
      await _frames(tester);
      expect(find.byType(DayDetailScreen), findsNothing);
      expect(_tab(tester), 0);
      expect(_onScreen(tester, 14), isTrue);
      expect(_lit(tester), {14});
      expect(reveals.waiting, isNull);
    });

    testWidgets('two deep (a History day, then a meal opened from it, '
        'nothing changed): both closed', (tester) async {
      final dao = _day(count: 3);
      final reveals = MealReveals();
      await _pumpApp(tester, dao, reveals);
      await _openToday(tester);
      await tester.tap(_card(2));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsOneWidget);

      reveals.request(const MealReveal(3));
      await _frames(tester);
      expect(find.byType(MealEditorScreen), findsNothing);
      expect(find.byType(DayDetailScreen), findsNothing);
      expect(_tab(tester), 0);
      expect(_lit(tester), {3});
    });

    testWidgets('a screen with nothing to lose over an editor with unsaved '
        'changes: nothing is closed, not even the one on top', (tester) async {
      final dao = _day(count: 3);
      final reveals = MealReveals();
      await _pumpApp(tester, dao, reveals);
      await tester.tap(_card(1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('editorCalories')), '650');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      unawaited(Navigator.of(tester.element(find.byType(MealEditorScreen)))
          .push(MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('on top')))));
      await tester.pumpAndSettle();
      expect(reveals.canShowNow, isFalse);

      reveals.request(const MealReveal(3));
      await _frames(tester);
      expect(find.text('on top'), findsOneWidget,
          reason: 'the user is not left half way, in the editor');
      expect(reveals.waiting, const MealReveal(3));
      // Back to the editor: it still holds its changes, so it waits on.
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(find.byType(MealEditorScreen), findsOneWidget);
      expect(find.text('650'), findsOneWidget);
      expect(reveals.waiting, const MealReveal(3));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discardChangesDiscard')));
      await _frames(tester);
      expect(_tab(tester), 0);
      expect(_lit(tester), {3}, reason: 'shown once it is let go');
    });
  });

  // Review of PR 80: these states had no test.
  group('a question open, or typing: the request waits, and is shown when '
      'that ends', () {
    testWidgets('a dialog over the tabs', (tester) async {
      final dao = _day();
      final reveals = MealReveals();
      await _pumpApp(tester, dao, reveals);
      await tester.tap(_navTab('Settings'));
      await tester.pumpAndSettle();
      unawaited(showDialog<void>(
          context: _shell(tester),
          builder: (_) => const AlertDialog(content: Text('A question'))));
      await tester.pumpAndSettle();
      expect(reveals.canShowNow, isFalse);

      reveals.request(const MealReveal(14));
      await _frames(tester);
      expect(find.text('A question'), findsOneWidget, reason: 'left open');
      expect(_tab(tester), 3);
      expect(reveals.waiting, const MealReveal(14));

      await tester.binding.handlePopRoute(); // the user dismisses it
      await _frames(tester);
      expect(find.text('A question'), findsNothing);
      expect(_tab(tester), 0);
      expect(_onScreen(tester, 14), isTrue);
      expect(_lit(tester), {14});
    });

    testWidgets('a sheet over the tabs', (tester) async {
      final dao = _day();
      final reveals = MealReveals();
      await _pumpApp(tester, dao, reveals);
      await tester.tap(_navTab('Settings'));
      await tester.pumpAndSettle();
      unawaited(showModalBottomSheet<void>(
          context: _shell(tester),
          builder: (_) =>
              const SizedBox(height: 200, child: Text('A sheet'))));
      await tester.pumpAndSettle();
      expect(reveals.canShowNow, isFalse);

      reveals.request(const MealReveal(14));
      await _frames(tester);
      expect(find.text('A sheet'), findsOneWidget, reason: 'left open');
      expect(_tab(tester), 3);
      expect(reveals.waiting, const MealReveal(14));

      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(find.text('A sheet'), findsNothing);
      expect(_tab(tester), 0);
      expect(_lit(tester), {14});
    });

    testWidgets('a dialog over a screen with nothing to lose: once it is '
        'answered, the screen is closed and the meal shown', (tester) async {
      final dao = _day(count: 3);
      final reveals = MealReveals();
      await _pumpApp(tester, dao, reveals);
      await _openToday(tester);
      // One that takes no focus: its closing moves no focus, and the shell
      // is not back on top after it, so the route change is all there is
      // to hear (RouteStack).
      unawaited(showDialog<void>(
          context: tester.element(find.byType(DayDetailScreen)),
          requestFocus: false,
          builder: (_) => const AlertDialog(content: Text('A question'))));
      await tester.pumpAndSettle();

      reveals.request(const MealReveal(3));
      await _frames(tester);
      expect(find.text('A question'), findsOneWidget);
      expect(find.byType(DayDetailScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(find.byType(DayDetailScreen), findsNothing);
      expect(_tab(tester), 0);
      expect(_lit(tester), {3});
    });

    testWidgets('a text field with the focus, over the tabs with no route '
        'of its own: shown once the focus leaves it', (tester) async {
      final dao = _day();
      final reveals = MealReveals();
      await _pumpApp(tester, dao, reveals);
      await tester.tap(_navTab('Settings'));
      await tester.pumpAndSettle();
      final entry = OverlayEntry(
          builder: (_) => const Align(
              alignment: Alignment.topCenter,
              child: Material(
                  child: SizedBox(
                      width: 300,
                      child: TextField(key: Key('overlayField'))))));
      Navigator.of(_shell(tester)).overlay!.insert(entry);
      addTearDown(entry.remove);
      await tester.pump();
      await tester.showKeyboard(find.byKey(const Key('overlayField')));
      await tester.enterText(find.byKey(const Key('overlayField')), 'typing');
      await tester.pump();
      expect(reveals.canShowNow, isFalse);

      reveals.request(const MealReveal(14));
      await _frames(tester);
      expect(_tab(tester), 3, reason: 'nothing moves mid-typing');
      expect(reveals.waiting, const MealReveal(14));
      expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorStateOfType<EditableTextState>(),
          isNotNull,
          reason: 'the focus is not taken');

      FocusManager.instance.primaryFocus?.unfocus();
      await _frames(tester);
      expect(_tab(tester), 0);
      expect(_onScreen(tester, 14), isTrue);
      expect(_lit(tester), {14});
    });
  });

  // Review of PR 80: a TalkBack user heard nothing name the meal, and the
  // ring is only seen.
  testWidgets("a screen reader is told which meal it is, once its card is "
      'on screen, while the ring shows', (tester) async {
    final handle = tester.ensureSemantics();
    final dao = _day()..seed(_meal(20, _yesterday, 23, 'Late snack'));
    final reveals = MealReveals();
    await _pumpApp(tester, dao, reveals);
    await tester.tap(_navTab('Settings'));
    await tester.pumpAndSettle();
    expect(_said(tester), isNull);

    reveals.request(const MealReveal(14));
    await _frames(tester);
    expect(_onScreen(tester, 14), isTrue);
    expect(_said(tester), 'Meal 14 — ~314 kcal');
    await tester.pumpAndSettle();
    expect(_said(tester), isNull, reason: 'gone with the ring');

    // A meal dated another day, on its History day.
    reveals.request(const MealReveal(20));
    await _frames(tester);
    expect(find.byType(DayDetailScreen), findsOneWidget);
    expect(_said(tester), 'Late snack — ~320 kcal');
    await tester.pumpAndSettle();
    handle.dispose();
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

    testWidgets('logged while an editor holds unsaved changes: the plain '
        'message, and the editor is left alone', (tester) async {
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

    // Review of PR 80: the View stayed tappable over whatever opened after
    // it showed, an editor included.
    testWidgets('View over a screen opened after it showed, with nothing '
        'to lose: a tap closes that screen and goes to the meal at once',
        (tester) async {
      final dao = _day();
      final reveals = MealReveals();
      await tester.pumpWidget(CalorieTrackerApp(
          services: _services(dao, reveals), messengerKey: messengerKey));
      await tester.pumpAndSettle();
      await tester.tap(_navTab('History'));
      await tester.pumpAndSettle();
      announcer(reveals)(shared(14));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(Key('historyDay$_today')));
      await tester.pumpAndSettle();
      expect(find.byType(DayDetailScreen), findsOneWidget);

      final view = find.widgetWithText(SnackBarAction, 'View');
      expect(view.hitTestable(), findsOneWidget, reason: 'still offered');
      await tester.tap(view);
      await _frames(tester);
      expect(find.byType(DayDetailScreen), findsNothing);
      expect(_tab(tester), 0);
      expect(_onScreen(tester, 14), isTrue);
      expect(_lit(tester), {14});
      await drain(tester);
    });

    testWidgets('View is taken away once the user types on a screen opened '
        'after it showed: nothing is asked for, the typing is kept',
        (tester) async {
      final dao = _day(count: 3);
      final reveals = MealReveals();
      await tester.pumpWidget(CalorieTrackerApp(
          services: _services(dao, reveals), messengerKey: messengerKey));
      await tester.pumpAndSettle();
      announcer(reveals)(shared(3));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(SnackBarAction, 'View'), findsOneWidget);
      await tester.tap(_card(1));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SnackBarAction, 'View'), findsOneWidget,
          reason: 'an editor only opened: it could still close');

      await tester.enterText(find.byKey(const Key('editorCalories')), '650');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SnackBarAction, 'View'), findsNothing);
      expect(reveals.waiting, isNull, reason: 'nothing asked for');
      expect(find.byType(MealEditorScreen), findsOneWidget);
      expect(find.text('650'), findsOneWidget);
      // Nothing asked for either when the typing ends: no jump later.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discardChangesDiscard')));
      await _frames(tester);
      expect(_lit(tester), isEmpty);
      await drain(tester);
    });

    testWidgets('a screen that takes unsaved changes with no typing (its '
        'pop held): View is taken away, and a meal asked for meanwhile is '
        'shown once it lets go', (tester) async {
      final dao = _day(count: 3);
      final reveals = MealReveals();
      await tester.pumpWidget(CalorieTrackerApp(
          services: _services(dao, reveals), messengerKey: messengerKey));
      await tester.pumpAndSettle();
      announcer(reveals)(shared(3));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      unawaited(Navigator.of(_shell(tester))
          .push(MaterialPageRoute<void>(builder: (_) => const _HeldPage())));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SnackBarAction, 'View'), findsOneWidget);

      await tester.tap(find.text('change')); // a switch, a stepper: no field
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SnackBarAction, 'View'), findsNothing);
      expect(reveals.canShowNow, isFalse);

      // A card tapped now waits for it.
      reveals.request(const MealReveal(3));
      await _frames(tester);
      expect(find.byType(_HeldPage), findsOneWidget);
      await tester.tap(find.text('change')); // changed back: nothing to lose
      await _frames(tester);
      expect(find.byType(_HeldPage), findsNothing);
      expect(_tab(tester), 0);
      expect(_lit(tester), {3});
      await drain(tester);
    });

    // Review of PR 80: nothing pinned a View handed over while the app was
    // in the background.
    testWidgets('logged while the app was in the background: View on '
        'return, and it goes to the meal', (tester) async {
      final dao = _day();
      final reveals = MealReveals();
      await tester.pumpWidget(CalorieTrackerApp(
          services: _services(dao, reveals), messengerKey: messengerKey));
      await tester.pumpAndSettle();
      await tester.tap(_navTab('Settings'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      announcer(reveals)(shared(14));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
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

/// A screen that takes unsaved changes from a control, not a text field:
/// its pop is held while [_changed] (a PopScope, as DiscardChangesGuard
/// holds one), and the tap that changes it takes no focus.
class _HeldPage extends StatefulWidget {
  const _HeldPage();

  @override
  State<_HeldPage> createState() => _HeldPageState();
}

class _HeldPageState extends State<_HeldPage> {
  bool _changed = false;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_changed,
        child: Scaffold(
          body: Center(
            child: GestureDetector(
              onTap: () => setState(() => _changed = !_changed),
              child: const Padding(
                  padding: EdgeInsets.all(24), child: Text('change')),
            ),
          ),
        ),
      );
}
