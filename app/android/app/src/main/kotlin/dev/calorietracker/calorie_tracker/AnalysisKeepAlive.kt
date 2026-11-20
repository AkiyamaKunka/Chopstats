package dev.calorietracker.calorie_tracker

import android.content.Context
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
/// on Android 12 and later, plain below (KeepAliveRules.expedited), with a
/// network constraint and no notification. A running job keeps the process
/// out of the cached state, so it is not frozen, and an expedited job
/// keeps its network. Its worker only waits: it returns once nothing is
/// live, and the job is cancelled as the last request ends, so it never
/// keeps the process up after that. One job runs 2 minutes 45 seconds at
/// most (KeepAliveRules.JOB_CAP_MS, below the 3 minutes past which Android
/// counts an expedited job as timed out); a request still live then gets a
/// follow-up job. An engine that dies takes its requests with it (drop,
/// from MainActivity.cleanUpFlutterEngine). Nothing is persisted: a job
/// WorkManager re-runs in a new process finds nothing live there and ends
/// at once.
internal object AnalysisKeepAlive {
    private val ledger = KeepAliveLedger()
    private val sessions = AtomicLong()

    /// A session for a Flutter engine MainActivity configures: its
    /// requests are told apart from another engine's by it.
    fun newSession(): Long = sessions.incrementAndGet()

    /// Request [id] of [session] began: recorded, and the job enqueued
    /// unless one is pending or running already (ExistingWorkPolicy.KEEP).
    /// A WorkManager that cannot be reached leaves the request as it was
    /// before, without the job.
    fun begin(context: Context, session: Long, id: Long): Boolean {
        val added = ledger.begin(session, id, SystemClock.elapsedRealtime())
        try {
            WorkManager.getInstance(context)
                .enqueueUniqueWork(KeepAliveRules.WORK_NAME, ExistingWorkPolicy.KEEP, request())
        } catch (e: Exception) {
            // No job: the analysis runs on, as every analysis did before.
        }
        return added
    }

    /// Request [id] of [session] ended (settled, failed, refused or let
    /// go): the job goes once nothing is live (settle).
    fun end(context: Context, session: Long, id: Long): Boolean {
        val removed = ledger.end(session, id)
        if (removed) settle(context)
        return removed
    }

    /// [session]'s engine is gone, and every request it had with it.
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
        try {
            WorkManager.getInstance(context).enqueueUniqueWork(
                KeepAliveRules.WORK_NAME,
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                request(),
            )
        } catch (e: Exception) {
            // No follow-up: the request goes on as it did before.
        }
    }

    /// The keep-alive job: one time, needs a network (a request without
    /// one fails on its own; with one, JobScheduler lets the job's process
    /// use it), expedited where that needs no foreground service.
    private fun request(): OneTimeWorkRequest {
        val builder = OneTimeWorkRequest.Builder(AnalysisKeepAliveWorker::class.java)
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
            )
        if (KeepAliveRules.expedited(Build.VERSION.SDK_INT)) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        return builder.build()
    }
}

/// The keep-alive job's worker (AnalysisKeepAlive): it waits while an
/// analysis is live in this process (2 minutes 45 seconds at most, then a
/// follow-up job if one still is), then succeeds, never retried. No
/// foreground info: it is expedited only on Android 12 and later, where
/// WorkManager never asks for it. R8 keeps it (proguard-rules.pro:
/// WorkManager builds workers by their class name).
class AnalysisKeepAliveWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        AnalysisKeepAlive.runJob(applicationContext)
        return Result.success()
    }
}
