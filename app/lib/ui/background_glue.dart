/// Integrator wiring for the photo module's background half (spec §6.4) —
/// the composition-root counterpart that services/photo/background.dart's
/// library docs demand. Nothing here was wired before 2026-07-23, which is
/// why "automatic" intake only worked while the app was open and unfrozen.
///
/// Three layers of catch-up keep the watcher honest on aggressive OEMs
/// (Honor/EMUI freezes backgrounded apps within minutes):
///   1. Foreground change-notify watcher (di.dart) — instant while open.
///   2. Periodic WorkManager job (this file) — while the app is closed.
///   3. Launch/resume backfill over the FULL lookback window (di.dart +
///      app.dart) — the correctness backstop when 1–2 were killed.
///
/// The periodic job runs in a FRESH isolate each time (empty session
/// dedup), so it scans from a persisted watermark instead of the whole
/// window — otherwise every run would re-read the original bytes of every
/// window photo just to rediscover them in the md5 ledger.
library;

import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:io' show Platform;
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../core/app_channel.dart' show photoLibraryInBuild;
import '../core/contracts.dart';
import '../core/outcome_kind.dart';
import '../data/meals_dao_impl.dart';
import '../services/analyzer/platform_decode.dart' show isHeadlessEngine;
import '../services/analyzer/provider_analyzers.dart';
import '../services/backup/backup_coordinator.dart';
import '../services/backup/backup_prefs.dart' show backupHoldsCatchUp;
import '../services/local_store.dart' show LocalNoBackupStore;
import '../services/photo/background.dart';
import '../services/photo/background_runs.dart';
import '../services/photo/background_schedule.dart';
import '../services/photo/deferred_assets.dart';
import '../services/photo/food_prefilter.dart' show foodScoreViaImageIO;
import '../services/photo/glasses_check.dart' show recordGlassesCheckLocally;
import '../services/photo/photo_library.dart' show photoLibraryAccess;
import '../services/photo/run_traffic.dart';
import '../services/photo/watcher.dart';
import '../services/report/notifications.dart';
import '../l10n/app_localizations.dart';
import 'coach_strings.dart';
import 'format.dart' show mealDescription;
import 'meal_reveal.dart' show revealForMeal;
import '../services/settings/app_language_sync.dart'
    show appLanguageAndroidPrefsKey, backgroundAppLanguage;
import '../services/settings/app_settings.dart';
import 'photo_pipeline.dart';
import 'play_channel.dart' show retireWatchCameraRoll;
import 'refresh_signal.dart' show noteMealsChangedForOtherEngine;
import 'os_summary.dart';
import 'outcome_text.dart';

/// Persisted watermark: start time of the last completed background scan.
/// Stored as a UTC instant (see [readStoredInstant]).
const String backgroundWatermarkPrefsKey = 'background.last_scan_iso';

/// When the OS last LAUNCHED a background run (before any guard) — the
/// Settings "background scan" row. On iOS this is the only visible proof
/// that BGAppRefresh fires on a given phone; the OS decides the cadence
/// and no debugger is needed to read this (2026-09-30).
const String backgroundLastRunPrefsKey = 'background.last_run_iso';

/// Reads an instant stored by this file. Both keys are WRITTEN as UTC
/// ('…Z'): a zone-less local string is read back in whatever zone the
/// phone is in NOW, so a Shanghai → Chicago flight moved the watermark
/// 13 hours into the future and the scan skipped every photo taken in
/// between — the airport and in-flight meals (2026-10-08). Read back as
/// local, because Settings formats `.hour` directly. A pre-fix zone-less
/// value still parses as local, exactly as before, and the next forward
/// checkpoint rewrites it as UTC.
@visibleForTesting
DateTime? readStoredInstant(String? stored) =>
    DateTime.tryParse(stored ?? '')?.toLocal();

/// Re-scan overlap behind the watermark, absorbing camera write latency and
/// photos created while the previous scan was running.
///
/// The watermark is the newest COVERED photo's createDate (the intake's
/// frontier), not the scan start, so every run lists each photo from this
/// hour before it again until a newer photo is covered. On iOS the ones a
/// meal already names are counted covered without a read (2026-11-28,
/// LibraryPhotoIntake.scanSkipsLogged); every other one — a photo that
/// was not food, failed or was deleted, and on Android the logged ones too
/// — is re-read and re-hashed, and the ledger answers it with no model
/// call. Typically well under a second, but a very dense hour of such
/// photos (100+) can spend iOS's offer budget before a newer photo is
/// reached; the next app open's catch-up clears it (run 7, P5). The hour
/// itself is unchanged.
const Duration backgroundScanOverlap = Duration(hours: 1);

/// Periodic cadence. WorkManager's floor is 15 min; 30 keeps EMUI battery
/// stats friendly while the watermark keeps each run cheap when nothing
/// new was shot: no model call, only [backgroundScanOverlap]'s re-reads.
const Duration backgroundScanFrequency = Duration(minutes: 30);

/// iOS BGAppRefreshTask wall budget. The OS grants roughly 30 s and then
/// runs the expiration handler, which cancels the run outright — a photo
/// mid-analysis would leave a 'processing' reservation until the next
/// launch reclaims it. Stop OFFERING photos after this much, so the last
/// server analysis (3–10 s typical) still lands inside the grant. When the
/// grant expires mid-analysis anyway, that orphaned row answers later runs
/// as [PhotoReservation.inFlight] — a retryable outcome — so the frontier
/// below waits in front of the photo instead of passing over it
/// (2026-10-07). Counted from the run's start ([backgroundRunStart]), not
/// from the scan start (2026-10-19): the engine boot, the settings load and
/// the database open come out of the same grant.
///
/// It bounds the run's FIRST photo only loosely (7 s before the run's
/// deadline at worst): every later one must also have, before
/// [iosRunDeadline], as long as the slowest photo of the run took
/// (drainBackfill finishBy). A Claude Plan analysis alone takes several
/// seconds and can pass 15, so a second photo admitted with 7 s left was
/// often analyzed on the server and then cut off unsaved (review,
/// 2026-10-19).
const Duration iosBackgroundBudget = Duration(seconds: 15);

/// Android's offer budget (review 171, Play push): past this much of the
/// run no new photo is offered. WorkManager stops a worker after 10
/// minutes (long-running work doc) and gives Dart no signal
/// ([androidRunDeadline]); one Claude Plan analysis can be held for up to
/// about 15 minutes. Counted from the run's start, like iOS's.
const Duration androidBackgroundBudget = Duration(minutes: 7);

/// When workmanager started this run's headless engine, as an ISO instant:
/// written natively by the AppDelegate's registrant callback, which
/// workmanager calls right after it creates and starts the engine, before
/// Dart's task runs (2026-10-19). iOS's grant is already running then —
/// since the process launch and the shell's creation, which the stamp
/// misses — and Dart's own clock starts later still.
const String backgroundNativeLaunchPrefsKey = 'background.native_launch_iso';

/// The most a native launch stamp may lead the run's entry into Dart and
/// still count as this run's. Every iOS run stamps before its Dart can read
/// the store, and runs are 15 min or more apart, so a stamp within the
/// grant (~30 s) is this run's, however slow its boot was: counted from
/// it, a run that booted for 25 s offers nothing and ends at once, where
/// counting from the Dart entry would run on long past the grant and be
/// killed mid-photo. Older, it is an earlier run's and says nothing about
/// this one.
const Duration nativeLaunchMaxLead = Duration(seconds: 30);

/// Where this run's time budgets count from: the native launch stamp
/// ([backgroundNativeLaunchPrefsKey]) when it belongs to this run — not
/// after [enteredDart], at most [nativeLaunchMaxLead] before it — else
/// [enteredDart] itself (Android writes no stamp; a missing or stale one
/// changes nothing).
@visibleForTesting
DateTime backgroundRunStart(String? nativeStamp, DateTime enteredDart) {
  final native = DateTime.tryParse(nativeStamp ?? '');
  if (native == null) return enteredDart;
  final lead = enteredDart.difference(native);
  if (lead.isNegative || lead > nativeLaunchMaxLead) return enteredDart;
  return native;
}

