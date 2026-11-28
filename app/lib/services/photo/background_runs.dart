/// A small, persisted record of the last background runs (2026-10-18).
///
/// The background scan runs where no debugger reaches: iOS starts it when
/// it likes, for ~30 s, and kills it without a word. Two timestamps were
/// all the app kept (last launch, last watermark), and when the watermark
/// froze for days (Oct 11, Oct 15) nothing on the phone said how far each
/// run had got. Each run now keeps ONE entry, rewritten at every step, so a
/// run the OS killed still shows the step it was on and what it had done.
///
/// Counts and timestamps only: never photo content, hashes, keys, URLs or
/// error messages (an error is recorded by its class name).
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One JSON list, newest first.
const String backgroundRunsPrefsKey = 'background.runs_v1';

/// How many runs are kept.
const int backgroundRunsKept = 20;

/// The step a run was on when it last wrote its entry. In run order; a run
/// moves between [photo] and [checkpoint] once per photo.
enum BackgroundRunStage {
  /// The OS launched it (before the settings load).
  boot,

  /// Settings loaded; the guards are next.
  settings,

  /// Listing the photo library.
  scan,

  /// A photo is being processed (hashed, decoded, analyzed, saved).
  photo,

  /// Moving the watermark forward after a photo.
  checkpoint,

  /// Finished — [BackgroundRunRecord.stopReason] says how.
  done,
}

/// Why a run ended. Anything else in the field is `error:<class name>`.
abstract final class BackgroundStop {
  static const done = 'done';
  static const budget = 'budget';
  static const paused = 'paused';
  static const noKey = 'no_key';

  /// The own server's address is not https://: the app sends it nothing,
  /// so the scan did not run (AppSettings.autoAnalysisNeedsHttps).
  static const needsHttps = 'needs_https';
  static const watcherOff = 'watcher_off';
  static const noPermission = 'no_permission';

  /// Written by the NEXT run on an entry that never finished: the OS
  /// stopped it (iOS's grant expired, Android's 10-minute limit or job
  /// quota) and told Dart nothing. Its end stays unknown (null).
  static const stoppedBySystem = 'system_stop';
  static String error(Object e) => 'error:${e.runtimeType}';
}

/// Why a photo was left for a later run ([BackgroundRunRecord.left]):
/// what the phone needs to answer "why was nothing logged" (2026-11-28).
/// A run used to say only how many were left.
abstract final class BackgroundLeft {
  /// The AI service said it was busy or over its limit: the user's own
  /// server while it analyzes another photo, a provider's 503, 529 or 429.
  /// As the photo's verdict, or as the last thing heard for it before the
  /// run's deadline.
  static const busy = 'busy';

  /// The AI service could not be reached, or answered with a server error.
  static const unreachable = 'unreachable';

  /// The run's deadline cut the photo off with its request out and no
  /// answer yet. A slow answer, a busy server that holds the request and a
  /// hung network all look like this from the phone.
  static const deadline = 'deadline';

  /// The run's deadline cut it off before anything was sent for it: the
  /// phone was still preparing it (its food check, its decode). The one
  /// cut that can count against the photo (deferred_assets.dart).
  static const preparing = 'preparing';

  /// Listed, never started: the run's time for starting photos was over.
  static const notOffered = 'not_offered';

  /// Any other verdict that keeps a photo for later: a photo this engine
  /// left for the app, one another run holds, a preview copy waiting for
  /// its full-size one.
  static const other = 'other';

  /// In the order the diagnostics page says them.
  static const all = [
    busy,
    unreachable,
    deadline,
    preparing,
    notOffered,
    other,
  ];
}

class BackgroundRunRecord {
  const BackgroundRunRecord({
    required this.start,
    required this.platform,
    this.end,
    this.stage = BackgroundRunStage.boot,
    this.enumerated = 0,
    this.offered = 0,
    this.analyzed = 0,
    this.saved = 0,
    this.released = 0,
    this.alreadyLogged = 0,
    this.left = const {},
    this.stopReason,
    this.watermarkBefore,
    this.watermarkAfter,
    this.bootMs,
  });

  /// UTC instants.
  final DateTime start;

  /// Null: the run never finished — the OS ended it at [stage] (or it is
  /// running right now).
  final DateTime? end;

  /// 'ios' or 'android'.
  final String platform;
  final BackgroundRunStage stage;

  /// Photos the scan listed in its window.
  final int enumerated;

  /// Photos whose bytes were read and handed to the pipeline.
  final int offered;

  /// Photos the pipeline finished with (any verdict).
  final int analyzed;

  /// New meals, or leftovers deducted from one.
  final int saved;

