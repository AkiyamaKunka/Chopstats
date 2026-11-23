/// "Show me that meal" (Android): the View on the snackbar after a shared
/// photo was logged, and a tap on a Logged meals card, ask the app shell
/// to go to the meal (HomeShell): Today, scrolled to the meal and briefly
/// ringed, or that day in History for a meal dated another day. A tap on
/// the cards' group summary asks for Today itself ([MealReveal.today]).
///
/// The shell goes there at once when it can: the screens open over the
/// tabs that Back would close without asking (a History day, a Settings
/// page, an editor with nothing changed) are closed for it. Nothing is
/// closed or covered while a screen holds unsaved changes (its discard
/// guard), a dialog, sheet or menu is open, or a text field has the focus:
/// the request waits until that ends, if that is within
/// [MealReveals.waitLimit]. The View action is offered only while the
/// shell could go there at once ([MealReveals.canShowNow]), and is taken
/// away when that stops ([MealReveals.availability]).
library;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, Listenable, VoidCallback, immutable;

import '../services/report/notifications.dart' show ReportNotifier;
import 'photo_pipeline.dart' show PhotoOutcome, PhotoOutcomeKind;

/// One meal to show, by its id in the meals table, or Today itself
/// ([today]).
@immutable
class MealReveal {
  const MealReveal(int this.mealId);

  const MealReveal._today() : mealId = null;

  /// Today, no meal: what a tap on the Logged meals cards' group summary
  /// asks for (ReportNotifier.mealGroupPayload; PR80-B2, 2026-11-23). The
  /// shell goes there as for a meal that is gone: Today, nothing ringed,
  /// over the same screens and with the same wait. Today because that is
  /// where the meals the cards announce are listed: the background scan
  /// logs photos soon after they are taken. Not one of those meals: the
  /// tap was on the group, and a tap on any line of the collapsed group
  /// is the summary's. A card whose meal is dated another day (a photo
  /// from before midnight) still goes to that day, from the expanded
  /// group.
  static const MealReveal today = MealReveal._today();

  /// The meal's id; null for [today].
  final int? mealId;

  static const String _prefix = 'meal:';

  /// The payload of a Logged meals card for this meal
  /// (ReportNotifier.showMealCard): handed back by Android when the card
  /// is tapped. For [today], the group summary's.
  String get payload {
    final id = mealId;
    return id == null ? ReportNotifier.mealGroupPayload : '$_prefix$id';
  }

  /// The meal a card's [payload] names, or [today] for the group
  /// summary's; null for any other payload (the daily summary's, a
  /// notice's none, anything malformed).
  static MealReveal? fromPayload(String? payload) {
    if (payload == ReportNotifier.mealGroupPayload) return today;
    if (payload == null || !payload.startsWith(_prefix)) return null;
    final digits = payload.substring(_prefix.length);
    if (!RegExp(r'^[0-9]{1,15}$').hasMatch(digits)) return null;
    final id = int.parse(digits);
    return id > 0 ? MealReveal(id) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is MealReveal && other.mealId == mealId;

  @override
  int get hashCode => mealId.hashCode;

  @override
  String toString() => 'MealReveal(${mealId ?? 'today'})';
}

/// The meal a shared photo's verdict [o] logged or changed, for the View
/// on its snackbar: the new meal, or the meal its leftovers were deducted
/// from. Null for any other verdict, and for a photo that was not shared
/// (PhotoOutcome.shared): one picked in the add flow, or one the automatic
/// scan logged.
MealReveal? revealForShared(PhotoOutcome o) {
  if (!o.shared) return null;
  return revealForMeal(o);
}

/// The meal a verdict [o] logged or changed: the new meal of a save, or
/// the meal a leftover photo cut. Null for every other verdict, or without
/// a meal id.
MealReveal? revealForMeal(PhotoOutcome o) {
  if (o.kind != PhotoOutcomeKind.saved &&
      o.kind != PhotoOutcomeKind.leftoverApplied) {
    return null;
  }
  final id = o.mealId;
  return id == null || id <= 0 ? null : MealReveal(id);
}

/// Taps on this app's cards (Android), turned into [MealReveal] requests:
/// [onTap] for one tapped while this engine runs (ReportNotifier's
/// onTap), [launch] for the one that started it. A card's [MealReveal
/// .payload] names its meal, and the cards' group summary asks for
/// [MealReveal.today]; any other card (the daily summary, a notice) asks
/// for nothing and opens the app as before.
///
/// One tap, one request: when Android recreates the activity for a tap
/// (its process had been stopped), the tap arrives as a new intent before
/// this engine listens, and the plugin hands it to [onTap] as soon as it
/// listens, during its init, and also reports it as the launch. So the
/// launch is not read once [onTap] has had a tap.
class MealCardTaps {
  MealCardTaps(this._reveals);