/// Written by the Check new photos action (the iPhone trial build of
/// 2026-11-28, ios/Runner/CheckNewPhotosIntent.swift) just before it starts
/// this very run through workmanager: when it did, as an ISO instant in
/// [backgroundNativeLaunchPrefsKey]'s format. The run it started takes it
/// as its own ([startedByShortcut]) and removes it.
const String shortcutHintPrefsKey = 'background.shortcut_hint_iso';

/// The answer a run the action started leaves for it; the action polls for
/// it, at most 25 s from its own start, and words it for Shortcuts and
/// Siri. JSON ([shortcutResultFor]): the hint it took, when it ended, the
/// meals it saved, the photos it left for a later run, its stop reason
/// ([BackgroundStop]) and whether its settings allowed sending to the AI
/// service they name. Written at the run's end, also when the deadline ends
/// it ([finishWithinGrant]) or it throws. A run the OS started never
/// writes it.
const String shortcutResultPrefsKey = 'background.shortcut_result';

/// The most the action's hint may lead the run's start and still be its:
/// the action writes it, then workmanager creates the engine and stamps the
/// launch ([backgroundNativeLaunchPrefsKey]), within a second or two.
const Duration shortcutHintMaxLead = Duration(seconds: 10);

/// Whether the action's [hint] belongs to the run that started at
/// [runStart] ([backgroundRunStart]): at most [shortcutHintMaxLead] older,
/// and not newer.
@visibleForTesting
bool startedByShortcut(String? hint, DateTime runStart) {
  final at = DateTime.tryParse(hint ?? '');
  if (at == null) return false;
  final lead = runStart.difference(at);
  return !lead.isNegative && lead <= shortcutHintMaxLead;
}

/// The action's answer ([shortcutResultPrefsKey]) from [run], this run's
/// entry as it ended. [sharing]: null when the run ended before it had its
/// settings.
@visibleForTesting
Map<String, Object?> shortcutResultFor(BackgroundRunRecord? run,
        {required String hint, required DateTime at, bool? sharing}) =>
    {
      'hint': hint,
      'at': at.toUtc().toIso8601String(),
      'saved': run?.saved ?? 0,
      'left': run?.released ?? 0,
      'stop': run?.stopReason ?? 'unknown',
      'sharing': ?sharing,
    };

/// [run], then the action's answer from the run's entry as it ended: run
/// to the end, ended by the deadline, or thrown. Never throws more than
/// [run] does.
Future<bool> _answerShortcut(Future<bool> run,
    {required SharedPreferences prefs,
    required BackgroundRunRecorder recorder,
    required String hint,
    required RunInFlight inFlight,
    required DateTime Function() clock}) async {
  try {
    return await run;
  } finally {
    try {
      bool? sharing;
      try {
        sharing = inFlight.sharingAllowed?.call();
      } catch (_) {}
      await prefs.setString(
          shortcutResultPrefsKey,
          jsonEncode(shortcutResultFor(recorder.current,
              hint: hint, at: clock(), sharing: sharing)));
    } catch (_) {
      // The action then says the check ran out of time.
    }
  }
}

/// Result of one drained backfill: what happened to each photo, whether
/// the SCAN itself completed (a scan abort means unseen photos remain),
/// and the intake's coverage frontier (never advance a watermark past it).
class BackfillDrain {
  final List<PhotoOutcome> outcomes;
  final bool scanCompleted;
  final DateTime? frontier;

  /// True when the [drainBackfill] deadline passed with photos still
  /// unoffered — they were RELEASED (not burned), so the next run
  /// re-offers them; the watermark stops short of them by construction.
  final bool cutShort;

  /// How many photos the deadline released unprocessed.
  final int deadlineReleases;

  /// What aborted the scan when [scanCompleted] is false (its class is all
  /// the diagnostics record keeps).
  final Object? scanError;
  const BackfillDrain(this.outcomes,
      {required this.scanCompleted,
      this.frontier,
      this.cutShort = false,
      this.deadlineReleases = 0,
      this.scanError});
}

/// Run one backfill through the pipeline with FULL backpressure: the
/// intake awaits each photo's processing before reading the next photo's
/// bytes (one photo resident at a time — a 200-photo backlog must not hold
/// ~1 GB while the first Gemini call is in flight). When [onOutcome] is
/// set it runs per photo BEFORE the next one starts, so progress
/// (notifications, watermark checkpoints) survives a WorkManager
/// hard-stop mid-batch. Past [deadline] (iOS's ~30 s grant) no further
/// photo is processed — nor even read: the intake asks before each
/// original's bytes, and a photo read just before the deadline is released
/// at the sink. Both halt the frontier in front of the photo.
///
/// [finishBy] (iOS: [iosRunDeadline] from the run's start) is when the
/// whole run must be over. A photo is started only if, at the pace of the
/// slowest photo this drain has processed, it would be done by then — one
/// that cannot finish is not started (an analysis cut off unsaved still
/// costs the server, and the provider's quota). The first photo has no
/// pace to go by: [deadline] alone admits it.
///
/// [lateImports] (design G1b): once the scan has completed, and only while
/// the budget still has room, the intake's late-import pass
/// ([PhotoIntake.lateImportScan]) goes through the same sink under the
/// same budget. Its photos carry no safeFrontier, so the frontier and every
/// checkpoint stay the scan's alone.
Future<BackfillDrain> drainBackfill(PhotoIntake intake, PhotoPipeline pipeline,
    {int lookbackDays = 0,
    DateTime? since,
    DateTime? deadline,
    DateTime? finishBy,
    DateTime Function() clock = DateTime.now,
    bool lateImports = false,
    Future<void> Function(IntakePhoto photo)? onOffer,
    Future<void> Function(
            IntakePhoto photo, PhotoOutcome outcome, DateTime? safeFrontier)?
        onOutcome}) async {
  final outcomes = <PhotoOutcome>[];
  var cutShort = false;
  var deadlineReleases = 0;
  final timed = deadline != null || finishBy != null;
  // The longest one photo has taken in this drain.
  var slowest = Duration.zero;
  // Whether another photo may start now. Once past the deadline, past it
  // for good: a clock step backwards must not reopen the run.
  bool roomLeft() {
    if (!timed) return true;
    if (cutShort) return false;
    final now = clock();
    return (deadline == null || now.isBefore(deadline)) &&
        (finishBy == null || !now.add(slowest).isAfter(finishBy));
  }

  // [roomLeft], counting every photo turned away.
  bool budgetLeft() {
    if (roomLeft()) return true;
    cutShort = true;
    deadlineReleases++;
    return false;
  }

  intake.attachSink((p, safeFrontier) async {
    if (!budgetLeft()) {
      return false; // released, not burned: the next run re-offers it
    }
    if (onOffer != null) await onOffer(p);
    final began = clock();
    final o = await pipeline.process(p);
    final took = clock().difference(began);
    if (took > slowest) slowest = took;
    outcomes.add(o);
    if (onOutcome != null) await onOutcome(p, o, safeFrontier);
    return !o.retryable;
  });
  var scanCompleted = false;
  DateTime? frontier;
  Object? scanError;
  try {
    frontier = await intake.backfillScan(
        lookbackDays: lookbackDays,
        since: since,
        shouldContinue: timed ? budgetLeft : null);
    scanCompleted = true;
    // Asked without counting: a pass that cannot start turns no photo
    // away (they wait in its carry, or in the library's history).
    if (lateImports && roomLeft()) {
      try {
        await intake.lateImportScan(shouldContinue: timed ? budgetLeft : null);
      } catch (_) {
        // Never the scan's failure: its frontier and photos stand.
      }
    }
  } catch (e) {
    // Library query died / window truncated. Photos delivered before the
    // throw are already fully processed (sink is awaited inline); the
    // false flag tells the caller the window was NOT fully covered.
    scanError = e;
  } finally {
    intake.attachSink(null);
  }
  return BackfillDrain(outcomes,
      scanCompleted: scanCompleted,
      frontier: frontier,
      cutShort: cutShort,
      deadlineReleases: deadlineReleases,
      scanError: scanError);
}

