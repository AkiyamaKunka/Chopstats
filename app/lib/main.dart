/// Entry point: async init (settings → dao → reclaimStaleProcessing →
/// services, wired in ui/di.dart), then the Material app shell.
library;

import 'dart:async' show Timer;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:sqflite/sqflite.dart' show DatabaseException;

import 'ui/app.dart';
import 'ui/di.dart';
import 'ui/l10n.dart';
import 'ui/unit_text.dart';
import 'ui/widgets/usual_offer_card.dart' show usualSnackClosing;

final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Snackbar sink for the photo pipeline and the startup glue (di.dart
/// `notify`). A message can arrive BEFORE the first frame: a cold-start
/// share whose verdict needs no analyzer call (duplicate / already logged,
/// DB-only) resolves while init is still running, and
/// `currentState?.showSnackBar` dropped it on the floor. Held until a frame
/// has mounted the ScaffoldMessenger, then shown in arrival order.
final List<_AppSnack> _pendingSnackbars = [];

/// One message waiting for the messenger.
class _AppSnack {
  const _AppSnack(this.message,
      {this.action, this.offered, this.offerChanges, this.givesWay = false});
  final String message;
  final SnackBarAction? action;

  /// Asked as the message is shown: whether [action] is offered then. Null:
  /// always. A throw counts as no.
  final bool Function()? offered;

  /// Tells when [offered] may have changed. While the message is up with
  /// [action], it is asked again each time: once it says no, the action
  /// is taken away. A message already seen goes; one that has only just
  /// come on screen shows plain instead.
  final Listenable? offerChanges;

  /// Under a screen reader [action] holds the message up only until
  /// another message waits behind it: then it goes once it has had
  /// [kAppActionSnackDuration], and the next one is shown.
  final bool givesWay;
}

void showAppSnackbar(String message) => _holdSnackbar(_AppSnack(message));

/// [showAppSnackbar] with one action button: the restaurant assist's Undo
/// after it applied a chain's published numbers (di.dart `notifyAction`).
void showAppSnackbarWithAction(
        String message, String action, void Function() onAction) =>
    _holdSnackbar(_AppSnack(message,
        action: SnackBarAction(label: action, onPressed: onAction)));

/// [showAppSnackbar] with a View that goes to a meal: the one a shared
/// photo logged (Android, di.dart `notifyView`). Offered only while
/// [available] says that the app could go there at once (meal_reveal.dart:
/// no unsaved changes or question open over its tabs, nobody typing):
/// asked as the message is shown, and again each time [changes] notifies
/// while it is up. A View no longer offered is taken away, so it never
/// sits on a screen it could not leave at once; the message shows plain
/// where it was not offered.
///
/// It leaves after [kAppActionSnackDuration]. With a screen reader on it
/// is held, like the lookup's Undo, while it is the last message: reaching
/// View takes longer there. A message that arrives behind it is not held
/// back: the View goes once it has had its 8 s (a several-photo share's
/// each View).
void showAppSnackbarWithView(String message, String action,
        void Function() onAction, bool Function() available,
        Listenable changes) =>
    _holdSnackbar(_AppSnack(message,
        action: SnackBarAction(label: action, onPressed: onAction),
        offered: available,
        offerChanges: changes,
        givesWay: true));

void _holdSnackbar(_AppSnack snack) {
  _pendingSnackbars.add(snack);
  final shown = _shown;
  if (shown != null) _giveWay(shown);
  _flushSoon();
}

/// [_AppSnack.action] if it is offered now.
SnackBarAction? _actionNow(_AppSnack s) =>
    s.action != null && _offeredNow(s) ? s.action : null;

/// Whether [_AppSnack.offered] says yes now (no check: yes; a throw: no).
bool _offeredNow(_AppSnack s) {
  final offered = s.offered;
  if (offered == null) return true;
  try {
    return offered();
  } catch (_) {
    return false;
  }
}

/// [_flushSnackbars] now, or after the next frame when the messenger is
/// not mounted yet.
void _flushSoon() {
  if (!_flushSnackbars()) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushSnackbars());
  }
}

/// How long a snackbar with an action (the lookup's Undo) stays up: the
/// same 8 s as the usual-foods and Settings ones.
const Duration kAppActionSnackDuration = Duration(seconds: 8);

/// The one message of ours the messenger holds (on screen, or behind a
/// screen's own snackbar), until it closes.
_Shown? _shown;

