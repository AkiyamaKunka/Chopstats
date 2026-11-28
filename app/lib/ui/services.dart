/// UI-local seams and the service bundle every screen receives.
///
/// Screens depend on core/contracts.dart plus ONLY these interfaces; the
/// adapters binding them to the concrete settings/photo modules live in
/// di.dart so an integration-time signature drift is fixed in one file.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable, ValueListenable;

import '../core/contracts.dart';
import '../core/server_transport.dart' show serverKeyForOtherHost;
import '../services/analysis_keep_alive.dart' show AnalysisKeepAlive;
import '../services/backup/backup_coordinator.dart';
import '../services/backup/save_file_channel.dart' show SaveFileStatus;
import '../services/garmin_client.dart';
import '../services/photo/coverage.dart';
import '../services/photo/photo_library.dart';
import '../services/photo/scan_status.dart' show PhotoScanStatus;
import '../services/usual/usual_foods.dart' show UsualFoods;
import 'ai_consent.dart' show SharedPhotoConsentGate;
import 'meal_in_use.dart';
import 'meal_reveal.dart' show MealReveals;
import 'meal_thumbs.dart';
import 'photo_pipeline.dart';
import 'restaurant_assist_controls.dart';

/// The settings surface the UI needs (spec §8 knobs the user edits).
/// di.dart adapts the concrete AppSettings onto this; tests use in-memory
/// fakes.
abstract class SettingsStore {
  /// The ACTIVE provider's API key — [apiKey]/[model] always read and
  /// write the provider selected by [provider].
  String get apiKey;

  /// Active AI provider: 'gemini' | 'openai' | 'anthropic' | 'server'
  /// (own server on the Claude subscription) | 'qwen' | 'doubao' | 'glm'
  /// | 'deepseek' | 'xai' | 'openrouter'. String-typed so the UI seam stays
  /// free of module imports (di adapts the enum).
  String get provider;

  /// Spec §3.3 quota-pause latch: while true, analyses cannot succeed —
  /// backfill triggers skip the byte-reads entirely.
  bool get isQuotaPaused;

  /// When the §3.3 latch lifts, or null when not paused — the Settings
  /// banner shows the user WHY nothing is analyzing and until when.
  DateTime? get quotaPauseUntil;

  /// See AppSettings.canAnalyze — key present for the ACTIVE provider and no
  /// quota latch. Screens gate byte-reading sweeps on this single predicate
  /// rather than re-deriving it.
  bool get canAnalyze;

  /// [canAnalyze] for the AUTOMATIC scan (launch/resume catch-up, watcher
  /// toggle sweep): also false while a rejected key or blocked region has
  /// latched it (AppSettings.isAnalysisBlocked). Deliberate paths — the
  /// coverage screen included — keep [canAnalyze].
  bool get canAutoAnalyze;

  /// 'rejectedKey' | 'regionBlocked' | 'billing' while that latch is armed,
  /// else null; with [autoScanBlockedUntil] it tells Settings why nothing
  /// is scanned.
  String? get autoScanBlockedKind;
  DateTime? get autoScanBlockedUntil;

  /// Re-read the latch from disk (the background run may have armed it).
  Future<void> reloadAutoScanBlock();

  /// 测试 AI 服务 proved the active provider's credentials work: lift a
  /// rejected-key pause, and a blocked-region one only when the probe
  /// [reachedGeneration] (went through the endpoint that refuses regions).
  Future<void> credentialsProven({required bool reachedGeneration});

  /// Whether the user allowed meal data to go to the AI recipient [route]
  /// (core/ai_consent.dart aiConsentRoute: the provider id, or
  /// `server:<plan>`). App Store 5.1.2(i): ui/ai_consent.dart asks before
  /// the first send to a recipient; [setAiConsent] records the answer, and
  /// Settings' Stop sharing row withdraws it.
  bool hasAiConsent(String route);
  Future<void> setAiConsent(String route, {required bool granted});