/// The pipeline's view of [AppSettings]' automatic-analysis latch — one
/// adapter for the foreground pipeline (di.dart) and the background run.
AutoScanLatch autoScanLatchFor(AppSettings settings) => AutoScanLatch(
      blockedKind: () => switch (settings.analysisBlockedKind) {
        'rejectedKey' => AnalysisErrorKind.rejectedKey,
        'regionBlocked' => AnalysisErrorKind.regionBlocked,
        'billing' => AnalysisErrorKind.billing,
        _ => null,
      },
      revision: () => settings.credentialRevision,
      block: (kind, revision) =>
          settings.blockAutomaticAnalysis(kind.name, revision: revision),
      clear: settings.clearAnalysisBlock,
      refresh: settings.reloadAnalysisBlock,
    );

/// The pipeline's view of the AI consent at the send (photo_pipeline.dart
/// [AiSendGate]) — one adapter for the foreground pipeline (di.dart) and
/// the background run. Allowed: the recipient the current provider choice
/// sends to has the consent — or no key is set for it, when nothing can
/// leave the phone and the analyzer answers with its own 'no key' line
/// (the same rule as ui/ai_consent.dart aiConsentNeeded).
///
/// [rereadFromDisk]: the background run, whose [AppSettings] is another
/// isolate's snapshot — it re-reads the consent before each send, so a
/// Stop Sharing confirmed in the open app holds for the photos that run
/// has not sent yet. Never for the app's own engine
/// ([AppSettings.reloadAiConsent]).
AiSendGate aiSendGateFor(AppSettings settings,
        {bool rereadFromDisk = false}) =>
    AiSendGate(
      allowed: () =>
          (settings.activeApiKey ?? '').trim().isEmpty ||
          settings.hasAiConsent(settings.activeAiConsentRoute),
      refresh: rereadFromDisk ? settings.reloadAiConsent : null,
    );

/// Moves the background watermark forward to [mark], never past [cap] and
/// never back over the value it reads; returns the value written, or null
/// when it did not move.
///
/// Both engines write it (2026-10-19): the background run as it scans,
/// and the app's launch/resume catch-ups ([foregroundCatchUp]), each
/// through its own preferences cache — so the stored value is re-read
/// first, and a stale cache can never carry it backwards over the other
/// engine's progress. The read and the write are not one step, though:
/// two writers interleaving between them (A reads X, B writes Y, A writes
/// Z < Y) can leave the EARLIER mark. That direction is safe — a re-scan
/// the ledger absorbs, never a skip — so "forward only" holds for what
/// each writer can see, not strictly across the two engines. Written as
/// UTC (see [readStoredInstant]).
Future<DateTime?> advanceBackgroundWatermark(
        SharedPreferences prefs, DateTime mark,
        {required DateTime cap}) async =>
    (await _advanceWatermark(prefs, mark, cap: cap)).written;

/// [advanceBackgroundWatermark], also saying what the store held.
Future<({DateTime? written, DateTime? stored})> _advanceWatermark(
    SharedPreferences prefs, DateTime mark,
    {required DateTime cap}) async {
  final capped = mark.isAfter(cap) ? cap : mark;
  try {
    await prefs.reload();
  } catch (_) {
    // Unreadable store: compare against this engine's own copy.
  }
  final cur = readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));
  if (cur != null && !capped.isAfter(cur)) return (written: null, stored: cur);
  await prefs.setString(
      backgroundWatermarkPrefsKey, capped.toUtc().toIso8601String());
  return (written: capped, stored: cur);
}

/// The background watermark as this engine's preferences hold it, with no
/// re-read from disk: what the app's intake compares photo dates with to
/// tell which photos look unchecked, for Today's "Checking photos" row
/// (LibraryPhotoIntake.checkedThrough). Every catch-up re-reads the store
/// as it checkpoints ([foregroundCatchUp]), so this is at worst as old as
/// the app's last one, and an older value only makes more photos look
/// unchecked, which the ledger then answers for.
DateTime? cachedBackgroundWatermark(SharedPreferences prefs) =>
    readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));

/// The app's launch/resume catch-up over the full lookback window — the
/// pipeline [PhotoPipeline.bind] attached processes each photo — which
/// also moves the BACKGROUND watermark over what it covered. It used to
/// leave it days behind: the next background run then spent its grant
/// re-reading and re-hashing every photo the app had just logged before
/// it reached a new one (2026-10-19). Then the intake's late-import pass
/// ([PhotoIntake.lateImportScan], design G1b), which moves nothing.
///
/// The newest day's photos go first, so a quick open logs today's meal
/// before the rest of the week (PhotoIntake.backfillScan newestDayFirst);
/// the background run keeps strict oldest-first from its watermark.
///
/// Only the intake's safeFrontier is persisted — per photo as it
/// terminates (the app may be suspended mid-scan), then the final
/// frontier — never past this scan's start. A truncated window reports
/// none and throws [BackfillWindowTruncated], which propagates. A
/// preferences failure never stops the scan.
///
/// [shouldContinue] is asked before each photo's original is read; false
/// ends the scan there, unread photos uncovered. iOS passes "the app is
/// still in the foreground" (appEngineBackgrounded): once the user leaves,
/// the photo in flight finishes in its background task and nothing more
/// is read (2026-10-19).
///
/// One round for Today's "Checking photos" row (scan_status.dart) when the
/// intake reports its scans: the window scan and the late-import pass each
/// report their own photos, and a row the first one brought up stays, on
/// its last count, until both are over, instead of going away after the
/// last photo it expected and coming back for the photos imported late.
Future<DateTime?> foregroundCatchUp(PhotoIntake intake,
    {DateTime Function() clock = DateTime.now,
    Future<SharedPreferences> Function()? loadPrefs,
    bool Function()? shouldContinue}) async {
  final round = beginCatchUpRound(intake);
  final scanStart = clock();
  // The latest mark this catch-up knows the store holds, read or written.
  // A covered photo at or before it would move nothing, so it costs no
  // reload: a cold launch walks a week of already-logged photos, most of
  // them older than the background run's own watermark, and each reload
  // is a full read of the store over the platform channel.
  DateTime? known;
  Future<void> checkpoint(DateTime mark) async {
    final capped = mark.isAfter(scanStart) ? scanStart : mark;
    final seen = known;
    if (seen != null && !capped.isAfter(seen)) return;
    try {
      final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
      final r = await _advanceWatermark(prefs, mark, cap: scanStart);
      final latest = r.written ?? r.stored;
      final now = known;
      if (latest != null && (now == null || latest.isAfter(now))) {
        known = latest;
      }
    } catch (_) {}
  }

  try {
    final frontier = await intake.backfillScan(
        onCovered: checkpoint,
        newestDayFirst: true,
        shouldContinue: shouldContinue);
    if (frontier != null) await checkpoint(frontier);
    return frontier;
  } finally {
    try {
      // Photos other apps imported late (design G1b): after the window, so
      // today's photos still go first. Never a watermark; never a throw. A
      // truncated window still gets it. Not once the user has left (iOS).
      if (shouldContinue?.call() ?? true) {
        try {
          await intake.lateImportScan(shouldContinue: shouldContinue);
        } catch (_) {}
      }
    } finally {
      // Whatever happened above ([shouldContinue] is the caller's, and may
      // throw): a round left open would hold the row on its last count for
      // the rest of the session.
      round?.end();
    }
  }
}

/// Stamps "the OS launched a background run" for the Settings 后台扫描 row.
/// Written as UTC (see [readStoredInstant]).
Future<void> recordBackgroundLaunch(
        SharedPreferences prefs, DateTime Function() clock) =>
    prefs.setString(
        backgroundLastRunPrefsKey, clock().toUtc().toIso8601String());