class _Shown {
  _Shown(this.messenger, this.controller, this.snack,
      {required this.withAction, required this.held});

  final ScaffoldMessengerState messenger;
  final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller;
  final _AppSnack snack;

  /// Its action is on it: it was offered as the message was handed over.
  final bool withAction;

  /// Held up for a screen reader (SnackBar.persist).
  final bool held;

  /// On screen. The messenger builds only the snackbar it shows, not the
  /// ones queued behind it, so once its content was built it is the
  /// messenger's current snackbar until it closes, and hiding the
  /// current one hides this one and no screen's own.
  bool onScreen = false;

  /// A held message that gives way ([_AppSnack.givesWay]) has had its
  /// [kAppActionSnackDuration].
  bool due = false;
  Timer? dueTimer;
}

/// [shown]'s snackbar was built: it is on screen ([_Shown.onScreen]).
/// Called while building, so what it changes waits for the frame's end.
void _onScreen(_Shown shown) {
  if (shown.onScreen) return; // built again, on another screen's Scaffold
  shown.onScreen = true;
  if (shown.held && shown.snack.givesWay) {
    shown.dueTimer = Timer(kAppActionSnackDuration, () {
      shown.due = true;
      _giveWay(shown);
    });
  }
  // It may have waited behind a screen's own snackbar since its action was
  // offered: asked again now that it shows.
  if (shown.withAction && shown.snack.offerChanges != null) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _offerChanged(shown, justShown: true));
  }
}

/// A held View that has had its time goes once another message waits.
void _giveWay(_Shown shown) {
  if (!identical(_shown, shown) || !shown.due || !shown.onScreen) return;
  if (_pendingSnackbars.isEmpty) return;
  shown.messenger.hideCurrentSnackBar();
}

/// [shown]'s action may no longer be offered ([_AppSnack.offerChanges]):
/// taken away if it is not. A message that was seen goes; one that has
/// only just come on screen ([justShown]) shows plain in its place.
/// Before it is on screen nothing is done: it is asked as it shows.
void _offerChanged(_Shown shown, {bool justShown = false}) {
  if (!identical(_shown, shown) || !shown.withAction || !shown.onScreen) {
    return;
  }
  if (_offeredNow(shown.snack)) return;
  if (justShown) {
    _pendingSnackbars.insert(0, _AppSnack(shown.snack.message));
    shown.messenger.removeCurrentSnackBar();
  } else {
    shown.messenger.hideCurrentSnackBar();
  }
}

/// Calls [onShown] when first built: as a snackbar's content, as the
/// messenger puts that snackbar on screen.
class _OnScreen extends StatefulWidget {
  const _OnScreen({required this.onShown, required this.child});

  final VoidCallback onShown;
  final Widget child;

  @override
  State<_OnScreen> createState() => _OnScreenState();
}

