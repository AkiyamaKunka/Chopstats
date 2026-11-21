package dev.calorietracker.calorie_tracker

import android.content.Intent
import android.os.Build
import java.io.File
import java.io.InputStream

/// MainActivity's decisions, kept free of Android objects so the JVM unit
/// tests (src/test, `./gradlew :app:testDebugUnitTest`, run by
/// .github/workflows/mobile-build.yml) can run them for real. MainActivity
/// only wires them to the platform, and manifest_gate_test pins that
/// wiring. (Intent's flag, action and category and Build's version codes
/// are compile-time constants: no Android class is loaded.)
internal object IntakeRules {
    /// Whether the launch intent was delivered before: the activity is
    /// recreated (saved state: Android stopped its process while it sat in
    /// the background) or relaunched from Recents. Either way it still
    /// carries the intent that first started its task.
    fun isRedelivery(hasSavedState: Boolean, flags: Int): Boolean =
        hasSavedState || (flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0

    /// Whether an intent with [action], [categories], data ([hasData]) and
    /// [type] is exactly the launcher's own: MAIN with the LAUNCHER
    /// category alone, no data and no type (ActivityRecord.isMainIntent).
    fun isLauncherIntent(action: String?, categories: Set<String>?, hasData: Boolean, type: String?): Boolean =
        action == Intent.ACTION_MAIN &&
            categories != null && categories.size == 1 && Intent.CATEGORY_LAUNCHER in categories &&
            !hasData && type == null

    /// Whether the activity's task is a launcher task, decided once per
    /// activity record: what its last instance saved ([saved], null when
    /// nothing was), else what the intent it has now says ([fromIntent],
    /// isLauncherIntent). Android checks the intent the record was created
    /// with, which never changes. An activity recreated after its process
    /// died gets that intent again, but one relaunched in the same process
    /// (theme colours, Bold text, grammatical gender) gets whatever intent
    /// its last instance set: the replay rewrite's, with no action, or a
    /// notification tap's.
    fun launcherTask(saved: Boolean?, fromIntent: Boolean): Boolean = saved ?: fromIntent

    /// Whether Flutter's back callback stays registered at the root route
    /// on Android [sdk], for a task the launcher's own intent created
    /// ([launcherTask]) or any other (MainActivity.setFrameworkHandlesBack).
    /// With enableOnBackInvokedCallback, Flutter hands Back at the root to
    /// Android. Android 14 and later move the task to the back only when
    /// the home screen started it with the launcher intent, and finish any
    /// other root (ActivityClientController.shouldMoveTaskToBack): a task a
    /// share, the setup link or a notification created, its engine with
    /// it. Android 13 moves every task whose root is a launcher activity
    /// to the back (onBackPressedOnTaskRoot), and Android 12 and lower have
    /// no back callback: Back reaches Flutter through onBackPressed. Where
    /// the callback stays, as on Android 12 and lower, Back at the root
    /// goes through Flutter's SystemNavigator.pop to
    /// MainActivity.popSystemNavigator, which moves the task to the back.
    fun keepsBackCallbackAtRoot(sdk: Int, launcherTask: Boolean): Boolean =
        sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && !launcherTask

    /// Whether the app sets the navigation bar's colour itself on Android
    /// [sdk] (MainActivity.colorNavigationBar): from Android 15 (API 35),
    /// where the app draws edge to edge and Flutter's engine leaves the
    /// colour alone. Android then took the window's light background for a
    /// light bar and forced dark buttons until the app set a colour
    /// (APPEARANCE_FORCE_LIGHT_NAVIGATION_BARS), and tints the 3-button
    /// bar's contrast scrim with the colour set. Below that Flutter sets
    /// the colour as before, an opaque bar.
    fun colorsNavigationBar(sdk: Int): Boolean = sdk >= Build.VERSION_CODES.VANILLA_ICE_CREAM

    /// The app's languages, as Android 13 and later list them for it
    /// (res/xml/locales_config.xml): lib/l10n/app_en.arb and app_zh.arb.
    val APP_LANGUAGES = setOf("en", "zh")

    /// What MainActivity sets as the app's own language on Android 13 and
    /// later (setAppLanguage) for [tags] from Dart (app_language_sync.dart):
    /// one of [APP_LANGUAGES], or "" for none, which hands the app back to
    /// the system's language. Null for anything else, which is never set.
    fun appLanguageTags(tags: String?): String? = tags?.takeIf { it.isEmpty() || it in APP_LANGUAGES }

    /// share_plus's FileProvider authority after the package name (its
    /// AndroidManifest.xml: ${applicationId}.flutter.share_provider).
    const val SHARE_OUT_AUTHORITY_SUFFIX = ".flutter.share_provider"

    /// Whether a stream with [scheme] and [authority] is one of the app's
    /// own share-out files (Today's day image, an Export): Chopstats is a
    /// target in its own sharesheet, and such a file is no meal.
    fun isOwnShareOut(scheme: String?, authority: String?, packageName: String): Boolean =
        "content".equals(scheme, ignoreCase = true) &&
            "$packageName$SHARE_OUT_AUTHORITY_SUFFIX".equals(authority, ignoreCase = true)

    /// Whether [path] is [dir] or lies inside it once both are resolved
    /// (symbolic links included). True when that cannot be told: callers
    /// use it to refuse, so an unknown fails closed.
    fun liesIn(dir: File, path: String?): Boolean {
        if (path == null) return true
        return try {
            val target = File(path).canonicalPath
            val own = dir.canonicalPath
            target == own || target.startsWith(own + File.separator)
        } catch (e: Exception) {
            true
        }
    }

    /// The regular file at [path] when its real path (symbolic links
    /// resolved) lies strictly inside [dir]; null for anything else.
    fun regularFileIn(dir: File, path: String?): File? {
        if (path.isNullOrEmpty()) return null
        return try {
            val root = dir.canonicalFile
            val file = File(path).canonicalFile
            if (file.path.startsWith(root.path + File.separator) && file.isFile) file else null
        } catch (e: Exception) {
            null
        }
    }

    /// The most photos one pick returns, whatever the picker allows: each
    /// is copied (up to 25 MB) before the call is answered.
    const val MAX_PICK = 100

    /// [requested] clamped to 1, to MAX_PICK, and to [systemLimit] (the
    /// system picker's own limit, which its contract enforces; null where
    /// there is no system picker).
    fun pickMax(requested: Int, systemLimit: Int?): Int =
        requested.coerceIn(1, minOf(systemLimit ?: MAX_PICK, MAX_PICK).coerceAtLeast(1))

    /// The first [max] of [picked]: the ACTION_OPEN_DOCUMENT fallback
    /// ignores the picker's maximum.
    fun <T> firstPicks(picked: List<T>, max: Int): List<T> = picked.take(max.coerceAtLeast(1))

    const val DAY_MS = 24L * 60 * 60 * 1000

    /// Removes what earlier picks left under [root]: empty folders (Dart
    /// read and deleted their copy), and folders or files untouched for
    /// [maxAgeMs] (a pick whose app was stopped before Dart read it).
    /// Never [root] itself, and never a copy younger than [maxAgeMs].
    fun tidyPickFolders(root: File, nowMs: Long, maxAgeMs: Long = DAY_MS) {
        root.listFiles()?.forEach { entry ->
            try {
                val children = if (entry.isDirectory) entry.listFiles() ?: return@forEach else emptyArray()
                val newest = (children.map { it.lastModified() } + entry.lastModified()).maxOrNull() ?: 0L
                val empty = entry.isDirectory && children.isEmpty()
                if (empty || nowMs - newest > maxAgeMs) entry.deleteRecursively()
            } catch (e: Exception) {
                // The next pick tries again.
            }
        }
    }

    /// Removes everything under [root], whatever its age, never [root]
    /// itself: what picks of an earlier activity left. MainActivity.onCreate
    /// runs it before a pick of its own can open, and a pick's call dies
    /// with the engine that made it (onPhotosPicked copies nothing without
    /// an open call), so a copy still there has no reader: one an app
    /// stopped mid-pick left, partial or whole, used to stay until a pick
    /// at least a day later (tidyPickFolders), or for good.
    fun clearPickFolders(root: File) {
        root.listFiles()?.forEach { entry ->
            try {
                entry.deleteRecursively()
            } catch (e: Exception) {
                // The next start tries again.
            }
        }
    }

    /// What a create-document result leads to: CANCEL when nothing was
    /// created, COPY the checked source into it, DISCARD the new (empty)
    /// document when there is no source to copy (the call that asked for
    /// it is gone and its state with it).
    enum class SaveStep { CANCEL, COPY, DISCARD }

    fun saveStep(resultOk: Boolean, hasTarget: Boolean, hasSource: Boolean): SaveStep = when {
        !resultOk || !hasTarget -> SaveStep.CANCEL
        hasSource -> SaveStep.COPY
        else -> SaveStep.DISCARD
    }

    /// Deletes a cancelled save's source at [path] when no call is left to
    /// answer ([callOpen] false). An open call's Dart caller deletes the
    /// export itself once the call returns; with none (Android recreated
    /// the activity while the create-document screen was up, and the
    /// caller died with its engine) nothing else would, and the export,
    /// the whole food log with every picture, stayed in the cache until
    /// the next export. (A copy deletes its source as it opens it:
    /// openSaveSource.) Only a regular file in [cacheDir] (regularFileIn).
    /// True when one was deleted.
    fun dropSaveSource(cacheDir: File, path: String?, callOpen: Boolean): Boolean {
        if (callOpen) return false
        val file = regularFileIn(cacheDir, path) ?: return false
        return try {
            file.delete()
        } catch (e: Exception) {
            false
        }
    }

    /// Opens a save's source at [path] (only a regular file in [cacheDir],
    /// regularFileIn) for its copy, and deletes it from the cache at once:
    /// the open stream still reads every byte. So no export is left behind
    /// whatever happens to the copy, its call or the app meanwhile, and a
    /// file written later under the same name is never this save's to
    /// delete: deleting by name once a copy was done could take the export
    /// the restarted app wrote under that name (one per day) while a slow
    /// copy still ran. Null when there is nothing to open.
    fun openSaveSource(cacheDir: File, path: String?): InputStream? {
        val file = regularFileIn(cacheDir, path) ?: return null
        val input = try {
            file.inputStream()
        } catch (e: Exception) {
            return null
        }
        try {
            file.delete()
        } catch (e: Exception) {
            // Left for the Dart caller, or the next export's sweep.
        }
        return input
    }

    /// The modes a save opens its new document with, in order. Both
    /// truncate; plain "w" may leave a longer file's old bytes at the end
    /// on some providers, so it is never tried: no stream is a failed save.
    val SAVE_MODES = listOf("wt", "rwt")

    /// The first stream [open] gives for one of [modes]; a mode that
    /// throws or gives null is skipped. Null when none does.
    fun <T : Any> firstStream(modes: List<String>, open: (String) -> T?): T? {
        for (mode in modes) {
            try {
                open(mode)?.let { return it }
            } catch (e: Exception) {
                // The next mode.
            }
        }
        return null
    }

    /// Opens the first of [pages] that [open] accepts (it throws for one
    /// the device lacks). False when none was opened.
    fun <T> openFirst(pages: List<T>, open: (T) -> Unit): Boolean {
        for (page in pages) {
            try {
                open(page)
                return true
            } catch (e: Exception) {
                // Not on this device: the next page.
            }
        }
        return false
    }
}

/// One method call at a time, answered exactly once: MethodChannel.Result
/// throws on a second answer, and a call never answered leaves its Dart
/// caller waiting for good (and, here, every later call busy). [open]
/// numbers each call; only the open call's number can answer it, once.
/// Main thread only.
internal class SingleCall<V> {
    private var pending: ((V) -> Unit)? = null
    private var current = 0L