/// The headless scan body, dependency-injected so tests can drive it with
/// fakes. Returns WorkManager success (true) in every recoverable state —
/// background.dart's no-retry-storm rule.
///
/// [recorder] (begun by the caller) gets every step of this run, as it
/// happens (background_runs.dart); [photoAccess] tells a run that found no
/// photos because it may not read any.
///
/// [deferred] notes each photo this run defers and forgets each one it
/// gives a verdict (deferred_assets.dart); the run's intake was built to
/// pass over the ones deferred too often.
///
/// [budget] counts from [startedAt] — the OS-launched run's start
/// ([backgroundRunStart], in [runHeadlessBackfill]) — so the engine boot,
/// the keychain read, the settings load and the database open spend it
/// too; it used to start at the scan, a second or more into iOS's grant.
/// Null: from the scan start. [finishBy]: see [drainBackfill].
///
/// [photoOffered] hears each photo handed to the pipeline, just before it
/// is processed (RunInFlight.offered).
///
/// [showMealCard] posts a Logged meals card; a meal's card carries its
/// meal ([payload], MealReveal.payload), so a tap on it goes to that meal
/// (Android: meal_reveal.dart). A notice carries none.
@visibleForTesting
Future<bool> headlessBackfillWith({
  required AppSettings settings,
  required SharedPreferences prefs,
  required PhotoIntake intake,
  required Future<PhotoPipeline> Function() pipeline,
  required Future<void> Function(String title, String body, {String? payload})
      showMealCard,
  DateTime Function() clock = DateTime.now,
  Duration? budget,
  DateTime? startedAt,
  DateTime? finishBy,
  void Function()? photoOffered,
  DeferredAssets? deferred,
  bool launchRecorded = false,
  BackgroundRunRecorder? recorder,
  Future<bool?> Function()? photoAccess,
}) async {
  // First, unconditionally: "the OS ran us" is what Settings reports,
  // whatever the guards below decide. Skipped when [runHeadlessBackfill]
  // already wrote it before loading the settings — one launch, one stamp.
  if (!launchRecorded) await recordBackgroundLaunch(prefs, clock);
  await recorder?.stage(BackgroundRunStage.settings);
  // Belt and braces: on Android disabling the watcher cancels the job, but
  // a stale chain must never scan against the user's setting. On iOS the
  // job stays registered (iCloud Backup, the summary's re-arm), so this is
  // where a run with the watcher off stops.
  if (!settings.watcherEnabled) {
    await recorder?.finish(BackgroundStop.watcherOff);
    return true;
  }
  // No key yet / quota latch armed / an earlier automatic photo came back
  // 'key rejected' or 'region blocked' (the automatic-analysis latch):
  // analyses cannot succeed, so don't even read photo bytes — every 30
  // minutes this used to re-upload the whole window. The watermark stays
  // put — those photos are scanned once the blocker clears
  // (release-not-burn keeps them eligible).
  if (!settings.canAutoAnalyze) {
    await recorder?.finish((settings.activeApiKey ?? '').trim().isEmpty
        ? BackgroundStop.noKey
        : settings.autoAnalysisNeedsHttps
            ? BackgroundStop.needsHttps
            : BackgroundStop.paused);
    return true;
  }
  // iCloud Backup (1.7.0): a restore offer is open or a restore is
  // running in the app. Photos logged now would win over the backup's own
  // (possibly corrected) meals for the same photos, so the scan waits for
  // the answer (a 30-minute lease, renewed while a restore runs).
  if (backupHoldsCatchUp(prefs, clock())) {
    await recorder?.finish(BackgroundStop.paused);
    return true;
  }

  final scanStart = clock();
  final since = readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey));
  await recorder?.stage(BackgroundRunStage.scan);

  Future<void> checkpoint(DateTime mark) async {
    // Monotonic forward only, never past this scan's start.
    final moved = await advanceBackgroundWatermark(prefs, mark, cap: scanStart);
    if (moved != null) await recorder?.checkpoint(moved);
  }

  // The pipeline (and its database handle) is built ONLY past the guards:
  // most runs guard out or find nothing, and every needless cross-isolate
  // open is a shot at the shared-handle transaction races.
  final drain = await drainBackfill(
    intake,
    await pipeline(),
    since: since?.subtract(backgroundScanOverlap),
    deadline: budget == null ? null : (startedAt ?? scanStart).add(budget),
    finishBy: finishBy,
    clock: clock,
    // Photos imported late, with whatever budget the scan left (G1b).
    lateImports: true,
    onOffer: (_) async {
      photoOffered?.call();
      await recorder?.offered();
    },
    onOutcome: (photo, o, safeFrontier) async {
      await recorder?.processed(
          saved: o.kind == PhotoOutcomeKind.saved ||
              o.kind == PhotoOutcomeKind.leftoverApplied,
          released: o.retryable,
          left: o.retryable ? backgroundLeftFor(o) : null);
      // A photo this engine could not decode (deferUndecodable) is counted;
      // twice, and later runs pass it over instead of halting on it again.
      if (o.retryable && o.errorKind == AnalysisErrorKind.badPhoto) {
        await deferred?.deferred(photo.assetId);
      } else if (!o.retryable) {
        await deferred?.settled(photo.assetId);
      }
      // Per photo, BEFORE the next one: a WorkManager hard-stop mid-batch
      // must not lose the notification for an already-saved meal, nor the
      // progress the run already made.
      // A leftover deduction CUTS an already-logged meal's calories, so
      // an unattended one needs a card as much as a new meal does — it
      // used to be silent here (the foreground snackbar was its only
      // announcement, and the headless path has no snackbar).
      if (o.kind == PhotoOutcomeKind.saved ||
          o.kind == PhotoOutcomeKind.leftoverApplied) {
        // In the app language, like the coach summary (headless, so via
        // the saved preference rather than a BuildContext).
        final l = localizationsFor(settings.appLanguage);
        await showMealCard(
            o.kind == PhotoOutcomeKind.saved
                ? l.mealCardAutoTitle
                : l.mealCardLeftoverTitle,
            mealCardBody(l, o),
            // The meal logged, or the one the leftovers were deducted
            // from: a tap on the card goes to it.
            payload: revealForMeal(o)?.payload);
      }
      // The intake's safeFrontier is the ONLY persistable value: it is
      // createDate-based (the watermark's timebase), halts at transient
      // failures, and is null for truncated windows. Deriving it from the
      // photo (filename dates) skipped photos permanently.
      if (!o.retryable && safeFrontier != null) {
        await checkpoint(safeFrontier);
      }
    },
  );
  // Final watermark: ONLY the intake's frontier — no scanStart fast path.
  // Outcomes can't see photos whose byte read failed (they never reach the
  // sink), so "no retryable outcomes" does NOT mean full coverage; the
  // frontier is the single honest source. Cost: the next run re-offers
  // every photo in the overlap hour before it (backgroundScanOverlap), not
  // just the newest; the ledger absorbs them without a model call.
  if (drain.frontier != null) await checkpoint(drain.frontier!);
  await recorder?.releasedUnprocessed(drain.deadlineReleases);
  // This run ARMED the automatic-scan pause (it started unpaused — see the
  // guard above): the background has no snackbar, and without a word the
  // scan just stops for up to a day. One notice per arm: every later run
  // is guarded out above until the pause lifts. Re-read from disk first:
  // a key edited in the foreground during this run has already lifted the
  // pause there, and a notice about it would be stale.
  await settings.reloadAnalysisBlock();
  final pausedUntil = settings.analysisBlockedUntil;
  if (pausedUntil != null) {
    final l = localizationsFor(settings.appLanguage);
    final line = autoScanPausedLine(l,
        kind: settings.analysisBlockedKind,
        until: pausedUntil,
        provider: settings.provider.name,
        serverBackend: settings.serverBackend);
    if (line != null) {
      try {
        await showMealCard(l.autoScanPausedTitle, line);
      } catch (_) {}
    }
  }
  if (recorder != null) {
    await recorder.finish(
        await _stopReason(drain,
            pausedNow: pausedUntil != null,
            listedNothing: recorder.current?.enumerated == 0,
            photoAccess: photoAccess),
        watermarkAfter:
            readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey)));
  }
  return true;
}

