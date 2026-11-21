package dev.calorietracker.calorie_tracker

import android.content.Context
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.SystemClock
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException

/// Keeps the process running, and its network usable, while an analysis
/// the user started is on its way to the AI or their own server (owner
/// decision 9, option 1, 2026-11-20): a photo shared, picked, logged from
/// Photo Coverage or checked as leftovers, a typed meal, a Fix meals
/// request. Android caches an app's process once it is neither in front
/// nor the "previous" app, freezes it about 10 s later (API 35 and 36:
/// Home and then another app froze Chopstats at about +17 s; Android 16
/// also freezes the previous app after about 70 s), and cuts a background
/// app's network about 8 s after Home: the reply then waited in the frozen
/// process until the user came back, and a kill lost it (QA 2026-11-20).
///
/// Dart's AnalysisKeepAlive (lib/services/analysis_keep_alive.dart) sends
/// "begin" and "end" for each request over MainActivity's keep-alive
/// channel. While one is live (KeepAliveLedger: begun, not ended, younger
/// than KeepAliveRules.CAP_MS) a WorkManager one-time job runs: expedited
/// on Android 12 and later, plain below (KeepAliveRules.expedited), with no
/// notification, and from Android 9 a constraint for any network that
/// reaches the internet, validated or not (KeepAliveRules
/// .usesNetworkRequest). A running job keeps the process out of the cached
/// state, so it is not frozen, and an expedited job keeps its network. Its
/// worker only waits: it returns once nothing is live, and the job is
/// cancelled as the last request ends, so it never keeps the process up
/// after that. One job runs 2 minutes 45 seconds at most
/// (KeepAliveRules.JOB_CAP_MS, below the 3 minutes past which Android
/// counts an expedited job as timed out); a request still live then gets a
/// follow-up job. An engine that dies takes its requests with it (drop,
/// from MainActivity.cleanUpFlutterEngine), and an engine's Dart starting
/// over (a hot restart) drops the ones its last run left (reset). Nothing
/// is persisted, but WorkManager keeps the job's own record: a job it runs
/// again in a new process, after a backoff, finds nothing live there and
/// ends at once, and the first request a process begins replaces any such
/// job with a fresh one (KeepAliveRules.replacesJob) instead of adopting it.
internal object AnalysisKeepAlive {
    private val ledger = KeepAliveLedger()
    private val sessions = AtomicLong()

    /// A session for a Flutter engine MainActivity configures: its
    /// requests are told apart from another engine's by it.
    fun newSession(): Long = sessions.incrementAndGet()

    /// Request [id] of [session] began: recorded, and the job enqueued.
    /// The first live request replaces whatever job WorkManager has
    /// (ExistingWorkPolicy.REPLACE: a backed-off re-run, or one finishing);
    /// one that joins a live request keeps the job that runs for it (KEEP).
    /// A WorkManager that cannot be reached leaves the request as it was
    /// before, without the job.
    fun begin(context: Context, session: Long, id: Long): Boolean {
        val now = SystemClock.elapsedRealtime()
        // Asked before the request is recorded: was one live already?
        val replace = KeepAliveRules.replacesJob(liveBefore = ledger.live(now))
        val added = ledger.begin(session, id, now)
        enqueue(context, if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP)
        return added
    }

    /// Request [id] of [session] ended (settled, failed, refused or let
    /// go): the job goes once nothing is live (settle).
    fun end(context: Context, session: Long, id: Long): Boolean {
        val removed = ledger.end(session, id)
        if (removed) settle(context)
        return removed
    }

    /// [session]'s engine is gone, and every request it had with it; or
    /// its Dart started over (MainActivity's "reset"), and can no longer
    /// end the requests its last run began.
    fun drop(context: Context, session: Long) {
        if (ledger.drop(session) > 0) settle(context)
    }

    /// Nothing live left: the job is cancelled now, whether it runs (its
    /// worker has returned already, woken by the change) or still waits
    /// for its turn or its network, so it never starts for nothing.
    private fun settle(context: Context) {
        if (ledger.live(SystemClock.elapsedRealtime())) return
        try {
            WorkManager.getInstance(context).cancelUniqueWork(KeepAliveRules.WORK_NAME)
        } catch (e: Exception) {
            // Then the worker, if it runs, returns on its own.
        }
    }

