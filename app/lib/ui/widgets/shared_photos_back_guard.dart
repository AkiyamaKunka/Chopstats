/// Back at the root while a shared photo is on its way to a meal (Android,
/// decision 6.1, Q9; review 2026-11-20).
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart';

/// Keeps the app running when Back reaches the root while [pending] is
/// true (ShareIntake.photosPending: a shared photo with no verdict written
/// yet), on Android.
///
/// MainActivity.popSystemNavigator moves the task to the back instead of
/// finishing it, but only a Back that Flutter handles gets there. At the
/// root, with nothing to pop, Flutter hands Back to Android
/// (setFrameworkHandlesBack(false)). With predictive back on (every
/// Android 16 phone, since the app targets SDK 36, and Android 13-15 with
/// android:enableOnBackInvokedCallback) Android then answers that Back
/// itself: it moves to the back only a task the home screen started with
/// the launcher intent, and FINISHES any other, such as the task a share
/// from Gallery started, destroying the engine in the middle of the
/// analysis. The photo came back only at the next start, sent to the AI a
/// second time, or never when that start was a day later.
///
/// So while [pending] is true the root route does not pop (PopScope with
/// canPop false): Flutter keeps the Back (setFrameworkHandlesBack(true))
/// and, when one reaches the root, calls SystemNavigator.pop, which
/// MainActivity answers with moveTaskToBack. The engine lives on and logs
/// the photo, on every Android version. Once nothing is pending, Back at
/// the root is Android's own again, with its back-to-home preview. Screens
/// and dialogs over the shell pop as before. iPhone has no Back: [child]
/// as it is.
class SharedPhotosBackGuard extends StatelessWidget {
  const SharedPhotosBackGuard(
      {super.key, required this.pending, required this.child});

  final ValueListenable<bool> pending;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: pending,
      child: child,
      builder: (context, busy, child) => PopScope<Object?>(
        canPop: !busy,
        onPopInvokedWithResult: (didPop, _) {
          // A Back that reached the root while a photo is pending: to the
          // back, never finished (MainActivity.popSystemNavigator).
          if (!didPop && busy) {
            unawaited(SystemNavigator.pop()
                .then((_) {}, onError: (Object _) {}));
          }
        },
        child: child!,
      ),
    );
  }
}