  /// The consent text (core/ai_consent.dart aiConsentWordingVersion)
  /// [route] was allowed under: 0 = not allowed, 1 = allowed before
  /// versions were recorded. [setAiConsent] records the current one.
  int aiConsentVersion(String route);

  /// Whether the user answered Not now to allowing [route] again for the
  /// current text (ui/ai_consent.dart askAiConsentUpdate): asked once.
  bool aiConsentUpdateDeclined(String route);
  Future<void> declineAiConsentUpdate(String route);

  /// Whether a meal was ever saved in the app (AppSettings.mealLogged): a
  /// key-less install that logs by hand opens on Today, not on Settings.
  bool get mealLogged;
  Future<void> markMealLogged();
  String get model; // ACTIVE provider's model string
  int get lookbackDays; // backfill window, clamp 1–30 (spec §6.4/§8)
  String get reportTime; // 'HH:mm' local, daily-report notification time

  /// Whether the daily summary notification is delivered at all (default
  /// true). Off cancels every delivery path; the time row hides with it.
  bool get summaryEnabled;
  bool get watcherEnabled;

  /// True once the user accepted the one-time 监控相册 disclosure (photos
  /// go to the chosen AI service); only the Settings toggle reads it.
  bool get watcherDisclosureSeen;

  /// The 'Meta glasses photos' switch (AppSettings.watchGlasses; default
  /// on, off on Android: AppSettings.defaultWatchGlasses).
  bool get watchGlasses;
  String get dietaryProfile; // spec §1.3 photo-prompt appendix

  /// Base URL of the user's own server (AiProvider.server); '' when unset.
  String get serverBaseUrl;

  /// The host the own server's upload key was saved for
  /// (AppSettings.serverKeyHost, lowercased); null: no key, one saved
  /// before any address, or only a key whose server is not known
  /// ([serverKeyHostUnknown]). The key is sent to that host only
  /// (core/server_transport.dart serverKeyForOtherHost).
  String? get serverKeyHost;

  /// Whether a key is kept whose server is not known
  /// (AppSettings.serverKeyHostUnknown): one an earlier version stored
  /// without its server address. It is not the upload key ([apiKey] is ''
  /// on the server): never in the key field or sent, until the user uses
  /// it for the address ([bindServerKeyToAddress]) or enters another key.
  bool get serverKeyHostUnknown;

  /// The own server's upload key as its key field shows it at the saved
  /// address (AppSettings.serverKeyForAddress): the key while it is bound
  /// to the address's host, or to none yet; '' while it is bound to another
  /// host, or to one while the address names none, and at every address
  /// for a key whose server is not known.
  String get serverKeyForAddress;

  /// The text of the upload key that may go to [host] (AppSettings
  /// .serverKeyFor), or null: what HttpsOnlyServerClient checks each
  /// X-API-Key against.
  String? serverKeyFor(String host);

  /// The server page's key field, edited (AppSettings
  /// .setServerKeyFromField): what it holds is the key for the address it
  /// was filled at, [filledAt]. False, and nothing written, when the saved
  /// address has moved to another host since.
  Future<bool> setServerKeyFromField(String value,
      {required String filledAt});

  /// Fires on every change to these settings (the store notifies on each
  /// write). The server page refreshes its fields from it: a setup link
  /// confirmed with the page open replaced the address and the key under
  /// fields that still showed the previous server's (review of PR 74).
  Listenable get changes;

  /// Settings › Your own server › "Use this key for …": the saved
  /// upload key is the current address's too, or the key kept whose server
  /// is not known is the current address's (AppSettings
  /// .bindServerKeyToAddress). Only on the user's tap.
  Future<void> bindServerKeyToAddress();

