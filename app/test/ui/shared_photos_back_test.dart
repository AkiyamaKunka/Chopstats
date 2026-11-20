// Q9 under predictive back (review 2026-11-20): MainActivity's
// popSystemNavigator moves the task to the back, but Flutter calls it only
// for a Back it handles. At the root it handed Back to Android
// (setFrameworkHandlesBack(false)), and with predictive back on (every
// Android 16 phone, the app targeting SDK 36) Android finished a task a
// share started: the engine died mid-analysis, and the photo came back
// only at the next start, sent to the AI a second time, or never when that
// start was a day later.
//
// While a shared photo is pending the shell's guard keeps the Back in
// Flutter, and a Back at the root calls SystemNavigator.pop, which lands in
// popSystemNavigator: through the old key path (popRoute) and through the
// predictive gesture alike. Once the photo is settled, Back at the root is
// Android's own again. iPhone has no Back and no guard.
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

UiServices _services(ValueListenable<bool>? pending) {
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

/// The Android 14+ predictive back gesture as the engine sends it
/// (FlutterActivity's OnBackAnimationCallback), let go past the point of
/// no return. Only sent while Flutter handles Back.
Future<void> _predictiveBack(WidgetTester tester) async {
  Future<void> send(String method, [Map<String, Object?>? arguments]) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall(method, arguments)),
          (_) {});
  await send('startBackGesture',
      {'touchOffset': [5.0, 300.0], 'progress': 0.0, 'swipeEdge': 0});
  await tester.pump();
  await send('updateBackGestureProgress',
      {'x': 120.0, 'y': 300.0, 'progress': 0.4, 'swipeEdge': 0});
  await tester.pump();
  await send('commitBackGesture');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Android: while a shared photo is pending, Flutter keeps Back '
      'at the root and moves the app to the back; settled, Back is '
      'Android\'s again', (tester) async {
    final platform = _Platform()..listen(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final pending = ValueNotifier<bool>(false);
    await tester.pumpWidget(CalorieTrackerApp(services: _services(pending)));
    await tester.pumpAndSettle();
    expect(platform.handlesBack.lastOrNull ?? false, isFalse,
        reason: 'nothing pending: Android answers Back at the root');

    // A share arrives: its photo is read and sent.
    pending.value = true;
    await tester.pumpAndSettle();
    expect(platform.handlesBack.last, isTrue,
        reason: 'Flutter takes Back while the photo is pending, so Android '
            'never finishes the task itself');

    // Back with the key (API 32 and lower, or predictive back off).
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(platform.pops, 1,
        reason: 'SystemNavigator.pop: MainActivity moves the task back');
    expect(find.byType(HomeShell), findsOneWidget);

    // The predictive back gesture (Android 14 and later).
    await _predictiveBack(tester);
    expect(platform.pops, 2);
    expect(find.byType(HomeShell), findsOneWidget);

    // Its meal is written: the copy goes, and Back is Android's own again
    // (its back-to-home preview included).
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
    await tester.pumpWidget(CalorieTrackerApp(services: _services(pending)));
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate((w) => w is PopScope<Object?> && !w.canPop),
        findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
