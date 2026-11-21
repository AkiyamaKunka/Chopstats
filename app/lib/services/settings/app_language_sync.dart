/// Android 13 and later: the app's Language row and Android's per-app
/// language (Settings › Apps › Chopstats › Language) are one setting.
///
/// res/xml/locales_config.xml names the app's two languages, so Android 13
/// and later list Chopstats there. Either side can change the language:
/// - A pick in the app (settings.app_language) goes to Android
///   (MainActivity "set": LocaleManager.setApplicationLocales, with the
///   region of the phone's own locale in the language: en-GB on a British
///   phone); Follow system clears Android's.
/// - A pick in Android's settings becomes the app's own, and the Language
///   row shows it. It is read at the app's launch, before the first frame
///   (di.dart); when Android hands the running app new locales
///   (didChangeLocales: MainActivity takes that configuration change
///   itself, so it is never recreated for it and nothing on screen is
///   lost); and when the app comes back to the front, since a pick that
///   changes none of the app's locales sends no change.
///
/// Once the app has a language of its own, Android puts it first in the
/// app's locales and takes the FlutterView's 12/24-hour clock from it, so
/// each round also reads what the phone itself is set to ([PhoneSettings],
/// MainActivity "phone"): the restaurant assist takes the phone's region
/// from the phone's own languages (meal_assist.dart phoneRegion), and the
/// app's times follow the phone's own clock (format.dart). MainActivity
/// asks for a round when the phone's 12/24-hour switch changes.
///
/// Which side changed is told by the language the two last agreed on
/// ([appLanguageAndroidPrefsKey]): Android's differs from it after a pick
/// in Android's settings, the app's after a pick in the app. Without one
/// for this install, a language Android already keeps wins, and otherwise
/// the app's goes to Android. So at this version's first launch a language
/// picked in the app before stays (no earlier version told Android), and
/// so does one in preferences that came from another install (a backup
/// restored after a reinstall, a new phone): their agreement carries that
/// install's first-install time, and Android may keep no language for the
/// app here.
///
/// Android 15 and later keep the first-install time across an uninstall
/// that keeps the app's data (the uninstall dialog offers it:
/// hasFragileUserData), but drop the app's language. So the agreement also
/// carries when the version it was agreed under was installed, and which
/// version that was: the same version installed again since, with no
/// language left in Android, counts as no agreement, and the language
/// picked stays. A newer version installed after such an uninstall reads
/// as an update: the app then follows the system, as Android's setting
/// says. A language set to System default in Android's settings is never
/// undone by an update.
///
/// Android 12 and lower have no per-app language: MainActivity answers
/// null and nothing is read or written. Built for the app's own engine on
/// Android only (di.dart); iOS is unchanged. The background engine writes
/// nothing: for its own run it takes a language picked in Android's
/// settings since the app last ran ([backgroundAppLanguage]), which the
/// app takes at its next launch.
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, Locale, WidgetsBinding, WidgetsBindingObserver;
import 'package:shared_preferences/shared_preferences.dart';

import '../photo/background_restriction.dart' show backgroundRestrictionChannel;
import 'app_settings.dart';

/// MainActivity.APP_LANGUAGE_CHANNEL.
const String appLanguageChannelName = 'dev.calorietracker/applanguage';

/// The language the app and Android last agreed on, with the install it
/// was agreed under: this install's first-install time, then when the
/// version installed was installed and its version code
/// ('zh@1732000000000@1732500000000@10'). Written without them when they
/// could not be read ('zh').
const String appLanguageAndroidPrefsKey = 'app_language.android_agreed';

/// The app's language settings (AppSettings.appLanguage).
const Set<String> _languages = {'system', 'en', 'zh'};

/// The app's language setting for Android's per-app language [tags]
/// (language tags, comma-separated, the preferred first): 'en' or 'zh' by
/// the first tag's language, whatever its script or region ('zh-Hans-CN',
/// 'en-GB'); 'system' for none, or for a language the app does not have.
String appLanguageOfTags(String tags) =>
    switch (tags.split(',').first.trim().split(RegExp('[-_]')).first
        .toLowerCase()) {
      'en' => 'en',
      'zh' => 'zh',
      _ => 'system',
    };

/// The language tags Android is given for the app's [appLanguage]: one of
/// res/xml/locales_config.xml's, or none ('') for 'system'. MainActivity
/// adds the region of the phone's own locale in that language.
String tagsOfAppLanguage(String appLanguage) => switch (appLanguage) {
      'en' => 'en',
      'zh' => 'zh',
      _ => '',
    };