  /// Settings › Your own server › "Remove this key": deletes the key kept
  /// whose server is not known ([serverKeyHostUnknown]) from the phone
  /// (AppSettings.removeServerKeyOfUnknownHost); its field is empty, so
  /// clearing the field cannot. Only on the user's tap; the upload key, if
  /// there is one instead, is never touched.
  Future<void> removeServerKeyOfUnknownHost();

  /// A confirmed setup link: the own server on [serverBackend] at
  /// [serverBaseUrl] with [apiKey], set together and notified once
  /// (AppSettings.applyServerSetup), so nothing sees the new address with
  /// the previous key.
  Future<void> applyServerSetup({
    required String serverBackend,
    required String serverBaseUrl,
    required String apiKey,
  });

  /// Whose subscription pays on the server: 'claude' | 'glm' | 'doubao'
  /// (AppSettings.serverBackends). Plan keys live in the server's .env.
  String get serverBackend;

  /// 'system' | 'en' | 'zh' — the UI language override (app-only §9).
  String get appLanguage;

  /// 'metric' | 'imperial' — body-data DISPLAY units (app-only §9;
  /// storage stays metric, zh UI renders metric regardless).
  String get units;

  /// Claude-plan model/effort choice ('' = server default; claude-only —
  /// the vendor plans map models server-side).
  String get serverModel;
  String get serverEffort;

  /// Daily calorie goal for the coach notification; 0 = unset (the
  /// summary then compares against the typical-day median).
  int get calorieGoal;

  /// The restaurant assist (design R7a; AppSettings.restaurantAssist…):
  /// 'off' | 'auto' ('When unsure') | 'always'.
  String get restaurantAssist;

  /// 'Use photo location' (false on Android whatever is stored).
  bool get restaurantAssistLocation;

  /// The consent: when it was given and to which recipient
  /// (LookupSupport.recipientStamp); both null without one.
  DateTime? get restaurantAssistConsentAt;
  String? get restaurantAssistConsentRecipient;

  /// Writes the restaurant assist's settings together (one change signal,
  /// so the assist never sees a mode without its consent). Null leaves a
  /// value as it is; [clearConsent] forgets the consent.
  Future<void> updateRestaurantAssist({
    String? mode,
    bool? location,
    DateTime? consentAt,
    String? consentRecipient,
    bool clearConsent = false,
  });

  Future<void> update({
    String? apiKey,
    String? provider,
    String? model,
    int? lookbackDays,
    String? reportTime,
    bool? summaryEnabled,
    bool? watcherEnabled,
    bool? watcherDisclosureSeen,
    bool? watchGlasses,
    String? dietaryProfile,
    String? serverBaseUrl,
    String? serverBackend,
    String? appLanguage,
    String? units,
    String? serverModel,
    String? serverEffort,
    int? calorieGoal,
  });
}

/// Whether [s] is on the own server with an upload key saved for another
/// host than its address (core/server_transport.dart): nothing is sent
/// with that key until the user pastes this server's key or uses the saved
/// one for it (SettingsStore.bindServerKeyToAddress).
bool serverKeyForOtherAddress(SettingsStore s) =>
    s.provider == 'server' &&
    s.apiKey.trim().isNotEmpty &&
    serverKeyForOtherHost(s.serverKeyHost, s.serverBaseUrl);

/// Recent-photo picking for the Add flow grid. The photo module exposes
/// pickFromRecent; di.dart adapts it here. Returned photos MUST carry
/// deliberate=true (user-picked → reclaims failed/skipped/deleted ledger
/// rows, spec §2.3 caller policies).
abstract class RecentPhotoPicker {
  /// LIST the recent assets without reading their bytes, plus a per-asset
  /// thumbnail fetch and an on-demand original. The eager recentPhotos()
  /// this replaced pulled up to 30 ORIGINALS (25 MB each) into one list,
  /// and the grid decoded every 12 MP image full-res for a ~120 px cell —
  /// hundreds of MB resident on a screen that uses exactly one photo.
  Future<List<RecentAsset>> recentAssets({int limit = 30});
  Future<Uint8List?> thumbnail(String assetId);
  Future<IntakePhoto?> loadOriginal(RecentAsset asset);
}