class _OnScreenState extends State<_OnScreen> {
  @override
  void initState() {
    super.initState();
    widget.onShown();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The usual-foods snackbar's closing that [_flushSnackbars] waits for.
Future<void>? _waitingFor;

/// True once the messenger is mounted (the next pending message is on it,
/// or waits for the one it holds). Not mounted (startup error screen):
/// kept for the next message or frame.
///
/// One at a time, so a usual-foods result and its Undo (showUsualSnack,
/// shown in place of the snackbar that is up) are next on screen, and the
/// messages still pending here follow it (owner decision 2026-11-11, RC
/// 1.6.0 finding 4). Handed over all at once, a catch-up's "Logged" lines
/// sat in the messenger's own queue, ahead of the Undo, 4 s each.
///
/// None is handed over while a usual-foods snackbar is up either
/// (usualSnackClosing): in the messenger's queue the message would wait
/// behind it, and a second Use, which replaces only the snackbar that is
/// up, would put its own Undo behind the message.
///
/// A snackbar with an action never times out by default (SnackBar.persist
/// defaults to `action != null`): the lookup's Undo stayed up until tapped,
/// and every later message queued unseen behind it. It times out after
/// [kAppActionSnackDuration] and is held only with a screen reader on,
/// where reaching Undo takes longer (the usual-foods rule); a View
/// ([showAppSnackbarWithView]) is held so too, until a message waits
/// behind it.
bool _flushSnackbars() {
  final messenger = messengerKey.currentState;
  if (messenger == null) return false;
  final shown = _shown;
  // A disposed messenger never reports its snackbars closed: once it is
  // gone, nothing waits for it.
  if (shown != null &&
      identical(shown.messenger, messenger) &&
      messenger.mounted) {
    return true;
  }
  _shown = null;
  if (_pendingSnackbars.isEmpty) return true;
  final usual = usualSnackClosing(messenger);
  if (usual != null) {
    if (!identical(_waitingFor, usual)) {
      _waitingFor = usual;
      usual.whenComplete(() {
        if (identical(_waitingFor, usual)) _waitingFor = null;
        _flushSoon();
      });
    }
    return true;
  }
  final s = _pendingSnackbars.removeAt(0);
  final action = _actionNow(s);
  final held =
      action != null && MediaQuery.accessibleNavigationOf(messenger.context);
  // An action that can be taken away, or a held message that gives way,
  // needs to know when its snackbar is on screen.
  final watched = action != null && (s.offerChanges != null || s.givesWay);
  late final _Shown handed;
  // In the app language of the screen it shows on: a number keeps its
  // unit in Chinese ('已记录：… —— 约 485 千卡').
  final Widget text =
      Builder(builder: (context) => unitText(context.l10n, s.message));
  final Widget content = watched
      ? _OnScreen(onShown: () => _onScreen(handed), child: text)
      : text;
  final controller = messenger.showSnackBar(action == null
      ? SnackBar(content: content)
      : SnackBar(
          content: content,
          action: action,
          duration: kAppActionSnackDuration,
          persist: held,
        ));
  handed = _Shown(messenger, controller, s,
      withAction: action != null, held: held);
  _shown = handed;
  final changes = action == null ? null : s.offerChanges;
  void offerChanged() => _offerChanged(handed);
  changes?.addListener(offerChanged);
  controller.closed.whenComplete(() {
    changes?.removeListener(offerChanged);
    handed.dueTimer?.cancel();
    if (!identical(_shown, handed)) return;
    _shown = null;
    _flushSoon();
  });
  return true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformDispatcher.instance.onError = onUncaughtError;
  await _boot();
}

/// The root isolate's uncaught errors. The engine's own report of one
/// ('Unhandled Exception: ' and its text) reaches the device log in release
/// builds too, and sqflite's text carries the statement and its arguments:
/// meal text, weights, girths. A database error is logged by its type and
/// its stack, never its text, and handled; every other error goes on to
/// the engine's report as before (false). A backstop: the code that writes
/// catches its errors.
///
/// The stack is frames only (function, file, line; in a release build
/// addresses, which `flutter symbolize` reads with the Dart symbols each
/// release keeps), so it says which write threw. The string as the VM
/// made it: debugPrintStack parses every frame, and a release build's
/// split-debug-info frames do not parse (it throws on them).
@visibleForTesting
bool onUncaughtError(Object error, StackTrace stack) {
  if (error is! DatabaseException) return false;
  debugPrint('Uncaught database error (${error.runtimeType})\n$stack');
  return true;
}

/// One startup attempt. A failure shows [StartupErrorApp], which calls this
/// again when the app returns to the foreground: the usual cause is an iOS
/// launch while the phone is still locked before the stored keys have
/// moved to the after-first-unlock keychain class — unlocking fixes it,
/// and nothing should require a force-quit (2026-10-09). AppSettings.load
/// is init's first step, so a keychain failure leaves nothing half-done.
Future<void> _boot() async {
  try {
    final services = await AppServices.init(
      // Notification-style snackbar for background photo saves and
      // share-sheet verdicts (spec §6).
      notify: showAppSnackbar,
      // The restaurant assist's "used the chain's numbers" line and its Undo.
      notifyAction: showAppSnackbarWithAction,
      // Android: a shared photo's "Meal logged" line and its View.
      notifyView: showAppSnackbarWithView,
    );
    runApp(CalorieTrackerApp(services: services.ui, messengerKey: messengerKey));
  } catch (e) {
    // Startup must never leave a blank screen; surface the failure.
    // Only a keychain failure (PlatformException from the settings load,
    // init's first step) is retried: it clears once the phone unlocks. A
    // later step failing would re-run init's side effects on every resume.
    runApp(StartupErrorApp(
        error: '$e', onRetry: e is PlatformException ? _boot : null));
  }
}
