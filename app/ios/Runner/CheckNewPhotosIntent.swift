import AppIntents
import Flutter
import Foundation
import UIKit
import os
import workmanager_apple

/// "Check new photos" (检查新照片): an action Shortcuts, Siri and Spotlight
/// can run while Chopstats is closed. TRIAL BUILD (2026-11-28, Phase 0 of
/// the iPhone background plan): it answers on the owner's phone whether a
/// Shortcuts automation (App: Camera, Is Closed) gets a lunch photo logged
/// within the minute, before the real version is built.
///
/// What it runs is the background photo scan iOS already starts a few
/// times a day: workmanager's one-off task under the BGTask identifier
/// (AppDelegate.photoBackfillIdentifier), which creates a headless engine
/// at the stored dispatcher (appBackgroundDispatcher, from the app's
/// Workmanager().initialize at each launch) and hands it that identifier
/// as the task name (workmanager_apple 0.9.1+2 BackgroundWorker.swift,
/// BackgroundMode.backgroundOneOffTask), which isPhotoBackfillTask accepts.
/// So the run has the same guards, the same consent check at each send,
/// the same limits (photos offered for 15 s, the run over by 22 s), and
/// never reads or sends a photo the background scan would not. The only
/// differences, written by Dart: the run's entry in Recent background
/// scans says it was started by Shortcuts, and the run leaves its result
/// for this action (lib/ui/background_glue.dart, shortcutResultPrefsKey).
///
/// Never thrown for an expected state: every way it ends is an
/// [CheckNewPhotos.Outcome] with a line for Shortcuts and Siri and the
/// number of meals logged as the value.
@available(iOS 16.0, *)
struct CheckNewPhotosIntent: AppIntent {
  static var title: LocalizedStringResource = "Check new photos"
  static var description = IntentDescription(
    "Checks new photos for meals and logs them, as Chopstats' background scan does. Needs Watch Camera Roll on.")

  /// IntentAuthenticationPolicy.alwaysAllowed: "allows the app intent to
  /// run at any time, including when the device is locked" (the default
  /// asks for an unlock first). The scan already runs on a locked phone
  /// when iOS starts it: keys are readable after the first unlock.
  static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  // openAppWhenRun stays at its default (false), and supportedModes (iOS
  // 26) is left to its default: the action never brings the app forward.

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
    let outcome = await CheckNewPhotos.check(.live)
    return .result(value: outcome.meals, dialog: IntentDialog(outcome.line))
  }
}

/// The action's App Shortcut: in Shortcuts (under Chopstats), Spotlight and
/// Siri from install, with no set-up. Phrases must name the app
/// (${applicationName}); AppShortcuts.strings localizes them (the string
/// catalog form needs an iOS 17 deployment target).
@available(iOS 16.0, *)
struct ChopstatsShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CheckNewPhotosIntent(),
      phrases: [
        "Check new photos in \(.applicationName)",
        "Log my meal photos with \(.applicationName)",
      ])
  }
}

/// The action's parts that need no AppIntents type: tested in RunnerTests.
enum CheckNewPhotos {
  /// Dart's 'background.shortcut_hint_iso' as shared_preferences stores it
  /// (background_glue.dart shortcutHintPrefsKey): when the action started
  /// a run, ISO 8601 UTC with milliseconds, as stampBackgroundLaunch writes.
  static let hintDefaultsKey = "flutter.background.shortcut_hint_iso"

  /// Dart's 'background.shortcut_result' (shortcutResultPrefsKey): the run's
  /// answer, JSON {hint, at, saved, left, stop, sharing?}.
  static let resultDefaultsKey = "flutter.background.shortcut_result"

  /// Dart's 'background.runs_v1' (background_runs.dart backgroundRunsPrefsKey).
  static let runsDefaultsKey = "flutter.background.runs_v1"

  /// This trial's own log, newest first: when the action ran, the app's
  /// state then, how long the process had been up, and how it ended. JSON
  /// list; read by nothing yet.
  static let trialLogDefaultsKey = "flutter.trial.check_photos_log"
  static let trialLogKept = 30

  /// How long the action waits, from the top of perform(): an app intent
  /// gets about 30 s in the background, and the run it starts is over 22 s
  /// after its own start (iosRunDeadline), plus its wrap-up.
  static let budget: TimeInterval = 25
  static let pollInterval: TimeInterval = 0.5

  /// An unfinished run entry younger than this is a run still going: every
  /// run ends within 22 s of its start, and its boot comes before.
  static let liveRunWindow: TimeInterval = 30

  /// workmanager_apple 0.9.1+2 UserDefaultsHelper: where Workmanager()
  /// .initialize stores the dispatcher's callback handle.
  static let workmanagerSuite = "dev.fluttercommunity.workmanager.userDefaults"
  static let workmanagerHandleKey = "dev.fluttercommunity.workmanager.callbackHandle"