/// Why a photo whose verdict keeps it for later was left, for the run's
/// record ([BackgroundLeft]): the AI service was busy or over its limit,
/// it could not be reached, or anything else.
@visibleForTesting
String backgroundLeftFor(PhotoOutcome o) => switch (o.errorKind) {
      AnalysisErrorKind.serverBusy ||
      AnalysisErrorKind.rateLimited =>
        BackgroundLeft.busy,
      AnalysisErrorKind.network => BackgroundLeft.unreachable,
      _ => BackgroundLeft.other,
    };

/// Why the photo the run's deadline cut off was left, from what the run
/// was waiting for then ([RunTraffic.cutOffAt]).
@visibleForTesting
String backgroundLeftForCut(CutOffAt at) => switch (at) {
      CutOffAt.preparing => BackgroundLeft.preparing,
      CutOffAt.busy => BackgroundLeft.busy,
      CutOffAt.unreachable => BackgroundLeft.unreachable,
      CutOffAt.waiting => BackgroundLeft.deadline,
    };

/// The body of a background meal card: the meal itself ('Pasta — ~650
/// kcal'), under a title that already says what happened. It used to be
/// outcomeBody's snackbar line, which repeats it: 'Meal logged: …' under
/// 'Meal logged automatically' (Play push, UX screenshot 06). A meal with
/// no description is named like everywhere else (nlUnnamedMeal); without
/// a name or calories, the pipeline's summary, then the snackbar line.
@visibleForTesting
String mealCardBody(AppLocalizations l, PhotoOutcome o) {
  final analysis = o.analysis;
  final raw = o.mealName;
  final name = raw == null
      ? null
      : analysis != null && mealDescription(analysis, fallback: '').isEmpty
          ? l.nlUnnamedMeal
          : raw;
  final kcal = o.kcal;
  switch (o.kind) {
    case PhotoOutcomeKind.saved:
      if (name != null && kcal != null) {
        return l.outcomeSavedSummary(name, kcal);
      }
    case PhotoOutcomeKind.leftoverApplied:
      final cut = o.deductedKcal;
      if (name != null && kcal != null && cut != null) {
        return l.outcomeLeftoverSummary(name, '$cut', kcal);
      }
    default:
  }
  return o.detail ?? outcomeBody(l, o);
}

/// How a scan that ran to the end of [headlessBackfillWith] stopped, for
/// the diagnostics record. The budget first (photos are waiting), then a
/// pause this run armed (the rest were released), then a scan that died or
/// listed nothing because the app may not read the library.
Future<String> _stopReason(BackfillDrain drain,
    {required bool pausedNow,
    required bool listedNothing,
    Future<bool?> Function()? photoAccess}) async {
  if (drain.cutShort) return BackgroundStop.budget;
  if (pausedNow) return BackgroundStop.paused;
  if (!drain.scanCompleted || listedNothing) {
    bool? access;
    try {
      access = await photoAccess?.call();
    } catch (_) {}
    if (access == false) return BackgroundStop.noPermission;
  }
  final error = drain.scanError;
  if (!drain.scanCompleted && error != null) return BackgroundStop.error(error);
  return BackgroundStop.done;
}

/// Production assembly for one background run. Mirrors di.dart's startup
/// EXCEPT reclaimStaleProcessing: that launch sweep assumes it owns the
/// only pipeline, and the foreground app may be mid-analysis right now —
/// reclaiming its 'processing' reservation here could double-log a meal.
///
/// The daily summary: after the scan the run RE-ARMS the OS card, on both
/// platforms, so a meal logged while the app was closed is in the card the
/// OS delivers at the slot (os_summary.dart). Android used to POST it from
/// this job instead (2026-08-06 to the Play push), which is why it came
/// late, or never offline or in the Rare and Restricted buckets.
///
/// The launch marker is written BEFORE the settings load, and a failed load
/// ends the run as a success. Loading reads every key from the keychain;
/// on a locked iPhone that read threw (keys were stored under a class
/// readable only while unlocked), the run died silently, and the 后台扫描
/// row read as if iOS had never run the task (2026-10-09). The keystore
/// now survives a locked phone (MigratingKeyStore), and should a load
/// still fail — say before the first unlock after a reboot — the row
/// shows that iOS did run the task. The seams exist for that test.
Future<bool> runHeadlessBackfill({
  bool? isIOS,
  Future<AppSettings> Function()? loadSettings,
  Future<SharedPreferences> Function()? loadPrefs,
  DateTime Function() clock = DateTime.now,
}) async {
  // FIRST, before anything can decode a photo: this isolate is the
  // headless engine. On iOS its GPU is off for the whole run and a dart:ui
  // decode never finishes, so platform_decode must skip that step here
  // (2026-10-18).
  isHeadlessEngine = true;
  // iOS's grant is already running: the time budgets count from here, or
  // from the native launch stamp when there is one for this run (the
  // engine boot came out of the grant too).
  final enteredDart = clock();
  final ios = isIOS ?? Platform.isIOS;
  final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
  final startedAt = ios
      ? backgroundRunStart(
          prefs.getString(backgroundNativeLaunchPrefsKey), enteredDart)
      : enteredDart;
  // iOS: the Check new photos action started this run (the trial build):
  // its hint is taken once, the entry says so, and the run's answer is
  // left for the action at its end. Every other run is as before.
  final hint = ios ? prefs.getString(shortcutHintPrefsKey) : null;
  final byShortcut = hint != null && startedByShortcut(hint, startedAt);
  if (byShortcut) {
    try {
      await prefs.remove(shortcutHintPrefsKey);
    } catch (_) {}
  }
  await recordBackgroundLaunch(prefs, clock);
  // This run's diagnostics entry, rewritten at every step so a run iOS
  // kills still shows how far it got (background_runs.dart).
  final recorder = BackgroundRunRecorder(prefs,
      platform: ios ? 'ios' : 'android',
      clock: clock,
      trigger: byShortcut ? BackgroundTrigger.shortcuts : null);
  await recorder.begin(
      watermarkBefore:
          readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey)),
      bootLead: enteredDart.difference(startedAt));
  final runDeadline = ios ? iosRunDeadline : androidRunDeadline;
  final inFlight = RunInFlight(
      deadline: startedAt.add(runDeadline),
      window: ios ? slowPhotoWindow : androidSlowPhotoWindow,
      clock: clock);
  inFlight.recorder = recorder;
  final run = _runAfterLaunch(
      ios: ios,
      prefs: prefs,
      recorder: recorder,
      startedAt: startedAt,
      inFlight: inFlight,
      loadSettings: loadSettings);
  // The whole run ends in its time, whatever it is stuck on: inside iOS's
  // grant, and before WorkManager's 10-minute stop on Android.
  final finished = finishWithinGrant(run,
      left: startedAt.add(runDeadline).difference(clock()),
      recorder: recorder,
      abandon: ios ? inFlight.abandon : inFlight.endAtDeadline,
      abandonLimit: ios ? iosAbandonLimit : androidDeadlineWrapUp);
  if (hint == null || !byShortcut) return finished;
  return _answerShortcut(finished,
      prefs: prefs,
      recorder: recorder,
      hint: hint,
      inFlight: inFlight,
      clock: clock);
}

/// How long iOS's deadline waits for the photo in flight to be released
/// before replying ([finishWithinGrant]).
const Duration iosAbandonLimit = Duration(milliseconds: 1500);

/// How long Android's deadline waits for the release and the summary's
/// re-arm ([RunInFlight.endAtDeadline]): inside the minute between
/// [androidRunDeadline] and WorkManager's 10-minute stop.
const Duration androidDeadlineWrapUp = Duration(seconds: 30);

/// How long a photo must have had to itself, before the iOS run's
/// deadline, for a cut-off to count against it ([DeferredAssets.cutOff]):
/// offered no later than 7 s into the run. Most first photos of a run have
/// it; a photo offered after another was processed mostly has not, and its
/// cut-off says nothing about the photo (review, 2026-10-19). The window
/// is necessary, not sufficient: the cut must also have come before
/// anything was sent for the photo ([RunInFlight.abandon]).
const Duration slowPhotoWindow = Duration(seconds: 15);

