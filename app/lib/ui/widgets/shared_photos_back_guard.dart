/// Back at the root while a shared photo is on its way to a meal (Android,
/// decision 6.1, Q9; review 2026-11-20).
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart';

/// Keeps the app running when Back reaches the root while [pending] is
/// true (ShareIntake.photosPending: a shared photo not settled yet), on
/// Android, in every task.
///
/// MainActivity.popSystemNavigator moves the task to the back instead of
/// finishing it, but only a Back that Flutter handles gets there. With
/// predictive back on (android:enableOnBackInvokedCallback, Android 13 and
/// later), at an idle root Flutter hands Back to Android
/// (setFrameworkHandlesBack(false)), which answers it itself: Android 13
/// moves a task whose root is a launcher activity, as MainActivity is, to
/// the back, and Android 14 and later a task the home screen started with
/// the launcher intent. Any other task keeps Flutter's callback on
/// Android 14 and later (MainActivity.setFrameworkHandlesBack: a share,
/// the setup link, a notification), so its Back reaches popSystemNavigator
/// anyway. One start is left that Android 14 and later FINISH on that
/// Back: the launcher intent sent from somewhere other than the home
/// screen (Play's Open button), which looks like the launcher's own to the
/// app. A photo shared into such a task (singleTask: the share reaches the
/// running activity) would die with its engine in the middle of the
/// analysis, and come back only at the next start, sent to the AI a
/// second time, or never when that start was a day later.
///
/// So while [pending] is true the root route does not pop (PopScope with
/// canPop false): Flutter keeps the Back (setFrameworkHandlesBack(true))
/// and, when one reaches the root, calls SystemNavigator.pop, which
/// MainActivity answers with moveTaskToBack. The engine lives on and logs
/// the photo, in every task on every Android version; where Android or
/// MainActivity would move the task back anyway, the guard does the same.
/// Once nothing is pending, Back at the root is as it was, with Android's
/// back-to-home preview in a task the home screen started. Screens and
/// dialogs over the shell pop as before. iPhone has no Back: [child] as it
/// is.
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