  private static let log = Logger(
    subsystem: "dev.calorietracker.calorieTracker", category: "CheckNewPhotos")

  /// How the action ended.
  enum Outcome: Equatable {
    /// Chopstats is on screen: its own scan checks photos (nothing started).
    case appOpen
    /// A check this action started, or a background run, is still going.
    case anotherCheck
    /// No dispatcher stored yet: Chopstats has not been opened since install.
    case notReady
    case logged(meals: Int, waiting: Int)
    /// Nothing new, or nothing new that was food.
    case nothingNew
    /// No meal: photos left for a later run (the AI service busy or out of
    /// reach, say).
    case waiting(photos: Int)
    case watcherOff
    case noAI
    case needsHttps
    case paused
    case sharingStopped
    case noPhotoAccess
    /// The run used its time, or no answer came within [budget].
    case outOfTime
    /// The run stopped on an error, or was stopped by iOS.
    case failed

    /// The intent's value.
    var meals: Int {
      if case .logged(let meals, _) = self { return meals }
      return 0
    }

    /// For the trial log and the unified log.
    var name: String {
      switch self {
      case .appOpen: return "app_open"
      case .anotherCheck: return "another_check"
      case .notReady: return "not_ready"
      case .logged: return "logged"
      case .nothingNew: return "nothing_new"
      case .waiting: return "waiting"
      case .watcherOff: return "watcher_off"
      case .noAI: return "no_ai"
      case .needsHttps: return "needs_https"
      case .paused: return "paused"
      case .sharingStopped: return "sharing_stopped"
      case .noPhotoAccess: return "no_photo_access"
      case .outOfTime: return "out_of_time"
      case .failed: return "failed"
      }
    }
  }

  /// What a run started by this action leaves for it (Dart:
  /// shortcutResultFor). [hint] is the action's own stamp, echoed: an
  /// answer from any other run is not this one's.
  struct RunResult: Equatable {
    var hint: String
    var saved: Int
    var left: Int
    var stop: String
    /// Whether the run's settings allowed sending to the AI service they
    /// name; nil when the run ended before it had settings.
    var sharing: Bool?
  }

  static func parseResult(_ raw: String?) -> RunResult? {
    guard let raw = raw, let data = raw.data(using: .utf8),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let hint = json["hint"] as? String, let stop = json["stop"] as? String
    else { return nil }
    return RunResult(
      hint: hint,
      saved: max(0, json["saved"] as? Int ?? 0),
      left: max(0, json["left"] as? Int ?? 0),
      stop: stop,
      sharing: json["sharing"] as? Bool)
  }

  /// The run's stop reasons (background_runs.dart BackgroundStop) as the
  /// action reports them. Nil: no answer in time.
  static func outcome(for result: RunResult?) -> Outcome {
    guard let r = result else { return .outOfTime }
    if r.saved > 0 { return .logged(meals: r.saved, waiting: r.left) }
    switch r.stop {
    case "watcher_off": return .watcherOff
    case "no_key": return .noAI
    case "needs_https": return .needsHttps
    case "no_permission": return .noPhotoAccess
    case "paused": return .paused
    case "done", "budget":
      // The scan ran, and its photos were held back at the send: the
      // consent check (AiSendGate) refused the AI service the settings name.
      if r.sharing == false { return .sharingStopped }
      if r.stop == "budget" { return .outOfTime }
      return r.left > 0 ? .waiting(photos: r.left) : .nothingNew
    default: return .failed  // error:<class>, system_stop, a later version's reason
    }
  }

  /// What [check] needs from the app and the system (RunnerTests fake it).
  struct Environment {
    var appState: @MainActor () -> UIApplication.State
    var defaults: UserDefaults
    var now: () -> Date
    /// Whether workmanager can start a run: a dispatcher is stored.
    var dispatcherReady: () -> Bool
    /// Starts the background scan (startBackgroundScan).
    var startRun: @MainActor () -> Void
    /// Waits; false when the action was cancelled.
    var sleep: (TimeInterval) async -> Bool
    var uptime: () -> TimeInterval?

