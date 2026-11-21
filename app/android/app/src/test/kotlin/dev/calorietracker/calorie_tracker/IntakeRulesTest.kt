package dev.calorietracker.calorie_tracker

import android.content.Intent
import android.os.Build
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/// MainActivity's decisions on the JVM (IntakeRules.kt). Run with
/// `./gradlew :app:testDebugUnitTest` from app/android; mobile-build.yml
/// runs it on every pull request.
class IntakeRulesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    // --- A launch intent seen before reaches no plugin (share replay).

    @Test
    fun aRecreatedActivityIsARedelivery() {
        assertTrue(IntakeRules.isRedelivery(hasSavedState = true, flags = 0))
    }

    @Test
    fun aLaunchFromRecentsIsARedelivery() {
        assertEquals(0x00100000, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertTrue(IntakeRules.isRedelivery(false, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY))
        assertTrue(IntakeRules.isRedelivery(false, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY or 0x10000000))
    }

    @Test
    fun aFreshLaunchIsNot() {
        assertFalse(IntakeRules.isRedelivery(false, 0))
        // FLAG_ACTIVITY_NEW_TASK | FLAG_GRANT_READ_URI_PERMISSION: a share.
        assertFalse(IntakeRules.isRedelivery(false, 0x10000000 or 0x00000001))
    }

    // --- Back at the root: Android 14+ moves only a task the launcher's
    // own intent created to the back, and finishes any other; those keep
    // Flutter's back callback (MainActivity.setFrameworkHandlesBack).

    private val launcher = setOf("android.intent.category.LAUNCHER")

    @Test
    fun theLauncherIntentIsALauncherTask() {
        assertEquals("android.intent.action.MAIN", Intent.ACTION_MAIN)
        assertEquals("android.intent.category.LAUNCHER", Intent.CATEGORY_LAUNCHER)
        assertTrue(IntakeRules.isLauncherIntent(Intent.ACTION_MAIN, launcher, hasData = false, type = null))
    }

    @Test
    fun anyOtherIntentIsNot() {
        // A share, a several-photo share, the bitewise://setup link.
        assertFalse(IntakeRules.isLauncherIntent(Intent.ACTION_SEND, null, false, "image/jpeg"))
        assertFalse(IntakeRules.isLauncherIntent(Intent.ACTION_SEND_MULTIPLE, null, false, "image/*"))
        assertFalse(
            IntakeRules.isLauncherIntent(
                Intent.ACTION_VIEW,
                setOf("android.intent.category.BROWSABLE", "android.intent.category.DEFAULT"),
                hasData = true,
                type = null,
            ),
        )
        // A notification tap (flutter_local_notifications' launch intent
        // with its own action).
        assertFalse(IntakeRules.isLauncherIntent("SELECT_NOTIFICATION", launcher, false, null))
        // MAIN, but not exactly the launcher's (ActivityRecord.isMainIntent).
        assertFalse(IntakeRules.isLauncherIntent(Intent.ACTION_MAIN, null, false, null))
        assertFalse(IntakeRules.isLauncherIntent(Intent.ACTION_MAIN, emptySet(), false, null))
        assertFalse(
            IntakeRules.isLauncherIntent(
                Intent.ACTION_MAIN,
                launcher + "android.intent.category.DEFAULT",
                false,
                null,
            ),
        )
        assertFalse(IntakeRules.isLauncherIntent(Intent.ACTION_MAIN, launcher, hasData = true, type = null))
        assertFalse(IntakeRules.isLauncherIntent(Intent.ACTION_MAIN, launcher, false, "image/jpeg"))
        // What the replay rewrite leaves (emptyShare): no action at all.
        assertFalse(IntakeRules.isLauncherIntent(null, launcher, false, null))
        assertFalse(IntakeRules.isLauncherIntent(null, null, false, null))
    }

    @Test
    fun flutterKeepsBackAtTheRootOfAnyOtherTaskFromAndroid14() {
        assertEquals(34, android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        for (sdk in listOf(34, 35, 36, 37)) {
            assertTrue(IntakeRules.keepsBackCallbackAtRoot(sdk, launcherTask = false))
            // A task the launcher started: Android moves it to the back,
            // with its back-to-home preview.
            assertFalse(IntakeRules.keepsBackCallbackAtRoot(sdk, launcherTask = true))
        }
        // Android 13 moves every root of a launcher activity to the back;
        // Android 12 and lower deliver Back through onBackPressed.
        for (sdk in listOf(24, 30, 32, 33)) {
            assertFalse(IntakeRules.keepsBackCallbackAtRoot(sdk, launcherTask = false))
            assertFalse(IntakeRules.keepsBackCallbackAtRoot(sdk, launcherTask = true))
        }
    }

    @Test
    fun theLauncherTaskDecisionOutlivesARelaunch() {
        // A relaunch in the same process (Bold text, theme colours) gets the
        // intent the last instance set: the replay rewrite's has no action.
        // The saved state keeps the first create's answer.
        val emptied = IntakeRules.isLauncherIntent(null, launcher, false, null)
        assertFalse(emptied)
        assertTrue(IntakeRules.launcherTask(saved = true, fromIntent = emptied))
        assertFalse(
            IntakeRules.keepsBackCallbackAtRoot(
                34,
                IntakeRules.launcherTask(saved = true, fromIntent = emptied),
            ),
        )
        // A task a share created stays one, whatever intent it has now.
        val launcherNow = IntakeRules.isLauncherIntent(Intent.ACTION_MAIN, launcher, false, null)
        assertTrue(launcherNow)
        assertFalse(IntakeRules.launcherTask(saved = false, fromIntent = launcherNow))
        // Nothing saved (the first create): the intent decides.
        assertTrue(IntakeRules.launcherTask(saved = null, fromIntent = true))
        assertFalse(IntakeRules.launcherTask(saved = null, fromIntent = false))
    }

    // --- The navigation bar's colour: the app sets it from Android 15,
    // where Flutter no longer does and Android forced dark buttons on a
    // window that started light (A36-1).

    @Test
    fun theAppColorsTheNavigationBarFromAndroid15() {
        assertEquals(35, Build.VERSION_CODES.VANILLA_ICE_CREAM)
        for (sdk in listOf(24, 29, 33, 34)) {
            assertFalse(IntakeRules.colorsNavigationBar(sdk))
        }
        for (sdk in listOf(35, 36, 37)) {
            assertTrue(IntakeRules.colorsNavigationBar(sdk))
        }
    }

    // --- A share that comes before share intake listens waits for it
    // (ShareHold): the plugin tells only a listener, and Android delivers
    // the share a stopped app was started again for before Dart runs.

    @Test
    fun sharesBeforeShareIntakeListensAreHeldThenHandedOverOnceInOrder() {
        val hold = ShareHold<String>()
        assertFalse(hold.pass("first"))
        assertFalse(hold.pass("second"))
        assertEquals(listOf("first", "second"), hold.ready())
        // From then on a share goes at once, and none is handed over twice.
        assertTrue(hold.pass("third"))
        assertEquals(emptyList<String>(), hold.ready())
        assertTrue(hold.pass("fourth"))
    }

    @Test
    fun aShareHoldWithNothingHeldHandsOverNothing() {
        val hold = ShareHold<String>()
        assertEquals(emptyList<String>(), hold.ready())
        assertTrue(hold.pass("later"))
        assertEquals(emptyList<String>(), hold.ready())
    }

    // --- The app's own share-out files are no meal.

    @Test
    fun shareOutFilesAreRecognisedByAuthority() {
        val pkg = "dev.calorietracker.calorie_tracker"
        assertTrue(IntakeRules.isOwnShareOut("content", "$pkg.flutter.share_provider", pkg))
        assertTrue(IntakeRules.isOwnShareOut("CONTENT", "$pkg.FLUTTER.share_provider", pkg))
        // Any other provider, or any other scheme, is a share like any other.
        assertFalse(IntakeRules.isOwnShareOut("content", "media", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", "com.google.android.apps.photos.contentprovider", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", "other.app.flutter.share_provider", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", null, pkg))
        assertFalse(IntakeRules.isOwnShareOut("file", "$pkg.flutter.share_provider", pkg))
        assertFalse(IntakeRules.isOwnShareOut(null, "$pkg.flutter.share_provider", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", "content", pkg))
    }

    // --- Only a regular file in the cache is ever saved out.

    private fun layout(): Triple<File, File, File> {
        val data = tmp.newFolder("data")
        val cache = File(data, "cache").apply { mkdirs() }
        val db = File(data, "databases/calorie_tracker.db").apply {
            parentFile!!.mkdirs()
            writeText("meals")
        }
        return Triple(data, cache, db)
    }

    @Test
    fun aFileInTheCacheIsSaved() {
        val (_, cache, _) = layout()
        val export = File(cache, "chopstats-2026-11-13.json").apply { writeText("{}") }
        assertEquals(export.canonicalFile, IntakeRules.regularFileIn(cache, export.path))
        val nested = File(cache, "a/b.json").apply {
            parentFile!!.mkdirs()
            writeText("{}")
        }
        assertEquals(nested.canonicalFile, IntakeRules.regularFileIn(cache, nested.path))
    }

    @Test
    fun nothingOutsideTheCacheIsSaved() {
        val (data, cache, db) = layout()
        assertNull(IntakeRules.regularFileIn(cache, db.path))
        assertNull(IntakeRules.regularFileIn(cache, "${cache.path}/../databases/calorie_tracker.db"))
        assertNull(IntakeRules.regularFileIn(cache, "${cache.path}_x/a.json"))
        assertNull(IntakeRules.regularFileIn(cache, cache.path))
        assertNull(IntakeRules.regularFileIn(cache, File(data, "cache").path + "/"))
        assertNull(IntakeRules.regularFileIn(cache, null))
        assertNull(IntakeRules.regularFileIn(cache, ""))
        // A folder or a missing file in the cache is no regular file.
        File(cache, "dir").mkdirs()
        assertNull(IntakeRules.regularFileIn(cache, File(cache, "dir").path))
        assertNull(IntakeRules.regularFileIn(cache, File(cache, "missing.json").path))
    }

    @Test
    fun aLinkInTheCacheToTheDatabaseIsNotSaved() {
        val (_, cache, db) = layout()
        val link = File(cache, "export.json")
        try {
            Files.createSymbolicLink(link.toPath(), db.toPath())
        } catch (e: IOException) {
            return // no symbolic links on this file system
        } catch (e: UnsupportedOperationException) {
            return
        }
        assertNull(IntakeRules.regularFileIn(cache, link.path))
    }

    // --- A file:// pick or share inside the app's own data is refused.

    @Test
    fun appFilesAreRecognisedAfterResolving() {
        val (data, cache, db) = layout()
        assertTrue(IntakeRules.liesIn(data, db.path))
        assertTrue(IntakeRules.liesIn(data, data.path))
        assertTrue(IntakeRules.liesIn(data, "${cache.path}/../databases/calorie_tracker.db"))
        assertTrue(IntakeRules.liesIn(data, null))
        val outside = tmp.newFile("DCIM-photo.jpg")
        assertFalse(IntakeRules.liesIn(data, outside.path))
        assertFalse(IntakeRules.liesIn(data, "${data.path}_other/x.jpg"))
    }

    // --- How many photos one pick returns.

    @Test
    fun theMaximumIsClamped() {
        assertEquals(1, IntakeRules.pickMax(0, null))
        assertEquals(1, IntakeRules.pickMax(-5, 100))
        assertEquals(1, IntakeRules.pickMax(1, 100))
        assertEquals(8, IntakeRules.pickMax(8, 100))
        // The system picker's own limit (its contract refuses more).
        assertEquals(20, IntakeRules.pickMax(50, 20))
        // No system picker: still at most MAX_PICK.
        assertEquals(100, IntakeRules.MAX_PICK)
        assertEquals(100, IntakeRules.pickMax(Int.MAX_VALUE, null))
        assertEquals(100, IntakeRules.pickMax(500, 1000))
        assertEquals(1, IntakeRules.pickMax(5, 0))
    }

    @Test
    fun aFallbackPickerIsCutToTheMaximum() {
        val picked = (1..150).toList()
        assertEquals(listOf(1), IntakeRules.firstPicks(picked, 1))
        assertEquals((1..100).toList(), IntakeRules.firstPicks(picked, 100))
        assertEquals(listOf(1, 2), IntakeRules.firstPicks(listOf(1, 2), 5))
        assertEquals(listOf(1), IntakeRules.firstPicks(picked, 0))
    }

    // --- picked_photos: only what earlier picks left.

    @Test
    fun tidyingKeepsFreshCopiesAndRemovesEmptyAndOldFolders() {
        val root = tmp.newFolder("picked_photos")
        val now = System.currentTimeMillis()
        val fresh = File(root, "fresh").apply { mkdirs() }
        File(fresh, "IMG_1.jpg").writeText("x")
        val empty = File(root, "empty").apply { mkdirs() }
        val old = File(root, "old").apply { mkdirs() }
        val oldCopy = File(old, "IMG_0.jpg").apply { writeText("x") }
        val longAgo = now - IntakeRules.DAY_MS - 60_000
        oldCopy.setLastModified(longAgo)
        old.setLastModified(longAgo)
        IntakeRules.tidyPickFolders(root, now)
        assertTrue(root.isDirectory)
        assertTrue(File(fresh, "IMG_1.jpg").isFile)
        assertFalse(empty.exists())
        assertFalse(old.exists())
        // Nothing to tidy, or no folder at all, is no error.
        IntakeRules.tidyPickFolders(root, now)
        IntakeRules.tidyPickFolders(File(root, "missing"), now)
        assertTrue(File(fresh, "IMG_1.jpg").isFile)
    }

    @Test
    fun startingClearsEveryCopyEarlierPicksLeftButNotTheFolder() {
        val root = tmp.newFolder("picked_photos")
        val now = System.currentTimeMillis()
        // Seconds old: a copy whose engine died before Dart read it, which
        // a later pick's tidy keeps for a day.
        val young = File(root, "young").apply { mkdirs() }
        File(young, "IMG_1.jpg").writeText("x")
        IntakeRules.tidyPickFolders(root, now)
        assertTrue(File(young, "IMG_1.jpg").isFile)
        // A copy cut short, a stray file, an empty folder, a copy dated
        // ahead of the clock: none has a reader once the activity starts.
        File(root, "partial").mkdirs()
        File(root, "partial/IMG_2.jpg").writeText("")
        File(root, "stray.jpg").writeText("x")
        File(root, "empty").mkdirs()
        File(root, "ahead").mkdirs()
        File(root, "ahead/IMG_3.jpg").apply {
            writeText("x")
            setLastModified(now + IntakeRules.DAY_MS)
        }
        IntakeRules.clearPickFolders(root)
        assertTrue(root.isDirectory)
        assertEquals(emptyList<String>(), root.list()!!.toList())
        // Nothing left, or no folder at all, is no error.
        IntakeRules.clearPickFolders(root)
        IntakeRules.clearPickFolders(File(root, "missing"))
        assertTrue(root.isDirectory)
    }

    // --- A create-document result.

    @Test
    fun aSaveResultCopiesCancelsOrDiscards() {
        assertEquals(IntakeRules.SaveStep.COPY, IntakeRules.saveStep(resultOk = true, hasTarget = true, hasSource = true))
        assertEquals(IntakeRules.SaveStep.CANCEL, IntakeRules.saveStep(false, true, true))
        assertEquals(IntakeRules.SaveStep.CANCEL, IntakeRules.saveStep(true, false, true))
        assertEquals(IntakeRules.SaveStep.CANCEL, IntakeRules.saveStep(false, false, false))
        // The document exists but nothing is left to copy into it.
        assertEquals(IntakeRules.SaveStep.DISCARD, IntakeRules.saveStep(true, true, false))
    }

    @Test
    fun aSaveWithNoCallerLeftDeletesItsSourceAndOnlyThen() {
        val (_, cache, db) = layout()
        val export = File(cache, "chopstats-2026-11-19.json").apply { writeText("{}") }
        // A caller waits for the answer: it deletes the export itself.
        assertFalse(IntakeRules.dropSaveSource(cache, export.path, callOpen = true))
        assertTrue(export.isFile)
        // None is left (Android recreated the activity while the
        // create-document screen was up): the native side deletes it.
        assertTrue(IntakeRules.dropSaveSource(cache, export.path, callOpen = false))
        assertFalse(export.exists())
        // Never a file outside the cache, and no source is no error.
        assertFalse(IntakeRules.dropSaveSource(cache, db.path, callOpen = false))
        assertFalse(
            IntakeRules.dropSaveSource(cache, "${cache.path}/../databases/calorie_tracker.db", callOpen = false),
        )
        assertTrue(db.isFile)
        assertFalse(IntakeRules.dropSaveSource(cache, null, callOpen = false))
        assertFalse(IntakeRules.dropSaveSource(cache, export.path, callOpen = false))
    }

    @Test
    fun aSaveCopyHoldsItsSourceOpenAndLeavesItsNameToLaterFiles() {
        val (_, cache, db) = layout()
        val export = File(cache, "chopstats-2026-11-19.json").apply { writeText("first export") }
        val input = IntakeRules.openSaveSource(cache, export.path)!!
        // Out of the cache as soon as the copy has it open, whatever
        // happens to the copy, its call or the app afterwards...
        assertFalse(export.exists())
        // ...and the export the restarted app writes under the same name
        // (one per day) while a slow copy still runs is not this save's:
        // the copy still reads all of its own, and nothing deletes the new
        // one when it ends.
        export.writeText("second export")
        assertEquals("first export", input.use { String(it.readBytes()) })
        assertEquals("second export", export.readText())
        // Never a file outside the cache, and nothing to open is no error.
        assertNull(IntakeRules.openSaveSource(cache, db.path))
        assertNull(IntakeRules.openSaveSource(cache, "${cache.path}/../databases/calorie_tracker.db"))
        assertTrue(db.isFile)
        assertNull(IntakeRules.openSaveSource(cache, null))
        assertNull(IntakeRules.openSaveSource(cache, File(cache, "missing.json").path))
        assertEquals("second export", export.readText())
    }

    @Test
    fun aSaveOpensOnlyTruncatingModes() {
        assertEquals(listOf("wt", "rwt"), IntakeRules.SAVE_MODES)
        val tried = mutableListOf<String>()
        val stream = IntakeRules.firstStream(IntakeRules.SAVE_MODES) { mode ->
            tried.add(mode)
            if (mode == "wt") throw UnsupportedOperationException("no wt") else "stream:$mode"
        }
        assertEquals("stream:rwt", stream)
        assertEquals(listOf("wt", "rwt"), tried)
        assertEquals("stream:wt", IntakeRules.firstStream(IntakeRules.SAVE_MODES) { "stream:$it" })
        // No mode works: no stream (a failed save), and never plain "w".
        tried.clear()
        assertNull(IntakeRules.firstStream<String>(IntakeRules.SAVE_MODES) { tried.add(it); null })
        assertEquals(listOf("wt", "rwt"), tried)
    }

    // --- The notification-settings link.

    @Test
    fun aSettingsPageCountsOnlyWhenItOpened() {
        val opened = mutableListOf<String>()
        assertTrue(IntakeRules.openFirst(listOf("notifications", "app info")) { opened.add(it) })
        assertEquals(listOf("notifications"), opened)
        opened.clear()
        assertTrue(
            IntakeRules.openFirst(listOf("notifications", "app info")) {
                if (it == "notifications") throw IllegalStateException("not on this device")
                opened.add(it)
            },
        )
        assertEquals(listOf("app info"), opened)
        assertFalse(IntakeRules.openFirst(listOf("a", "b")) { throw IllegalStateException() })
        assertFalse(IntakeRules.openFirst(emptyList<String>()) { opened.add(it) })
    }

    // --- One call at a time, answered once.

    @Test
    fun aCallIsAnsweredExactlyOnce() {
        val calls = SingleCall<String>()
        val answers = mutableListOf<String>()
        assertFalse(calls.isOpen)
        val call = calls.open { answers.add(it) }!!
        assertTrue(calls.isOpen)
        assertTrue(calls.answer(call, "cancelled"))
        assertFalse(calls.isOpen)
        // A second answer, by mistake, sends nothing (Result would throw).
        assertFalse(calls.answer(call, "ok"))
        assertEquals(listOf("cancelled"), answers)
    }

    @Test
    fun aSecondCallIsRefusedWhileOneIsOpenAndAcceptedAfter() {
        val calls = SingleCall<String>()
        val first = mutableListOf<String>()
        val second = mutableListOf<String>()
        val a = calls.open { first.add(it) }!!
        assertNull(calls.open { second.add(it) })
        assertTrue(calls.answer(a, "ok"))
        val b = calls.open { second.add(it) }!!
        // The finished call's number cannot answer the new one.
        assertFalse(calls.answer(a, "late"))
        assertTrue(calls.answer(b, "cancelled"))
        assertEquals(listOf("ok"), first)
        assertEquals(listOf("cancelled"), second)
    }

    // --- A save whose call died with its engine: the restarted app hears
    // how it ended, once (LateSaveResult; Android QA Q4).

    @Test
    fun aLateSaveResultIsKeptForOneAsk() {
        val late = LateSaveResult<String>()
        val answers = mutableListOf<String?>()
        late.take { answers.add(it) }
        assertEquals(listOf<String?>(null), answers) // nothing to say
        late.started()
        late.finished("ok")
        late.take { answers.add(it) }
        late.take { answers.add(it) }
        assertEquals(listOf(null, "ok", null), answers)
    }

    @Test
    fun anAskDuringTheCopyIsAnsweredWhenItEnds() {
        val late = LateSaveResult<String>()
        val answers = mutableListOf<String?>()
        late.started()
        late.take { answers.add(it) }
        assertEquals(emptyList<String?>(), answers)
        late.finished("failed")
        assertEquals(listOf<String?>("failed"), answers)
        // Told once: the next ask hears nothing.
        late.take { answers.add(it) }
        assertEquals(listOf("failed", null), answers)
    }

    @Test
    fun aSecondAskWhileOneWaitsTakesItsPlace() {
        val late = LateSaveResult<String>()
        val first = mutableListOf<String?>()
        val second = mutableListOf<String?>()
        late.started()
        late.take { first.add(it) }
        late.take { second.add(it) }
        assertEquals(listOf<String?>(null), first)
        late.finished("ok")
        assertEquals(listOf<String?>(null), first)
        assertEquals(listOf<String?>("ok"), second)
    }

    @Test
    fun aDiscardedSaveWithNoCallIsKeptAsFailed() {
        // No copy ran (its source was gone), so no started(): still said.
        val late = LateSaveResult<String>()
        late.finished("failed")
        val answers = mutableListOf<String?>()
        late.take { answers.add(it) }
        assertEquals(listOf<String?>("failed"), answers)
    }
}