  /// Photos left eligible for a later run: a retryable verdict, not
  /// started because the time budget ran out, or (since 2026-11-28) the
  /// one the run's deadline cut off and released.
  final int released;

  /// Why they were left: a [BackgroundLeft] reason to how many. Adds up to
  /// [released] for a run that recorded reasons; empty for every run
  /// before 2026-11-28.
  final Map<String, int> left;

  /// Photos the scan counted covered without reading them, because a meal
  /// already names each one (LibraryPhotoIntake.scanSkipsLogged, the iOS
  /// run, 2026-11-28). In [enumerated] and in no other count: they used to
  /// be read and processed again by every run, an hour behind the
  /// watermark.
  final int alreadyLogged;
  final String? stopReason;

  /// The watermark (UTC) when the run started, and as it last wrote it.
  final DateTime? watermarkBefore;
  final DateTime? watermarkAfter;

  /// iOS: milliseconds from the native launch stamp to the run's entry into
  /// Dart — the boot the time budgets now count (2026-10-19). A floor: the
  /// stamp comes right after workmanager creates and starts the engine, so
  /// the process launch and the shell's creation before it are not in it.
  /// Null without a stamp for this run.
  final int? bootMs;

  bool get finished => end != null;

  /// [left] with [count] more photos left for [reason].
  Map<String, int> leftWith(String reason, [int count = 1]) =>
      {...left, reason: (left[reason] ?? 0) + count};

  BackgroundRunRecord copyWith({
    DateTime? end,
    BackgroundRunStage? stage,
    int? enumerated,
    int? offered,
    int? analyzed,
    int? saved,
    int? released,
    int? alreadyLogged,
    Map<String, int>? left,
    String? stopReason,
    DateTime? watermarkAfter,
  }) =>
      BackgroundRunRecord(
        start: start,
        platform: platform,
        end: end ?? this.end,
        stage: stage ?? this.stage,
        enumerated: enumerated ?? this.enumerated,
        offered: offered ?? this.offered,
        analyzed: analyzed ?? this.analyzed,
        saved: saved ?? this.saved,
        released: released ?? this.released,
        alreadyLogged: alreadyLogged ?? this.alreadyLogged,
        left: left ?? this.left,
        stopReason: stopReason ?? this.stopReason,
        watermarkBefore: watermarkBefore,
        watermarkAfter: watermarkAfter ?? this.watermarkAfter,
        bootMs: bootMs,
      );

  Map<String, Object?> toJson() => {
        'start': start.toUtc().toIso8601String(),
        'end': end?.toUtc().toIso8601String(),
        'platform': platform,
        'stage': stage.name,
        'enumerated': enumerated,
        'offered': offered,
        'analyzed': analyzed,
        'saved': saved,
        'released': released,
        'stop': stopReason,
        'wm_before': watermarkBefore?.toUtc().toIso8601String(),
        'wm_after': watermarkAfter?.toUtc().toIso8601String(),
        if (bootMs != null) 'boot_ms': bootMs,
        // Only when there is something to say: an entry without them is
        // exactly what every earlier version wrote, and reads back as 0.
        if (alreadyLogged > 0) 'known': alreadyLogged,
        if (left.isNotEmpty) 'left': left,
      };

  /// Null for an entry that cannot be read (a newer or damaged shape):
  /// one bad entry must not hide the others.
  static BackgroundRunRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = DateTime.tryParse('${json['start']}');
    if (start == null) return null;
    DateTime? instant(Object? v) => v is String ? DateTime.tryParse(v) : null;
    int count(Object? v) => v is int && v >= 0 ? v : 0;
    final stage = BackgroundRunStage.values
        .where((s) => s.name == json['stage'])
        .firstOrNull;
    final platform = json['platform'];
    final stop = json['stop'];
    return BackgroundRunRecord(
      start: start,
      end: instant(json['end']),
      platform: platform is String ? platform : '',
      stage: stage ?? BackgroundRunStage.boot,
      enumerated: count(json['enumerated']),
      offered: count(json['offered']),
      analyzed: count(json['analyzed']),
      saved: count(json['saved']),
      released: count(json['released']),
      alreadyLogged: count(json['known']),
      left: _leftFrom(json['left']),
      stopReason: stop is String ? stop : null,
      watermarkBefore: instant(json['wm_before']),
      watermarkAfter: instant(json['wm_after']),
      bootMs: json['boot_ms'] is int ? count(json['boot_ms']) : null,
    );
  }
}

