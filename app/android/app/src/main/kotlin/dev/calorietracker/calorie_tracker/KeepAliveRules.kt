package dev.calorietracker.calorie_tracker

import android.os.Build
import androidx.work.WorkInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/// The analysis keep-alive's decisions (owner decision 9, option 1,
/// 2026-11-20; AnalysisKeepAlive.kt wires them to WorkManager), kept free
/// of Android objects as IntakeRules is, so the JVM tests
/// (KeepAliveRulesTest, `./gradlew :app:testDebugUnitTest`) run them for
/// real. manifest_gate_test pins the wiring. (Build's version codes and
/// WorkInfo's stop reasons are compile-time constants: no Android class is
/// loaded.)
internal object KeepAliveRules {
    /// How long one analysis may keep the process up, from its begin:
    /// 3 minutes. A direct provider's call gives up after 90 s a try
    /// (provider_analyzers.dart); the user's own server may take longer
    /// (its deadline is 5 minutes, server_analyzer.dart). Past the cap the
    /// request goes on without the job, as every request did before.
    const val CAP_MS = 3L * 60 * 1000

    /// How long one keep-alive job runs at most: 2 minutes 45 seconds.
    /// Android counts an expedited job that runs 3 minutes or longer as
    /// timed out, however it ends (JobSchedulerService.maybeProcessBuggyJob,
    /// RUNTIME_MIN_EJ_GUARANTEE_MS), and more than 10 timeouts in a day put
    /// the app in the restricted standby bucket, where the photo scan and
    /// the summary's alarm wait for days. A request still live when a job
    /// reaches this gets a follow-up job (AnalysisKeepAlive.runJob), until
    /// its own cap.
    const val JOB_CAP_MS = 165L * 1000

    /// WorkManager's unique name for the one keep-alive job.
    const val WORK_NAME = "chopstats.analysis_keep_alive"

    /// Whether the job is expedited on Android [sdk]: from Android 12
    /// (API 31), where WorkManager hands expedited work to JobScheduler as
    /// an expedited job (no notification; out of quota it runs as a plain
    /// job, OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST). Below
    /// that WorkManager runs expedited work as a foreground service with a
    /// notification, through its SystemForegroundService and the
    /// FOREGROUND_SERVICE permission, both stripped from the manifest, and
    /// the worker's foreground info, which the keep-alive worker does not
    /// give: there the job is a plain one-time job.
    fun expedited(sdk: Int): Boolean = sdk >= Build.VERSION_CODES.S

    /// Whether the job asks for its network as a NetworkRequest on Android
    /// [sdk] (AnalysisKeepAlive.request): from Android 9 (API 28), where
    /// WorkManager hands one to JobScheduler (JobInfo.setRequiredNetwork)
    /// and tracks it in-process itself. The request is JobInfo's
    /// NETWORK_TYPE_ANY without NET_CAPABILITY_VALIDATED: a network can
    /// carry the app's requests and still fail Android's validation probe
    /// (a phone in mainland China with no VPN, whose probes go to Google;
    /// a network that blocks the probe hosts; partial connectivity), and
    /// NetworkType.CONNECTED, which asks for a validated one, never let the
    /// job start there, or stopped it as the network lost its validation.
    /// The constraint itself stays: JobScheduler gives an expedited job its
    /// network bypass (BIND_BYPASS_POWER_NETWORK_RESTRICTIONS) only with
    /// one. Below Android 9 the job is plain, with no bypass to keep, and
    /// CONNECTED would wait for a validated network as well (JobScheduler
    /// and WorkManager's tracker, API 26 and 27): no network constraint
    /// there, so the job runs on any network or none.
    fun usesNetworkRequest(sdk: Int): Boolean = sdk >= Build.VERSION_CODES.P

    /// Whether a request that begins replaces the keep-alive job
    /// (ExistingWorkPolicy.REPLACE) instead of keeping the one WorkManager
    /// has (KEEP): when nothing was live before it ([liveBefore] false),
    /// the first request of a burst, and so the first one in any process.
    /// A job left from before then serves nothing: one finishing as its
    /// requests ended, or one WorkManager runs again after the system
    /// stopped it or its process died mid-run (a swipe from Recents). Such
    /// a re-run is never expedited (runAttemptCount above 0) and waits out
    /// its backoff (30 s from its enqueue, longer on later attempts), and
    /// KEEP adopted it: the new request had no expedited job, and no
    /// running one for up to 30 s. REPLACE puts a fresh, expedited job in
    /// its place. A request that joins a live one keeps the job that runs
    /// for it.
    fun replacesJob(liveBefore: Boolean): Boolean = !liveBefore