    @MainActor
    static var live: Environment {
      Environment(
        appState: { UIApplication.shared.applicationState },
        defaults: .standard,
        now: { Date() },
        dispatcherReady: { CheckNewPhotos.dispatcherStored() },
        startRun: { CheckNewPhotos.startBackgroundScan() },
        sleep: { seconds in
          do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return true
          } catch {
            return false
          }
        },
        uptime: { CheckNewPhotos.processUptime() })
    }
  }

  /// A check this action started is still waiting (one at a time).
  @MainActor static var checking = false

  /// The action itself, from the top of perform().
  @MainActor
  static func check(_ env: Environment) async -> Outcome {
    let started = env.now()
    let stamp = iso(started)
    let state = env.appState()
    let uptime = env.uptime()
    log.info(
      "start state=\(stateName(state), privacy: .public) uptime=\(uptime ?? -1, privacy: .public)")
    var entry: [String: Any] = ["at": stamp, "state": stateName(state)]
    if let uptime = uptime { entry["uptime_s"] = round1(uptime) }
    writeTrialEntry(env.defaults, entry)
    let outcome: Outcome
    if state == .active {
      // Read on the main actor. The open app's own scan checks photos.
      outcome = .appOpen
    } else if checking || runStillGoing(in: env.defaults, now: started) {
      outcome = .anotherCheck
    } else if !env.dispatcherReady() {
      outcome = .notReady
    } else {
      checking = true
      env.defaults.removeObject(forKey: resultDefaultsKey)
      env.defaults.set(stamp, forKey: hintDefaultsKey)
      env.startRun()
      outcome = await waitForResult(env, hint: stamp, until: started.addingTimeInterval(budget))
      checking = false
    }
    let waited = env.now().timeIntervalSince(started)
    log.info(
      "end outcome=\(outcome.name, privacy: .public) meals=\(outcome.meals, privacy: .public) waited=\(waited, privacy: .public)"
    )
    entry["outcome"] = outcome.name
    entry["meals"] = outcome.meals
    entry["waited_s"] = round1(waited)
    writeTrialEntry(env.defaults, entry)
    return outcome
  }

  /// Polls for the run's answer every [pollInterval] until [deadline].
  @MainActor
  static func waitForResult(_ env: Environment, hint: String, until deadline: Date) async
    -> Outcome
  {
    while true {
      if let result = parseResult(env.defaults.string(forKey: resultDefaultsKey)),
        result.hint == hint
      {
        return outcome(for: result)
      }
      let left = deadline.timeIntervalSince(env.now())
      if left <= 0 { return .outOfTime }
      guard await env.sleep(min(pollInterval, left)) else { return .outOfTime }
    }
  }

  /// The newest stored run has no end and no stop reason, and began less
  /// than [liveRunWindow] ago: a background run is still going. Starting
  /// another would put two scans side by side, and their entries in Recent
  /// background scans over each other.
  static func runStillGoing(in defaults: UserDefaults, now: Date) -> Bool {
    guard let raw = defaults.string(forKey: runsDefaultsKey),
      let data = raw.data(using: .utf8),
      let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
      let newest = list.first,
      let startText = newest["start"] as? String,
      let start = parseInstant(startText)
    else { return false }
    let open = !(newest["end"] is String) && !(newest["stop"] is String)
    let age = now.timeIntervalSince(start)
    return open && age > -liveRunWindow && age < liveRunWindow
  }

  /// workmanager's stored dispatcher: without it its BackgroundWorker
  /// gives up at once (Workmanager not initialized), and the action would
  /// only wait out its time.
  static func dispatcherStored() -> Bool {
    guard let suite = UserDefaults(suiteName: workmanagerSuite),
      let handle = suite.object(forKey: workmanagerHandleKey) as? Int64
    else { return false }
    return FlutterCallbackCache.lookupCallbackInformation(handle) != nil
  }

  /// The background scan, started as workmanager's registerOneOffTask
  /// does: under a UIKit background task of its own, which workmanager
  /// ends when the run's engine is done. With .invalid the app could be
  /// suspended the moment perform() returns, mid-photo; this way a run
  /// still finishing its last write gets to finish it, and the expiry
  /// handler ends the task if iOS calls time first. On the main thread:
  /// the engine is created there.
  @MainActor
  static func startBackgroundScan() {
    var task: UIBackgroundTaskIdentifier = .invalid
    task = UIApplication.shared.beginBackgroundTask(withName: "Check new photos") {
      UIApplication.shared.endBackgroundTask(task)
    }
    WorkmanagerPlugin.startOneOffTask(
      identifier: AppDelegate.photoBackfillIdentifier, taskIdentifier: task, inputData: nil,
      delaySeconds: 0)
  }

  /// Seconds since this process started (sysctl), to tell a launch made
  /// for the action from a process already in memory.
  static func processUptime(now: Date = Date()) -> TimeInterval? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    let began = Date(
      timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    return now.timeIntervalSince(began)
  }

  static func stateName(_ state: UIApplication.State) -> String {
    switch state {
    case .active: return "active"
    case .inactive: return "inactive"
    case .background: return "background"
    @unknown default: return "unknown"
    }
  }

  /// UTC, milliseconds: the format of AppDelegate.stampBackgroundLaunch,
  /// which Dart's DateTime.parse reads.
  static func iso(_ date: Date) -> String {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format.string(from: date)
  }

  /// Reads Dart's toIso8601String (microseconds when it has them) and this
  /// file's own stamps.
  static func parseInstant(_ text: String) -> Date? {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = format.date(from: text) { return date }
    if let dot = text.firstIndex(of: "."),
      let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber })
    {
      let digits = text[text.index(after: dot)..<end]
      if digits.count > 3 {
        let trimmed = String(text[...dot]) + digits.prefix(3) + text[end...]
        if let date = format.date(from: trimmed) { return date }
      }
    }
    format.formatOptions = [.withInternetDateTime]
    return format.date(from: text)
  }

  private static func round1(_ seconds: TimeInterval) -> Double {
    (seconds * 10).rounded() / 10
  }

  /// Puts [entry] first in the trial log, replacing the one with the same
  /// "at" (the start of the same check). Never throws.
  static func writeTrialEntry(_ defaults: UserDefaults, _ entry: [String: Any]) {
    var list: [[String: Any]] = []
    if let raw = defaults.string(forKey: trialLogDefaultsKey),
      let data = raw.data(using: .utf8),
      let stored = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    {
      list = stored
    }
    let at = entry["at"] as? String
    list.removeAll { ($0["at"] as? String) == at }
    list.insert(entry, at: 0)
    let kept = Array(list.prefix(trialLogKept))
    guard JSONSerialization.isValidJSONObject(kept),
      let data = try? JSONSerialization.data(withJSONObject: kept),
      let text = String(data: data, encoding: .utf8)
    else { return }
    defaults.set(text, forKey: trialLogDefaultsKey)
  }
}

