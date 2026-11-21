/// main.dart's snackbar sink (the pipeline / startup-glue `notify`).
///
/// A cold-start share whose verdict needs no analyzer call (duplicate /
/// already logged — DB-only) can resolve before the first frame mounts the
/// ScaffoldMessenger; `currentState?.showSnackBar` used to drop it.
///
/// Owner decision 2026-11-11 (RC 1.6.0 review, finding 4): a usual-foods
/// result and its Undo jump the queue. The app's own messages are handed
/// to the messenger one at a time, so the Undo is shown next and the
/// "Logged" lines a catch-up queued follow it, none dropped.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/main.dart';
import 'package:calorie_tracker/ui/widgets/usual_offer_card.dart';

Widget _app() => MaterialApp(
    scaffoldMessengerKey: messengerKey, home: const Scaffold(body: Text('')));

/// [seconds] one-second frames, stopping early once [text] is on screen.
Future<bool> _seenWithin(WidgetTester tester, String text, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (find.text(text).evaluate().isNotEmpty) return true;
  }
  return false;
}

const _used = 'Used your usual numbers: 300 → 350 kcal';

SnackBar _usedSnack(ScaffoldMessengerState messenger) =>
    _usualSnack(messenger, _used);

/// A usual-foods result with Undo, as showUsualUsedSnack builds it.
SnackBar _usualSnack(ScaffoldMessengerState messenger, String text) =>
    SnackBar(
        duration: kUsualUndoSnackDuration,
        persist: usualUndoPersists(messenger),
        content: Text(text),
        action: SnackBarAction(label: 'Undo', onPressed: () {}));

/// The snackbar texts on screen now, for a failure message.
String _onScreen() => [
      for (final e in find
          .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
          .evaluate())
        (e.widget as Text).data,
    ].join(' | ');

