package dev.calorietracker.calorie_tracker

import android.content.Intent
import android.os.Build
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Locale
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

    // --- Back at the root: Android 14+ moves the task to the back only
    // after starts from the home screen (the start that created the
    // activity on Android 14 and the first release of Android 15, the
    // latest start into its task on Android 15 QPR1 and later and Android
    // 16) and finishes any other root; unless the home screen made both,
    // Flutter keeps its back callback (MainActivity.setFrameworkHandlesBack).

    private val launcher = setOf("android.intent.category.LAUNCHER")
    private val home = "com.google.android.apps.nexuslauncher"

    @Test
    fun theLaunchersOwnIntentIsRecognised() {
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
    fun theCallerIsTheOneAndroidRecorded() {
        assertEquals("android-app", IntakeRules.REFERRER_SCHEME)
        // The home screen's tap (NEW_TASK | RESET_TASK_IF_NEEDED), and adb.
        assertEquals(home, IntakeRules.callerPackage("android-app", home, claimed = false, flags = 0x10200000))
        assertEquals("com.android.shell", IntakeRules.callerPackage("android-app", "com.android.shell", false, 0))
        // A referrer the sender wrote itself (EXTRA_REFERRER, on the start's
        // intent or the activity's), which getReferrer() reports in place
        // of Android's record.
        assertNull(IntakeRules.callerPackage("android-app", home, claimed = true, flags = 0))
        // A task restored from Recents is started under the caller that
        // first started it, not the one starting it now.
        assertEquals(0x00100000, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertNull(
            IntakeRules.callerPackage("android-app", home, false, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY or 0x10200000),
        )
        // No referrer, or none of Android's form.
        assertNull(IntakeRules.callerPackage(null, null, false, 0))
        assertNull(IntakeRules.callerPackage("https", home, false, 0))
        assertNull(IntakeRules.callerPackage("android-app", null, false, 0))
        assertNull(IntakeRules.callerPackage("android-app", "", false, 0))
    }

    @Test
    fun onlyTheLauncherIntentFromTheDefaultHomeAppIsAHomeStart() {
        assertTrue(IntakeRules.homeStart(launcherIntent = true, referrerPackage = home, homePackage = home))
        // The same intent from anyone else: `am start`, Play's Open button,
        // the package installer's, the app itself.
        for (sender in listOf(
            "com.android.shell",
            "com.android.vending",
            "com.google.android.packageinstaller",
            "com.android.packageinstaller",
            "dev.calorietracker.calorie_tracker",
            "com.example.otherhome",
        )) {
            assertFalse(sender, IntakeRules.homeStart(true, sender, home))
        }
        // A share, the setup link, a notification tap: never the launcher's
        // intent, whoever sends it.
        assertFalse(IntakeRules.homeStart(launcherIntent = false, referrerPackage = home, homePackage = home))
        // No known caller.
        assertFalse(IntakeRules.homeStart(true, null, home))
        // No known home app: nothing resolved, or the system's chooser
        // (several home apps, no default), a caller in "android" included.
        assertFalse(IntakeRules.homeStart(true, home, null))
        assertFalse(IntakeRules.homeStart(true, null, null))
        assertFalse(IntakeRules.homeStart(true, "android", "android"))
    }

    @Test
    fun androidMovesTheTaskBackOnlyAfterHomeStartsFirstAndLatest() {
        // Created from the home screen, nothing since.
        val tapped = HomeStarts.restore(first = null, latest = null) { true }
        assertEquals(HomeStarts(first = true, latest = true), tapped)
        assertTrue(tapped.systemMovesTaskBack)
        // Then a share, a notification tap, the setup link or Play's Open
        // button into the running activity, which Android 15 QPR1 and later
        // judge.
        val shared = tapped.after(home = false, covered = false)
        assertEquals(HomeStarts(first = true, latest = false), shared)
        assertFalse(shared.systemMovesTaskBack)
        // The home icon again: both rules move the task back.
        assertTrue(shared.after(home = true, covered = false).systemMovesTaskBack)
        // Created by `am start`, Play's Open button or the installer's,
        // which Android 14 and the first Android 15 judge for good.
        val opened = HomeStarts.restore(null, null) { false }
        assertFalse(opened.systemMovesTaskBack)
        assertFalse(opened.after(home = true, covered = false).systemMovesTaskBack)
        // A home start while another activity of the task covered this one
        // (a picker, the share sheet): Android gave it to that activity,
        // which the start closed, so here it counts as none.
        assertEquals(HomeStarts(true, false), tapped.after(home = true, covered = true))
        assertFalse(shared.after(home = true, covered = true).systemMovesTaskBack)
        // The app opened another activity in its task (a picker), or the
        // window shell started the task in split screen: a latest start
        // that was not the home screen's, until the next home start.
        val picked = tapped.afterOtherStart()
        assertEquals(HomeStarts(first = true, latest = false), picked)
        assertFalse(picked.systemMovesTaskBack)
        assertTrue(picked.after(home = true, covered = false).systemMovesTaskBack)
        // It never makes one, and the first stays.
        assertEquals(HomeStarts(false, false), opened.afterOtherStart())
        assertEquals(HomeStarts(false, false), HomeStarts(false, true).afterOtherStart())
        assertEquals(picked, picked.afterOtherStart())
    }

    @Test
    fun theHomeStartsOutliveARelaunch() {
        // A relaunch in the same process (Bold text, theme colours) gets the
        // intent the last instance set, which tells nothing of the starts
        // before: the saved state keeps both answers, and the intent is not
        // asked.
        assertEquals(HomeStarts(true, false), HomeStarts.restore(first = true, latest = false) { error("asked") })
        assertEquals(HomeStarts(false, true), HomeStarts.restore(false, true) { error("asked") })
        // Nothing saved (the first create): the creating start decides both.
        assertEquals(HomeStarts(true, true), HomeStarts.restore(null, null) { true })
        assertEquals(HomeStarts(false, false), HomeStarts.restore(null, null) { false })
        // Half a state, which nothing writes: as if none.
        assertEquals(HomeStarts(false, false), HomeStarts.restore(true, null) { false })
        assertEquals(HomeStarts(false, false), HomeStarts.restore(null, true) { false })
    }

    @Test
    fun flutterKeepsBackAtTheRootFromAndroid14UnlessAndroidMovesTheTaskBack() {
        assertEquals(34, Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        for (sdk in listOf(34, 35, 36, 37)) {
            assertTrue(IntakeRules.keepsBackCallbackAtRoot(sdk, systemMovesTaskBack = false))
            // The home screen made the first and the latest start: Android
            // moves the task to the back, with its back-to-home preview.
            assertFalse(IntakeRules.keepsBackCallbackAtRoot(sdk, systemMovesTaskBack = true))
        }
        // Android 13 moves every root of a launcher activity to the back;
        // Android 12 and lower deliver Back through onBackPressed.
        for (sdk in listOf(24, 30, 32, 33)) {
            assertFalse(IntakeRules.keepsBackCallbackAtRoot(sdk, systemMovesTaskBack = false))
            assertFalse(IntakeRules.keepsBackCallbackAtRoot(sdk, systemMovesTaskBack = true))
        }
    }

    /// What happens to MainActivity's task, in order.
    private enum class Kind {
        /// A start Android delivers to MainActivity: the one that creates
        /// it, or a later one through onNewIntent. MainActivity is
        /// singleTask, so a later one closes an activity the app opened
        /// above it (clear-top).
        START,

        /// The app opens another activity in its task above MainActivity
        /// (the photo picker, a permission dialog, the share sheet): a start
        /// from the app's own process, with no intent for MainActivity,
        /// which pauses below it.
        OPEN,

        /// That activity closes (a pick, a cancel): MainActivity resumes.
        CLOSE,

        /// A return from Recents: a start of the task by the app that shows
        /// Recents, with no intent.
        RECENTS,

        /// The window shell starts the task into split screen: a start of
        /// it from Recents by SystemUI, with no intent; MainActivity comes
        /// up in multi-window mode (then full screen again).
        SPLIT,
    }

    /// One event: for a start, whether its intent is the launcher's, and the
    /// package Android records as its caller.
    private data class Event(
        val name: String,
        val kind: Kind,
        val launcherIntent: Boolean = false,
        val caller: String = "",
    )

    private val app = "dev.calorietracker.calorie_tracker"
    private val icon = Event("home icon", Kind.START, true, home)
    private val adb = Event("am start -a MAIN -c LAUNCHER", Kind.START, true, "com.android.shell")
    private val play = Event("Play's Open button", Kind.START, true, "com.android.vending")
    private val installer = Event("the installer's Open button", Kind.START, true, "com.google.android.packageinstaller")
    private val share = Event("a shared photo", Kind.START, false, "com.google.android.apps.photos")
    private val setupLink = Event("the setup link", Kind.START, false, "com.google.android.GoogleCamera")
    private val notification = Event("a notification tap", Kind.START, false, app)
    private val picker = Event("the photo picker", Kind.OPEN, caller = app)
    private val close = Event("the picker closes", Kind.CLOSE)
    private val recents = Event("the Recents card", Kind.RECENTS, caller = home)
    private val split = Event("split screen from Recents", Kind.SPLIT, caller = "com.android.systemui")

    /// With a third-party home app as the default, Recents is still the
    /// system launcher's, which is then not the home app: the one start
    /// MainActivity cannot tell (setFrameworkHandlesBack).
    private val recentsOfAnotherApp = Event("the Recents card, a third-party home app", Kind.RECENTS, caller = "com.android.launcher3")

    private val events = listOf(
        icon, adb, play, installer, share, setupLink, notification,
        picker, close, recents, split, recentsOfAnotherApp,
    )

    /// Whether [history] can happen: the app opens an activity only from
    /// MainActivity on top, and only an open one closes.
    private fun possible(history: List<Event>): Boolean {
        var covered = false
        for (event in history.drop(1)) {
            when (event.kind) {
                Kind.START -> covered = false
                Kind.OPEN -> if (covered) return false else covered = true
                Kind.CLOSE -> if (covered) covered = false else return false
                Kind.RECENTS, Kind.SPLIT -> Unit
            }
        }
        return true
    }

    /// [history] with MainActivity back at its root: an activity the app
    /// left open closes first.
    private fun atRoot(history: List<Event>): List<Event> {
        var covered = false
        for (event in history) {
            when (event.kind) {
                Kind.START, Kind.CLOSE -> covered = false
                Kind.OPEN -> covered = true
                Kind.RECENTS, Kind.SPLIT -> Unit
            }
        }
        return if (covered) history + close else history
    }

    /// MainActivity's answers after [history], whose first event is the
    /// start that created it, as MainActivity notes the events: a start in
    /// onNewIntent (noteStart), an activity the app opened as MainActivity
    /// pauses below it (onPause), split screen as it comes up in
    /// multi-window mode (onResume, onMultiWindowModeChanged). A return
    /// from Recents tells it nothing.
    private fun answers(history: List<Event>): HomeStarts {
        fun isHome(start: Event) = IntakeRules.homeStart(
            start.launcherIntent,
            IntakeRules.callerPackage(IntakeRules.REFERRER_SCHEME, start.caller, false, 0),
            home,
        )
        var answers = HomeStarts.restore(null, null) { isHome(history.first()) }
        var covered = false
        for (event in history.drop(1)) {
            when (event.kind) {
                Kind.START -> {
                    answers = answers.after(isHome(event), covered)
                    covered = false
                }
                Kind.OPEN -> {
                    covered = true
                    answers = answers.afterOtherStart()
                }
                Kind.CLOSE -> covered = false
                Kind.RECENTS -> Unit
                Kind.SPLIT -> answers = answers.afterOtherStart()
            }
        }
        return answers
    }

    /// Whether Android moves the task to the back on a Back at an idle root
    /// after [history] (ActivityClientController.shouldMoveTaskToBack): the
    /// intent that created the activity is the launcher's, and its launch
    /// source is the home screen's. [latestRule]: Android 15 QPR1 and later
    /// and Android 16, where each start into the task
    /// (ActivityStarter.startActivityInner) and each start of it from
    /// Recents (ActivityTaskSupervisor.startActivityFromRecents) gives the
    /// task's top activity the start's own launch source, the app's own
    /// start of the picker included. Otherwise Android 14 and the first
    /// release of Android 15, where the activity keeps the creating start's.
    private fun androidMovesTaskBack(latestRule: Boolean, history: List<Event>): Boolean {
        val created = history.first()
        var source = created.caller
        if (latestRule) {
            var covered = false
            for (event in history.drop(1)) {
                when (event.kind) {
                    // An open activity takes the start, which closes it.
                    Kind.START -> if (covered) covered = false else source = event.caller
                    // MainActivity is the task's top as the picker starts.
                    Kind.OPEN -> {
                        source = event.caller
                        covered = true
                    }
                    Kind.CLOSE -> covered = false
                    Kind.RECENTS, Kind.SPLIT -> if (!covered) source = event.caller
                }
            }
        }
        return created.launcherIntent && source == home
    }

    /// The rules Android [sdk] can run (androidMovesTaskBack): Android 15
    /// (API 35) runs the first-start rule in its first release and the
    /// latest-start rule from QPR1 on.
    private fun rulesOf(sdk: Int): List<Boolean> = when {
        sdk >= 36 -> listOf(true)
        sdk == 35 -> listOf(false, true)
        else -> listOf(false)
    }

    @Test
    fun backIsLeftToAndroidOnlyWhereAndroid14To16MoveTheTaskBack() {
        // Every possible history of up to four events after the start that
        // created the activity, then a Back at its idle root.
        var histories = events.filter { it.kind == Kind.START }.map { listOf(it) }
        val all = histories.toMutableList()
        repeat(4) {
            histories = histories.flatMap { h -> events.map { h + it } }.filter { possible(it) }
            all += histories
        }
        var leftToAndroid = 0
        for (history in all.map { atRoot(it) }) {
            val answers = answers(history)
            for (sdk in 34..36) {
                if (IntakeRules.keepsBackCallbackAtRoot(sdk, answers.systemMovesTaskBack)) continue
                leftToAndroid++
                for (latestRule in rulesOf(sdk)) {
                    if (androidMovesTaskBack(latestRule, history)) continue
                    // Android finishes the activity: only ever after the one
                    // start the app cannot tell.
                    assertTrue(
                        "Android $sdk (latest rule: $latestRule) would finish after ${history.map { it.name }}",
                        recentsOfAnotherApp in history,
                    )
                }
            }
        }
        assertTrue(leftToAndroid > 0)
    }

    @Test
    fun theOneStartLeftUnseenIsAReturnFromRecentsShownByAnotherApp() {
        // With a third-party home app as the default, a return from Recents
        // after a home start leaves Back to Android, and Android 15 QPR1 and
        // later finish the activity; a pending shared photo or an analysis
        // in flight keeps that Back in Flutter (SharedPhotosBackGuard).
        val history = listOf(icon, recentsOfAnotherApp)
        for (sdk in 34..36) {
            assertFalse(IntakeRules.keepsBackCallbackAtRoot(sdk, answers(history).systemMovesTaskBack))
        }
        assertFalse(androidMovesTaskBack(latestRule = true, history))
        assertTrue(androidMovesTaskBack(latestRule = false, history))
    }

    @Test
    fun theMeasuredRunsKeepBackWhereAndroidFinished() {
        // RC-171-verify.md's rows: whether Flutter keeps Back at the root
        // (and moves the task to the back itself) on Android 15 and 16.
        fun keeps(sdk: Int, vararg history: Event) =
            IntakeRules.keepsBackCallbackAtRoot(sdk, answers(history.toList()).systemMovesTaskBack)
        for (sdk in listOf(35, 36)) {
            // A: started from the home screen. Android moves it back, with
            // its preview.
            assertFalse(keeps(sdk, icon))
            // B: then `am start` into it (Play's Open button alike), which
            // Android 16 finished.
            assertTrue(keeps(sdk, icon, adb))
            assertTrue(keeps(sdk, icon, play))
            // D, E: the home icon after that. Android moves it back.
            assertFalse(keeps(sdk, icon, icon))
            assertFalse(keeps(sdk, icon, adb, icon))
            // F: created by `am start`, then the home icon, which the first
            // Android 15 finished.
            assertTrue(keeps(sdk, adb, icon))
            assertTrue(keeps(sdk, installer, icon))
            // G: one photo shared into it, which Android 16 finished; a
            // notification tap or the setup link alike.
            assertTrue(keeps(sdk, icon, share))
            assertTrue(keeps(sdk, icon, notification))
            assertTrue(keeps(sdk, icon, setupLink))
        }
    }

    @Test
    fun anActivityTheAppOpensOrSplitScreenKeepsBackUntilTheNextHomeStart() {
        fun keeps(sdk: Int, vararg history: Event) =
            IntakeRules.keepsBackCallbackAtRoot(sdk, answers(history.toList()).systemMovesTaskBack)
        // Review of #82, F1: the photo picker, then a pick or a cancel.
        // Android 15 QPR1 and later then finish the activity on an idle
        // root Back.
        assertFalse(androidMovesTaskBack(latestRule = true, listOf(icon, picker, close)))
        // F2: split screen from Recents, then full screen again.
        assertFalse(androidMovesTaskBack(latestRule = true, listOf(icon, split)))
        for (sdk in 34..36) {
            assertTrue(keeps(sdk, icon, picker, close))
            // A start that found the picker open goes to it: still none from
            // the home screen.
            assertTrue(keeps(sdk, icon, picker, icon))
            // The home icon once the picker closed: Android moves it back.
            assertFalse(keeps(sdk, icon, picker, close, icon))
            assertTrue(keeps(sdk, icon, split))
            assertFalse(keeps(sdk, icon, split, icon))
            // A return from Recents with the default home app tells the app
            // nothing: Android moves the task back after it, and the app
            // keeps what it knew, the picker's start included.
            assertFalse(keeps(sdk, icon, recents))
            assertTrue(keeps(sdk, icon, picker, close, recents))
        }
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

    // --- Flutter's engine flags come from the launch intent in a debug or
    // profile build only. A release build takes none, the software-rendering
    // one the engine reads itself included, or any app that starts
    // MainActivity could pick the renderer; `flutter run --release` loses
    // its engine options with them (EXTRAS-1, EXTRAS-1 review).

    @Test
    fun onlyDebugAndProfileBuildsTakeEngineFlagsFromTheLaunchIntent() {
        assertFalse(IntakeRules.takesEngineFlagsFromIntent(releaseBuild = true))
        assertTrue(IntakeRules.takesEngineFlagsFromIntent(releaseBuild = false))
    }

    // --- The app's own language on Android 13 and later
    // (MainActivity.setAppLanguage): one of the app's languages
    // (res/xml/locales_config.xml) or none, nothing else.

    @Test
    fun theAppSetsOnlyItsOwnLanguagesOrNone() {
        assertEquals(setOf("en", "zh"), IntakeRules.APP_LANGUAGES)
        assertEquals("en", IntakeRules.appLanguageTags("en"))
        assertEquals("zh", IntakeRules.appLanguageTags("zh"))
        // None: the app follows the system's language again.
        assertEquals("", IntakeRules.appLanguageTags(""))
        for (tags in listOf(null, "fr", "EN", " en", "en,zh", "zh-Hant", "zh-CN", "und", "system")) {
            assertNull(tags, IntakeRules.appLanguageTags(tags))
        }
    }

    // --- The language goes to Android with the region of the phone's own
    // locale in it (MainActivity.setAppLanguage): a bare "en" became the
    // app's main locale, and English times went 12-hour on a phone whose
    // own language is 24-hour (review of PR 79, F1).

    @Test
    fun theAppsLanguageKeepsThePhonesRegion() {
        assertEquals("en-GB", IntakeRules.appLanguageTag("en", "en-GB"))
        assertEquals("zh-Hans-CN", IntakeRules.appLanguageTag("zh", "zh-Hans-CN,en-US"))
        // The first in the language, wherever it is in the phone's list.
        assertEquals("en-US", IntakeRules.appLanguageTag("en", "zh-Hans-CN,en-US,en-GB"))
        assertEquals("zh-CN", IntakeRules.appLanguageTag("zh", "en-US,zh-CN"))
        assertEquals("zh-Hans-SG", IntakeRules.appLanguageTag("zh", "zh-Hans-SG"))
        assertEquals("zh-Hans-HK", IntakeRules.appLanguageTag("zh", "zh-Hans-HK"))
        // Language, script and region only: Android 14's regional
        // preferences (Unicode extensions) stay the phone's.
        assertEquals("en-GB", IntakeRules.appLanguageTag("en", "en-GB-u-mu-celsius-fw-mon"))
        // The app's Chinese is Simplified: Traditional Chinese never counts,
        // with its script or by its region.
        assertEquals("zh", IntakeRules.appLanguageTag("zh", "zh-Hant-TW,en-US"))
        assertEquals("zh", IntakeRules.appLanguageTag("zh", "zh-TW"))
        assertEquals("zh", IntakeRules.appLanguageTag("zh", "zh-HK,zh-MO"))
        assertEquals("zh-CN", IntakeRules.appLanguageTag("zh", "zh-Hant-HK,zh-CN"))
        // None in the language: the bare tag.
        assertEquals("en", IntakeRules.appLanguageTag("en", "de-DE"))
        assertEquals("en", IntakeRules.appLanguageTag("en", ""))
        assertEquals("zh", IntakeRules.appLanguageTag("zh", "en-US"))
        // Follow system clears the app's language, whatever the phone's.
        assertEquals("", IntakeRules.appLanguageTag("", "en-GB"))
    }

    // --- The phone's own 12/24-hour clock (MainActivity.phone), which the
    // FlutterView no longer reports once the app has a language of its own.

    @Test
    fun thePhonesOwnClockIsItsSwitchElseItsFirstLanguages() {
        // 'Use 24-hour format' set: that, whatever the language.
        assertEquals(true, IntakeRules.usesTwentyFourHourClock("24", "h:mm:ss a z"))
        assertEquals(false, IntakeRules.usesTwentyFourHourClock("12", "HH:mm:ss z"))
        assertEquals(true, IntakeRules.usesTwentyFourHourClock("24", null))
        // 'Use locale default': the first language's long time format.
        assertEquals(true, IntakeRules.usesTwentyFourHourClock(null, "HH:mm:ss z"))
        assertEquals(true, IntakeRules.usesTwentyFourHourClock(null, "z HH:mm:ss"))
        assertEquals(true, IntakeRules.usesTwentyFourHourClock(null, "H:mm:ss z"))
        assertEquals(false, IntakeRules.usesTwentyFourHourClock(null, "h:mm:ss a z"))
        assertEquals(false, IntakeRules.usesTwentyFourHourClock(null, "z ah:mm:ss"))
        assertEquals(false, IntakeRules.usesTwentyFourHourClock(null, "Bh:mm:ss [z]"))
        // Quoted text is no hour (DateFormat.hasDesignator).
        assertEquals(false, IntakeRules.usesTwentyFourHourClock(null, "h 'H' mm a"))
        assertEquals(true, IntakeRules.usesTwentyFourHourClock(null, "'h' HH:mm"))
        assertNull(IntakeRules.usesTwentyFourHourClock(null, null))
        // The patterns themselves, from the locale data (the JDK's here,
        // ICU's on the phone): British English is 24-hour, bare English
        // 12-hour, as on the phone.
        assertEquals(true, IntakeRules.usesTwentyFourHourClock(null, IntakeRules.longTimePattern(Locale.UK)))
        assertEquals(true, IntakeRules.usesTwentyFourHourClock(null, IntakeRules.longTimePattern(Locale.GERMANY)))
        assertEquals(false, IntakeRules.usesTwentyFourHourClock(null, IntakeRules.longTimePattern(Locale.ENGLISH)))
        assertEquals(false, IntakeRules.usesTwentyFourHourClock(null, IntakeRules.longTimePattern(Locale.US)))
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

    // --- A shared item that gives no copy goes on as a refused item, so
    // share intake can say it was skipped and why.

    @Test
    fun aVideoIsRefusedAsAVideoAndAnyOtherTypeAsAFileType() {
        assertEquals(IntakeRules.ShareRefusal.VIDEO, IntakeRules.typeRefusal("video/mp4"))
        assertEquals(IntakeRules.ShareRefusal.VIDEO, IntakeRules.typeRefusal("video/*"))
        for (type in listOf("application/pdf", "text/plain", "*/*", "audio/mpeg", "", null)) {
            assertEquals(type, IntakeRules.ShareRefusal.FILE_TYPE, IntakeRules.typeRefusal(type))
        }
    }

    @Test
    fun aRefusedItemsPathNamesNoFileAndEndsInItsReason() {
        assertEquals("/chopstats-refused/video", IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.VIDEO))
        assertEquals("/chopstats-refused/file_type", IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.FILE_TYPE))
        assertEquals("/chopstats-refused/too_big", IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.TOO_BIG))
        assertEquals("/chopstats-refused/unreadable", IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.UNREADABLE))
        val paths = IntakeRules.ShareRefusal.values().map { IntakeRules.refusedSharePath(it) }
        assertEquals("one path per reason", paths.size, paths.toSet().size)
        for (path in paths) {
            // A folder at the root no app can write in: never a copy, and
            // never in the share folder (MainActivity.SHARE_FOLDER).
            assertTrue(path, path.startsWith(IntakeRules.REFUSED_SHARE_PATH + "/"))
            assertFalse(path, File(path).exists())
            assertFalse(path, path.contains("shared_photos"))
        }
        // No image type: the plugin reports such an item as a file, and
        // share intake reads nothing at its path.
        assertEquals("application/x-chopstats-refused", IntakeRules.REFUSED_SHARE_TYPE)
        assertFalse(IntakeRules.REFUSED_SHARE_TYPE.startsWith("image"))
        assertFalse(IntakeRules.REFUSED_SHARE_TYPE.startsWith("video"))
        assertFalse(IntakeRules.REFUSED_SHARE_TYPE.startsWith("text"))
    }

    // --- An item refused for its type carries its name's extension, so
    // share intake can name an image format Android has no type for: a CR3
    // in a share of several was called a kind of file (device QA
    // 2026-11-22, PR81-QA-3).

    private val fileType = IntakeRules.ShareRefusal.FILE_TYPE

    @Test
    fun anItemRefusedForItsTypeCarriesItsNamesExtension() {
        // The six RAW formats Android's MIME table does not know.
        assertEquals("/chopstats-refused/file_type/cr3", IntakeRules.refusedSharePath(fileType, "IMG_0001.CR3"))
        assertEquals("/chopstats-refused/file_type/3fr", IntakeRules.refusedSharePath(fileType, "B0000001.3FR"))
        assertEquals("/chopstats-refused/file_type/rwl", IntakeRules.refusedSharePath(fileType, "L1000001.rwl"))
        assertEquals("/chopstats-refused/file_type/sr2", IntakeRules.refusedSharePath(fileType, "DSC00001.SR2"))
        assertEquals("/chopstats-refused/file_type/srf", IntakeRules.refusedSharePath(fileType, "DSC00001.srf"))
        assertEquals("/chopstats-refused/file_type/x3f", IntakeRules.refusedSharePath(fileType, "SDIM0001.X3F"))
        // Any other: share intake names only an image format it does not
        // read, so a PDF stays a kind of file there.
        assertEquals("/chopstats-refused/file_type/pdf", IntakeRules.refusedSharePath(fileType, "menu.pdf"))
        assertEquals("/chopstats-refused/file_type/txt", IntakeRules.refusedSharePath(fileType, "notes.TXT"))
        // The part after the last dot, whatever comes before it.
        assertEquals("/chopstats-refused/file_type/avif", IntakeRules.refusedSharePath(fileType, "a.b.AVIF"))
        assertEquals("/chopstats-refused/file_type/cr3", IntakeRules.refusedSharePath(fileType, ".cr3"))
        // Lower-cased as the root locale does it, whatever the phone's.
        val phone = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertEquals("/chopstats-refused/file_type/ico", IntakeRules.refusedSharePath(fileType, "FAVICON.ICO"))
        } finally {
            Locale.setDefault(phone)
        }
        // Still a path no file has, outside the share folder.
        val path = IntakeRules.refusedSharePath(fileType, "IMG_0001.CR3")
        assertTrue(path, path.startsWith(IntakeRules.REFUSED_SHARE_PATH + "/"))
        assertFalse(path, File(path).exists())
        assertFalse(path, path.contains("shared_photos"))
    }

    @Test
    fun nothingElseOfTheNameTravels() {
        // No extension, or a part after the last dot that is no short run
        // of letters a-z and digits: the reason alone, as before.
        for (name in listOf(
            null, "", "IMG_1731500000000", "IMG.", ".", "Dinner with J.Smith", "Lunch with.Sarah",
            "photo.jpeg2000", "a.cr 3", "a.c-3", "a.c_3", "a.cr3 ", "a.étc",
            // The Kelvin sign lower-cases to a plain k, and full-width
            // letters are no a-z: both are left out before lower-casing.
            "a.K", "a.ＣＲ３",
        )) {
            assertEquals("$name", "/chopstats-refused/file_type", IntakeRules.refusedSharePath(fileType, name))
            assertNull("$name", IntakeRules.refusedExtension(name))
        }
        // At most MAX_REFUSED_EXTENSION, the longest image format share
        // intake names ('avif').
        assertEquals(4, IntakeRules.MAX_REFUSED_EXTENSION)
        assertEquals("abcd", IntakeRules.refusedExtension("x.ABCD"))
        assertNull(IntakeRules.refusedExtension("x.abcde"))
        // A video carries none: its line says it is a video. (A refusal
        // for its size or a failed copy carries one too since PR81-QA-4:
        // the next tests.)
        assertEquals(
            "/chopstats-refused/video",
            IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.VIDEO, "IMG_0001.CR3"),
        )
        assertEquals("/chopstats-refused/file_type", IntakeRules.refusedSharePath(fileType))
    }

    // --- An item over the share cap, or whose copy failed, carries its
    // name's extension too, so share intake can name an image format it
    // does not read: a RAW file over 25 MB shared alone was said to be
    // over 25 MB, although no smaller one would be read (device QA
    // 2026-11-23, PR81-QA-4).

    private val tooBig = IntakeRules.ShareRefusal.TOO_BIG
    private val unreadable = IntakeRules.ShareRefusal.UNREADABLE

    @Test
    fun anItemOverTheCapOrUnreadableCarriesItsNamesExtension() {
        assertEquals("/chopstats-refused/too_big/cr3", IntakeRules.refusedSharePath(tooBig, "IMG_0001.CR3"))
        assertEquals("/chopstats-refused/too_big/dng", IntakeRules.refusedSharePath(tooBig, "PXL_20261123.RAW-01.dng"))
        assertEquals("/chopstats-refused/too_big/nef", IntakeRules.refusedSharePath(tooBig, "DSC_0001.NEF"))
        assertEquals("/chopstats-refused/unreadable/cr3", IntakeRules.refusedSharePath(unreadable, "IMG_0001.CR3"))
        assertEquals("/chopstats-refused/unreadable/arw", IntakeRules.refusedSharePath(unreadable, "DSC00001.ARW"))
        // Any other: share intake names only an image format it does not
        // read, so a JPEG over 25 MB is still over 25 MB there.
        assertEquals("/chopstats-refused/too_big/jpg", IntakeRules.refusedSharePath(tooBig, "IMG_0001.JPG"))
        assertEquals("/chopstats-refused/unreadable/jpg", IntakeRules.refusedSharePath(unreadable, "IMG_0001.jpg"))
        // Lower-cased as the root locale does it, whatever the phone's.
        val phone = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertEquals("/chopstats-refused/too_big/ico", IntakeRules.refusedSharePath(tooBig, "FAVICON.ICO"))
            assertEquals("/chopstats-refused/unreadable/ico", IntakeRules.refusedSharePath(unreadable, "FAVICON.ICO"))
        } finally {
            Locale.setDefault(phone)
        }
        // Still paths no file has, outside the share folder.
        for (path in listOf(
            IntakeRules.refusedSharePath(tooBig, "IMG_0001.CR3"),
            IntakeRules.refusedSharePath(unreadable, "IMG_0001.CR3"),
        )) {
            assertTrue(path, path.startsWith(IntakeRules.REFUSED_SHARE_PATH + "/"))
            assertFalse(path, File(path).exists())
            assertFalse(path, path.contains("shared_photos"))
        }
    }

    @Test
    fun everyRefusalButAVideosCarriesTheSameExtensionAndNothingElse() {
        for (name in listOf(
            "IMG_0001.CR3", "B0000001.3FR", "a.b.AVIF", ".cr3", "notes.TXT", "x.ABCD",
            null, "", "IMG_1731500000000", "IMG.", ".", "Dinner with J.Smith", "Lunch with.Sarah",
            "photo.jpeg2000", "a.cr 3", "a.c-3", "a.c_3", "a.cr3 ", "a.étc", "a.K", "a.ＣＲ３", "x.abcde",
        )) {
            // Exactly refusedExtension's output, or the reason alone.
            val ext = IntakeRules.refusedExtension(name)
            for (refusal in listOf(fileType, tooBig, unreadable)) {
                val reason = "/chopstats-refused/${refusal.token}"
                assertEquals(
                    "${refusal.name} $name",
                    if (ext == null) reason else "$reason/$ext",
                    IntakeRules.refusedSharePath(refusal, name),
                )
            }
            assertEquals(
                "$name",
                "/chopstats-refused/video",
                IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.VIDEO, name),
            )
        }
        // Without a name (no stream, or no name for it): the reason alone.
        for (refusal in IntakeRules.ShareRefusal.values()) {
            assertEquals("/chopstats-refused/${refusal.token}", IntakeRules.refusedSharePath(refusal))
        }
    }

    // --- A shared image whose name has no extension Android knows is
    // copied under the one its type gives, so share intake reads it.

    /// A few of the extensions MimeTypeMap knows, as copyName asks them.
    private val known = setOf("jpg", "jpeg", "png", "heic", "dng", "txt", "pdf", "mp4")

    private fun copyName(name: String, ext: String? = "jpg", asked: MutableList<String>? = null): String =
        IntakeRules.copyName(name, { known.contains(it) }) {
            asked?.add(name)
            ext
        }

    @Test
    fun aNameWithNoExtensionGetsTheOneItsTypeGives() {
        assertEquals("IMG_1731500000000.jpg", copyName("IMG_1731500000000"))
        assertEquals("Lunch with Sarah.png", copyName("Lunch with Sarah", "png"))
        // A dot in the name that starts no extension Android knows.
        assertEquals("Lunch with.Sarah.jpg", copyName("Lunch with.Sarah"))
        assertEquals("Dinner with J.Smith.jpg", copyName("Dinner with J.Smith"))
        assertEquals("Screenshot 2026-11-21 at 12.30.45.png", copyName("Screenshot 2026-11-21 at 12.30.45", "png"))
        assertEquals("image.jpg_large.jpg", copyName("image.jpg_large"))
        // Nothing after the dot.
        assertEquals("IMG.jpg", copyName("IMG."))
    }

    @Test
    fun aNameWithAKnownExtensionIsKeptAndItsTypeNotAskedFor() {
        val asked = mutableListOf<String>()
        for (name in listOf("IMG_1.jpg", "IMG_1.JPG", "scan.Dng", "PXL_1.heic", "notes.txt", "menu.pdf", ".jpg")) {
            assertEquals(name, copyName(name, "png", asked))
        }
        assertEquals("the type is looked up only for a name without one", emptyList<String>(), asked)
    }

    @Test
    fun aTypeThatGivesNoPlainExtensionLeavesTheNameAsItIs() {
        for (ext in listOf(null, "", "j/pg", "jp g", ".jpg", "jpg\u0000", "\u00e9tc")) {
            assertEquals("$ext", "IMG_1731500000000", copyName("IMG_1731500000000", ext))
        }
    }

    @Test
    fun aNameThatWouldGrowPastTheLongestFileNameIsKept() {
        val fits = "a".repeat(IntakeRules.MAX_NAME_BYTES - 4)
        assertEquals("$fits.jpg", copyName(fits))
        val full = "a".repeat(IntakeRules.MAX_NAME_BYTES - 3)
        assertEquals(full, copyName(full))
        // Counted in bytes: each of these is three.
        val wide = "\u98df".repeat((IntakeRules.MAX_NAME_BYTES - 3) / 3)
        assertEquals(wide, copyName(wide))
        assertEquals(255, IntakeRules.MAX_NAME_BYTES)
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
