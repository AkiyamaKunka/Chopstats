// Q9 under predictive back (review 2026-11-20): MainActivity's
// popSystemNavigator moves the task to the back, but Flutter calls it only
// for a Back it handles. At an idle root Flutter hands Back to Android
// (setFrameworkHandlesBack(false)), and with predictive back on
// (enableOnBackInvokedCallback) Android 14 and later finish every task the
// home screen did not start with the launcher intent. MainActivity keeps
// Back in Flutter in all of them but one: a task the launcher intent
// started from somewhere other than the home screen (Play's Open button),
// which looks like the launcher's own to the app. A photo shared into such
// a task would die with its engine mid-analysis, and come back only at the
// next start, sent to the AI a second time, or never when that start was a
// day later.
//
// While a shared photo is pending the shell's guard keeps the Back in
// Flutter, in every task, and a Back at the root calls SystemNavigator.pop,
// which lands in popSystemNavigator: through the old key path (popRoute)
// and through the predictive gesture alike. Once the photo is settled,
// Flutter leaves Back at the root to the platform again. iPhone has no
// Back and no guard.
//
// Owner decision 9 (2026-11-20): the same holds while any analysis the
// user started is in flight (AnalysisKeepAlive.inFlight: a picked photo,
// a typed meal, a Fix meals request, a leftover estimate), not only a
// pending share: a Back that finished such a task lost the request with
// its engine.
import 'dart:async' show Completer;

import 'package:calorie_tracker/services/analysis_keep_alive.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/back_gesture.dart' show predictiveBack;
import 'fakes.dart';

UiServices _services(ValueListenable<bool>? pending,
    {AnalysisKeepAlive? keepAlive}) {
  final settings = FakeSettings();
  return UiServices(
    dao: FakeDao(),
    analyzer: FakeAnalyzer(),
    executor: FakeExecutor(),
    settings: settings,
    settingsChanges: settings,
    picker: FakePicker(),
    photoIntake: FakeIntake(),
    requestPhotoPermission: () async => true,
    sharedPhotosPending: pending,
    analysisKeepAlive: keepAlive,
  );
}

/// What the app told the platform about Back: each setFrameworkHandlesBack
/// in order, and how many SystemNavigator.pop calls.
class _Platform {
  final List<bool> handlesBack = [];
  int pops = 0;

  void listen(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        handlesBack.add(call.arguments as bool);
      } else if (call.method == 'SystemNavigator.pop') {
        pops++;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }
}