    val isOpen: Boolean get() = pending != null

    /// Opens a call that [reply] answers; null, opening nothing, while
    /// another call is open.
    fun open(reply: (V) -> Unit): Long? {
        if (pending != null) return null
        pending = reply
        current += 1
        return current
    }

    /// Answers call [call] with [value] and closes it. False, sending
    /// nothing, when [call] is not the open call (already answered, or
    /// never opened).
    fun answer(call: Long, value: V): Boolean {
        val reply = pending ?: return false
        if (call != current) return false
        pending = null
        reply(value)
        return true
    }
}

/// The result of a save no call is left to hear: Android recreated the
/// activity while the create-document screen was up, so the saveFile call
/// died with its engine, and the copy still runs (onSaveTargetPicked).
/// The restarted app asks once ("takeSaveResult") and says "Export saved."
/// or that the save failed; it said nothing before (Android QA Q4). An ask
/// that comes while the copy still runs is answered when it ends. Main
/// thread only.
internal class LateSaveResult<V : Any> {
    private var copying = false
    private var kept: V? = null
    private var waiting: ((V?) -> Unit)? = null

    /// A copy that no call will hear about has started.
    fun started() {
        copying = true
        kept = null
    }

    /// That copy ended with [value]: to the ask waiting for it, or kept for
    /// the next ask.
    fun finished(value: V) {
        copying = false
        val reply = waiting
        if (reply == null) {
            kept = value
            return
        }
        waiting = null
        reply(value)
    }