    /// One job's run: it waits while a request is live, for
    /// KeepAliveRules.JOB_CAP_MS at most (Android counts an expedited job
    /// of 3 minutes or more as timed out). A request still live then gets
    /// a follow-up job, appended to this one so it starts as this one
    /// ends; cancelled with it, should the last request end first.
    suspend fun runJob(context: Context) {
        val stillLive = ledger.awaitIdleOrCap(KeepAliveRules.JOB_CAP_MS) {
            SystemClock.elapsedRealtime()
        }
        if (!stillLive) return
        enqueue(context, ExistingWorkPolicy.APPEND_OR_REPLACE)
    }

    /// The system stopped a running job with [stopReason] (Android 12 and
    /// later): while a request is still live, and the stop is one a fresh
    /// job can outlast (KeepAliveRules.renewsAfterStop), a fresh job
    /// replaces it now, expedited again, instead of WorkManager's re-run of
    /// the stopped one: plain, and only after a backoff.
    fun renewAfterStop(context: Context, stopReason: Int) {
        if (!KeepAliveRules.renewsAfterStop(stopReason)) return
        if (!ledger.live(SystemClock.elapsedRealtime())) return
        enqueue(context, ExistingWorkPolicy.REPLACE)
    }

    private fun enqueue(context: Context, policy: ExistingWorkPolicy) {
        try {
            WorkManager.getInstance(context)
                .enqueueUniqueWork(KeepAliveRules.WORK_NAME, policy, request())
        } catch (e: Exception) {
            // No job: the analysis runs on, as every analysis did before.
        }
    }

    /// The keep-alive job: one time, expedited where that needs no
    /// foreground service. From Android 9 it needs a network, any that
    /// reaches the internet, validated or not (KeepAliveRules
    /// .usesNetworkRequest): JobInfo's NETWORK_TYPE_ANY without
    /// NET_CAPABILITY_VALIDATED. An unvalidated network can still carry
    /// the request (a phone in mainland China with no VPN fails Android's
    /// probe on every network), and a validated-only constraint kept the
    /// job from starting there, or stopped it partway as the network lost
    /// its validation; with a constraint, JobScheduler lets an expedited
    /// job's process use the network. Below Android 9 the job is plain and
    /// needs no network: there a constraint waited for a validated one, and
    /// gave the job nothing.
    private fun request(): OneTimeWorkRequest {
        val constraints = if (KeepAliveRules.usesNetworkRequest(Build.VERSION.SDK_INT)) {
            Constraints.Builder().setRequiredNetworkRequest(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                    .build(),
                NetworkType.CONNECTED,
            ).build()
        } else {
            Constraints.NONE
        }
        val builder = OneTimeWorkRequest.Builder(AnalysisKeepAliveWorker::class.java)
            .setConstraints(constraints)
        if (KeepAliveRules.expedited(Build.VERSION.SDK_INT)) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        return builder.build()
    }
}

/// The keep-alive job's worker (AnalysisKeepAlive): it waits while an
/// analysis is live in this process (2 minutes 45 seconds at most, then a
/// follow-up job if one still is), then succeeds, never retried. Stopped
/// by the system mid-wait (Android 12 and later), it hands the stop to
/// AnalysisKeepAlive.renewAfterStop, which may put a fresh job in its
/// place. No foreground info: it is expedited only on Android 12 and
/// later, where WorkManager never asks for it. R8 keeps it
/// (proguard-rules.pro: WorkManager builds workers by their class name).
class AnalysisKeepAliveWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        try {
            AnalysisKeepAlive.runJob(applicationContext)
        } catch (e: CancellationException) {
            // Stopped: by the app (nothing live, or a newer burst replaced
            // the job), or by the system, whose stop reason is known from
            // Android 12, where the job is expedited.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                AnalysisKeepAlive.renewAfterStop(applicationContext, stopReason)
            }
            throw e
        }
        return Result.success()
    }
}
