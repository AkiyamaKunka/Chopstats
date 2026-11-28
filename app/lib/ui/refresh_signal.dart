/// "The meal list changed" broadcast.
///
/// The pipeline can save a meal at ANY time — the foreground watcher, the
/// launch/resume catch-up, the coverage screen's Log/Retry, or the
/// WorkManager isolate handing over on resume. The screens live in an
/// IndexedStack and are built once, so without a signal they keep showing
/// pre-save data until something else happens to reload them: a real
/// 07:40 latte was analyzed and saved correctly at 18:06 and still looked
/// missing to the user (2026-07-26 report).
///
/// A plain counter rather than a stream: listeners only need "something
/// changed, re-query", and a ValueNotifier needs no lifecycle management.
///
/// The counter belongs to ONE engine. The background run is another
/// isolate with its own copy, which nobody listens to: a meal it saved
/// while the app was open stayed invisible until the next return to the
/// app, a tab tap or a save of the app's own (2026-11-27: the app was
/// opened as a run was analyzing a photo, and Today went on showing 0).
/// So the run leaves a note where both engines can read it
/// ([noteMealsChangedForOtherEngine]), and the app looks for it
/// ([OtherEngineMeals]) and sends its own signal when it finds a new one.
library;

import 'package:flutter/foundation.dart';

import '../services/local_store.dart';

final ValueNotifier<int> mealsChangedSignal = ValueNotifier<int>(0);

void signalMealsChanged() => mealsChangedSignal.value++;

/// The local_store.dart document that holds the note: `{at: <UTC time>}`,
/// when an engine with no listeners of its own last changed the meal list.
/// A time and nothing else. In the backup-excluded store: it means nothing
/// on another phone, and reading it is one small file read with no cache
/// in between (shared_preferences would need a full reload of the store
/// for every look).
const String mealsChangedDocument = 'meals_changed';

/// [mealsChangedDocument]'s schema version.
const int mealsChangedDocumentVersion = 1;

/// The background run's half: it saved a meal, or cut one for leftovers
/// (PhotoPipeline.onMealSaved in ui/background_glue.dart). Never throws: a
/// note that cannot be written only leaves the app as it was before notes
/// existed.
Future<void> noteMealsChangedForOtherEngine(
  LocalNoBackupStore store, {
  DateTime Function() clock = DateTime.now,
}) async {
  try {
    await store.write(mealsChangedDocument, {
      'at': clock().toUtc().toIso8601String(),
    }, version: mealsChangedDocumentVersion);
  } catch (_) {}
}

/// The app's half: looks for a note newer than the last one it saw, and
/// sends this engine's own signal once for it. The app looks when it
/// returns to the foreground, after each photo of its own scan, and every
/// few seconds while Today is on screen (ui/app.dart, ui/di.dart).
class OtherEngineMeals {
  OtherEngineMeals({
    required this.store,
    this.onChanged = signalMealsChanged,
    this.minGap = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Where the note is read from (the app's: LocalNoBackupStore.platform).
  final LocalNoBackupStore store;

  /// Called once per new note: this engine's own meals-changed signal.
  final void Function() onChanged;
  final DateTime Function() _clock;

  /// The least time between two looks that were not forced: a scan walks
  /// dozens of already-logged photos a second, and each asks for one.
  final Duration minGap;

  String? _seen;
  bool _primed = false;
  DateTime? _lastLook;
  Future<bool>? _looking;

  /// Takes the note as it stands for seen: what the screens load from here
  /// on already holds whatever it tells of. Called once at launch, before
  /// the first screen reads the meals. Never throws.
  Future<void> prime() async {
    _seen = await _read();
    _primed = true;
  }

  /// Looks at the note. A new one since the last look: [onChanged] is
  /// called once, and the answer is true. [force]: look even right after
  /// another look ([minGap]). Looks asked for while one is in flight share
  /// it. Never throws.
  Future<bool> check({bool force = false}) {
    final looking = _looking;
    if (looking != null) return looking;
    final now = _clock();
    final last = _lastLook;
    if (!force && last != null && now.difference(last).abs() < minGap) {
      return Future<bool>.value(false);
    }
    _lastLook = now;
    late final Future<bool> look;
    look = _look().whenComplete(() {
      if (identical(_looking, look)) _looking = null;
    });
    return _looking = look;
  }

  Future<bool> _look() async {
    final note = await _read();
    if (!_primed) {
      // Never primed (a launch that could not read the store): the first
      // look is the baseline, not news.
      _primed = true;
      _seen = note;
      return false;
    }
    if (note == null || note == _seen) return false;
    _seen = note;
    try {
      onChanged();
    } catch (_) {}
    return true;
  }

  /// The note's time as written, or null when there is none (or it cannot
  /// be read: the store answers {} for every trouble).
  Future<String?> _read() async {
    try {
      final at = (await store.read(
        mealsChangedDocument,
        version: mealsChangedDocumentVersion,
      ))['at'];
      return at is String && at.isNotEmpty ? at : null;
    } catch (_) {
      return null;
    }
  }
}