/// Android's [slowPhotoWindow]: 5 minutes before [androidRunDeadline], so
/// offered no later than 4 minutes into the run. iOS's 15 s counted every
/// Android cut — offers stop 2 minutes before the deadline — and a photo
/// offered late while the server hung was passed over (review
/// 2026-11-19). The length was chosen as one full attempt of the slowest
/// analyzer (ServerAnalyzer.deadline); a cut that comes with a request
/// out no longer counts at all, so it now only says how long the phone
/// must have been preparing the photo.
const Duration androidSlowPhotoWindow = Duration(minutes: 5);

/// What the run's deadline needs from a run still going: its pipeline
/// once built, its deferral notes once loaded, when the photo in flight
/// was offered, and what has been sent for it since.
@visibleForTesting
class RunInFlight {
  /// [client]: where the run's analyzer sends (tests); the run's own
  /// [http.Client] otherwise, made at its first request.
  RunInFlight(
      {this.deadline,
      this.window = slowPhotoWindow,
      DateTime Function()? clock,
      http.Client? client})
      : _clock = clock ?? DateTime.now,
        traffic = RunTraffic(client);

  /// When the run must be over ([iosRunDeadline] or [androidRunDeadline]
  /// from its start); null: no deadline (tests).
  final DateTime? deadline;

  /// How long a photo must have had before [deadline] for its cut-off to
  /// count ([slowPhotoWindow] on iOS, [androidSlowPhotoWindow]).
  final Duration window;
  final DateTime Function() _clock;
  PhotoPipeline? pipeline;
  DeferredAssets? deferred;
  DateTime? _offeredAt;

  /// The run's diagnostics entry: [abandon] says in it why the photo the
  /// deadline cut off was left. Null (tests): nothing is said.
  BackgroundRunRecorder? recorder;

  /// The HTTP client the run's analyzer sends through, whichever AI
  /// service it is: what was sent for the photo in flight, and what came
  /// back, is the evidence [abandon] goes by (run_traffic.dart).
  final RunTraffic traffic;

  /// The summary's re-arm ([rearmSummaryAfterRun]), set once the run has
  /// its settings and notifier: Android's deadline runs it
  /// ([endAtDeadline]).
  Future<void> Function()? rearm;

  /// Whether the run's settings allow sending to the AI service they name
  /// (as the consent check at each send reads them), set once the run has
  /// its settings: the Check new photos action's answer says so
  /// ([shortcutResultFor]). Read by nothing else.
  bool Function()? sharingAllowed;

  /// Android's end at [androidRunDeadline]: the photo in flight released
  /// ([abandon]), then the summary re-armed — the run's own re-arm sits at
  /// its end, which a run cut short never reaches (review, 2026-11-13).
  /// Never throws: the reply to WorkManager matters more.
  Future<void> endAtDeadline() async {
    try {
      await abandon();
    } catch (_) {}
    try {
      await rearm?.call();
    } catch (_) {}
  }

  /// A photo was handed to the pipeline: the one in flight from now on
  /// (the background pipeline takes one photo at a time).
  void offered() {
    _offeredAt = _clock();
    traffic.next();
  }

  /// MealsDao.loggedAssetIds through the run's own database handle (the
  /// pipeline's): the late-import pass opens no second one. Nothing is
  /// known before the pipeline exists — the pass then reads, and the
  /// ledger answers.
  Future<Set<String>> loggedAssetIds(List<String> assetIds) async {
    final dao = pipeline?.dao;
    return dao == null ? const <String>{} : dao.loggedAssetIds(assetIds);
  }

  /// Releases the photo in flight ([PhotoPipeline.abandon]). It stays
  /// eligible, and the next run offers it again.
  ///
  /// The cut also counts against the photo only when the run's own
  /// evidence points at it (2026-11-28): it had at least [window] to
  /// itself, and in all that time nothing was sent for it
  /// ([CutOffAt.preparing]: the phone was still on its food check or its
  /// decode). After [cutsBeforePassOver] of those, later runs pass it over
  /// (the app's catch-up still logs it), so one photo this engine cannot
  /// get ready does not eat every run and hold the watermark, and every
  /// photo after it, until the app opens.
  ///
  /// Every other cut costs the photo nothing more than the retry: offered
  /// late; cut off with its request out and unanswered; cut off after the
  /// AI service said it was busy, or could not be reached. A busy server,
  /// a hung network and a slow answer all cut off whatever photo the run
  /// meets, and a full window used to count each one against the photo
  /// (three, and it got no background log until the app was opened).
  ///
  /// What that leaves, knowingly: a photo the AI service answers too
  /// slowly for in every run is sent again by each one and holds the
  /// watermark until the app opens. From the phone it looks the same as a
  /// hung network, and the run cannot tell which it is.
  Future<void> abandon() async {
    // Read before the release, which awaits: an answer that lands
    // meanwhile is not what the photo was cut off at.
    final cutAt = traffic.cutOffAt;
    final assetId = await pipeline?.abandon();
    if (assetId == null || assetId.isEmpty) return;
    // Why it was left, for the run's record. In the entry from this call
    // on; its write is awaited last, behind what the next run goes by.
    final noted = recorder?.cutOff(backgroundLeftForCut(cutAt));
    final at = _offeredAt, end = deadline;
    if (cutAt == CutOffAt.preparing &&
        at != null &&
        end != null &&
        end.difference(at) >= window) {
      await deferred?.cutOff(assetId);
    }
    await noted;
  }
}