/// The lines Shortcuts shows and Siri says (Localizable.strings, en and
/// zh-Hans).
@available(iOS 16.0, *)
extension CheckNewPhotos.Outcome {
  var line: LocalizedStringResource {
    switch self {
    case .appOpen:
      return LocalizedStringResource(
        "check.appOpen", defaultValue: "Chopstats is open and checks your photos itself.")
    case .anotherCheck:
      return LocalizedStringResource(
        "check.anotherCheck",
        defaultValue: "Another photo check is running. Try again in a moment.")
    case .notReady:
      return LocalizedStringResource(
        "check.notReady", defaultValue: "Open Chopstats once, then try again.")
    case .logged(let meals, let waiting):
      switch (meals == 1, waiting > 0) {
      case (true, false):
        return LocalizedStringResource("check.logged.one", defaultValue: "Logged 1 meal.")
      case (false, false):
        return LocalizedStringResource(
          "check.logged.many", defaultValue: "Logged \(meals) meals.")
      case (true, true):
        return LocalizedStringResource(
          "check.logged.one.more",
          defaultValue: "Logged 1 meal. More photos wait for the next check.")
      case (false, true):
        return LocalizedStringResource(
          "check.logged.many.more",
          defaultValue: "Logged \(meals) meals. More photos wait for the next check.")
      }
    case .nothingNew:
      return LocalizedStringResource("check.nothingNew", defaultValue: "No new meal photos.")
    case .waiting(let photos):
      return photos == 1
        ? LocalizedStringResource(
          "check.waiting.one", defaultValue: "No meal logged yet: 1 photo waits for the next check.")
        : LocalizedStringResource(
          "check.waiting.many",
          defaultValue: "No meal logged yet: \(photos) photos wait for the next check.")
    case .watcherOff:
      return LocalizedStringResource(
        "check.watcherOff",
        defaultValue: "Watch Camera Roll is off in Chopstats, so no photo was checked.")
    case .noAI:
      return LocalizedStringResource(
        "check.noAI", defaultValue: "Chopstats has no AI service set up yet, so nothing was sent.")
    case .needsHttps:
      return LocalizedStringResource(
        "check.needsHttps",
        defaultValue: "Your server's address in Chopstats must start with https://, so nothing was sent.")
    case .paused:
      return LocalizedStringResource(
        "check.paused",
        defaultValue: "Automatic analysis is paused in Chopstats. Open it to see why.")
    case .sharingStopped:
      return LocalizedStringResource(
        "check.sharingStopped",
        defaultValue: "Sharing with your AI service is stopped in Chopstats, so nothing was sent.")
    case .noPhotoAccess:
      return LocalizedStringResource(
        "check.noPhotoAccess",
        defaultValue: "Chopstats may not read your photos. Allow access in iPhone Settings.")
    case .outOfTime:
      return LocalizedStringResource(
        "check.outOfTime",
        defaultValue: "The check ran out of time. Photos left wait for the next check.")
    case .failed:
      return LocalizedStringResource(
        "check.failed",
        defaultValue: "The check stopped early. See Recent background scans in Chopstats.")
    }
  }
}