    /// The app asks: [reply] gets the kept result, once, or the running
    /// copy's when it ends, or null when there is none. An ask that comes
    /// while another waits takes its place, and the first gets null.
    fun take(reply: (V?) -> Unit) {
        val value = kept
        if (value != null) {
            kept = null
            reply(value)
            return
        }
        if (!copying) {
            reply(null)
            return
        }
        waiting?.invoke(null)
        waiting = reply
    }
}

/// The shares onNewIntent gets before share intake (Dart) listens for
/// them. receive_sharing_intent tells only a listener and keeps nothing
/// for later, and Android hands a share to a stopped app's recreated
/// activity in the launch that recreates it, before its Dart has run: such
/// a share waits here until Dart says it listens ("shareIntakeReady"),
/// then goes to the plugin once. An activity that goes before then (a
/// swipe from Recents during the cold start; a Back Android answers by
/// finishing it, which Android 14 and later still do in a task the
/// launcher intent started from somewhere other than the home screen:
/// MainActivity.setFrameworkHandlesBack) takes what it holds with it;
/// those copies stay in shared_photos, where share intake's sweep takes
/// them (share_intake.dart, strandedRecheck). Main thread only.
internal class ShareHold<T> {
    private val held = ArrayList<T>()
    private var listening = false

    /// Whether [share] goes to the plugins now; false: it is held until
    /// [ready].
    fun pass(share: T): Boolean {
        if (listening) return true
        held.add(share)
        return false
    }

    /// Share intake listens from now on: the shares held so far, in the
    /// order they came, each handed out once. Later ones pass at once.
    fun ready(): List<T> {
        listening = true
        val out = ArrayList(held)
        held.clear()
        return out
    }
}