/// A notice the app shell owes the user once: shown while [pending] says
/// so, and forgotten through [shown] once dismissed. The Google Play
/// build's word that it turned Watch Camera Roll off (play_channel.dart).
class OwedNotice {
  const OwedNotice({required this.pending, required this.shown});
  final bool Function() pending;
  final Future<void> Function() shown;
}

/// One camera-roll entry, bytes NOT read.
class RecentAsset {
  const RecentAsset(this.id, this.fileName, this.createdAt);
  final String id;
  final String fileName;
  final DateTime createdAt;
}

/// [read] for the first call only: every later call answers null without
/// calling [read], also while the first is still pending and after it
/// failed (LINK-1, 2026-11-22). di.dart reads app_links' initial link
/// through it for [UiServices.initialSetupLink], which each HomeShell
/// reads in initState. app_links 7.2.1 answers that read with the same
/// link for as long as the plugin lives, so a second shell or a rebuilt
/// one asked about that setup link again, as the second shell of
/// RCREL-V-1 did.
///
/// That link need not be one that started the app. The plugin keeps the
/// first link it is given, and nothing clears it: the launch link or,
/// when there was none, the first one that came while the app ran, which
/// its stream delivers too (Android AppLinksPlugin.handleIntent, for
/// onNewIntent as well; iPhone AppLinksIosPlugin.handleLink, for every
/// URL the app is opened with). The stream sends each link once: a
/// listener that comes later is sent the initial link only if no link was
/// sent yet. So the one read left in an engine is its first shell's, as
/// the app starts.
///
/// The one the shells read is built once per app engine
/// (AppServices.init), so it answers once per engine. On Android that is
/// once per plugin: a new MainActivity starts a new engine, whose new
/// plugin has seen only that activity's links. On the iPhone the plugin
/// outlives an engine: AppLinks.shared is one object for every engine in
/// the process. UIKit may disconnect the app's scene in the background
/// and connect it again while the process lives. The scene then loads
/// Main.storyboard again, and its new FlutterViewController starts a new
/// engine (the app delegate hands out its launch engine once), so main
/// runs again in a new isolate, with a new wrapper. Its first read gets
/// the process's first link, whose sheet comes back: stopping that takes
/// a guard that lives as long as the process, which this one does not.
/// And when the process had a link before, a link that connects the
/// scene this time reaches only the plugin's latest link: neither this
/// read nor the stream hands it on. iPhone only, rare, and older than
/// this wrapper, as every shell read the plugin before it (LINK-1
/// review, 2026-11-23; read from app_links 7.2.1's and Flutter 3.44.2's
/// sources, not seen on a device).
///
/// A throw from [read] fails the first call's future, which HomeShell
/// handles, instead of escaping the call.
Future<Uri?> Function() launchLinkOnce(Future<Uri?> Function() read) {
  var asked = false;
  return () async {
    if (asked) return null;
    asked = true;
    return read();
  };
}

/// Everything a screen may need, built once at startup (di.dart) or from
/// fakes in widget tests.
class UiServices {
  final MealsDao dao;

  /// Fires when settings change — the app shell rebinds MaterialApp.locale
  /// from it so the language switch applies live. Null in tests (locale
  /// then follows the harness).
  final Listenable? settingsChanges;

  /// Today's Garmin active-burn fetch via the user's server; null = off.
  final GarminDailyFetch? garminDaily;
  final AnalyzerService analyzer;
  final NlExecutor executor;
  final PhotoIntake? photoIntake; // null in tests that never toggle the watcher
  final SettingsStore settings;
  final RecentPhotoPicker picker;
  final Future<bool> Function() requestPhotoPermission;

  /// Meal-photo thumbnails for the list UIs; null in tests → placeholders.
  final MealThumbResolver? thumbs;