  final MealReveals _reveals;
  bool _tapped = false;

  /// A card tapped while this engine runs.
  void onTap(String? payload) {
    _tapped = true;
    final reveal = MealReveal.fromPayload(payload);
    if (reveal != null) _reveals.request(reveal);
  }

  /// The card whose tap started this engine, read once the notifier is
  /// initialized ([launchPayload]: ReportNotifier.launchPayload).
  Future<void> launch(Future<String?> Function() launchPayload) async {
    if (_tapped) return;
    final payload = await launchPayload();
    if (_tapped) return; // a newer tap came meanwhile: it wins
    final reveal = MealReveal.fromPayload(payload);
    if (reveal != null) _reveals.request(reveal);
  }
}

/// Carries [MealReveal] requests to the app shell, which [attach]es once it
/// is up. One request waits at a time, the newest: a request made before
/// the shell is up (a cold start from a card), or while it cannot show it
/// (unsaved changes or a question open over it, or typing), is kept until
/// the shell takes it, for at most [waitLimit].
class MealReveals {
  MealReveals({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// How long a request waits for the shell: a user who tapped a card
  /// while an editor held unsaved changes, a question was open or they
  /// were typing, and is still there a minute later, has moved on. They
  /// are not taken to the meal when that ends.
  static const Duration waitLimit = Duration(seconds: 60);

  final _Signal _availability = _Signal();

  /// Tells when [canShowNow] may have changed: a screen came or went over
  /// the tabs, one held or let go of unsaved changes, or the focus moved
  /// (the shell's [availabilityChanged]). The View on a message listens
  /// while it is up, and is taken away once it is no longer offered.
  Listenable get availability => _availability;

  /// The shell: [canShowNow] may have changed.
  void availabilityChanged() => _availability.ping();

  ({MealReveal reveal, DateTime at})? _waiting;
  VoidCallback? _wake;
  bool Function()? _canShow;

  /// Asks the shell to show [reveal]. It replaces any request still
  /// waiting.
  void request(MealReveal reveal) {
    _waiting = (reveal: reveal, at: _clock());
    try {
      _wake?.call();
    } catch (_) {
      // The shell asks again when it is next back on top.
    }
  }

  /// The request waiting to be shown, unless it waited longer than
  /// [waitLimit]: then it is dropped.
  MealReveal? get waiting {
    final w = _waiting;
    if (w == null) return null;
    final age = _clock().difference(w.at);
    if (age > waitLimit || age.isNegative) {
      _waiting = null;
      return null;
    }
    return w.reveal;
  }

  /// Takes [waiting] (the shell shows it now).
  MealReveal? take() {
    final r = waiting;
    _waiting = null;
    return r;
  }

  /// Whether the shell could show a meal right now: it is up, nothing open
  /// over it holds unsaved changes or asks a question, and nobody is
  /// typing. The View action is offered only then. False with no shell, or
  /// when the shell cannot say.
  bool get canShowNow {
    try {
      return _canShow?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The shell is up: [wake] is called for each request (and now, for one
  /// already waiting), and [canShowNow] answers [MealReveals.canShowNow].
  void attach(VoidCallback wake, {required bool Function() canShowNow}) {
    _wake = wake;
    _canShow = canShowNow;
    if (_waiting != null) wake();
  }

  /// The shell that attached [wake] is going.
  void detach(VoidCallback wake) {
    // ==, not identical: two tear-offs of one method are equal only.
    if (_wake != wake) return;
    _wake = null;
    _canShow = null;
  }
}

/// [MealReveals.availability]: notifyListeners is protected.
class _Signal extends ChangeNotifier {
  void ping() => notifyListeners();
}