/// The stored reasons: short names with a count above 0. Anything else in
/// the map is dropped, and anything that is not a map reads as none. A
/// name this version does not know (a later one's) is kept: the page says
/// it with the others.
Map<String, int> _leftFrom(Object? json) {
  if (json is! Map) return const {};
  return {
    for (final MapEntry(:key, :value) in json.entries)
      if (key is String &&
          key.isNotEmpty &&
          key.length <= 24 &&
          value is int &&
          value > 0)
        key: value,
  };
}

/// Parses the stored list, newest first; unreadable entries are skipped.
List<BackgroundRunRecord> decodeBackgroundRuns(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  try {
    final list = jsonDecode(stored);
    if (list is! List) return const [];
    return [
      for (final e in list) ?BackgroundRunRecord.fromJson(e),
    ];
  } catch (_) {
    return const [];
  }
}

/// The stored runs, read FRESH: the background engine wrote them from
/// another isolate, and this isolate's preferences cache would not know.
/// Empty when nothing is stored or the store cannot be read.
Future<List<BackgroundRunRecord>> readBackgroundRuns(
    {Future<SharedPreferences> Function()? prefs}) async {
  try {
    final p = await (prefs ?? SharedPreferences.getInstance)();
    await p.reload();
    return decodeBackgroundRuns(p.getString(backgroundRunsPrefsKey));
  } catch (_) {
    return const [];
  }
}

/// Whether the stored runs (newest first) say the background scan is
/// stuck — for the Settings 后台扫描 row, which otherwise shows only the
/// last launch time: the time kept advancing through Oct 11 and Oct 15
/// while no run logged a thing (2026-10-19). Two signs, nothing else, so a
/// quiet week of no photos never reads as trouble:
///   * the 3 newest runs each took a photo and finished none (hung on it,
///     killed on it, or out of time on it);
///   * runs keep starting — 3 or more in the last 2 days — yet no run has
///     made progress for 2 days.
/// A run made progress when it moved the watermark, saved a meal, or
/// finished its scan with nothing left over. A run its guard stopped (no
/// key, the watcher off, paused, no photo access) counts as fine: Settings
/// explains those elsewhere, and opening the app would not fix them.
///
/// [watermark] is the stored background watermark, read fresh. Later than
/// the newest run left it, something moved it since — the app's own
/// catch-up (foregroundCatchUp), which is exactly the remedy the hint
/// names — so the runs before that say nothing about now: not stuck until
/// later runs show it again. Without this the hint stayed on after the
/// user opened the app and everything was logged, telling them to open
/// the app while they were in it (2026-10-19).
bool backgroundScanLooksStuck(List<BackgroundRunRecord> runs,
    {required DateTime now, DateTime? watermark}) {
  if (runs.length < 3) return false;
  if (watermark != null) {
    final newest = runs.first;
    final left = newest.watermarkAfter ?? newest.watermarkBefore;
    if (left == null || watermark.isAfter(left)) return false;
  }
  if (runs.take(3).every((r) => r.offered > 0 && r.analyzed == 0)) {
    return true;
  }
  final since = now.subtract(const Duration(days: 2));
  final recent = runs.where((r) => r.start.isAfter(since)).toList();
  if (recent.length < 3 || recent.any(_madeProgress)) return false;
  // No progress in 2 days — known only if a run older than that shows it,
  // or the record reaches back that far.
  final older = runs.where((r) => !r.start.isAfter(since));
  return older.isNotEmpty;
}

const _guardStops = {
  BackgroundStop.watcherOff,
  BackgroundStop.noKey,
  BackgroundStop.needsHttps,
  BackgroundStop.paused,
  BackgroundStop.noPermission,
};

bool _madeProgress(BackgroundRunRecord r) {
  if (_guardStops.contains(r.stopReason)) return true;
  if (r.saved > 0) return true;
  final before = r.watermarkBefore, after = r.watermarkAfter;
  if (after != null && (before == null || after.isAfter(before))) return true;
  return r.finished &&
      r.stopReason == BackgroundStop.done &&
      r.released == 0 &&
      r.offered == r.analyzed;
}

