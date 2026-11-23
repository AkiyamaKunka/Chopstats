package dev.calorietracker.calorie_tracker

import android.content.Intent
import android.os.Build
import java.io.File
import java.io.InputStream
import java.util.Locale

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

    /// The scheme of the referrer Activity.getReferrer() builds from the
    /// caller Android recorded: android-app://<package>.
    const val REFERRER_SCHEME = "android-app"

    /// The package Android recorded as the caller of a start, from
    /// Activity.getReferrer() ([scheme] and [host] of
    /// android-app://<package>), or null when it is not known: no referrer,
    /// or another scheme; [claimed], a referrer the sender wrote into an
    /// intent itself (EXTRA_REFERRER or EXTRA_REFERRER_NAME on the start's
    /// intent or the activity's own), which getReferrer() reports in place
    /// of Android's record; or a launch from history ([flags],
    /// FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY): a task Android restores from
    /// Recents is started under the caller that first started it, while
    /// Android judges the one starting it now.
    fun callerPackage(scheme: String?, host: String?, claimed: Boolean, flags: Int): String? =
        if (claimed || (flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0 ||
            scheme != REFERRER_SCHEME
        ) null else host?.takeIf { it.isNotEmpty() }

    /// Whether a start came from the home screen as Android 14 and later
    /// count one on a Back at an idle root: the launcher's own intent
    /// ([launcherIntent], isLauncherIntent; ActivityRecord.isMainIntent)
    /// sent by the home app (LAUNCH_SOURCE_TYPE_HOME: the caller's process
    /// is the home process), which here means the caller Android recorded
    /// ([referrerPackage], callerPackage) is the default home app's package
    /// ([homePackage], what the home intent resolves to). Play's Open
    /// button, the package installer's, `am start` and any other app send
    /// the same intent under their own package. No home app is known when
    /// nothing resolved or the system's chooser stands in for one
    /// (ResolverActivity, package "android": several home apps and no
    /// default). An unknown caller or home is no home start, so the answer
    /// errs toward keeping Flutter's back callback (keepsBackCallbackAtRoot).
    fun homeStart(launcherIntent: Boolean, referrerPackage: String?, homePackage: String?): Boolean =
        launcherIntent && referrerPackage != null && homePackage != null &&
            homePackage != "android" && referrerPackage == homePackage

    /// Whether Flutter's back callback stays registered at the root route
    /// on Android [sdk] (MainActivity.setFrameworkHandlesBack): from
    /// Android 14, unless Android moves the task to the back on a Back at
    /// an idle root ([systemMovesTaskBack], HomeStarts). With
    /// enableOnBackInvokedCallback, Flutter hands Back at the root to
    /// Android, and Android 14 and later finish any root they do not move
    /// back (ActivityClientController.shouldMoveTaskToBack), its engine
    /// with it. Android 13 moves every task whose root is a launcher
    /// activity to the back (onBackPressedOnTaskRoot), and Android 12 and
    /// lower have no back callback: Back reaches Flutter through
    /// onBackPressed. Where the callback stays, as on Android 12 and lower,
    /// Back at the root goes through Flutter's SystemNavigator.pop to
    /// MainActivity.popSystemNavigator, which moves the task to the back,
    /// without Android's back-to-home preview.
    fun keepsBackCallbackAtRoot(sdk: Int, systemMovesTaskBack: Boolean): Boolean =
        sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && !systemMovesTaskBack

    /// Whether the app sets the navigation bar's colour itself on Android
    /// [sdk] (MainActivity.colorNavigationBar): from Android 15 (API 35),
    /// where the app draws edge to edge and Flutter's engine leaves the
    /// colour alone. Android then took the window's light background for a
    /// light bar and forced dark buttons until the app set a colour
    /// (APPEARANCE_FORCE_LIGHT_NAVIGATION_BARS), and tints the 3-button
    /// bar's contrast scrim with the colour set. Below that Flutter sets
    /// the colour as before, an opaque bar.
    fun colorsNavigationBar(sdk: Int): Boolean = sdk >= Build.VERSION_CODES.VANILLA_ICE_CREAM

    /// share_plus's FileProvider authority after the package name (its
    /// AndroidManifest.xml: ${applicationId}.flutter.share_provider).
    const val SHARE_OUT_AUTHORITY_SUFFIX = ".flutter.share_provider"

    /// Whether a stream with [scheme] and [authority] is one of the app's
    /// own share-out files (Today's day image, an Export): Chopstats is a
    /// target in its own sharesheet, and such a file is no meal.
    fun isOwnShareOut(scheme: String?, authority: String?, packageName: String): Boolean =
        "content".equals(scheme, ignoreCase = true) &&
            "$packageName$SHARE_OUT_AUTHORITY_SUFFIX".equals(authority, ignoreCase = true)

    /// Why a shared item gave no copy (MainActivity.withSafeShares). Share
    /// intake (Dart) reads it from the refused item's path, whose last
    /// part is the token (share_intake.dart androidRefusalTokens), and
    /// says how many items were skipped and why.
    enum class ShareRefusal(val token: String) {
        VIDEO("video"),
        FILE_TYPE("file_type"),
        TOO_BIG("too_big"),
        UNREADABLE("unreadable"),
    }

    /// The type a refused item goes to the plugin with
    /// (share_intake.dart androidRefusedShareType). It is no image, so
    /// share intake reads nothing at its path.
    const val REFUSED_SHARE_TYPE = "application/x-chopstats-refused"

    /// Where a refused item's path starts (share_intake.dart
    /// androidRefusedSharePath): a folder no file is in.
    const val REFUSED_SHARE_PATH = "/chopstats-refused"

    /// The refusal for a shared item of [itemType] that is no image: a
    /// video, or any other kind of file (a PDF, or no type at all).
    fun typeRefusal(itemType: String?): ShareRefusal =
        if (itemType?.startsWith("video") == true) ShareRefusal.VIDEO else ShareRefusal.FILE_TYPE

    /// The path a refused item reaches the plugin with: a file:// URI of
    /// it names no file, and the plugin hands a file:// URI's path on as it
    /// is, without opening it.
    fun refusedSharePath(refusal: ShareRefusal): String = "$REFUSED_SHARE_PATH/${refusal.token}"

    /// The longest file name a copy may have, in bytes (ext4 and f2fs).
    const val MAX_NAME_BYTES = 255

    /// The name a shared image is copied under (MainActivity.withSafeShares):
    /// [name] as its provider shows it, or, when that has no extension
    /// Android knows ([isKnownExtension], asked about the part after the
    /// last dot, lower-cased), with the one its image type gives
    /// ([typeExtension], asked only then). A provider may show a name
    /// without one (IMG_1731500000000, "Lunch with.Sarah"), and share
    /// intake takes a copy by its name's type: such a JPEG was refused as a
    /// kind of file Chopstats can't read. Unchanged when the type gives no
    /// plain extension, or the name would grow past MAX_NAME_BYTES.
    fun copyName(name: String, isKnownExtension: (String) -> Boolean, typeExtension: () -> String?): String {
        val dot = name.lastIndexOf('.')
        if (dot in 0 until name.length - 1 &&
            isKnownExtension(name.substring(dot + 1).lowercase(Locale.ROOT))
        ) return name
        val ext = typeExtension()?.takeIf { e ->
            e.isNotEmpty() && e.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' }
        } ?: return name
        val named = if (name.endsWith('.')) name + ext else "$name.$ext"
        return if (named.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) name else named
    }

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

/// Whether the home screen made MainActivity's first start, the one that
/// created it, and its latest (IntakeRules.homeStart). On a Back at an
/// idle root, Android 14 and the first release of Android 15 judge the
/// first: the activity keeps the launch source it was created with.
/// Android 15 QPR1 and later, and Android 16, judge the latest: each start
/// into a task sets the launch source of the task's top activity to its
/// own (ActivityStarter.startActivityInner), from the home screen or not,
/// the app's own starts of other activities in its task included, and so
/// does a start of the task from Recents (ActivityTaskSupervisor
/// .startActivityFromRecents), by whoever asks for it: the app that shows
/// Recents, or the system's window shell (SystemUI). Both rules run on
/// API 35, so the SDK level never picks one: the answer holds for both.
internal data class HomeStarts(val first: Boolean, val latest: Boolean) {
    /// After a start Android delivers to the running activity
    /// (onNewIntent): [home] whether it was a home start; [covered] whether
    /// another activity of the task (a picker, the share sheet, a
    /// permission dialog) sat above this one when it came. Android then
    /// sets that activity's launch source, the start closes it, and this
    /// one keeps its earlier source. The first stays. The latest is a home
    /// start only when [home] and nothing covered the activity; a covered
    /// start never makes it one.
    fun after(home: Boolean, covered: Boolean): HomeStarts = copy(latest = home && !covered)

    /// After a start into the task that Android does not deliver to this
    /// activity and that did not come from the home screen: the app
    /// opening another activity in its task above this one (the photo
    /// picker, a document picker, a permission dialog, the share sheet, a
    /// Settings page), which this one is the task's top for when it
    /// starts, so it takes the app's own launch source; or the window
    /// shell launching the task into split screen or a desktop window
    /// (SystemUI's). The first stays; the latest is no home start until
    /// the next home start Android delivers (after).
    fun afterOtherStart(): HomeStarts = copy(latest = false)

    /// Whether Android 14 and later move the task to the back on a Back at
    /// an idle root (ActivityClientController.shouldMoveTaskToBack): where
    /// the home screen made both the first start and the latest, both
    /// rules move it; any other root counts as one Android may finish.
    val systemMovesTaskBack: Boolean get() = first && latest

    companion object {
        /// Decided once per activity record: what its last instance saved
        /// ([first], [latest], null when nothing was), else the answer for
        /// the start that created it ([created], asked only then), which
        /// is its latest too.
        fun restore(first: Boolean?, latest: Boolean?, created: () -> Boolean): HomeStarts =
            if (first != null && latest != null) HomeStarts(first, latest)
            else created().let { HomeStarts(it, it) }
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
/// finishing it, which Android 14 and later still may after a start the
/// activity cannot see: MainActivity.setFrameworkHandlesBack) takes what
/// it holds with it; those copies stay in shared_photos, where share
/// intake's sweep takes them (share_intake.dart, strandedRecheck). Main
/// thread only.
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