/// The background engine's language for one run (background_glue.dart):
/// the app's [stored] setting, or a language picked for the app in
/// Android's settings since the app engine last agreed one with Android
/// ([agreed], the stored agreement). Android 13 and later put that
/// language first in the app's locales ([first], the engine's first
/// locale), and System default picked there leaves the phone's first. Only
/// an explicit 'en' or 'zh' goes stale this way ('system' follows those
/// locales already), and only while the app's side still says what was
/// agreed (a pick in the app since then is newer). With no agreement
/// (Android 12 and lower, or the app never ran this version), [stored].
String backgroundAppLanguage(String stored, {String? agreed, Locale? first}) {
  if (agreed == null || first == null) return stored;
  if (stored != 'en' && stored != 'zh') return stored;
  if (agreed.split('@').first != stored) return stored;
  final android = appLanguageOfTags(first.toLanguageTag());
  return android == 'en' || android == 'zh' ? android : stored;
}

/// What the phone itself is set to on Android 13 and later, which the
/// app's own language hides from the app engine (MainActivity "phone"), as
/// the app engine's sync last read it. Null below Android 13, on iOS, in
/// the background engine, before the first answer, or without one.
abstract final class PhoneSettings {
  /// The phone's own languages as language tags, the preferred first
  /// (LocaleManager.getSystemLocales): the restaurant assist's region
  /// (meal_assist.dart phoneRegion). The app's locales start with the
  /// app's own language, which Android's picker gives a region.
  static List<String>? locales;

  /// The phone's own 12/24-hour clock: its 'Use 24-hour format' switch,
  /// or with 'Use locale default' its own first language's. Flutter's
  /// (MediaQuery.alwaysUse24HourFormat) follows the app's language there:
  /// English on a Chinese phone read 12-hour (format.dart).
  static final ValueNotifier<bool?> use24HourClock = ValueNotifier(null);

  @visibleForTesting
  static void reset() {
    locales = null;
    use24HourClock.value = null;
  }
}

/// The install the agreement was made under (MainActivity "installTimes"):
/// first installed, last installed (an update or the same version again),
/// and the version code installed then.
typedef _Install = ({int? firstInstall, int? lastUpdate, int? versionCode});

class AppLanguageSync with WidgetsBindingObserver {
  /// Keeps [_settings]' language and Android's in step once [start]ed.
  AppLanguageSync(this._settings,
      {Future<SharedPreferences> Function()? prefs,
      this._channel = const MethodChannel(appLanguageChannelName),
      this._installChannel = backgroundRestrictionChannel})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final AppSettings _settings;
  final Future<SharedPreferences> Function() _prefs;
  final MethodChannel _channel;
  final MethodChannel _installChannel;

  /// The app engine's sync (startForApp).
  static AppLanguageSync? _app;

  /// Starts the app engine's sync for [settings] (di.dart, Android only)
  /// and returns once its first round is done, so the first frame is in
  /// the language agreed. A second start in the same run (startup tried
  /// again after a later step failed) stops the first one.
  static Future<void> startForApp(AppSettings settings) async {
    _app?.stop();
    final sync = _app = AppLanguageSync(settings);
    await sync.start();
  }

  /// The app's language as last seen, so only a change of the language
  /// itself starts a round ([_onSettingsChanged]).
  String? _seen;

  /// The last round started: each waits for the one before it.
  Future<void> _tail = Future<void>.value();

  /// This install as MainActivity tells it, read once per run.
  Future<_Install?>? _install;