  /// The coverage audit (spec §9): null in tests / when the photo module
  /// is absent.
  final CoverageAuditor? coverage;

  /// Process one photo through the app's ONE serialized pipeline — the
  /// coverage screen's "log missing / retry failed" actions go through
  /// here so they share the global FIFO with the watcher and share sheet.
  final Future<PhotoOutcome> Function(IntakePhoto photo)? processPhoto;

  /// The pipeline's own snackbar sink (di.dart words the outcome in the
  /// app language): for a verdict whose screen is gone — the add flow
  /// closed mid-analysis — so it is still said once (unannouncedOutcome).
  /// Null in tests that never back out.
  final void Function(PhotoOutcome outcome)? announceOutcome;

  /// Holds a shared photo until the user allows AI sharing for the current
  /// recipient (App Store 5.1.2(i)); the app shell attaches the dialog.
  /// Null in tests that never share.
  final SharedPhotoConsentGate? sharedPhotoConsent;

  /// Android: true while a shared photo is not settled yet
  /// (ShareIntake.photosPending); the shell's Back at the root then moves
  /// the app to the back in every task instead of leaving that Back to
  /// Android, which on Android 15 QPR1 and later can still finish the
  /// activity after a start MainActivity cannot see (SharedPhotosBackGuard).
  /// Null on iPhone and in most tests.
  final ValueListenable<bool>? sharedPhotosPending;

  /// Android: keeps the app running while an analysis the user started is
  /// in flight (owner decision 9): the pipeline keeps its
  /// deliberate photos, [executor] its typed meals and Fix meals requests,
  /// the leftover flow its estimate, and Photo Coverage its bulk run, as
  /// one request from its first photo to its last (SettingsScreen hands it
  /// on). Its [AnalysisKeepAlive.inFlight]
  /// also holds the shell's Back at the root, as [sharedPhotosPending]
  /// does (SharedPhotosBackGuard). Null on iPhone and in most tests.
  final AnalysisKeepAlive? analysisKeepAlive;

  /// Library access for coverage thumbnails; null in tests.
  final PhotoLibrary? photoLibrary;

  /// Server-provider Claude OAuth re-connect; null hides the button.
  final Future<({String? url, String? error})> Function()? startClaudeAuth;
  final Future<String?> Function(String code)? completeClaudeAuth;

  /// Server-side Claude sign-in state ('token' | 'none' | null unknown);
  /// null hides the status row. See ServerAnalyzer.serverLoginState.
  final Future<String?> Function()? serverLoginState;

  /// One-click setup links (bitewise://setup?...) — a warm-app stream and
  /// the cold-start link. Null in tests / when the platform has no plugin.
  /// Only an engine's first call gets the cold-start link: di.dart reads
  /// it through [launchLinkOnce], so a second or rebuilt shell gets null
  /// instead of that link's sheet again (LINK-1, 2026-11-22). On the
  /// iPhone a later engine in the same process can get it again (see
  /// there).
  final Stream<Uri>? setupLinks;
  final Future<Uri?> Function()? initialSetupLink;

  /// Whether the OS will show this app's notifications; null = unknown.
  /// Settings shows a "notifications are off" remedy when this is false.
  final Future<bool?> Function()? notificationsEnabled;

  /// The slot the daily summary is currently armed for (null: nothing
  /// armed) — the Settings "next summary" row. Null probe hides the row.
  final Future<DateTime?> Function()? nextSummaryAt;

  /// When the OS last launched the background photo scan (null: never).
  final Future<DateTime?> Function()? lastBackgroundScan;

  /// iOS Background App Refresh for this app: false = the system switch
  /// (or Low Power Mode) is off, so the background scan can never be
  /// scheduled. Null probe/answer = not applicable or unknown.
  final Future<bool?> Function()? backgroundRefreshEnabled;

  /// Whether the recorded background runs say the scan is stuck
  /// (backgroundScanLooksStuck). Null probe: never said.
  final Future<bool> Function()? backgroundScanStuck;

