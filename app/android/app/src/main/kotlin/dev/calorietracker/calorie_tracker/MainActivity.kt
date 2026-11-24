package dev.calorietracker.calorie_tracker

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.app.LocaleManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.LocaleList
import android.os.Looper
import android.os.ext.SdkExtensions
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.View
import android.webkit.MimeTypeMap
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLConnection
import java.util.Locale
import java.util.UUID

class MainActivity : FlutterActivity() {
    /// The open pickFiles call, answered from onActivityResult once the
    /// picked files are copied. Main thread only.
    private var pickReply: MethodChannel.Result? = null

    /// The open pickImages call (answered once, busy while open), its
    /// number, and the most photos it asked the picker for (which contract
    /// parses the result). Main thread only.
    private val photoPicks = SingleCall<Map<String, Any>>()
    private var photoPickCall = 0L
    private var photoPickMax = 1

    /// The open saveFile call and its number. Main thread only.
    private val saves = SingleCall<Map<String, Any>>()
    private var saveCall = 0L

    /// The cached file a create-document screen was opened for: the open
    /// saveFile call's, or one restored from saved state when Android
    /// recreated the activity while that screen was up (the call died with
    /// its engine, but the user still picked a place for the file).
    private var pendingSaveSource: File? = null

    /// That copy's result, for the restarted app ("takeSaveResult"). Main
    /// thread only.
    private val lateSave = LateSaveResult<String>()

    /// Shares onNewIntent got before share intake listened for them, until
    /// it does (onNewIntent, releaseHeldShares). Main thread only.
    private val heldShares = ShareHold<Intent>()

    /// Whether the home screen made this activity's first start, the one
    /// that created it, and its latest (HomeStarts): decided at its first
    /// create, moved on by each start onNewIntent delivers (noteStart) and
    /// by the starts the activity tells otherwise (onPause, onResume,
    /// onMultiWindowModeChanged), and kept in the saved state
    /// (onSaveInstanceState).
    private var homeStarts = HomeStarts(first = false, latest = false)

    /// Whether Flutter's back callback stays registered at the root route
    /// (setFrameworkHandlesBack), from homeStarts: set in onCreate, and
    /// again whenever homeStarts moves (noteStarts).
    private var backCallbackAtRoot = false

    /// What Flutter last asked for (setFrameworkHandlesBack): whether it
    /// has something to pop. Main thread only.
    private var flutterHandlesBack = false

    /// Whether another activity of this task (a picker, the share sheet, a
    /// permission dialog) sat above this one when it last paused, until it
    /// resumes: the app opened it, a start that was not the home screen's
    /// (onPause), and a start that comes meanwhile is not this one's
    /// (HomeStarts.after). Kept in the saved state.
    private var coveredInTask = false

