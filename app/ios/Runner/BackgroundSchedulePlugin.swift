import BackgroundTasks
import Flutter
import Foundation

/// The request iOS holds for the next background photo scan: counted, and
/// made again when it is gone.
///
/// WHY THIS EXISTS (2026-11-28): iOS launches the scan's BGAppRefreshTask
/// only while it holds a REQUEST for it. workmanager submits one at a cold
/// start and at the start of each run, and only logs a submit iOS refuses
/// (WorkmanagerPlugin.schedulePeriodicTask). A request refused once, or a
/// run that ended before it could ask for the next one, left an app that
/// stays in memory for days with no request at all: no background scan
/// until the next cold start, and nothing on the phone said so. On
/// 2026-11-27 a noon meal was logged at 23:05, and nobody could tell
/// whether a request had been waiting.
///
/// Channel `dev.calorietracker/bgschedule` (Dart side:
/// lib/services/photo/background_schedule.dart):
///   pending → Int
///     how many requests iOS holds for the photo scan's identifier
///     (BGTaskScheduler.getPendingTaskRequests)
///   submit → nil | {domain: String, code: Int}
///     one BGAppRefreshTaskRequest for that identifier with no earliest
///     time (iOS runs it when it likes); nil when iOS took it, else the
///     error it threw (BGTaskSchedulerErrorDomain: 1 unavailable, 2 too
///     many pending, 3 not permitted)
///
/// Only that one identifier, never one Dart names: the launch handler for
/// it is workmanager's (AppDelegate), and a request under any other name
/// would never run. A submit REPLACES a request iOS already holds for the
/// identifier, so Dart submits only when `pending` says there is none: an
/// existing request's earliest time is never pushed later (and one made
/// here has none to push).
///
/// Registered for both engines (AppDelegate.registerAppPlugins); only the
/// app's own engine calls it. The scheduler is asked off the main thread
/// (a submit can block), and every reply arrives on it.
final class BackgroundSchedulePlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.calorietracker/bgschedule"

  /// What the plugin needs from BGTaskScheduler (RunnerTests hand it a
  /// fake: the simulator refuses every submit).
  struct Queue {
    /// The identifiers of the requests iOS holds, one per request.
    var pending: (@escaping ([String]) -> Void) -> Void
    /// Submits one app-refresh request with no earliest time; throws what
    /// iOS throws.
    var submit: (_ identifier: String) throws -> Void

    static let system = Queue(
      pending: { done in
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
          done(requests.map { $0.identifier })
        }
      },
      submit: { identifier in
        try BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(identifier: identifier))
      })
  }

  private let queue: Queue
  private let work: DispatchQueue
  private let reply: DispatchQueue

  init(
    queue: Queue = .system,
    work: DispatchQueue = DispatchQueue.global(qos: .utility),
    reply: DispatchQueue = .main
  ) {
    self.queue = queue
    self.work = work
    self.reply = reply
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BackgroundSchedulePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let identifier = AppDelegate.photoBackfillIdentifier
    switch call.method {
    case "pending":
      let reply = self.reply
      queue.pending { identifiers in
        let count = identifiers.filter { $0 == identifier }.count
        reply.async { result(count) }
      }
    case "submit":
      let queue = self.queue
      let reply = self.reply
      work.async {
        let answer = BackgroundSchedulePlugin.submit(identifier, through: queue)
        reply.async { result(answer) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// nil when iOS took the request, else {domain, code} of what it threw.
  static func submit(_ identifier: String, through queue: Queue) -> [String: Any]? {
    do {
      try queue.submit(identifier)
      return nil
    } catch {
      let failure = error as NSError
      return ["domain": failure.domain, "code": failure.code]
    }
  }
}