/// [runHeadlessBackfill] past the launch stamp: settings, the scan, the
/// summary card, and on iOS the iCloud Backup.
Future<bool> _runAfterLaunch({
  required bool ios,
  required SharedPreferences prefs,
  required BackgroundRunRecorder recorder,
  required DateTime startedAt,
  required RunInFlight inFlight,
  Future<AppSettings> Function()? loadSettings,
}) async {
  final AppSettings settings;
  try {
    // Read-only key store: only the UI engine moves keys between keychain
    // classes, or an upload key an earlier version stored into its item,
    // so the two engines can never race on either one-time move.
    settings = await (loadSettings ??
        () => AppSettings.load(
            keyStore: platformKeyStore(migrate: false), readOnlyKeys: true))();
  } catch (e) {
    await recorder.finish(BackgroundStop.error(e));
    // Success, not a retry: the next scheduled run tries again, and a
    // WorkManager retry storm helps nobody (background.dart's rule).
    return true;
  }
  inFlight.sharingAllowed =
      () => settings.hasAiConsent(settings.activeAiConsentRoute);
  // Android 13 and later: a language picked for the app in Android's
  // settings since the app last ran is this run's (read only).
  final languageAgreed =
      takeAndroidLanguageForRun(settings, prefs, android: !ios);
  await recorder.stage(BackgroundRunStage.settings);
  // The Google Play build (core/app_channel.dart): the job of a GitHub
  // install it was installed over, run before the app was opened. No scan
  // (no photo permission either): Watch Camera Roll is turned off as the
  // first launch would, the app owes its one notice (play_channel.dart),
  // and the job cancels itself (backgroundJobWanted is false there).
  if (!photoLibraryInBuild) {
    try {
      await retireWatchCameraRoll(settings, prefs);
    } catch (_) {
      // The app's launch tries again.
    }
    await recorder.finish(BackgroundStop.watcherOff);
    try {
      await syncBackgroundScan(settings);
    } catch (_) {
      // The app's launch cancels it instead (di.dart).
    }
    return true;
  }
  final deferred = inFlight.deferred = await DeferredAssets.load(prefs);
  // Where this engine leaves word of a meal it saved: its own
  // meals-changed signal has no listener, and the app may be open
  // (refresh_signal.dart).
  final localStore = LocalNoBackupStore.platform();
  // Time-derived id seed: cards from successive runs stack instead of
  // overwriting each other. Base 10000 keeps the whole range clear of the
  // fixed daily-report id 9001 (a colliding meal card would silently
  // REPLACE an unread daily report).
  final notifier = ReportNotifier(
      channelStrings: () => notificationChannelFor(settings.appLanguage),
      mealChannelStrings: () =>
          mealNotificationChannelFor(settings.appLanguage),
      // Android: the summary over two or more of this run's and earlier
      // runs' cards (PR80-B2), in the app language too.
      mealGroupStrings: () => mealGroupSummaryFor(settings.appLanguage),
      mealCardIdSeed: 10000 +
          (DateTime.now().millisecondsSinceEpoch ~/ 10000) % 8640000);
  // After the scan (below) — or at Android's deadline, should the scan
  // still be going then (RunInFlight.endAtDeadline).
  inFlight.rearm = () => rearmSummaryAfterRun(
      prefs: prefs,
      settings: settings,
      notifier: notifier,
      openDao: createMealsDao,
      ios: ios,
      languageAgreedAtStart: languageAgreed);
  final bool ok;
  try {
    ok = await headlessBackfillWith(
      settings: settings,
      prefs: prefs,
      intake: createPhotoIntake(settings,
          onBackfillListed: recorder.listed,
          passOver: deferred.passOver,
          loggedAssetIds: inFlight.loggedAssetIds,
          // iOS: a photo a meal already names is counted covered without
          // a read, by the scan as by the late-import pass, so the 15 s
          // in which this run may start a photo go to new ones. Android's
          // run reads them as it always did (LibraryPhotoIntake
          // .scanSkipsLogged says why).
          scanSkipsLogged: ios,
          onScanSkippedLogged: recorder.alreadyLogged),
      pipeline: () async => inFlight.pipeline = PhotoPipeline(
          dao: await createMealsDao(),
          // A meal saved, or cut for leftovers: the open app, if there is
          // one, is told through a note it looks for (it used to find out
          // at its next return, tab tap or save of its own).
          onMealSaved: () =>
              unawaited(noteMealsChangedForOtherEngine(localStore)),
          // B14's previous-night candidates, under the consent that says so.
          previousDayContext: () => settings.previousDayLeftoverContext,
          // Through the run's own client, whichever AI service it is: what
          // was sent for the photo in flight is what the deadline goes by
          // (RunInFlight.abandon).
          analyzer:
              createMultiProviderAnalyzer(settings, client: inFlight.traffic),
          latch: autoScanLatchFor(settings),
          // The AI consent at each send, re-read from disk: the open app
          // may have stopped sharing since this run loaded its settings.
          sendGate: aiSendGateFor(settings, rereadFromDisk: true),
          // A glasses preview copy waits once for its full-size one (G2b).
          previewHold: holdGlassesPreview,
          // Design G3: the switch as this run loaded it, and on iOS the
          // on-device food check — on the CPU, or deferred to the app.
          includeGlasses: () => settings.watchGlasses,
          foodCheck: ios ? foodScoreViaImageIO : null,
          glassesCheckLog: recordGlassesCheckLocally,
          // iOS only: there dart:ui cannot decode (platform_decode.dart).
          deferUndecodable: ios),
      showMealCard: (title, body, {payload}) async {
        await notifier.init(); // idempotent; deferred until a card exists
        await notifier.showMealCard(title, body, payload: payload);
      },
      budget: ios ? iosBackgroundBudget : androidBackgroundBudget,
      startedAt: startedAt,
      finishBy: inFlight.deadline,
      photoOffered: inFlight.offered,
      deferred: deferred,
      launchRecorded: true,
      recorder: recorder,
      photoAccess: photoLibraryAccess,
    );
  } catch (e) {
    // A throw the scan did not contain (the database would not open, say):
    // the entry names its class, and WorkManager still sees the failure.
    await recorder.finish(BackgroundStop.error(e));
    rethrow;
  }
  // The scan's work is saved either way; a failed re-arm is refreshed at
  // the next open (rearmSummaryAfterRun never throws).
  await inFlight.rearm!();
  if (ios) {
    // iCloud Backup (1.7.0): only a backup this install already owns, only
    // if something changed, with at least 8 s left before the deadline;
    // never a first write, a download or a question here (G8).
    try {
      await BackupCoordinator.runHeadless(
          dao: await createMealsDao(),
          prefs: prefs,
          left: startedAt.add(iosRunDeadline).difference(DateTime.now()),
          tempDir: getTemporaryDirectory);
    } catch (_) {
      // The next run or the app's own triggers back up instead.
    }
  }
  return ok;
}

