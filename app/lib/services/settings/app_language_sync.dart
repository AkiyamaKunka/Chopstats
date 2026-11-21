/// Android 13 and later: the app's Language row and Android's per-app
/// language (Settings › Apps › Chopstats › Language) are one setting.
///
/// res/xml/locales_config.xml names the app's two languages, so Android 13
/// and later list Chopstats there. Either side can change the language:
/// - A pick in the app (settings.app_language) goes to Android
///   (MainActivity "set": LocaleManager.setApplicationLocales); Follow
///   system clears Android's.
/// - A pick in Android's settings becomes the app's own, and the Language
///   row shows it. It is read at the app's launch, before the first frame
///   (di.dart); when Android hands the running app new locales
///   (didChangeLocales: MainActivity takes that configuration change
///   itself, so it is never recreated for it and nothing on screen is
///   lost); and when the app comes back to the front, since a pick that
///   changes none of the app's locales sends no change.
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
/// Android 12 and lower have no per-app language: MainActivity answers
/// null and nothing is read or written. Built for the app's own engine on
/// Android only (di.dart); iOS is unchanged. The background engine reads
/// the setting as it was last written.
library;

import 'dart:async' show unawaited;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, Locale, WidgetsBinding, WidgetsBindingObserver;
import 'package:shared_preferences/shared_preferences.dart';

import '../photo/background_restriction.dart' show backgroundRestrictionChannel;
import 'app_settings.dart';

/// MainActivity.APP_LANGUAGE_CHANNEL.
const String appLanguageChannelName = 'dev.calorietracker/applanguage';

/// The language the app and Android last agreed on, with the first-install
/// time of the install that wrote it: 'zh@1732000000000'.
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
/// res/xml/locales_config.xml's, or none ('') for 'system'.
String tagsOfAppLanguage(String appLanguage) => switch (appLanguage) {
      'en' => 'en',
      'zh' => 'zh',
      _ => '',
    };

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

  /// This install's first-install time, read once per run.
  Future<int?>? _install;

  /// Listens to the settings and to the app's binding, and returns once
  /// the first round is done. Never throws.
  Future<void> start() async {
    _seen = _settings.appLanguage;
    _settings.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
    await _round();
  }

  /// Stops listening; a round already running still finishes.
  void stop() {
    _settings.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
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

  /// One round after those before it, never two at once. Never throws.
  Future<void> _round() =>
      _tail = _tail.then((_) => _sync()).then((_) {}, onError: (Object _) {});

  Future<void> _sync() async {
    final android = await _androidLanguage();
    if (android == null) return; // Android 12 and lower, or no answer
    final agreed = await _agreed();
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
      await _agree(android);
    } else if (app != android) {
      if (await _set(app)) await _agree(app);
    } else if (agreed == null) {
      await _agree(app);
    }
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

  /// The language last agreed on for this install, or null: none yet, or
  /// one written by an install with another first-install time. One
  /// written without a time (it could not be read) is taken as it is.
  Future<String?> _agreed() async {
    final raw = (await _prefs()).getString(appLanguageAndroidPrefsKey);
    if (raw == null) return null;
    final at = raw.lastIndexOf('@');
    final language = at < 0 ? raw : raw.substring(0, at);
    if (!_languages.contains(language)) return null;
    final stamp = at < 0 ? null : int.tryParse(raw.substring(at + 1));
    final install = await _firstInstall();
    if (stamp != null && install != null && stamp != install) return null;
    return language;
  }

  Future<void> _agree(String language) async {
    final install = await _firstInstall();
    await (await _prefs()).setString(appLanguageAndroidPrefsKey,
        install == null ? language : '$language@$install');
  }

  /// This install's first-install time (MainActivity "installTimes",
  /// PackageInfo.firstInstallTime), or null when it cannot be read.
  Future<int?> _firstInstall() => _install ??= () async {
        try {
          final times =
              await _installChannel.invokeMethod<Object?>('installTimes');
          final first = times is Map ? times['firstInstall'] : null;
          return first is int ? first : null;
        } catch (_) {
          return null;
        }
      }();
}