    /// This activity's engine's session in the analysis keep-alive
    /// (AnalysisKeepAlive): set when the engine is configured, dropped
    /// with the engine (cleanUpFlutterEngine).
    private var keepAliveSession = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        // Picked-photo copies an earlier activity left (its engine died
        // before Dart read them) have no reader: no pick of this one is
        // open yet.
        IntakeRules.clearPickFolders(File(cacheDir, PICKED_PHOTO_FOLDER))
        // Back at the root (setFrameworkHandlesBack): whether the home
        // screen made this activity's first start, the root of its task
        // (singleTask), and its latest (HomeStarts). The first create reads
        // the start that created it (isHomeStart: the intent, and the
        // caller Android recorded), before the replay rewrite below
        // empties that intent; that start is its latest too. Every later
        // create reads the saved state: an activity recreated after its
        // process died gets the creating intent again, and one relaunched
        // in the same process (theme colours, Bold text, grammatical
        // gender) whatever intent its last instance set, the replay
        // rewrite's or a notification tap's; neither tells of the starts
        // since, which the last instance noted as they came (noteStarts).
        homeStarts = HomeStarts.restore(
            first = savedInstanceState?.savedBoolean(STATE_FIRST_HOME_START),
            latest = savedInstanceState?.savedBoolean(STATE_LATEST_HOME_START),
        ) { intent?.let { isHomeStart(it) } ?: false }
        coveredInTask = savedInstanceState?.getBoolean(STATE_COVERED_IN_TASK) ?: false
        backCallbackAtRoot = IntakeRules.keepsBackCallbackAtRoot(Build.VERSION.SDK_INT, homeStarts.systemMovesTaskBack)
        // receive_sharing_intent reads the launch intent while
        // super.onCreate attaches it: the copies must be there already.
        // A share is delivered once. An activity Android recreates (saved
        // state: its process was stopped while it sat in the background)
        // or relaunches from Recents still carries the intent that first
        // started its task, so the plugins get an empty one, with nothing
        // copied; that also keeps a bitewise://setup link from reopening
        // its dialog. New shares arrive through onNewIntent, the one the
        // activity was recreated for too: Android delivers it in this same
        // launch, after onStart, before Dart has run, so onNewIntent holds
        // a share until share intake listens (ShareHold). The launch
        // intent is not re-delivered, but the copies of a share cut short
        // by the stop stay in shared_photos, those never read and those
        // whose photo was not settled yet (share intake deletes a copy
        // once its photo's verdict is written or the photo is let go):
        // share intake (Dart) picks them up at its next start, within a
        // day, through the same consent gate, and the photo ledger keeps
        // one already logged from being logged twice.
        val replay = IntakeRules.isRedelivery(savedInstanceState != null, intent?.flags ?: 0)
        if (replay) {
            intent?.let { setIntent(emptyShare(it)) }
        } else {
            intent?.let { setIntent(withSafeShares(it)) }
        }
        // As super.onCreate attaches the engine to the activity, the engine
        // reads one engine flag from the intent itself: a release build
        // takes it off first (dropSoftwareRenderingFlag).
        dropSoftwareRenderingFlag()
        super.onCreate(savedInstanceState)
        applyBackCallback()
        pendingSaveSource = cachedFile(savedInstanceState?.getString(STATE_SAVE_SOURCE))
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pendingSaveSource?.let { outState.putString(STATE_SAVE_SOURCE, it.path) }
        outState.putBoolean(STATE_FIRST_HOME_START, homeStarts.first)
        outState.putBoolean(STATE_LATEST_HOME_START, homeStarts.latest)
        outState.putBoolean(STATE_COVERED_IN_TASK, coveredInTask)
    }

    /// Whether another activity of the task covers this one
    /// (coveredInTask): one that does is the task's top as this one pauses
    /// for it, while for the home screen or another task this one stays
    /// its task's top. The app opened that activity (the photo picker, a
    /// document picker, a permission dialog, the share sheet, a Settings
    /// page), and this one was the task's top as it started: Android 15
    /// QPR1 and later gave this one the start's launch source, the app's
    /// own, and no intent tells of it. So the latest start is no home
    /// start from here (HomeStarts.afterOtherStart), even once that
    /// activity closes. A task that cannot be read counts as covered.
    override fun onPause() {
        super.onPause()
        coveredInTask = !isTopOfItsTask()
        if (coveredInTask) noteStarts(homeStarts.afterOtherStart())
    }

    /// Nothing covers the activity now (coveredInTask). In multi-window
    /// mode (split screen, a desktop window) the window shell starts the
    /// task itself, from Recents and with no intent, and Android 15 QPR1
    /// and later give this activity SystemUI's launch source; such a start
    /// brings the activity up in multi-window mode. So there the latest
    /// start never counts as a home start (onNewIntent delivers one before
    /// this), nor after it until the next home start
    /// (HomeStarts.afterOtherStart). The activity can also enter the mode
    /// while it runs (onMultiWindowModeChanged).
    override fun onResume() {
        super.onResume()
        coveredInTask = false
        if (isInMultiWindowMode) noteStarts(homeStarts.afterOtherStart())
    }

    /// The activity entered multi-window mode while it ran (onResume).
    @RequiresApi(Build.VERSION_CODES.O)
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        if (isInMultiWindowMode) noteStarts(homeStarts.afterOtherStart())
    }

    /// Flutter keeps its back callback registered only while it has
    /// something to pop (a route, a screen that asks before it closes, the
    /// shell while a shared photo is pending): at an idle root it hands
    /// Back to Android (enableOnBackInvokedCallback, AndroidManifest.xml).
    /// Android 14 and later then move the task to the back only after
    /// starts from the home screen, and finish any other root, its engine
    /// with it, mid-analysis: Android 14 and the first release of Android
    /// 15 judge the start that created the activity, Android 15 QPR1 and
    /// later and Android 16 the latest start into its task (HomeStarts).
    /// Unless the home screen made both, the activity keeps the callback
    /// (backCallbackAtRoot, IntakeRules.keepsBackCallbackAtRoot), so Back
    /// at its root goes through Flutter (handlePopRoute,
    /// SystemNavigator.pop, popSystemNavigator, which moves the task to the
    /// back) as on Android 12 and lower, and gives up Android's
    /// back-to-home preview: for good when the start that created the task
    /// was not the home screen's (Play's Open button, `am start`, a share),
    /// and until the next start from the home screen after a share, the
    /// bitewise://setup link or a notification into the task, after the
    /// app opened another activity in it (a picker, a permission dialog,
    /// the share sheet: onPause), and in and after multi-window mode
    /// (onResume). What Flutter asks for is kept (flutterHandlesBack), so a
    /// start can change the answer while the activity runs (noteStarts).
    /// One start is left that the activity never learns of: a return from
    /// Recents delivers no intent and counts as a start by the app that
    /// shows Recents, the home app on most phones but not with a
    /// third-party home app as the default. Android 15 QPR1 and later then
    /// finish the activity on a Back at an idle root, and a pending shared
    /// photo or an analysis in flight keeps that Back in Flutter
    /// (SharedPhotosBackGuard). FlutterActivity also calls this from its
    /// onCreate, with the state it saved.
    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        flutterHandlesBack = frameworkHandlesBack
        applyBackCallback()
    }

    /// Flutter's back callback registered while Flutter has something to
    /// pop (flutterHandlesBack) or the activity keeps it at the root
    /// (backCallbackAtRoot), and dropped otherwise.
    private fun applyBackCallback() {
        super.setFrameworkHandlesBack(flutterHandlesBack || backCallbackAtRoot)
    }

    /// Back at the root (Flutter's navigator has nothing left to pop) moves
    /// the task to the back instead of finishing the activity (decision
    /// 6.1). Finishing destroyed the engine with it: a shared photo still
    /// being analyzed was never saved (Q9), and every reopen started Dart
    /// cold on Today. Also what SystemNavigator.pop() does from Dart.
    /// Only a Back that Flutter handles gets here: every Back on Android 12
    /// and lower (onBackPressed); with predictive back on Android 13 and
    /// later (enableOnBackInvokedCallback), a Back at the root only while
    /// Flutter keeps its callback there. At an idle root Flutter hands Back
    /// to Android (setFrameworkHandlesBack(false)): Android 13 moves a task
    /// whose root is a launcher activity, as MainActivity is, to the back,
    /// and Android 14 and later an activity the home screen started
    /// (HomeStarts). On Android 14 and later the activity keeps the
    /// callback unless the home screen made both its first start and its
    /// latest (setFrameworkHandlesBack above), so after a share, the setup
    /// link, a notification, a picker, split screen, Play's Open button or
    /// `am start` its Back lands here. Android 15 QPR1 and later still
    /// finish it on a Back at an idle root after a start it cannot see (a
    /// return from Recents, with a third-party home app as the default).
    /// So while a shared photo is pending or an analysis the user started
    /// is in flight (AnalysisKeepAlive), the shell keeps Back at the root
    /// in Flutter in every task (SharedPhotosBackGuard, app.dart), and its
    /// SystemNavigator.pop() lands here on every Android version. A photo a
    /// finish still cuts off (a swipe from Recents, a Back before share
    /// intake has the share) is offered again at the next start, since its
    /// copy is kept until the photo is settled (share_intake.dart).
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    /// A share (withSafeShares made copies: a new SEND) goes to the plugins
    /// only once share intake listens: receive_sharing_intent tells only a
    /// listener and keeps nothing for later, and the share Android started
    /// a stopped process again for arrives before Dart has run. Until then
    /// it is held (ShareHold), not handed on, so the plugin cannot tell
    /// Dart twice. Anything else passes as before. Every one is first a
    /// start into the activity (noteStart).
    override fun onNewIntent(intent: Intent) {
        noteStart(intent)
        val safe = withSafeShares(intent)
        val copied = safe !== intent && safe.action != null
        if (copied && !heldShares.pass(safe)) return
        super.onNewIntent(safe)
    }

    /// [start], delivered to the running activity, is its latest start now
    /// (HomeStarts.after). Called first in onNewIntent: getReferrer() names
    /// this start's caller only during that call
    /// (Instrumentation.callActivityOnNewIntent sets the activity's
    /// referrer to the new intent's), and only while the activity's intent
    /// is still the one it had before (getReferrer() reads a referrer extra
    /// on it first, and flutter_local_notifications sets a notification
    /// tap's intent in super.onNewIntent). A start from the home icon
    /// arrives here too: MainActivity is singleTask, so Android hands it the
    /// launcher's intent (ActivityStarter.complyActivityFlags). The starts
    /// that deliver no intent are noted where the activity can tell them
    /// (onPause, onResume, onMultiWindowModeChanged), all but a return from
    /// Recents (setFrameworkHandlesBack).
    private fun noteStart(start: Intent) {
        noteStarts(homeStarts.after(isHomeStart(start), coveredInTask))
    }

    /// [starts] is what the activity knows of its starts now (homeStarts),
    /// and Flutter's back callback at the root follows at once
    /// (applyBackCallback).
    private fun noteStarts(starts: HomeStarts) {
        homeStarts = starts
        val keep = IntakeRules.keepsBackCallbackAtRoot(Build.VERSION.SDK_INT, starts.systemMovesTaskBack)
        if (keep == backCallbackAtRoot) return
        backCallbackAtRoot = keep
        applyBackCallback()
    }

    /// Whether [start] came from the home screen (IntakeRules.homeStart):
    /// the launcher's own intent, from the caller Android recorded for it
    /// (getReferrer: at the first create, the creating start's; in
    /// onNewIntent, the new start's), which is the default home app. A
    /// referrer the sender wrote into the intent (EXTRA_REFERRER,
    /// EXTRA_REFERRER_NAME) is its own word, not Android's record, and
    /// getReferrer() reports one on the activity's intent in place of the
    /// record, so a start that carries one, or one that comes while the
    /// activity's intent does, has no known caller
    /// (IntakeRules.callerPackage). False when anything cannot be read.
    private fun isHomeStart(start: Intent): Boolean = try {
        val claimed = start.namesReferrer() || intent?.namesReferrer() == true
        val from = referrer
        IntakeRules.homeStart(
            launcherIntent = IntakeRules.isLauncherIntent(start.action, start.categories, start.data != null, start.type),
            referrerPackage = IntakeRules.callerPackage(from?.scheme, from?.host, claimed, start.flags),
            homePackage = defaultHomePackage(),
        )
    } catch (e: Exception) {
        false
    }

    private fun Intent.namesReferrer(): Boolean =
        hasExtra(Intent.EXTRA_REFERRER) || hasExtra(Intent.EXTRA_REFERRER_NAME)

    /// The package the home intent (ACTION_MAIN with CATEGORY_HOME)
    /// resolves to: the default home app's, or the system chooser's
    /// ("android") when no default is set, which IntakeRules.homeStart
    /// takes for no home app. The app sees home apps through
    /// AndroidManifest.xml's <queries>; without it, Android 11 and later
    /// hide them from both this lookup and the referrer
    /// (ActivityRecord.getFilteredReferrer).
    @Suppress("DEPRECATION")
    private fun defaultHomePackage(): String? {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val found = if (Build.VERSION.SDK_INT >= 33) {
            packageManager.resolveActivity(
                home,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
        }
        return found?.activityInfo?.packageName
    }

    /// Whether this activity is the top one of its task, as Android
    /// reports it (ActivityManager.getAppTasks); false when that cannot be
    /// read. True below Android 14, where no answer depends on it
    /// (keepsBackCallbackAtRoot).
    private fun isTopOfItsTask(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val task = taskId
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            am.appTasks.asSequence().mapNotNull { it.taskInfo }
                .firstOrNull { it.taskId == task }?.topActivity == componentName
        } catch (e: Exception) {
            false
        }
    }

    /// The Boolean saved under [key], or null when none was.
    private fun Bundle.savedBoolean(key: String): Boolean? =
        if (containsKey(key)) getBoolean(key) else null

    /// Share intake listens now ("shareIntakeReady", sent after its listen
    /// on the same main thread): the shares onNewIntent held until then go
    /// to the plugins, in order, as onNewIntent would have handed them.
    /// How many there were.
    private fun releaseHeldShares(): Int {
        val held = heldShares.ready()
        for (share in held) super.onNewIntent(share)
        return held.size
    }

    /// receive_sharing_intent copied each shared stream into the cache on
    /// the main thread, under the file name the sender's provider reports,
    /// and caught nothing (review 171, C5): a share that could not be
    /// opened crashed the app, a name such as "../databases/…" wrote over
    /// the app's own files, and a share with no stream handed its text to
    /// Dart as the path, which share intake then deleted. The plugin now
    /// sees only copies made here, of the items it would report as images:
    /// each in a folder of its own under SHARE_FOLDER, under the sender's
    /// base name (its date stays readable; with the extension its image
    /// type gives when it has none Android knows, copyName, as share
    /// intake reads a copy by its name's type), at most MAX_SHARE_BYTES. What
    /// cannot be read is left out, and none of the sender's extras is
    /// passed on; a share with nothing left reaches no plugin. The plugin
    /// reports a file:// URI as it is, without opening it.
    ///
    /// An item left out for what it is (no image: a video, a PDF), for its
    /// size (over MAX_SHARE_BYTES) or because it could not be read goes on
    /// as a refused item after the copies, of type REFUSED_SHARE_TYPE: a
    /// file:// URI that names no file (IntakeRules.refusedSharePath), which
    /// the plugin hands Dart as its path. One left out once its name is
    /// known, for its type, its size or a failed copy, carries its name's
    /// extension and nothing else of the name (for its size or a failed
    /// copy, its copy's name's when its own gives none: the extension its
    /// image type gives, IntakeRules.failedCopyName), so share intake names
    /// an image format it does not read as it names a copy's: a CR3 among
    /// several, which Android has no type for (PR81-QA-3), and a RAW file
    /// over 25 MB (PR81-QA-4). A video carries none. Share intake says how
    /// many were skipped and why, after the share's photos (they used to
    /// go without a word); a share whose every item was refused reaches
    /// the plugin with those alone, and asks nothing. The app's own
    /// share-out files are still left out without one.
    private fun withSafeShares(intent: Intent): Intent {
        val kind = intent.action
        val shareType = intent.type ?: return intent
        if (kind != Intent.ACTION_SEND && kind != Intent.ACTION_SEND_MULTIPLE &&
            kind != Intent.ACTION_VIEW) return intent
        val streams: List<Uri?>
        var listedTypes: Array<String?>? = null
        try {
            streams = when (kind) {
                Intent.ACTION_VIEW -> listOf(intent.data)
                Intent.ACTION_SEND -> listOf(intent.streamExtra())
                else -> intent.streamListExtra()
            }
            if (kind == Intent.ACTION_SEND_MULTIPLE) {
                listedTypes = intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)
            }
        } catch (e: Exception) {
            return emptyShare(intent) // extras that cannot be read
        }
        val copies = ArrayList<Uri>()
        val copyTypes = ArrayList<String>()
        // Each item left out, as its refused item's path
        // (IntakeRules.refusedSharePath).
        val refused = ArrayList<String>()
        try {
            clearEmptyShareFolders()
        } catch (e: Exception) {
        }
        streams.forEachIndexed { i, uri ->
            // The name whose extension a failure of this item carries (the
            // catch below): its provider's once it has given one, then,
            // once its copy's name is known, the one a failed copy carries
            // (IntakeRules.failedCopyName).
            var named: String? = null
            try {
                if (uri == null) {
                    refused.add(IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.UNREADABLE))
                    return@forEachIndexed
                }
                if (IntakeRules.isOwnShareOut(uri.scheme, uri.authority, packageName)) return@forEachIndexed
                val name = shareName(uri)
                if (name == null) {
                    refused.add(IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.UNREADABLE))
                    return@forEachIndexed
                }
                named = name
                // The type the plugin gives it: the share's own, or for
                // several, each one's listed type, else its name's, else
                // its provider's. A name with no extension Android knows
                // ("Dinner with J.Smith") gave none, and such an image was
                // refused as a kind of file (device QA 2026-11-22,
                // PR81-QA-2); one shared alone has the share's type.
                val itemType = if (kind == Intent.ACTION_SEND_MULTIPLE)
                    listedTypes?.getOrNull(i) ?: URLConnection.guessContentTypeFromName(name)
                        ?: providerType(uri)
                else shareType
                // No image: refused before any copy, nothing read. One
                // refused for its type keeps its name's extension, so an
                // image format Android has no type for (a CR3 or an X3F:
                // no guess from its name, octet-stream from its provider)
                // is named, not called a kind of file (device QA
                // 2026-11-22, PR81-QA-3).
                if (itemType?.startsWith("image") != true) {
                    refused.add(IntakeRules.refusedSharePath(IntakeRules.typeRefusal(itemType), name))
                    return@forEachIndexed
                }
                // Over MAX_SHARE_BYTES, or a copy that failed: nothing of
                // it is kept. A size its provider gives over the cap
                // refuses it before it is opened; a copy that runs past
                // the cap, or fails, is deleted with its folder
                // (copyShare). Its refusal carries an extension too, so an
                // image format share intake does not read is named, as its
                // copy would be, and not said to be over 25 MB or
                // unreadable: Chopstats reads no file of that format, of
                // any size (device QA 2026-11-23, PR81-QA-4). It is the
                // extension of the name its provider shows, as for the
                // type refusal above, else of its copy's name, which has
                // the one its image type gives: a DNG whose provider shows
                // no extension was said to be over 25 MB, where a smaller
                // one was named (IntakeRules.failedCopyName).
                val copyAs = copyName(uri, name, itemType)
                named = IntakeRules.failedCopyName(name, copyAs)
                val (copy, copied) = copyShare(uri, copyAs)
                if (copy == null) {
                    refused.add(
                        IntakeRules.refusedSharePath(
                            if (copied == Copied.TOO_BIG) IntakeRules.ShareRefusal.TOO_BIG
                            else IntakeRules.ShareRefusal.UNREADABLE,
                            named,
                        ),
                    )
                    return@forEachIndexed
                }
                copies.add(Uri.fromFile(copy))
                copyTypes.add(itemType)
            } catch (e: Exception) {
                // This item only: the others still go. With the extension
                // its name gives once that is known, and a failed copy's
                // once its copy's name is (named).
                refused.add(IntakeRules.refusedSharePath(IntakeRules.ShareRefusal.UNREADABLE, named))
            }
        }
        if (copies.isEmpty() && refused.isEmpty()) return emptyShare(intent)
        return try {
            Intent(intent).apply {
                replaceExtras(Bundle())
                if (kind == Intent.ACTION_SEND_MULTIPLE || refused.isNotEmpty()) {
                    // The copies, then one item per refused one. A SEND or
                    // VIEW whose one item was refused goes as a list of
                    // that refused item, with no data left either.
                    action = Intent.ACTION_SEND_MULTIPLE
                    setDataAndType(null, shareType)
                    val items = ArrayList<Uri>(copies)
                    val types = ArrayList<String>(copyTypes)
                    for (path in refused) {
                        items.add(Uri.fromFile(File(path)))
                        types.add(IntakeRules.REFUSED_SHARE_TYPE)
                    }
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, items)
                    putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
                } else {
                    // A VIEW of an image reaches the plugin as the SEND it
                    // is to it, with no data left for a deep link to read.
                    action = Intent.ACTION_SEND
                    setDataAndType(null, shareType)
                    putExtra(Intent.EXTRA_STREAM, copies[0])
                }
            }
        } catch (e: Exception) {
            Intent()
        }
    }

    /// [intent] with nothing a plugin reads as a share or a link.
    private fun emptyShare(intent: Intent): Intent = try {
        Intent(intent).apply {
            replaceExtras(Bundle())
            action = null
            setDataAndType(null, null)
        }
    } catch (e: Exception) {
        Intent()
    }

    @Suppress("DEPRECATION")
    private fun Intent.streamExtra(): Uri? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    @Suppress("DEPRECATION")
    private fun Intent.streamListExtra(): List<Uri?> =
        if (Build.VERSION.SDK_INT >= 33) getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
        else getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()

    /// The name the plugin gave [uri]'s copy, without any folder part: the
    /// display name its provider reports, or the plugin's own fallback; a
    /// file's own name. Null for any other scheme, or a name that is no
    /// file name ("..").
    private fun shareName(uri: Uri): String? = when (uri.scheme?.lowercase()) {
        "content" -> {
            val shown = try {
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { c ->
                        val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (c.moveToFirst() && i >= 0 && !c.isNull(i)) c.getString(i) else null
                    }
            } catch (e: Exception) {
                null
            }
            if (shown == null) fallbackShareName(uri) else baseName(shown)
        }
        "file" -> baseName(uri.path)
        else -> null
    }

    private fun baseName(raw: String?): String? {
        val name = raw?.substringAfterLast('/') ?: return null
        return if (name.isEmpty() || name == "." || name == ".." || '\u0000' in name) null else name
    }

    /// The type [uri]'s provider gives it; null when it gives none or
    /// cannot be asked.
    private fun providerType(uri: Uri): String? = try {
        contentResolver.getType(uri)
    } catch (e: Exception) {
        null
    }

    /// The name a shared image of [itemType] at [uri] is copied under:
    /// [name], or with the extension its image type gives when [name] has
    /// none Android knows (IntakeRules.copyName). That type is the share's
    /// own for it, else, for one such as image/*, its provider's.
    private fun copyName(uri: Uri, name: String, itemType: String): String {
        val types = MimeTypeMap.getSingleton()
        fun extensionOf(type: String?): String? =
            type?.lowercase(Locale.ROOT)?.takeIf { it.startsWith("image/") }
                ?.let { types.getExtensionFromMimeType(it) }
        return IntakeRules.copyName(name, { types.hasExtension(it) }) {
            extensionOf(itemType) ?: extensionOf(providerType(uri))
        }
    }

    /// The plugin's name for a stream whose provider shows none.
    private fun fallbackShareName(uri: Uri): String {
        val mime = providerType(uri)
        val prefix = when {
            mime?.startsWith("image") == true -> "IMG"
            mime?.startsWith("video") == true -> "VID"
            else -> "FILE"
        }
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
        return "${prefix}_${System.currentTimeMillis()}" + (ext?.let { ".$it" } ?: "")
    }

    /// [uri] copied into a folder of its own under SHARE_FOLDER as [name],
    /// with how the copy went; no file when it is over MAX_SHARE_BYTES
    /// (TOO_BIG), or cannot be read or written, or is one of the app's own
    /// files (FAILED).
    private fun copyShare(uri: Uri, name: String): Pair<File?, Copied> {
        if (isOwnFile(uri)) return null to Copied.FAILED
        val dir = File(File(cacheDir, SHARE_FOLDER), UUID.randomUUID().toString())
        if (!dir.mkdirs()) return null to Copied.FAILED
        val out = File(dir, name)
        val copied = copyAtMost(uri, out, MAX_SHARE_BYTES)
        if (copied == Copied.OK) return out to copied
        out.delete()
        dir.delete()
        return null to copied
    }

    /// Whether [uri] is a file:// URI into the app's own data directory
    /// (or one that cannot be told apart from it): never copied, whether
    /// shared or picked.
    private fun isOwnFile(uri: Uri): Boolean =
        "file".equals(uri.scheme, ignoreCase = true) &&
            IntakeRules.liesIn(File(applicationInfo.dataDir), uri.path)

    /// Folders whose copy Dart has deleted (its photo settled).
    private fun clearEmptyShareFolders() {
        File(cacheDir, SHARE_FOLDER).listFiles()?.forEach {
            if (it.isDirectory && it.list()?.isEmpty() == true) it.delete()
        }
    }

    /// FlutterActivity takes its launch settings from the launch intent:
    /// its extras (FlutterActivityLaunchConfigs, and FlutterShellArgs'
    /// engine flags) and, in a debuggable build started with ACTION_RUN,
    /// its data. MainActivity is exported: the launcher, the
    /// bitewise://setup link and the share sheet start it, and so can any
    /// other app, with extras of its own (EXTRAS-1, 2026-11-22). On an
    /// Android 15 emulator, a cold start with a cached_engine_id or a
    /// cached_engine_group_id the app never cached crashed in onCreate
    /// (FlutterActivityAndFragmentDelegate.setUpFlutterEngine), and so did
    /// a background_mode Flutter does not know and dart_entrypoint_args
    /// that are no list; background_mode=transparent swapped the
    /// FlutterSurfaceView for a FlutterTextureView in a see-through window;
    /// a dart_entrypoint naming another function left the launch screen up
    /// for good, Dart never running; and with
    /// destroy_engine_with_activity=false the engine outlived its activity,
    /// so the next start ran a second one beside it. A running activity
    /// took them too, from a start onNewIntent delivered, once a plugin
    /// made that start's intent the activity's own, as
    /// flutter_local_notifications does for a notification tap's action
    /// (SELECT_NOTIFICATION): Flutter reads several of these getters again
    /// later (FlutterActivityAndFragmentDelegate.onSaveInstanceState and
    /// onDetach), and destroy_engine_with_activity=false sent that way left
    /// the engine running past the activity's destroy as well (EXTRAS-1
    /// review, 2026-11-23). The app uses no cached engine, engine group,
    /// transparent window, other entry point or other route: each getter
    /// below gives what a launch with no extras gets, whatever the intent
    /// carries, then or later. The intent itself stays as onCreate sets it,
    /// for the plugins that read it, less the one engine flag the engine
    /// reads from it itself in a release build (dropSoftwareRenderingFlag).

    /// No cached engine: the activity makes its own at every create.
    override fun getCachedEngineId(): String? = null

    /// No engine group either.
    override fun getCachedEngineGroupId(): String? = null

    /// The engine goes with the activity, as the engine an activity made
    /// itself does when the intent says nothing.
    override fun shouldDestroyEngineWithHost(): Boolean = true

    /// An opaque window, which also picks the FlutterSurfaceView and an
    /// opaque FlutterView (getRenderMode, getTransparencyMode).
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.opaque

    /// The app's one route: its MaterialApp has only a home. With Flutter's
    /// deep linking off (flutter_deeplinking_enabled, AndroidManifest.xml),
    /// neither the intent's route nor its data picks the first screen, and
    /// neither does `flutter run --route`.
    override fun getInitialRoute(): String = "/"

    /// lib/main.dart's main, in the root library, with no arguments: what
    /// the manifest gives, which sets no io.flutter.Entrypoint or
    /// io.flutter.EntrypointUri.
    override fun getDartEntrypointFunctionName(): String = "main"
    override fun getDartEntrypointLibraryUri(): String? = null
    override fun getDartEntrypointArgs(): List<String>? = null

    /// Flutter's state restoration stays on, as when the intent says
    /// nothing (enable_state_restoration).
    override fun shouldRestoreAndSaveState(): Boolean = true

    /// The app's own Dart bundle, the one FlutterActivityAndFragmentDelegate
    /// falls back to when this gives none: FlutterActivity took the
    /// intent's data as the bundle's path in a debuggable build started
    /// with ACTION_RUN, which `flutter run` never sends.
    override fun getAppBundlePath(): String = FlutterInjector.instance().flutterLoader().findAppBundlePath()

    /// Flutter's engine flags from the intent (FlutterShellArgs.fromIntent)
    /// in a debug or profile build only; none in a release build
    /// (IntakeRules.takesEngineFlagsFromIntent, which says why). So the
    /// engine options `flutter run --release` passes that way, such as
    /// --no-enable-impeller and --enable-hcpp, do nothing on Android: a
    /// release build takes them from the manifest's meta-data only
    /// (io.flutter.embedding.android.EnableImpeller, EnableHcpp and the
    /// rest of FlutterEngineFlags), which no other app can set (EXTRAS-1
    /// review, 2026-11-23). FlutterShellArgs is deprecated: Flutter means
    /// to stop reading engine flags from the intent
    /// (flutter/flutter#180686), and this override goes when it has.
    @Suppress("DEPRECATION")
    override fun getFlutterShellArgs(): io.flutter.embedding.engine.FlutterShellArgs =
        if (IntakeRules.takesEngineFlagsFromIntent(io.flutter.BuildConfig.RELEASE)) {
            super.getFlutterShellArgs()
        } else {
            io.flutter.embedding.engine.FlutterShellArgs(emptyArray<String>())
        }

    /// In a release build, Flutter's enable-software-rendering extra taken
    /// off the activity's intent before super.onCreate attaches the engine
    /// to the activity (onCreate). The engine reads that one engine flag
    /// from the intent itself, past getFlutterShellArgs and in every build
    /// (FlutterEngineConnectionRegistry.attachToActivityInternal): set, it
    /// tells the platform views controller that the engine renders in
    /// software, so a platform view in texture-layer mode gets no texture
    /// to draw into, while the engine itself renders as before
    /// (getFlutterShellArgs gives it no flags). The app has no platform
    /// view yet. Without the extra the engine reads the manifest, which
    /// sets no EnableSoftwareRendering (EXTRAS-1 review, 2026-11-23).
    /// Debug and profile builds keep it, as they keep the engine flag
    /// itself (IntakeRules.takesEngineFlagsFromIntent), for `flutter run
    /// --enable-software-rendering`.
    @Suppress("DEPRECATION")
    private fun dropSoftwareRenderingFlag() {
        if (IntakeRules.takesEngineFlagsFromIntent(io.flutter.BuildConfig.RELEASE)) return
        intent?.removeExtra(io.flutter.embedding.engine.FlutterShellArgs.ARG_KEY_ENABLE_SOFTWARE_RENDERING)
    }

    /// The phone's 12/24-hour switch (Settings.System.TIME_12_24). The
    /// Flutter embedding sends it to Dart (alwaysUse24HourFormat) when its
    /// view attaches and at a configuration change, and turning the switch
    /// is neither: the app kept the old clock until a restart or a rotation
    /// (Android QA Q7). The Settings app writes this setting and broadcasts
    /// ACTION_TIME_CHANGED; the observer sees the write, from `settings
    /// put` too. On a change the current configuration goes to the
    /// FlutterView again (FlutterActivity.FLUTTER_VIEW_ID, its public id),
    /// which re-sends the user settings exactly as a configuration change
    /// does. Registered for the activity's engine (configureFlutterEngine
    /// to cleanUpFlutterEngine), on the main thread. On Android 13 and
    /// later Dart is also told on the app-language channel ("phoneChanged"),
    /// and reads the phone's own clock again (phone): once the app has a
    /// language of its own, the FlutterView's clock is that language's.
    private val clockFormatObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
                ?.dispatchConfigurationChanged(resources.configuration)
            appLanguageChannel?.invokeMethod("phoneChanged", null)
        }
    }

    /// The app-language channel of this activity's engine
    /// (configureFlutterEngine to cleanUpFlutterEngine). Main thread only.
    private var appLanguageChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        contentResolver.registerContentObserver(
            Settings.System.getUriFor(Settings.System.TIME_12_24),
            false,
            clockFormatObserver,
        )
        // Settings › 照片 › 后台扫描 asks whether the user set the app to
        // 电池 › 受限 (App info › App battery usage › Restricted). In that
        // bucket Android parks the periodic WorkManager job — the
        // closed-app photo scan AND the nightly summary — for days, and
        // nothing else in the app could explain the frozen 尚未运行. Only
        // the UI engine goes through this activity; the background engine
        // never needs the answer. No manifest permission is involved.
        // openNotificationSettings: Settings' notifications-off remedy.
        // installTimes: tells preferences restored from another install
        // from this install's own (notification_permission.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isBackgroundRestricted" -> result.success(isBackgroundRestricted())
                    "openNotificationSettings" -> result.success(openNotificationSettings())
                    "installTimes" -> result.success(installTimes())
                    else -> result.notImplemented()
                }
            }
        // Settings › Your Data › Import › Choose File… (1.7.0): the system
        // file picker (Storage Access Framework), several files at once.
        // Each picked file is copied into the app's cache, and Dart deletes
        // the copy after the import. No storage permission is involved:
        // ACTION_OPEN_DOCUMENT grants access to the picked files only.
        // pickImages: Log and Leftovers through the system Photo Picker,
        // which grants the picked photos only, with no permission at all.
        // saveFile: Export › Save to device, written where the user picks
        // (ACTION_CREATE_DOCUMENT grants that one document only).
        // takeSaveResult: how a save whose call died with an earlier
        // engine ended (LateSaveResult), once.
        // shareIntakeReady: share intake listens to shares now, so those
        // onNewIntent held go to the plugins (releaseHeldShares).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareIntakeReady" -> result.success(releaseHeldShares())
                    "pickFiles" -> pickFiles(result)
                    "pickImages" -> pickImages(
                        (call.argument<Any?>("max") as? Number)?.toInt() ?: 1,
                        result,
                    )
                    "saveFile" -> saveFile(
                        call.argument<Any?>("path") as? String,
                        call.argument<Any?>("name") as? String,
                        call.argument<Any?>("mime") as? String,
                        result,
                    )
                    "takeSaveResult" -> lateSave.take { status ->
                        result.success(status?.let { saveAnswer(it) })
                    }
                    else -> result.notImplemented()
                }
            }
        // The analysis keep-alive (owner decision 9, AnalysisKeepAlive.kt):
        // Dart's AnalysisKeepAlive sends "begin" and "end" with its id for
        // each analysis the user started, under this engine's session, so
        // the requests of an engine that dies end with it
        // (cleanUpFlutterEngine). Its "reset", sent once as it is built,
        // drops what an earlier run of this engine's Dart left open: a hot
        // restart keeps the engine (no configure, no cleanup) and starts
        // the ids over. Nothing is open at a cold start. No permission:
        // WorkManager is the one the background photo scan already uses.
        val session = AnalysisKeepAlive.newSession()
        keepAliveSession = session
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEP_ALIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                val id = (call.argument<Any?>("id") as? Number)?.toLong()
                when {
                    call.method == "reset" -> {
                        AnalysisKeepAlive.drop(applicationContext, session)
                        result.success(true)
                    }
                    id == null -> result.success(false)
                    call.method == "begin" ->
                        result.success(AnalysisKeepAlive.begin(applicationContext, session, id))
                    call.method == "end" ->
                        result.success(AnalysisKeepAlive.end(applicationContext, session, id))
                    else -> result.notImplemented()
                }
            }
        // The navigation bar's colour on Android 15 and later, which
        // Flutter no longer sets there (colorNavigationBar).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_BARS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "navigationBarColor" ->
                        result.success(colorNavigationBar((call.argument<Any?>("color") as? Number)?.toLong()))
                    else -> result.notImplemented()
                }
            }
        // The app's own language on Android 13 and later (Settings › Apps ›
        // Chopstats › Language, which lists the languages in
        // res/xml/locales_config.xml), kept in step with the app's Language
        // row by lib/services/settings/app_language_sync.dart: "get" answers
        // it (appLanguage), "set" sets it (setAppLanguage). "phone" answers
        // what the phone itself is set to, which the app's own language
        // hides from the app (phone). No permission: an app sets its own.
        appLanguageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_LANGUAGE_CHANNEL)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "get" -> result.success(appLanguage())
                        "set" -> result.success(setAppLanguage(call.argument<Any?>("tags") as? String))
                        "phone" -> result.success(phone())
                        else -> result.notImplemented()
                    }
                }
            }
    }

    /// The engine is going (the activity is destroyed): the 12/24-hour
    /// observer registered for it stops (clockFormatObserver), with the
    /// channel it tells, and its analyses go with it, so they no longer
    /// keep the process up. Its Dart can never end them now.
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        contentResolver.unregisterContentObserver(clockFormatObserver)
        appLanguageChannel = null
        AnalysisKeepAlive.drop(applicationContext, keepAliveSession)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /// The navigation bar's colour, from the app's theme ([argb]: the tab
    /// bar's own, lib/ui/app.dart _SystemNavBarStyle), on Android 15 and
    /// later only (IntakeRules.colorsNavigationBar); true when it was set.
    /// Below that Flutter sets it itself, as an opaque bar. From Android 15
    /// the app draws edge to edge and Flutter leaves the colour alone, so
    /// Android took a light window background (the light launch theme) as
    /// a light bar and forced dark buttons on it
    /// (APPEARANCE_FORCE_LIGHT_NAVIGATION_BARS, DecorView.setWindowBackground):
    /// with 3-button navigation, a switch to dark while the app ran left
    /// dark buttons on the dark bar on Android 16 (A36-1; MainActivity
    /// handles uiMode itself, so the window background is never set
    /// again). A colour the app sets clears that, and Android never forces
    /// it again for this window: the buttons follow the app's own
    /// light/dark request (Flutter's systemNavigationBarIconBrightness).
    /// It also tints the contrast scrim Android draws behind the 3-button
    /// bar (the colour at 80%; none behind the gesture bar), which the app
    /// asks for so the buttons never sit on a screen's content (A36-2).
    @Suppress("DEPRECATION")
    private fun colorNavigationBar(argb: Long?): Boolean {
        if (argb == null || !IntakeRules.colorsNavigationBar(Build.VERSION.SDK_INT)) return false
        window.navigationBarColor = argb.toInt()
        return true
    }

    /// The language Android keeps for the app itself (LocaleManager, Android
    /// 13 and later) as language tags, the preferred first ("zh-Hans-CN"):
    /// "" when there is none and the app follows the system's. Null below
    /// Android 13, which has no such setting, or when it cannot be read.
    private fun appLanguage(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return try {
            getSystemService(LocaleManager::class.java)?.applicationLocales?.toLanguageTags()
        } catch (e: Exception) {
            null
        }
    }

    /// Sets the app's own language to [tags] on Android 13 and later: one of
    /// the app's languages, or none for "" (IntakeRules.appLanguageTags);
    /// true when it was set. The language goes in with the region of the
    /// phone's own locale in it (IntakeRules.appLanguageTag: "en-GB" on a
    /// British phone), which keeps the phone's clock and region. Android
    /// hands the change to this activity as a configuration change it takes
    /// itself (configChanges locale and layoutDirection,
    /// AndroidManifest.xml), so it is not recreated for it: FlutterView
    /// sends Dart the new locales, and nothing on screen is lost.
    private fun setAppLanguage(tags: String?): Boolean {
        val language = IntakeRules.appLanguageTags(tags) ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        return try {
            val manager = getSystemService(LocaleManager::class.java) ?: return false
            manager.applicationLocales = LocaleList.forLanguageTags(
                IntakeRules.appLanguageTag(language, manager.systemLocales.toLanguageTags()),
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /// What the phone itself is set to on Android 13 and later, which the
    /// app's own language hides from the app: its locales then start with
    /// the app's, and the FlutterView's 12/24-hour clock
    /// (DateFormat.is24HourFormat of this activity) is that language's.
    /// "locales": the phone's own languages as language tags, the
    /// preferred first (LocaleManager.systemLocales, which no app language
    /// changes); "use24h": the phone's own clock, its 'Use 24-hour format'
    /// switch or its first language's
    /// (IntakeRules.usesTwentyFourHourClock), null when neither tells. Null
    /// below Android 13, where the app's are the phone's, or when they
    /// cannot be read.
    private fun phone(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return try {
            val locales = getSystemService(LocaleManager::class.java)?.systemLocales ?: return null
            mapOf(
                "locales" to locales.toLanguageTags(),
                "use24h" to IntakeRules.usesTwentyFourHourClock(
                    Settings.System.getString(contentResolver, Settings.System.TIME_12_24),
                    if (locales.isEmpty) null else IntakeRules.longTimePattern(locales[0]),
                ),
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun isBackgroundRestricted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.isBackgroundRestricted
    }

    /// When this install was first installed and last updated (ms since
    /// the epoch, PackageInfo), and the version installed then. Preferences
    /// that Auto Backup restored, or a device transfer brought, carry
    /// another install's notification-ask flags;
    /// notification_permission.dart tells them apart by these. The app
    /// language's agreement tells by them when the same version was
    /// installed again (app_language_sync.dart). Null when they cannot be
    /// read.
    private fun installTimes(): Map<String, Long>? = try {
        @Suppress("DEPRECATION")
        val info = packageManager.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        val version = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
        mapOf("firstInstall" to info.firstInstallTime, "lastUpdate" to info.lastUpdateTime, "versionCode" to version)
    } catch (e: Exception) {
        null
    }

    /// Opens the system's notification page for this app (API 26+), else
    /// its App info page. False when neither could be opened.
    private fun openNotificationSettings(): Boolean {
        val pages = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            pages.add(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
            )
        }
        pages.add(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
        )
        return IntakeRules.openFirst(pages) { startActivity(it) }
    }

    private fun pickFiles(result: MethodChannel.Result) {
        if (pickReply != null) {
            result.success(mapOf("status" to "busy"))
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // Many file managers label .json as octet-stream or text.
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/json", "text/plain", "application/octet-stream"),
            )
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        pickReply = result
        try {
            startActivityForResult(intent, PICK_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pickReply = null
            result.success(mapOf("status" to "unavailable"))
        }
    }

    /// The system Photo Picker through AndroidX's contracts, run by hand:
    /// FlutterActivity is a plain Activity, with no
    /// registerForActivityResult. Where the picker is missing the contract
    /// itself falls back (Play services' backported picker, see the
    /// ModuleDependencies entry in AndroidManifest.xml, else
    /// ACTION_OPEN_DOCUMENT). [requested] is clamped (IntakeRules.pickMax).
    /// Answers {status, items, tooBig, failed} once the picks are copied
    /// (onPhotosPicked); busy while a pick is open.
    private fun pickImages(requested: Int, result: MethodChannel.Result) {
        if (photoPicks.isOpen) {
            result.success(photoPickAnswer("busy"))
            return
        }
        val max = IntakeRules.pickMax(requested, systemPickLimit())
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        val intent = try {
            if (max == 1) ActivityResultContracts.PickVisualMedia().createIntent(this, request)
            else ActivityResultContracts.PickMultipleVisualMedia(max).createIntent(this, request)
        } catch (e: Exception) {
            result.success(photoPickAnswer("unavailable"))
            return
        }
        val call = photoPicks.open { result.success(it) } ?: return result.success(photoPickAnswer("busy"))
        photoPickCall = call
        photoPickMax = max
        try {
            startActivityForResult(intent, PHOTO_PICK_REQUEST)
        } catch (e: Exception) {
            photoPicks.answer(call, photoPickAnswer("unavailable"))
        }
    }

    /// The system picker's most photos per pick (its contract refuses
    /// more), where AndroidX uses it: API 33+ or R extension 2+. Null where
    /// only a fallback picker exists.
    @SuppressLint("NewApi")
    private fun systemPickLimit(): Int? =
        if (Build.VERSION.SDK_INT >= 33 ||
            (Build.VERSION.SDK_INT >= 30 && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2)
        ) MediaStore.getPickImagesMaxLimit() else null

    private fun photoPickAnswer(
        status: String,
        items: List<Map<String, Any>> = emptyList(),
        tooBig: Int = 0,
        failed: Int = 0,
    ): Map<String, Any> =
        mapOf("status" to status, "items" to items, "tooBig" to tooBig, "failed" to failed)

    /// Copies each picked photo (at most the call's maximum: the
    /// ACTION_OPEN_DOCUMENT fallback ignores it) to
    /// cacheDir/PICKED_PHOTO_FOLDER/<uuid>/<name>, under the share cap,
    /// with its capture time when the provider gives one. First it tidies
    /// what earlier picks left (IntakeRules.tidyPickFolders: empty or
    /// day-old folders only; onCreate clears what an earlier activity's
    /// picks left). Off the UI thread; the call stays open
    /// (busy) until the answer. The grants last only while the app runs,
    /// hence the copies. With no open call (Android recreated the activity
    /// while the picker was up, and the call died with its engine) nothing
    /// is copied: no one would read it.
    private fun onPhotosPicked(resultCode: Int, data: Intent?) {
        if (!photoPicks.isOpen) return
        val call = photoPickCall
        val max = photoPickMax
        val picked: List<Uri> = try {
            if (max == 1) {
                listOfNotNull(ActivityResultContracts.PickVisualMedia().parseResult(resultCode, data))
            } else {
                ActivityResultContracts.PickMultipleVisualMedia(max).parseResult(resultCode, data)
            }
        } catch (e: Exception) {
            emptyList()
        }
        val uris = IntakeRules.firstPicks(picked, max)
        if (resultCode != Activity.RESULT_OK || uris.isEmpty()) {
            photoPicks.answer(call, photoPickAnswer("cancelled"))
            return
        }
        Thread {
            val items = mutableListOf<Map<String, Any>>()
            var tooBig = 0
            var failed = 0
            val root = File(cacheDir, PICKED_PHOTO_FOLDER)
            IntakeRules.tidyPickFolders(root, System.currentTimeMillis())
            uris.forEach { uri ->
                try {
                    if (isOwnFile(uri)) {
                        failed++
                        return@forEach
                    }
                    val name = shareName(uri)
                        ?: if ("content".equals(uri.scheme, ignoreCase = true)) fallbackShareName(uri) else null
                    val dir = File(root, UUID.randomUUID().toString())
                    if (name == null || !dir.mkdirs()) {
                        failed++
                        return@forEach
                    }
                    val out = File(dir, name)
                    when (copyAtMost(uri, out, MAX_SHARE_BYTES)) {
                        Copied.OK -> {
                            val item = mutableMapOf<String, Any>("path" to out.absolutePath, "name" to name)
                            dateTaken(uri)?.let { item["dateTakenMs"] = it }
                            items.add(item)
                        }
                        Copied.TOO_BIG -> {
                            out.delete()
                            dir.delete()
                            tooBig++
                        }
                        Copied.FAILED -> {
                            out.delete()
                            dir.delete()
                            failed++
                        }
                    }
                } catch (e: Exception) {
                    failed++
                }
            }
            runOnUiThread { photoPicks.answer(call, photoPickAnswer("ok", items, tooBig, failed)) }
        }.start()
    }

    /// When [uri]'s photo was taken (ms since the epoch), as the provider
    /// reports it; null when it does not (a document provider, say).
    private fun dateTaken(uri: Uri): Long? = try {
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATE_TAKEN), null, null, null)
            ?.use { c ->
                val i = c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
                if (c.moveToFirst() && i >= 0 && !c.isNull(i)) c.getLong(i).takeIf { it > 0 } else null
            }
    } catch (e: Exception) {
        null
    }

    /// Export › Save to device: asks the user where to save [name] (the
    /// system's create-document screen, suggested name and type [mime]),
    /// then copies the file at [path] there (onSaveTargetPicked). Only a
    /// regular file whose real path lies in the app's cache, where the
    /// export is written, is ever copied (cachedFile): never the database
    /// or anything else the app keeps. Answers {status:
    /// ok|cancelled|busy|unavailable|failed}.
    private fun saveFile(path: String?, name: String?, mime: String?, result: MethodChannel.Result) {
        if (saves.isOpen) {
            result.success(saveAnswer("busy"))
            return
        }
        val source = cachedFile(path)
        if (source == null) {
            result.success(saveAnswer("failed"))
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime?.takeIf { it.isNotBlank() } ?: "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, baseName(name) ?: source.name)
        }
        val call = saves.open { result.success(it) } ?: return result.success(saveAnswer("busy"))
        saveCall = call
        pendingSaveSource = source
        try {
            startActivityForResult(intent, SAVE_REQUEST)
        } catch (e: Exception) {
            pendingSaveSource = null
            saves.answer(call, saveAnswer("unavailable"))
        }
    }

    private fun saveAnswer(status: String): Map<String, Any> = mapOf("status" to status)

    /// The regular file at [path] in the app's cache; null for anything
    /// else (IntakeRules.regularFileIn).
    private fun cachedFile(path: String?): File? = IntakeRules.regularFileIn(cacheDir, path)

    /// The user picked where to save, or backed out (IntakeRules.saveStep).
    /// COPY: the checked source (checked again) goes into the new document
    /// off the UI thread, opened only in a truncating mode
    /// (IntakeRules.SAVE_MODES); a failed copy removes the document rather
    /// than leave an empty or partial file. The copy deletes its source as
    /// it opens it (IntakeRules.openSaveSource), so no export stays in the
    /// cache whatever happens next. DISCARD: the document exists but its
    /// source is gone, so it is removed. The open call, if any, is
    /// answered; with none (Android recreated the activity while the screen
    /// was up) the copy still finishes, from the source saved in the
    /// activity's state, since the user did choose a place for it, and its
    /// result waits for the restarted app (answerSave); a cancel deletes
    /// the source here: its caller, which would have, is gone
    /// (IntakeRules.dropSaveSource).
    private fun onSaveTargetPicked(resultCode: Int, data: Intent?) {
        val call = if (saves.isOpen) saveCall else null
        val uri = data?.data
        val source = pendingSaveSource
        pendingSaveSource = null
        val step = IntakeRules.saveStep(resultCode == Activity.RESULT_OK, uri != null, source != null)
        if (step == IntakeRules.SaveStep.CANCEL || uri == null) {
            IntakeRules.dropSaveSource(cacheDir, source?.path, call != null)
            call?.let { saves.answer(it, saveAnswer("cancelled")) }
            return
        }
        if (step == IntakeRules.SaveStep.DISCARD || source == null) {
            discardDocument(uri)
            answerSave(call, "failed")
            return
        }
        if (call == null) lateSave.started()
        Thread {
            val ok = try {
                val input = IntakeRules.openSaveSource(cacheDir, source.path) ?: throw IllegalStateException()
                input.use { inp ->
                    val out = IntakeRules.firstStream(IntakeRules.SAVE_MODES) { contentResolver.openOutputStream(uri, it) }
                    out?.use { o -> inp.copyTo(o, 64 * 1024) } != null
                }
            } catch (e: Exception) {
                false
            }
            if (!ok) discardDocument(uri)
            runOnUiThread { answerSave(call, if (ok) "ok" else "failed") }
        }.start()
    }

    /// A save's [status] to its open call [call]; with none (the call died
    /// with its engine), to the restarted app, which asks for it once
    /// ("takeSaveResult") and says so (LateSaveResult).
    private fun answerSave(call: Long?, status: String) {
        if (call != null) saves.answer(call, saveAnswer(status)) else lateSave.finished(status)
    }

    /// Removes a document the create-document screen just made (best
    /// effort): no empty or partial file is left where the user saves.
    private fun discardDocument(uri: Uri) {
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (e: Exception) {
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            PICK_REQUEST -> onFilesPicked(resultCode, data)
            PHOTO_PICK_REQUEST -> onPhotosPicked(resultCode, data)
            SAVE_REQUEST -> onSaveTargetPicked(resultCode, data)
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun onFilesPicked(resultCode: Int, data: Intent?) {
        val reply = pickReply ?: return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pickReply = null
            reply.success(mapOf("status" to "cancelled"))
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        // Copying a few MB off the UI thread; the reply goes back on it.
        // The call stays open until then (pickFiles answers busy): every
        // pick copies into the same folder, which a second pick would
        // empty while this one still writes it. Dart keeps Import busy
        // from the pick until it has read the copies.
        Thread {
            val dir = File(cacheDir, "picked").apply {
                deleteRecursively()
                mkdirs()
            }
            val paths = mutableListOf<String>()
            var tooBig = 0
            var failed = 0
            uris.forEachIndexed { i, uri ->
                val out = File(dir, "picked-$i.json")
                when (copyAtMost(uri, out, MAX_BYTES)) {
                    Copied.OK -> paths.add(out.absolutePath)
                    Copied.TOO_BIG -> {
                        out.delete()
                        tooBig++
                    }
                    Copied.FAILED -> {
                        out.delete()
                        failed++
                    }
                }
            }
            runOnUiThread {
                if (pickReply === reply) pickReply = null
                reply.success(
                    mapOf("status" to "ok", "paths" to paths, "tooBig" to tooBig, "failed" to failed),
                )
            }
        }.start()
    }

    /// What copying one picked or shared file came to.
    private enum class Copied { OK, TOO_BIG, FAILED }

    /// Copies [uri] to [out]. TOO_BIG: a file over [limit] bytes, by its
    /// declared size when the provider gives one, and by counting while
    /// copying in any case. FAILED: it could not be read or written (a
    /// cloud file that cannot be fetched now, a grant the provider
    /// refuses, a full disk), whatever its size. A provider that answers
    /// without a size column is copied and counted.
    private fun copyAtMost(uri: Uri, out: File, limit: Long): Copied {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.SIZE)
                if (i >= 0 && c.moveToFirst() && !c.isNull(i) && c.getLong(i) > limit) return Copied.TOO_BIG
            }
            val input = contentResolver.openInputStream(uri) ?: return Copied.FAILED
            input.use { inp ->
                out.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = inp.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > limit) return Copied.TOO_BIG
                        o.write(buf, 0, n)
                    }
                }
            }
            return Copied.OK
        } catch (e: Exception) {
            return Copied.FAILED
        }
    }

    private companion object {
        const val CHANNEL = "dev.calorietracker/background"
        const val FILES_CHANNEL = "dev.calorietracker/files"

        /// lib/services/analysis_keep_alive.dart keepAliveChannelName.
        const val KEEP_ALIVE_CHANNEL = "dev.calorietracker/keepalive"

        /// lib/ui/app.dart systemBarsChannelName.
        const val SYSTEM_BARS_CHANNEL = "dev.calorietracker/systembars"

        /// lib/services/settings/app_language_sync.dart appLanguageChannelName.
        const val APP_LANGUAGE_CHANNEL = "dev.calorietracker/applanguage"
        const val PICK_REQUEST = 4207
        const val PHOTO_PICK_REQUEST = 4208
        const val SAVE_REQUEST = 4209
        const val MAX_BYTES = 100L * 1024 * 1024

        /// Under cacheDir; share_intake.dart's androidShareFolderName.
        const val SHARE_FOLDER = "shared_photos"

        /// Under cacheDir: pickImages' copies, one folder each.
        const val PICKED_PHOTO_FOLDER = "picked_photos"

        /// Dart's maxPhotoBytes: share intake refuses anything larger.
        const val MAX_SHARE_BYTES = 25L * 1024 * 1024

        /// Saved state: the cached file an open create-document screen
        /// was asked for (onSaveTargetPicked).
        const val STATE_SAVE_SOURCE = "chopstats.saveFile.source"

        /// Saved state: whether the home screen made the activity's first
        /// start and its latest (homeStarts), and whether another activity
        /// of its task covered it (coveredInTask). 1.7.1 saved
        /// "chopstats.back.launcherTask" instead; nothing here reads it,
        /// since an update stops the app and finishes its activities,
        /// saved state and all, and a task reopened from Recents after that
        /// starts a new activity with none.
        const val STATE_FIRST_HOME_START = "chopstats.back.firstHomeStart"
        const val STATE_LATEST_HOME_START = "chopstats.back.latestHomeStart"
        const val STATE_COVERED_IN_TASK = "chopstats.back.coveredInTask"
    }
}