/// Writes THIS run's entry, incrementally: every call rewrites the entry
/// at once, so whatever the OS cuts short keeps the last step reached.
/// Never throws — a diagnostics write must not take the scan down — and
/// does nothing before [begin].
///
/// Only the background engine writes the key, and the OS never overlaps
/// two background runs, so the list is read once in [begin] and rewritten
/// from memory.
class BackgroundRunRecorder {
  BackgroundRunRecorder(this._prefs,
      {required this.platform, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final String platform;
  final DateTime Function() _clock;
  List<BackgroundRunRecord> _older = const [];
  BackgroundRunRecord? _current;

  /// This run's entry as last written (tests, and the run itself).
  BackgroundRunRecord? get current => _current;

  /// [bootLead]: how long before the Dart entry the run started natively
  /// (zero or null: no native stamp for this run).
  ///
  /// The newest stored entry, unfinished and unlabelled, belongs to a run
  /// the OS stopped (runs never overlap): it is labelled
  /// [BackgroundStop.stoppedBySystem], its step and counts kept, so the
  /// record tells it from a run still going.
  Future<void> begin({DateTime? watermarkBefore, Duration? bootLead}) async {
    final older =
        decodeBackgroundRuns(_prefs.getString(backgroundRunsPrefsKey));
    final last = older.firstOrNull;
    _older = last != null && !last.finished && last.stopReason == null
        ? [last.copyWith(stopReason: BackgroundStop.stoppedBySystem),
            ...older.skip(1)]
        : older;
    _current = BackgroundRunRecord(
        start: _clock().toUtc(),
        platform: platform,
        watermarkBefore: watermarkBefore?.toUtc(),
        watermarkAfter: watermarkBefore?.toUtc(),
        bootMs: bootLead == null || bootLead <= Duration.zero
            ? null
            : bootLead.inMilliseconds);
    await _write();
  }

  Future<void> stage(BackgroundRunStage stage) => _update(
      (r) => r.stage == BackgroundRunStage.done ? r : r.copyWith(stage: stage));

  Future<void> listed(int enumerated) => _update((r) => r.copyWith(
      stage: BackgroundRunStage.scan, enumerated: r.enumerated + enumerated));

  /// A photo's bytes were handed to the pipeline: written BEFORE it is
  /// processed, so a kill mid-analysis reads "photo, offered n, analyzed
  /// n-1".
  Future<void> offered() => _update((r) => r.copyWith(
      stage: BackgroundRunStage.photo, offered: r.offered + 1));

  /// [left]: why a [released] photo was left ([BackgroundLeft]);
  /// [BackgroundLeft.other] when the caller does not say.
  Future<void> processed(
          {required bool saved, required bool released, String? left}) =>
      _update((r) => r.copyWith(
          analyzed: r.analyzed + 1,
          saved: r.saved + (saved ? 1 : 0),
          released: r.released + (released ? 1 : 0),
          left: released ? r.leftWith(left ?? BackgroundLeft.other) : null));

  /// Photos the scan counted covered without a read, because a meal
  /// already names them ([BackgroundRunRecord.alreadyLogged]).
  Future<void> alreadyLogged(int count) => count <= 0
      ? Future.value()
      : _update((r) => r.copyWith(alreadyLogged: r.alreadyLogged + count));

  /// Photos released unprocessed (the time budget ran out).
  Future<void> releasedUnprocessed(int count) => count <= 0
      ? Future.value()
      : _update((r) => r.copyWith(
          released: r.released + count,
          left: r.leftWith(BackgroundLeft.notOffered, count)));

  /// The run's deadline cut off the photo in flight and released it
  /// (RunInFlight.abandon), for [reason]: [BackgroundLeft.deadline],
  /// [BackgroundLeft.preparing], or what the AI service last said. Called
  /// before [finish], which makes the entry final. The entry holds it
  /// from the moment of the call, whatever becomes of this write.
  Future<void> cutOff(String reason) => _update((r) =>
      r.copyWith(released: r.released + 1, left: r.leftWith(reason)));

  Future<void> checkpoint(DateTime watermark) => _update((r) => r.copyWith(
      stage: BackgroundRunStage.checkpoint, watermarkAfter: watermark.toUtc()));

  Future<void> finish(String stopReason, {DateTime? watermarkAfter}) =>
      _update((r) => r.finished
          ? r
          : r.copyWith(
              end: _clock().toUtc(),
              stage: BackgroundRunStage.done,
              stopReason: stopReason,
              watermarkAfter: watermarkAfter?.toUtc()));

  /// A finished entry is final: a run abandoned at the iOS deadline
  /// (finishWithinGrant) may still report a step before its engine goes,
  /// and must not reopen the entry that already says how it ended.
  Future<void> _update(
      BackgroundRunRecord Function(BackgroundRunRecord r) change) async {
    final cur = _current;
    if (cur == null || cur.finished) return;
    _current = change(cur);
    await _write();
  }

  Future<void> _write() async {
    final cur = _current;
    if (cur == null) return;
    try {
      final list = [cur, ..._older].take(backgroundRunsKept);
      await _prefs.setString(backgroundRunsPrefsKey,
          jsonEncode([for (final r in list) r.toJson()]));
    } catch (_) {}
  }
}
