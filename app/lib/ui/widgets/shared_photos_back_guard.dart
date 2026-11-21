/// Back at the root while a shared photo is on its way to a meal, or an
/// analysis the user started is in flight (Android, decision 6.1, Q9;
/// review 2026-11-20; owner decision 9).
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart';

/// Keeps the app running when Back reaches the root while [pending] is
/// true (ShareIntake.photosPending: a shared photo not settled yet) or
/// [analyzing] is (AnalysisKeepAlive.inFlight: a photo picked or shared, a
/// Photo Coverage photo, a leftover estimate, a typed meal or a Fix meals
/// request on its way to the AI or the user's own server), on Android, in
/// every task.
///
/// MainActivity.popSystemNavigator moves the task to the back instead of
/// finishing it, but only a Back that Flutter handles gets there. With
/// predictive back on (android:enableOnBackInvokedCallback, Android 13 and
/// later), at an idle root Flutter hands Back to Android
/// (setFrameworkHandlesBack(false)), which answers it itself: Android 13
/// moves a task whose root is a launcher activity, as MainActivity is, to
/// the back, and Android 14 and later an activity the home screen started.
/// On Android 14 and later MainActivity keeps Flutter's callback unless the
/// home screen made both its first start and its latest
/// (MainActivity.setFrameworkHandlesBack), so after a share, the setup
/// link, a notification, a picker, split screen or Play's Open button its
/// Back reaches popSystemNavigator anyway. Android 15 QPR1 and later also
/// judge a start the app cannot see, a return from Recents, by the app that
/// shows Recents, which is not the home app with a third-party home app as
/// the default; they then FINISH the activity on a Back at an idle root. A
/// photo shared into the running activity (singleTask), or any analysis
/// started there, would die with its engine in the middle of the request:
/// a shared photo came back only at the next start, sent to the AI a second
/// time, or never when that start was a day later, and a picked photo, a
/// typed meal or a fix was lost.
///
/// So while either is true the root route does not pop (PopScope with
/// canPop false): Flutter keeps the Back (setFrameworkHandlesBack(true))
/// and, when one reaches the root, calls SystemNavigator.pop, which
/// MainActivity answers with moveTaskToBack. The engine lives on and
/// finishes the request, in every task on every Android version (and the
/// analysis keep-alive keeps the process running meanwhile);
/// where Android or MainActivity would move the task back anyway, the
/// guard does the same. Once nothing is pending or in flight, Back at the
/// root is as it was, with Android's back-to-home preview in a task the
/// home screen started. Screens and dialogs over the shell pop as before.
/// iPhone has no Back: [child] as it is. Either source may be null (none
/// in that build or test).
class SharedPhotosBackGuard extends StatelessWidget {
  const SharedPhotosBackGuard(
      {super.key, this.pending, this.analyzing, required this.child});

  /// A shared photo not settled yet (ShareIntake.photosPending).
  final ValueListenable<bool>? pending;

  /// An analysis the user started in flight (AnalysisKeepAlive.inFlight).
  final ValueListenable<bool>? analyzing;
  final Widget child;

  /// Whether a source says the app must stay.
  bool get _busy =>
      (pending?.value ?? false) || (analyzing?.value ?? false);

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) return child;
    final sources = [?pending, ?analyzing];
    if (sources.isEmpty) return child;
    return ListenableBuilder(
      listenable: Listenable.merge(sources),
      child: child,
      builder: (context, child) {
        final busy = _busy;
        return PopScope<Object?>(
          canPop: !busy,
          onPopInvokedWithResult: (didPop, _) {
            // A Back that reached the root while a photo is pending or an
            // analysis in flight: to the back, never finished
            // (MainActivity.popSystemNavigator).
            if (!didPop && busy) {
              unawaited(SystemNavigator.pop()
                  .then((_) {}, onError: (Object _) {}));
            }
          },
          child: child!,
        );
      },
    );
  }
}