    /// Whether a keep-alive job the system stopped mid-run with
    /// [stopReason] (WorkInfo.STOP_REASON_*, Android 12 and later) is
    /// renewed while a request is still live (AnalysisKeepAlive
    /// .renewAfterStop): WorkManager runs a stopped job again as a plain
    /// job, never expedited, and not before its backoff from its enqueue
    /// has passed, so the request was held by a weaker job, or by nothing,
    /// in between. A fresh job (REPLACE) is expedited again, with no
    /// backoff.
    /// Renewed after the stops a fresh job can outlast: preempted, the
    /// device's state, the network gone for a moment (the fresh job waits
    /// for it), out of quota (the fresh job then runs as a plain one), the
    /// standby bucket, the system's own processing. Never after the app's
    /// own cancel (its requests ended, or a newer burst replaced the job),
    /// a user's stop, a background restriction the user set, or a timeout,
    /// which a second job would repeat (more than 10 in a day restrict the
    /// app); nor for a reason this list does not know.
    fun renewsAfterStop(stopReason: Int): Boolean = when (stopReason) {
        WorkInfo.STOP_REASON_PREEMPT,
        WorkInfo.STOP_REASON_DEVICE_STATE,
        WorkInfo.STOP_REASON_CONSTRAINT_CONNECTIVITY,
        WorkInfo.STOP_REASON_QUOTA,
        WorkInfo.STOP_REASON_APP_STANDBY,
        WorkInfo.STOP_REASON_SYSTEM_PROCESSING -> true
        else -> false
    }
}

/// The analyses in flight in this process: each by its engine's session
/// (one per Flutter engine MainActivity configured) and the request id
/// Dart gave it (never reused within that engine), with the time it
/// began. In memory only: a new process starts with none, so a keep-alive
/// job that outlived its process (WorkManager re-runs one its process
/// died in, after a backoff) finds nothing to wait for and ends at once,
/// and the first request that process begins replaces it with a fresh job
/// instead of adopting it (KeepAliveRules.replacesJob). Thread-safe: the
/// method channel calls on the main thread, the worker reads on its own.
internal class KeepAliveLedger(private val capMs: Long = KeepAliveRules.CAP_MS) {
    private val begun = HashMap<Pair<Long, Long>, Long>()

    /// Moves on with every change, so a waiting worker wakes ([awaitIdle]).
    private val version = MutableStateFlow(0L)

    /// Records request [id] of [session] as begun at [nowMs] (on the clock
    /// [msLeft] is asked on). False when it is open already: a repeated
    /// begin changes nothing.
    fun begin(session: Long, id: Long, nowMs: Long): Boolean = synchronized(begun) {
        val added = begun.putIfAbsent(session to id, nowMs) == null
        if (added) version.value += 1
        added
    }

    /// Ends request [id] of [session]. False when it is not open: ended
    /// already, never begun (its begin failed), or its engine was dropped.
    /// Such an end changes nothing, so it can never end another request.
    fun end(session: Long, id: Long): Boolean = synchronized(begun) {
        val removed = begun.remove(session to id) != null
        if (removed) version.value += 1
        removed
    }

    /// Ends every request of [session], whose engine is gone: its Dart
    /// will never end them (Back finished the activity, a swipe from
    /// Recents). How many there were.
    fun drop(session: Long): Int = synchronized(begun) {
        val gone = begun.keys.filter { it.first == session }
        gone.forEach { begun.remove(it) }
        if (gone.isNotEmpty()) version.value += 1
        gone.size
    }

    /// How much longer the keep-alive must last at [nowMs]: until the
    /// youngest open request reaches the cap. 0 when nothing is live:
    /// every request ended, or began [capMs] or more ago.
    fun msLeft(nowMs: Long): Long = synchronized(begun) {
        begun.values.maxOfOrNull { (it + capMs - nowMs).coerceIn(0L, capMs) } ?: 0L
    }

    /// Whether a request is live at [nowMs] ([msLeft] above 0).
    fun live(nowMs: Long): Boolean = msLeft(nowMs) > 0L

    /// Requests begun and not ended, live or past the cap.
    fun open(): Int = synchronized(begun) { begun.size }

    /// Returns once nothing is live ([msLeft] is 0 on [now], the clock the
    /// begins were recorded on): at once when nothing is, else as the last
    /// live request ends or the youngest one reaches the cap. Woken by
    /// every begin, end and drop, so a request begun meanwhile keeps it
    /// waiting, up to that request's own cap.
    suspend fun awaitIdle(now: () -> Long) {
        while (true) {
            val seen = version.value
            val left = msLeft(now())
            if (left <= 0L) return
            withTimeoutOrNull(left) { version.first { it != seen } }
        }
    }

    /// One job's wait: [awaitIdle], for [jobCapMs] at most. True when a
    /// request is still live as it ends, so the job wants a follow-up.
    suspend fun awaitIdleOrCap(jobCapMs: Long, now: () -> Long): Boolean {
        withTimeoutOrNull(jobCapMs) { awaitIdle(now) }
        return live(now())
    }
}
