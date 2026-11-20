package dev.calorietracker.calorie_tracker

import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// The analysis keep-alive's decisions on the JVM (KeepAliveRules.kt).
/// Run with `./gradlew :app:testDebugUnitTest` from app/android;
/// mobile-build.yml runs it on every pull request.
class KeepAliveRulesTest {
    // --- Expedited only where WorkManager needs no foreground service.

    @Test
    fun expeditedFromAndroid12() {
        assertEquals(31, Build.VERSION_CODES.S)
        assertFalse(KeepAliveRules.expedited(24))
        assertFalse(KeepAliveRules.expedited(30))
        assertTrue(KeepAliveRules.expedited(31))
        assertTrue(KeepAliveRules.expedited(36))
    }

    @Test
    fun theCapIsThreeMinutes() {
        assertEquals(180_000L, KeepAliveRules.CAP_MS)
    }

    @Test
    fun aJobEndsWellBeforeAndroidCountsItAsTimedOut() {
        // JobSchedulerService.maybeProcessBuggyJob counts an expedited job
        // of RUNTIME_MIN_EJ_GUARANTEE_MS (3 minutes) or more as timed out,
        // however it ends.
        assertEquals(165_000L, KeepAliveRules.JOB_CAP_MS)
        assertTrue(KeepAliveRules.JOB_CAP_MS <= 180_000L - 15_000L)
        assertTrue(KeepAliveRules.JOB_CAP_MS < KeepAliveRules.CAP_MS)
    }

    // --- Begin and end, balanced on every path.