/// No key store for [summarySettingsNow]'s read: it reads the summary's
/// settings, which live in preferences, never a key.
class _NoKeys implements SecureKeyStore {
  const _NoKeys();
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

/// The settings as the open app may have changed them since this run
/// loaded its own — up to [androidRunDeadline] earlier: the summary's
/// switch, time, goal and language among them (review, 2026-11-13; the
/// precedent is AppSettings.reloadAiConsent). Read again from disk through
/// AppSettings' own loader, which only reads (its one possible write, the
/// one-time consent seed, depends on the provider alone and is written by
/// the first load), with no key store: the keys stay out of it. Loaded as
/// the background engine (readOnlyKeys): finding no upload key, the app
/// engine's load records the address's host for one it may not have read
/// (AppSettings._noteServerKeyUnread), which this load, with no key store
/// at all, must never do. The run's own copy when the store cannot be read.
///
/// The language is the run's (takeAndroidLanguageForRun) while the app
/// and Android still agree on the language they agreed on when the run
/// began ([agreedAtStart]): this engine's locales are still those of then,
/// and after a round of the app's sync since, the stored language is the
/// newer word.
@visibleForTesting
Future<AppSettings> summarySettingsNow(
    SharedPreferences prefs, AppSettings loaded,
    {String? agreedAtStart}) async {
  try {
    await prefs.reload();
    final now = await AppSettings.load(
        prefs: prefs, keyStore: const _NoKeys(), readOnlyKeys: true);
    if (agreedAtStart != null &&
        prefs.getString(appLanguageAndroidPrefsKey) == agreedAtStart) {
      takeAndroidLanguageForRun(now, prefs, android: true);
    }
    return now;
  } catch (_) {
    return loaded;
  }
}

/// Android 13 and later: a language picked for the app in Android's
/// settings since the app last ran becomes [settings]' language for this
/// run (app_language_sync.dart backgroundAppLanguage, from the language
/// the app and Android last agreed on and this engine's first locale,
/// which Android takes from that setting): the meal cards, the pause
/// notice, the notification channels' names and the meal names the model
/// is asked for. Only the app engine's sync writes the language, at the
/// app's next launch: nothing is written here. Returns the agreement read
/// (null: none, or not Android). [android] defaults to the platform;
/// [locales] to this engine's. Never throws.
@visibleForTesting
String? takeAndroidLanguageForRun(AppSettings settings, SharedPreferences prefs,
    {bool? android, List<Locale>? locales}) {
  if (!(android ?? Platform.isAndroid)) return null;
  try {
    final agreed = prefs.getString(appLanguageAndroidPrefsKey);
    final engine = locales ?? _engineLocales();
    settings.takeLanguageForRun(backgroundAppLanguage(settings.appLanguage,
        agreed: agreed, first: engine.isEmpty ? null : engine.first));
    return agreed;
  } catch (_) {
    return null;
  }
}

/// This engine's locales, as the engine was handed them when it started.
List<Locale> _engineLocales() {
  try {
    return WidgetsBinding.instance.platformDispatcher.locales;
  } catch (_) {
    // No binding (an early isolate).
    return PlatformDispatcher.instance.locales;
  }
}

/// The run's re-arm of the summary card, on both platforms, with the
/// settings as they are now ([summarySettingsNow]; on Android in the run's
/// language while [languageAgreedAtStart], the agreement read when the run
/// began, still holds); on Android the week ahead and a card still pending
/// past its slot (os_summary.dart). Never throws: the scan's work is saved
/// either way, and the next open re-arms.
@visibleForTesting
Future<void> rearmSummaryAfterRun({
  required SharedPreferences prefs,
  required AppSettings settings,
  required ReportNotifier notifier,
  required Future<MealsDao> Function() openDao,
  required bool ios,
  DateTime Function() now = DateTime.now,
  String? languageAgreedAtStart,
}) async {
  try {
    await armOsDailySummary(
        dao: await openDao(),
        settings: await summarySettingsNow(prefs, settings,
            agreedAtStart: languageAgreedAtStart),
        notifier: notifier,
        now: now,
        android: !ios,
        prefs: () async => prefs);
  } catch (_) {}
}

/// The whole iOS background run, from its start ([backgroundRunStart]),
/// ends within this (2026-10-19); Android's is [androidRunDeadline]. iOS expires a BGAppRefresh grant about
/// 30 s after launching it; a run still going then is killed, the task
/// never completes (workmanager calls setTaskCompleted only on Dart's
/// reply), its photo stays reserved, and iOS ranks the app lower for the
/// next launch. The offer budget ([iosBackgroundBudget]) stops new photos
/// at 15 s, but nothing bounded the photo already in flight (a slow
/// upload, a stalled decode) or the steps around the scan.
///
/// 22 s, not 25: what the start misses is unmeasured — the process launch
/// before the BGTask handler and the engine's creation always, and the
/// engine boot too when no native stamp came — and the teardown and
/// completion come after. A photo offered at the end of the offer budget
/// would have 7 s, so after the first, drainBackfill starts one only if
/// it can finish by this at the run's pace. One the deadline cuts off
/// anyway is released (finishWithinGrant) and offered again by a later
/// run — behind any older photo still waiting, not necessarily first.
const Duration iosRunDeadline = Duration(seconds: 22);

/// The whole Android background run, from its start, ends within this
/// (review 171, Play push). WorkManager stops a ListenableWorker after 10
/// minutes, and workmanager_android's onStopped then destroys the engine
/// without a word to Dart (BackgroundWorker.kt): a photo in flight kept
/// its 'processing' row, and the entry never said why. Ended here instead
/// ([finishWithinGrant]), the photo is released and the entry says
/// 'budget'. One minute short of the stop, two after the offer budget
/// ([androidBackgroundBudget]). Android 16's job quotas can stop a run
/// sooner still; the next run labels that one
/// ([BackgroundStop.stoppedBySystem]).
///
/// Counted from the run's entry into Dart: Android writes no native launch
/// stamp, so the engine's boot before it is not counted; the minute short
/// of the stop covers it, and the deadline's own wrap-up
/// ([androidDeadlineWrapUp]).
const Duration androidRunDeadline = Duration(minutes: 9);

/// [run] or, once [left] has passed, an end to the run anyway: the
/// diagnostics entry says 'budget' and the result is success, so
/// workmanager completes the BGTask (its executeTask reply is what calls
/// setTaskCompleted; workmanager_apple 0.9.1+2 BackgroundWorker.swift)
/// instead of iOS killing the process at expiry.
///
/// The reply destroys the engine (cleanupFlutterResources →
/// destroyContext), so the abandoned run never gets to finish anything —
/// a photo in flight would keep its 'processing' row, and that row would
/// refuse every later run and the open app for appProcessingStaleAge
/// (simulator, 2026-10-19). So before replying, [abandon] releases that
/// reservation and stops the pipeline from writing anything more
/// ([PhotoPipeline.abandon]), waiting at most [abandonLimit]. The offer
/// budget has passed by then, so the run starts no new photo either. Its
/// diagnostics entry is frozen once finished.
@visibleForTesting
Future<bool> finishWithinGrant(Future<bool> run,
    {required Duration left,
    required BackgroundRunRecorder recorder,
    Future<void> Function()? abandon,
    Duration abandonLimit = const Duration(milliseconds: 1500)}) {
  final done = Completer<bool>();
  final timer = Timer(left.isNegative ? Duration.zero : left, () {
    if (done.isCompleted) return;
    done.complete(() async {
      if (abandon != null) {
        try {
          await abandon().timeout(abandonLimit);
        } catch (_) {
          // Out of time for it: the reply matters more.
        }
      }
      await recorder.finish(BackgroundStop.budget);
      return true;
    }());
  });
  run.then((ok) {
    timer.cancel();
    if (!done.isCompleted) done.complete(ok);
  }, onError: (Object e, StackTrace st) {
    timer.cancel();
    if (!done.isCompleted) done.completeError(e, st);
  });
  return done.future;
}

/// WorkManager background entrypoint. Must stay top-level with the
/// vm:entry-point pragma or AOT tree-shaking removes it and every
/// background run dies before Dart (background.dart library docs).
@pragma('vm:entry-point')
void appBackgroundDispatcher() {
  Workmanager().executeTask((task, input) {
    // The registered inputData lookback is ignored on purpose: the runner
    // loads live settings, so slider edits apply without re-registration.
    headlessBackfill = (_) => runHeadlessBackfill();
    return handleBackgroundTask(task, input);
  });
}

/// Reconcile the periodic job with the current settings — call at startup
/// and whenever watcherEnabled/lookbackDays change. Android WorkManager
/// or iOS BGAppRefresh inside (enableBackgroundScan picks).
///
/// Android registers it only while Watch Camera Roll is on and cancels it
/// otherwise; iOS keeps it always ([backgroundJobWanted]). It used to stay
/// registered on Android with the watcher off, because the job carried the
/// daily summary too — cancelling it silently killed the notification
/// (2026-08-16). The summary is an OS alarm now (os_summary.dart), so it
/// no longer needs the job.
///
/// iOS: the plugin only logs a submit iOS refuses, so what iOS made of
/// this one is asked and recorded right after it
/// ([keepBackgroundScanScheduled]); Android asks nothing more.
Future<void> syncBackgroundScan(AppSettings settings) async {
  await enableBackgroundScan(
      backgroundJobWanted(watcherEnabled: settings.watcherEnabled),
      lookbackDays: settings.lookbackDays,
      frequency: backgroundScanFrequency,
      dispatcher: appBackgroundDispatcher);
  await keepBackgroundScanScheduled(settings);
}

/// iOS: the request for the next background scan, made again when iOS
/// holds none, and what iOS said recorded for Settings and the diagnostics
/// page (background_schedule.dart, 2026-11-28). Wanted under the same
/// condition as the launch's own submit ([backgroundJobWanted]: on iOS,
/// always). Called behind that submit ([syncBackgroundScan]) and by the
/// shell each time the app comes to the foreground and each time it leaves
/// (app.dart) — a return to the app used to ask for nothing, so a request
/// lost once stayed lost until the next cold start.
///
/// A request iOS already holds is never replaced. Android: nothing at all
/// — no channel call, no scheduler call, nothing written; WorkManager
/// keeps its own chain. Never throws.
Future<BackgroundSchedule?> keepBackgroundScanScheduled(AppSettings settings) =>
    keepBackgroundRequest(
        wanted: backgroundJobWanted(watcherEnabled: settings.watcherEnabled));

/// Settings' "the background scan is stuck" probe (2026-10-19): the
/// stored runs and the watermark, both read FRESH (the background engine
/// writes the runs; either engine moves the watermark), so a catch-up the
/// app just finished clears the hint (backgroundScanLooksStuck). An
/// unreadable store is not stuck.
Future<bool> backgroundScanStuckNow(
    {DateTime Function() clock = DateTime.now,
    Future<SharedPreferences> Function()? loadPrefs}) async {
  try {
    final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
    await prefs.reload();
    return backgroundScanLooksStuck(
        decodeBackgroundRuns(prefs.getString(backgroundRunsPrefsKey)),
        now: clock(),
        watermark:
            readStoredInstant(prefs.getString(backgroundWatermarkPrefsKey)));
  } catch (_) {
    return false;
  }
}

/// The last background launch, read FRESH: the run wrote it from another
/// isolate, and this isolate's SharedPreferences cache would not know.
Future<DateTime?> lastBackgroundRun() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return readStoredInstant(prefs.getString(backgroundLastRunPrefsKey));
}
