/// Android's predictive back gesture in a widget test, sent as the engine
/// sends it over `flutter/backgesture` (Flutter's own
/// predictive_back_page_transitions_builder_test does the same). Android 14
/// and later report the gesture's progress as it moves; the app sees it
/// with android:enableOnBackInvokedCallback="true" (AndroidManifest.xml),
/// and Android 16 for targetSdk 36 without it.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _send(WidgetTester tester, String method,
        [Map<String, Object?>? arguments]) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) {});

/// A back gesture from the left edge starts.
Future<void> backGestureStart(WidgetTester tester) async {
  await _send(tester, 'startBackGesture', {
    'touchOffset': [5.0, 300.0],
    'progress': 0.0,
    'swipeEdge': 0, // left
  });
  await tester.pump();
}

/// The gesture moves on to [progress] (0 to 1).
Future<void> backGestureProgress(WidgetTester tester, double progress) async {
  await _send(tester, 'updateBackGestureProgress', {
    'x': 5.0 + 300.0 * progress,
    'y': 300.0,
    'progress': progress,
    'swipeEdge': 0,
  });
  await tester.pump();
}

/// The finger lifts past the point of no return: the system's back.
Future<void> backGestureCommit(WidgetTester tester) async {
  await _send(tester, 'commitBackGesture');
  await tester.pumpAndSettle();
}

/// The finger lifts before it: nothing happens.
Future<void> backGestureCancel(WidgetTester tester) async {
  await _send(tester, 'cancelBackGesture');
  await tester.pumpAndSettle();
}

/// A whole back gesture: start, move, let go past the point of no return.
Future<void> predictiveBack(WidgetTester tester) async {
  await backGestureStart(tester);
  await backGestureProgress(tester, 0.35);
  await backGestureCommit(tester);
}

/// The predictive-back transition Flutter shows while the gesture runs
/// (PredictiveBackPageTransitionsBuilder's private shared-element one).
final Finder predictiveBackTransition = find.byWidgetPredicate((w) =>
    w.runtimeType.toString() == '_PredictiveBackSharedElementPageTransition');