    @Test
    fun aRequestIsLiveFromItsBeginToItsEnd() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        assertFalse(ledger.live(0))
        assertTrue(ledger.begin(session = 1, id = 1, nowMs = 0))
        assertTrue(ledger.live(10))
        assertEquals(1, ledger.open())
        assertTrue(ledger.end(session = 1, id = 1))
        assertFalse(ledger.live(10))
        assertEquals(0L, ledger.msLeft(10))
        assertEquals(0, ledger.open())
    }

    @Test
    fun aRepeatedBeginIsOneRequest() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        assertTrue(ledger.begin(1, 7, 0))
        assertFalse(ledger.begin(1, 7, 500))
        assertEquals(1, ledger.open())
        assertEquals("keeps the first begin's time", 0L, ledger.msLeft(1_000))
        assertTrue(ledger.end(1, 7))
        assertFalse(ledger.live(0))
    }

    @Test
    fun aStrayEndChangesNothing() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        ledger.begin(1, 1, 0)
        // Never begun (its begin failed), or ended already: no other
        // request is ever ended in its place.
        assertFalse(ledger.end(1, 2))
        assertTrue(ledger.end(1, 1))
        assertFalse(ledger.end(1, 1))
        ledger.begin(1, 3, 0)
        assertFalse(ledger.end(2, 3))
        assertEquals(1, ledger.open())
        assertTrue(ledger.live(0))
    }

    @Test
    fun theSameIdInAnotherEngineIsAnotherRequest() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        assertTrue(ledger.begin(1, 1, 0))
        assertTrue(ledger.begin(2, 1, 0))
        assertTrue(ledger.end(1, 1))
        assertTrue("engine 2's request is still in flight", ledger.live(0))
        assertTrue(ledger.end(2, 1))
        assertFalse(ledger.live(0))
    }

    @Test
    fun anEngineThatDiesTakesItsRequestsWithIt() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        ledger.begin(1, 1, 0)
        ledger.begin(1, 2, 0)
        ledger.begin(2, 1, 0)
        assertEquals(2, ledger.drop(1))
        assertEquals(1, ledger.open())
        assertTrue(ledger.live(0))
        assertEquals(0, ledger.drop(1))
        assertFalse("its Dart can no longer end them", ledger.end(1, 2))
        assertEquals(1, ledger.drop(2))
        assertFalse(ledger.live(0))
    }

    // --- The cap: each request keeps the process up for 3 minutes at most.

    @Test
    fun theYoungestRequestSetsHowLongItLasts() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        ledger.begin(1, 1, 0)
        assertEquals(1_000L, ledger.msLeft(0))
        assertEquals(400L, ledger.msLeft(600))
        ledger.begin(1, 2, 600)
        assertEquals(1_000L, ledger.msLeft(600))
        assertEquals(500L, ledger.msLeft(1_100))
        ledger.end(1, 2)
        assertEquals("only the older one is left, past its cap", 0L, ledger.msLeft(1_100))
    }

    @Test
    fun aRequestPastTheCapIsOpenButNotLive() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        ledger.begin(1, 1, 0)
        assertTrue(ledger.live(999))
        assertFalse(ledger.live(1_000))
        assertEquals("open until Dart ends it", 1, ledger.open())
        // A new request after it keeps the process up again, for its own
        // cap.
        ledger.begin(1, 2, 5_000)
        assertEquals(1_000L, ledger.msLeft(5_000))
        assertTrue(ledger.end(1, 1))
        assertTrue(ledger.end(1, 2))
        assertEquals(0, ledger.open())
    }

    @Test
    fun aClockBehindABeginNeverStretchesTheCap() {
        val ledger = KeepAliveLedger(capMs = 1_000)
        ledger.begin(1, 1, 5_000)
        assertEquals(1_000L, ledger.msLeft(0))
    }

    // --- The worker's wait.

    private val clock = { System.nanoTime() / 1_000_000 }

    @Test
    fun theWaitEndsAtOnceWhenNothingIsLive() = runBlocking {
        val ledger = KeepAliveLedger(capMs = 60_000)
        withTimeout(1_000) { ledger.awaitIdle(clock) }
        ledger.begin(1, 1, clock() - 60_000)
        withTimeout(1_000) { ledger.awaitIdle(clock) }
    }

    @Test
    fun theWaitEndsAsTheLastRequestEnds() = runBlocking {
        val ledger = KeepAliveLedger(capMs = 60_000)
        ledger.begin(1, 1, clock())
        ledger.begin(1, 2, clock())
        val wait = async(Dispatchers.Default) { ledger.awaitIdle(clock) }
        delay(100)
        assertFalse(wait.isCompleted)
        ledger.end(1, 1)
        delay(100)
        assertFalse("request 2 is still in flight", wait.isCompleted)
        ledger.end(1, 2)
        withTimeout(1_000) { wait.await() }
    }

    @Test
    fun theWaitEndsWhenItsEngineDies() = runBlocking {
        val ledger = KeepAliveLedger(capMs = 60_000)
        ledger.begin(4, 1, clock())
        val wait = async(Dispatchers.Default) { ledger.awaitIdle(clock) }
        delay(100)
        assertFalse(wait.isCompleted)
        ledger.drop(4)
        withTimeout(1_000) { wait.await() }
    }

    @Test
    fun theWaitEndsAtTheCapWhenARequestNeverEnds() = runBlocking {
        val ledger = KeepAliveLedger(capMs = 300)
        val start = clock()
        ledger.begin(1, 1, start)
        withTimeout(5_000) { ledger.awaitIdle(clock) }
        val waited = clock() - start
        assertTrue("waited $waited ms", waited >= 250)
        assertEquals(1, ledger.open())
    }

    @Test
    fun aJobStopsAtItsCapAndAsksForAFollowUpWhileARequestIsLive() = runBlocking {
        val ledger = KeepAliveLedger(capMs = 60_000)
        val start = clock()
        ledger.begin(1, 1, start)
        val stillLive = withTimeout(5_000) { ledger.awaitIdleOrCap(300, clock) }
        assertTrue("the request is still in flight: a follow-up job", stillLive)
        assertTrue(clock() - start >= 250)
        assertEquals(1, ledger.open())
    }

    @Test
    fun aJobThatSeesTheLastRequestEndAsksForNoFollowUp() = runBlocking {
        val ledger = KeepAliveLedger(capMs = 60_000)
        ledger.begin(1, 1, clock())
        val job = async(Dispatchers.Default) { ledger.awaitIdleOrCap(60_000, clock) }
        delay(100)
        ledger.end(1, 1)
        assertFalse(withTimeout(1_000) { job.await() })
        // Nor one for a request past its own cap.
        val stale = KeepAliveLedger(capMs = 200)
        stale.begin(1, 1, clock())
        assertFalse(withTimeout(5_000) { stale.awaitIdleOrCap(60_000, clock) })
        assertEquals(1, stale.open())
    }

    @Test
    fun aRequestBegunDuringTheWaitKeepsItWaiting() = runBlocking {
        val ledger = KeepAliveLedger(capMs = 60_000)
        ledger.begin(1, 1, clock())
        val wait = async(Dispatchers.Default) { ledger.awaitIdle(clock) }
        delay(50)
        ledger.begin(1, 2, clock())
        ledger.end(1, 1)
        delay(100)
        assertFalse(wait.isCompleted)
        ledger.end(1, 2)
        withTimeout(1_000) { wait.await() }
    }
}