  /// Re-arms the OS-scheduled daily summary (iOS). The shell calls it on
  /// every lifecycle transition so the pending card is never staler than
  /// the last time the user had the app open. Null on Android (the
  /// WorkManager heartbeat computes the summary at the slot instead) and
  /// in tests.
  final Future<void> Function()? refreshDailyNotification;

  /// Opens the OS app-settings page (permission remediation: once the OS
  /// stops re-showing the photo dialog, in-app re-requests are no-ops and
  /// this is the ONLY way back). Null in tests hides the buttons.
  final Future<void> Function()? openSystemSettings;

  /// The meals a screen is working on (design R6a): the editor, a leftover
  /// selection and a pending fix-meal request hold them, and the
  /// restaurant assist leaves them alone. Null in tests that do not care.
  final MealInUseRegistry? mealInUse;

  /// The restaurant assist as Settings and its consent sheets see it
  /// (design R7a). Null hides the Settings group (most tests).
  final RestaurantAssistControls? restaurantAssist;

  /// Usual foods (worked out on the phone from the meals table, nothing
  /// sent): Today's "your usual numbers" offers and Log › My usual foods.
  /// Null hides both (most tests).
  final UsualFoods? usualFoods;

  /// iCloud Backup (iPhone, 1.7.0): Settings › Your Data's rows, and the
  /// notice and restore offer the shell raises. Null on Android and in
  /// most tests.
  final BackupCoordinator? cloudBackup;

  /// The Google Play build's one notice after it turned off the Watch
  /// Camera Roll a GitHub install left on (play_channel.dart); the shell
  /// shows it over the first frame. Null elsewhere and in most tests.
  final OwedNotice? watchRetiredNotice;

  /// Android: how an Export › Save to Device ended whose call died with an
  /// earlier engine (Android recreated the activity while the save screen
  /// was up; the copy still ran), once — the shell says "Export saved."
  /// (save_file_channel.dart takeLateSaveResult). Null elsewhere and in
  /// most tests.
  final Future<SaveFileStatus?> Function()? lateSaveResult;

  /// Android: "show me that meal", from the View on a shared photo's
  /// snackbar and a tap on a Logged meals card. The shell attaches and goes
  /// to the meal, only over itself (meal_reveal.dart). Null on iPhone and
  /// in most tests.
  final MealReveals? mealReveals;

  /// What the automatic photo scan is doing now, for Today's "Checking
  /// photos" row (services/photo/scan_status.dart), and that row's Retry:
  /// the catch-up again, for photos a scan let go unchecked. Null in the
  /// Google Play build and in most tests: no row.
  final PhotoScanStatus? photoScanStatus;
  final Future<void> Function()? retryPhotoScan;

  const UiServices({
    required this.dao,
    required this.analyzer,
    required this.executor,
    required this.settings,
    required this.picker,
    required this.requestPhotoPermission,
    this.photoIntake,
    this.thumbs,
    this.coverage,
    this.processPhoto,
    this.announceOutcome,
    this.sharedPhotoConsent,
    this.sharedPhotosPending,
    this.analysisKeepAlive,
    this.photoLibrary,
    this.startClaudeAuth,
    this.completeClaudeAuth,
    this.serverLoginState,
    this.setupLinks,
    this.initialSetupLink,
    this.openSystemSettings,
    this.garminDaily,
    this.settingsChanges,
    this.refreshDailyNotification,
    this.notificationsEnabled,
    this.nextSummaryAt,
    this.lastBackgroundScan,
    this.backgroundRefreshEnabled,
    this.backgroundScanStuck,
    this.mealInUse,
    this.restaurantAssist,
    this.usualFoods,
    this.cloudBackup,
    this.watchRetiredNotice,
    this.lateSaveResult,
    this.mealReveals,
    this.photoScanStatus,
    this.retryPhotoScan,
  });
}