void main() {
  testWidgets('a message sent before the messenger mounts is shown after '
      'the first frame, in order', (tester) async {
    expect(messengerKey.currentState, isNull);
    showAppSnackbar('held one');
    showAppSnackbar('held two');
    await tester.pumpWidget(_app());
    await tester.pump(); // the post-frame flush schedules the snackbar frame
    expect(find.text('held one'), findsOneWidget);
    // Held behind the first, not lost.
    messengerKey.currentState!.removeCurrentSnackBar();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('held two'), findsOneWidget);
  });

  testWidgets('once mounted, a message shows straight away', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('now');
    await tester.pump();
    expect(find.text('now'), findsOneWidget);
  });

  // RC 1.6.0: the restaurant lookup's "used the chain's numbers" line with
  // Undo (di.dart notifyAction) had no duration and no persist, so on
  // Flutter 3.44 it never timed out and every later message queued unseen
  // behind it.
  testWidgets('no screen reader: the lookup Undo snackbar times out, and a '
      'message sent after it is seen', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbarWithAction(
        'Used Chipotle published numbers: 650 → 720 kcal', 'Undo', () {});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Undo'), findsOneWidget);
    showAppSnackbar('Logged: Oatmeal, 350 kcal');
    expect(await _seenWithin(tester, 'Logged: Oatmeal, 350 kcal', 12), isTrue,
        reason: 'queued behind an Undo snackbar that never left');
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('under VoiceOver / TalkBack the lookup Undo snackbar stays up '
      'until it is acted on', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_app());
    var undone = 0;
    showAppSnackbarWithAction('Used published numbers', 'Undo', () => undone++);
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Undo'), findsOneWidget,
        reason: 'a screen-reader user needs time to reach Undo');
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(undone, 1);
  });

  testWidgets('a plain message still leaves on its own', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Toast');
    await tester.pump();
    expect(find.text('Logged: Toast'), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Logged: Toast'), findsNothing);
  });

  testWidgets('Use on a chip while the lookup Undo snackbar is queued: its '
      'snackbar is next, and the lookup Undo follows it', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Big Mac');
    showAppSnackbarWithAction(
        'Used published numbers: 540 → 590 kcal', 'Undo', () {});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final messenger = messengerKey.currentState!;
    showUsualSnack(messenger, _usedSnack(messenger));
    expect(await _seenWithin(tester, _used, 2), isTrue,
        reason: 'the usual Undo jumps the queue');
    expect(find.text('Used published numbers: 540 → 590 kcal'), findsNothing);
    expect(
        await _seenWithin(
            tester, 'Used published numbers: 540 → 590 kcal', 11),
        isTrue,
        reason: 'the lookup Undo is not dropped');
  });

  testWidgets('Use on a chip after a catch-up logged three photos: its '
      'snackbar is next, for its full time, and the queued messages follow '
      'it in order', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Oatmeal');
    showAppSnackbar('Logged: Latte');
    showAppSnackbar('Logged: Banana');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Logged: Oatmeal'), findsOneWidget);
    final messenger = messengerKey.currentState!;
    showUsualSnack(messenger, _usedSnack(messenger));
    // Oatmeal's exit, then the Undo: nothing in between.
    expect(await _seenWithin(tester, _used, 2), isTrue,
        reason: 'on screen instead: ${_onScreen()}');
    // No later message cuts its 8 s short.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text(_used), findsOneWidget);
    expect(await _seenWithin(tester, 'Logged: Latte', 5), isTrue);
    expect(find.text(_used), findsNothing);
    expect(await _seenWithin(tester, 'Logged: Banana', 6), isTrue);
  });

  // Review 1.7.1: an app message that arrived while a usual-foods snackbar
  // was up went straight into the messenger's own queue, behind it. A
  // second Use then hid the first snackbar, the queued message came next,
  // and the second Undo waited behind it: about 4 s late, or for good
  // under a screen reader behind a held lookup Undo.
  testWidgets('a second Use while a message that arrived during the first '
      'waits: the second Undo is next, and the message follows it',
      (tester) async {
    await tester.pumpWidget(_app());
    final messenger = messengerKey.currentState!;
    showUsualSnack(messenger, _usualSnack(messenger, 'Used A'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Used A'), findsOneWidget);
    // A background save lands while Used A is up.
    showAppSnackbar('Logged: Latte');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Used A'), findsOneWidget);
    // Use on a second meal.
    showUsualSnack(messenger, _usualSnack(messenger, 'Used B'));
    expect(await _seenWithin(tester, 'Used B', 2), isTrue,
        reason: 'on screen instead: ${_onScreen()}');
    expect(find.text('Logged: Latte'), findsNothing);
    // Used B keeps its full time, then the message follows, not dropped.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Used B'), findsOneWidget);
    expect(await _seenWithin(tester, 'Logged: Latte', 5), isTrue);
  });

  testWidgets('screen reader: a second Use is not held behind a lookup '
      'Undo that arrived during the first', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_app());
    final messenger = messengerKey.currentState!;
    showUsualSnack(messenger, _usualSnack(messenger, 'Used A'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    var lookupUndone = 0;
    showAppSnackbarWithAction(
        'Used published numbers', 'Undo', () => lookupUndone++);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    showUsualSnack(messenger, _usualSnack(messenger, 'Used B'));
    expect(await _seenWithin(tester, 'Used B', 2), isTrue,
        reason: 'on screen instead: ${_onScreen()}');
    // Held for the screen-reader user, with its own Undo.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Used B'), findsOneWidget);
    expect(find.text('Used published numbers'), findsNothing);
    // Acting on it lets the lookup's line and Undo through.
    await tester.tap(find.text('Undo'));
    expect(await _seenWithin(tester, 'Used published numbers', 2), isTrue,
        reason: 'the lookup Undo is not dropped');
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(lookupUndone, 1);
  });

  testWidgets('a message sent while a usual-foods snackbar is up waits for '
      'it, then shows', (tester) async {
    await tester.pumpWidget(_app());
    final messenger = messengerKey.currentState!;
    showUsualSnack(messenger, _usedSnack(messenger));
    await tester.pump();
    showAppSnackbar('Logged: Toast');
    expect(await _seenWithin(tester, 'Logged: Toast', 7), isFalse,
        reason: 'the Undo keeps its 8 s');
    expect(find.text(_used), findsOneWidget);
    expect(await _seenWithin(tester, 'Logged: Toast', 4), isTrue);
  });

  testWidgets('a messenger that went away does not hold later messages '
      'back', (tester) async {
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Toast');
    showAppSnackbar('Logged: Tea');
    await tester.pump();
    expect(find.text('Logged: Toast'), findsOneWidget);
    // The startup error screen, then the app again: the first messenger is
    // disposed with Toast still up, and its close is never reported.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app());
    showAppSnackbar('Logged: Jam');
    expect(await _seenWithin(tester, 'Logged: Tea', 2), isTrue);
    expect(await _seenWithin(tester, 'Logged: Jam', 6), isTrue);
    // Nothing left held for the next test.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(SnackBar), findsNothing);
  });

  // Android, view-after-share lane: a shared photo's "Meal logged" line
  // offers View (di.dart notifyView), which goes to the meal, while the
  // app could go there at once.
  group('a View on a message (showAppSnackbarWithView)', () {
    testWidgets('offered while the app could go there: a tap asks for the '
        'meal', (tester) async {
      await tester.pumpWidget(_app());
      var viewed = 0;
      showAppSnackbarWithView('Meal logged: Ramen — ~600 kcal', 'View',
          () => viewed++, () => true, _Changes());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('View'), findsOneWidget);
      await tester.tap(find.text('View'));
      await tester.pump();
      expect(viewed, 1);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('no screen reader: it leaves on its own after 8 s',
        (tester) async {
      await tester.pumpWidget(_app());
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () {}, () => true, _Changes());
      await tester.pump();
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('View'), findsOneWidget, reason: 'its full 8 s');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    // Review of PR 80: under TalkBack the View left after 8 s like any
    // message, where every other action snackbar here (and Android's own)
    // stays up: reaching View by swiping takes longer than that.
    testWidgets('screen reader on: a View with nothing behind it stays up '
        'until it is acted on', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(_app());
      var viewed = 0;
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () => viewed++, () => true, _Changes());
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('View'), findsOneWidget,
          reason: 'a screen-reader user needs time to reach View');
      await tester.tap(find.text('View'));
      await tester.pump();
      expect(viewed, 1);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('screen reader on: a message behind a View is not held '
        'back; the View goes once it has had its 8 s', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(_app());
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () {}, () => true, _Changes());
      showAppSnackbar('Meal logged: Tea');
      await tester.pump();
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('View'), findsOneWidget, reason: 'its full 8 s');
      expect(await _seenWithin(tester, 'Meal logged: Tea', 3), isTrue,
          reason: 'held only while nothing waits behind it, unlike an Undo');
      expect(find.text('View'), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('screen reader on: a View held past its 8 s goes as soon as '
        'a message arrives behind it', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(_app());
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () {}, () => true, _Changes());
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('View'), findsOneWidget);
      showAppSnackbar('Meal logged: Tea');
      expect(await _seenWithin(tester, 'Meal logged: Tea', 2), isTrue);
      expect(find.text('View'), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('left off while the app could not go there: the plain '
        'message, gone after 4 s', (tester) async {
      await tester.pumpWidget(_app());
      var viewed = 0;
      showAppSnackbarWithView('Meal logged: Ramen', 'View', () => viewed++,
          () => false, _Changes());
      await tester.pump();
      expect(find.text('Meal logged: Ramen'), findsOneWidget);
      expect(find.text('View'), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Meal logged: Ramen'), findsNothing);
      expect(viewed, 0);
    });

    testWidgets('asked as the message shows, not when it was sent',
        (tester) async {
      await tester.pumpWidget(_app());
      var open = false;
      showAppSnackbar('Meal logged: Toast');
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () {}, () => open, _Changes());
      await tester.pump();
      expect(find.text('Meal logged: Toast'), findsOneWidget);
      open = true; // the screen over the tabs was closed meanwhile
      expect(await _seenWithin(tester, 'Meal logged: Ramen', 6), isTrue);
      expect(find.text('View'), findsOneWidget);
      // And the other way: a View sent while it could go there, shown once
      // a screen is up over the tabs, is left off.
      showAppSnackbarWithView(
          'Meal logged: Soup', 'View', () {}, () => open, _Changes());
      open = false;
      expect(await _seenWithin(tester, 'Meal logged: Soup', 10), isTrue);
      expect(find.text('View'), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    // Review of PR 80: View was asked once, as it showed, and then stayed
    // tappable for its 8 s over whatever came up next. A tap there made a
    // request nothing on screen spoke of, carried out minutes later.
    testWidgets('taken away once the app can no longer go there: the '
        'message goes, and nothing is asked for', (tester) async {
      await tester.pumpWidget(_app());
      final changes = _Changes();
      var open = true;
      var viewed = 0;
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () => viewed++, () => open, changes);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      // A change that leaves it offered leaves it up.
      changes.ping();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('View'), findsOneWidget);
      // The user starts typing, say.
      open = false;
      changes.ping();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('View'), findsNothing);
      expect(find.byType(SnackBar), findsNothing, reason: 'it was seen');
      expect(viewed, 0);
      expect(changes.listening, isFalse, reason: 'stops listening once gone');
    });

    testWidgets('one taken away does not hold the next message back',
        (tester) async {
      await tester.pumpWidget(_app());
      final changes = _Changes();
      var open = true;
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () {}, () => open, changes);
      showAppSnackbar('Meal logged: Tea');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      open = false;
      changes.ping();
      expect(await _seenWithin(tester, 'Meal logged: Tea', 2), isTrue);
      expect(find.text('View'), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets("one queued behind a screen's own snackbar: that snackbar "
        'is left alone, and the message shows plain if View is no longer '
        'offered by then', (tester) async {
      await tester.pumpWidget(_app());
      final messenger = messengerKey.currentState!;
      messenger.showSnackBar(const SnackBar(content: Text('Export saved.')));
      final changes = _Changes();
      var open = true;
      showAppSnackbarWithView(
          'Meal logged: Ramen', 'View', () {}, () => open, changes);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Export saved.'), findsOneWidget);
      open = false;
      changes.ping();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Export saved.'), findsOneWidget,
          reason: "the screen's own snackbar is not the one taken away");
      expect(await _seenWithin(tester, 'Meal logged: Ramen', 5), isTrue,
          reason: 'not dropped: it was never seen');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Meal logged: Ramen'), findsOneWidget);
      expect(find.text('View'), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a check that throws leaves View off', (tester) async {
      await tester.pumpWidget(_app());
      showAppSnackbarWithView('Meal logged: Ramen', 'View', () {},
          () => throw StateError('the shell went'), _Changes());
      await tester.pump();
      expect(find.text('Meal logged: Ramen'), findsOneWidget);
      expect(find.text('View'), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}

/// The app's "View may no longer be offered" signal (MealReveals
/// .availability), pinged by hand.
class _Changes extends ChangeNotifier {
  void ping() => notifyListeners();
  bool get listening => hasListeners;
}