void main() {
  testWidgets('Android: while a shared photo is pending, Flutter keeps Back '
      'at the root and moves the app to the back; settled, it leaves Back '
      'to the platform again', (tester) async {
    final platform = _Platform()..listen(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final pending = ValueNotifier<bool>(false);
    await tester.pumpWidget(CalorieTrackerApp(services: _services(pending)));
    await tester.pumpAndSettle();
    expect(platform.handlesBack.lastOrNull ?? false, isFalse,
        reason: 'nothing pending: Flutter leaves Back at the root to the '
            'platform (MainActivity keeps it in a task the launcher did '
            'not start, Android 14 and later)');

    // A share arrives: its photo is read and sent.
    pending.value = true;
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isTrue,
        reason: 'Flutter takes Back while the photo is pending, so Android '
            'never finishes the task itself');

    // Back through popRoute (Android 12 and lower, and Android 13's back
    // callback).
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(platform.pops, 1,
        reason: 'SystemNavigator.pop: MainActivity moves the task back');
    expect(find.byType(HomeShell), findsOneWidget);

    // The predictive back gesture (Android 14 and later), which the engine
    // sends only while Flutter handles Back.
    await predictiveBack(tester);
    expect(platform.pops, 2);
    expect(find.byType(HomeShell), findsOneWidget);

    // Its meal is written: the copy goes, and Flutter leaves Back at the
    // root to the platform again (Android's own, back-to-home preview
    // included, in a task the home screen started).
    pending.value = false;
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isFalse);
  });

  testWidgets('Android: a screen over the shell still pops first, and back '
      'at the root the guard holds again', (tester) async {
    final platform = _Platform()..listen(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final pending = ValueNotifier<bool>(true);
    await tester.pumpWidget(CalorieTrackerApp(services: _services(pending)));
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isTrue);

    final context = tester.element(find.byType(HomeShell));
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Sub page'))));
    await tester.pumpAndSettle();
    expect(find.text('Sub page'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Sub page'), findsNothing, reason: 'popped as before');
    expect(platform.pops, 0, reason: 'the app stays in front');
    expect(platform.handlesBack.last, isTrue,
        reason: 'the shell on top again, the photo still pending');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platform.pops, 1);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('Android: while an analysis is in flight (no share pending), '
      'Flutter keeps Back at the root and moves the app to the back; once '
      'it settles, Back goes to the platform again', (tester) async {
    final platform = _Platform()..listen(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final keepAlive = AnalysisKeepAlive();
    await tester.pumpWidget(CalorieTrackerApp(
        services: _services(ValueNotifier<bool>(false), keepAlive: keepAlive)));
    await tester.pumpAndSettle();
    expect(platform.handlesBack.lastOrNull ?? false, isFalse);

    // A typed meal on its way to the AI (Describe, Fix meals, a picked
    // photo or a leftover estimate are counted the same way).
    final reply = Completer<String>();
    final request = keepAlive.guard(() => reply.future);
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isTrue,
        reason: 'Flutter takes Back while the request is in flight');

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(platform.pops, 1,
        reason: 'SystemNavigator.pop: MainActivity moves the task back, the '
            'engine lives on and the reply lands');
    await predictiveBack(tester);
    expect(platform.pops, 2);
    expect(find.byType(HomeShell), findsOneWidget);

    reply.complete('saved');
    expect(await request, 'saved');
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isFalse);
  });

  testWidgets('Android: either source holds Back; neither lets it go',
      (tester) async {
    final platform = _Platform()..listen(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final pending = ValueNotifier<bool>(true);
    final keepAlive = AnalysisKeepAlive();
    await tester.pumpWidget(CalorieTrackerApp(
        services: _services(pending, keepAlive: keepAlive)));
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isTrue, reason: 'the share alone');

    final reply = Completer<void>();
    final request = keepAlive.guard(() => reply.future);
    pending.value = false;
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isTrue,
        reason: 'the share settled, the analysis still in flight');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platform.pops, 1);

    reply.complete();
    await request;
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isFalse, reason: 'neither');
    expect(
        find.byWidgetPredicate((w) => w is PopScope<Object?> && !w.canPop),
        findsNothing);
  });

  testWidgets('Android: only the analysis source (no share intake): the '
      'guard is there and idle until a request begins', (tester) async {
    final platform = _Platform()..listen(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final keepAlive = AnalysisKeepAlive();
    await tester.pumpWidget(
        CalorieTrackerApp(services: _services(null, keepAlive: keepAlive)));
    await tester.pumpAndSettle();
    expect(platform.handlesBack, everyElement(isFalse));
    final reply = Completer<void>();
    final request = keepAlive.guard(() => reply.future);
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isTrue);
    reply.complete();
    await request;
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isFalse);
  });

  testWidgets('no shared photo pending ever (the default): the shell has no '
      'guard, and nothing changes', (tester) async {
    final platform = _Platform()..listen(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(CalorieTrackerApp(services: _services(null)));
    await tester.pumpAndSettle();
    expect(platform.handlesBack, everyElement(isFalse));
    expect(
        find.byWidgetPredicate((w) => w is PopScope<Object?> && !w.canPop),
        findsNothing);
  });

  testWidgets('iPhone: no guard, whatever is pending', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final pending = ValueNotifier<bool>(true);
    final keepAlive = AnalysisKeepAlive();
    final reply = Completer<void>();
    final request = keepAlive.guard(() => reply.future);
    await tester.pumpWidget(CalorieTrackerApp(
        services: _services(pending, keepAlive: keepAlive)));
    await tester.pumpAndSettle();
    reply.complete();
    await request;
    expect(
        find.byWidgetPredicate((w) => w is PopScope<Object?> && !w.canPop),
        findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