  /// Listens to the settings, to the app's binding and to MainActivity,
  /// and returns once the first round is done. Never throws.
  Future<void> start() async {
    _seen = _settings.appLanguage;
    _settings.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_onCall);
    await _round();
  }

  /// Stops listening; a round already running still finishes.
  void stop() {
    _settings.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
  }

  /// A pick in the app. (Android's, which [_sync] writes, it marks seen
  /// first.)
  void _onSettingsChanged() {
    final now = _settings.appLanguage;
    if (now == _seen) return;
    _seen = now;
    unawaited(_round());
  }

  /// Android handed the app new locales: a pick in Android's settings, or
  /// the app's own pick arriving.
  @override
  void didChangeLocales(List<Locale>? locales) => unawaited(_round());

  /// Back from Android's settings, where a pick may have changed none of
  /// the app's locales (the system's language picked), so none came.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_round());
  }

  /// MainActivity: the phone's 12/24-hour switch changed
  /// (clockFormatObserver), which the FlutterView reports as the app's
  /// language has it.
  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'phoneChanged') unawaited(_round());
    return null;
  }

  /// One round after those before it, never two at once. Never throws.
  Future<void> _round() =>
      _tail = _tail.then((_) => _sync()).then((_) {}, onError: (Object _) {});

  Future<void> _sync() async {
    await _readPhone();
    final android = await _androidLanguage();
    if (android == null) return; // Android 12 and lower, or no answer
    final stored = (await _prefs()).getString(appLanguageAndroidPrefsKey);
    final install = await _thisInstall();
    final agreed = _agreed(stored, install, android: android);
    final app = _settings.appLanguage;
    final pickedInAndroid =
        agreed == null ? android != 'system' : android != agreed;
    if (pickedInAndroid) {
      // The setting first, then the agreement: a round cut short in
      // between finds Android's pick again next time, never the app's old
      // one to send back.
      if (app != android) {
        _seen = android;
        await _settings.setAppLanguage(android);
      }
      await _agree(android, install);
    } else if (app != android) {
      if (await _set(app)) await _agree(app, install);
    } else if (agreed == null ||
        (install != null && stored != _agreement(app, install))) {
      // In step, with no agreement for this install yet, or one made
      // under an earlier install of it (an update since): agreed as of
      // now, so the same version installed again is told by it. (An
      // install that cannot be read leaves an agreement as it is.)
      await _agree(app, install);
    }
  }

  /// What the phone itself is set to (MainActivity "phone") into
  /// [PhoneSettings]: null for both below Android 13 or without an answer.
  Future<void> _readPhone() async {
    Object? phone;
    try {
      phone = await _channel.invokeMethod<Object?>('phone');
    } catch (_) {
      phone = null;
    }
    final locales = phone is Map ? phone['locales'] : null;
    final use24h = phone is Map ? phone['use24h'] : null;
    PhoneSettings.locales = locales is String && locales.trim().isNotEmpty
        ? [for (final tag in locales.split(',')) tag.trim()]
        : null;
    PhoneSettings.use24HourClock.value = use24h is bool ? use24h : null;
  }

  /// Android's per-app language as the app's setting ([appLanguageOfTags]),
  /// or null below Android 13 or without an answer.
  Future<String?> _androidLanguage() async {
    try {
      final tags = await _channel.invokeMethod<Object?>('get');
      return tags is String ? appLanguageOfTags(tags) : null;
    } catch (_) {
      return null;
    }
  }

  /// Sets Android's per-app language to the app's [language]; true when
  /// MainActivity did.
  Future<bool> _set(String language) async {
    try {
      final done = await _channel.invokeMethod<Object?>(
          'set', {'tags': tagsOfAppLanguage(language)});
      return done == true;
    } catch (_) {
      return false;
    }
  }

  /// The language last agreed on for this install in [stored], or null:
  /// none yet, one written by an install with another first-install time,
  /// or one agreed before the same version was installed again while
  /// [android] keeps no language for the app (Android 15 and later keep
  /// the first-install time across an uninstall that keeps the data, and
  /// drop the app's language). One written without the install (it could
  /// not be read) is taken as it is.
  static String? _agreed(String? stored, _Install? install,
      {required String android}) {
    if (stored == null) return null;
    final parts = stored.split('@');
    final language = parts.first;
    if (!_languages.contains(language)) return null;
    int? part(int i) => parts.length > i ? int.tryParse(parts[i]) : null;
    final first = part(1), installed = part(2), version = part(3);
    final now = install;
    if (now == null) return language;
    if (first != null &&
        now.firstInstall != null &&
        first != now.firstInstall) {
      return null;
    }
    if (android == 'system' &&
        language != 'system' &&
        installed != null &&
        version != null &&
        now.lastUpdate != null &&
        now.lastUpdate != installed &&
        now.versionCode == version) {
      return null;
    }
    return language;
  }

  /// The agreement on [language] as stored for [install].
  static String _agreement(String language, _Install? install) {
    if (install == null || install.firstInstall == null) return language;
    final marker = install.lastUpdate == null || install.versionCode == null
        ? ''
        : '@${install.lastUpdate}@${install.versionCode}';
    return '$language@${install.firstInstall}$marker';
  }

  Future<void> _agree(String language, _Install? install) async {
    await (await _prefs())
        .setString(appLanguageAndroidPrefsKey, _agreement(language, install));
  }

  /// This install (MainActivity "installTimes", PackageInfo), or null when
  /// it cannot be read.
  Future<_Install?> _thisInstall() => _install ??= () async {
        try {
          final times =
              await _installChannel.invokeMethod<Object?>('installTimes');
          if (times is! Map) return null;
          int? of(String key) => times[key] is int ? times[key] as int : null;
          final first = of('firstInstall');
          if (first == null) return null;
          return (
            firstInstall: first,
            lastUpdate: of('lastUpdate'),
            versionCode: of('versionCode'),
          );
        } catch (_) {
          return null;
        }
      }();
}
