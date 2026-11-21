/// Android 13 and later's per-app language and the app's Language row are
/// one setting (app_language_sync.dart): a pick on either side shows on
/// the other, a language picked in the app before this version stays, and
/// Android 12 and lower see nothing new.
library;

import 'package:calorie_tracker/services/photo/background_restriction.dart'
    show backgroundRestrictionChannel;
import 'package:calorie_tracker/services/settings/app_language_sync.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings_test.dart' show freshSettings;

/// MainActivity's side of the language channel and of "installTimes", as
/// the tests see it.
class _Android {
  /// Android's per-app language as "get" answers it: language tags, ''
  /// for none; null, as below Android 13.
  String? tags = '';

  /// The tags of every "set", in order.
  final List<String> sets = [];

  /// "get" calls answered.
  int gets = 0;

  /// When set, "set" answers false and changes nothing.
  bool refuse = false;

  /// When set, every call fails.
  bool broken = false;

  int firstInstall = 1732000000000;

  Future<Object?> language(MethodCall call) async {
    if (broken) throw PlatformException(code: 'unavailable');
    switch (call.method) {
      case 'get':
        gets++;
        return tags;
      case 'set':
        final sent = (call.arguments as Map)['tags'] as String;
        sets.add(sent);
        if (refuse) return false;
        tags = sent;
        return true;
    }
    throw MissingPluginException();
  }

  Future<Object?> install(MethodCall call) async {
    if (broken) throw PlatformException(code: 'unavailable');
    if (call.method != 'installTimes') throw MissingPluginException();
    return {'firstInstall': firstInstall, 'lastUpdate': firstInstall + 5};
  }
}

/// Lets the rounds' channel calls and preference writes run.
Future<void> _settle() => pumpEventQueue(times: 50);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const languageChannel = MethodChannel(appLanguageChannelName);
  late _Android android;

  setUp(() {
    android = _Android();
    messenger.setMockMethodCallHandler(languageChannel, android.language);
    messenger.setMockMethodCallHandler(
        backgroundRestrictionChannel, android.install);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(languageChannel, null);
    messenger.setMockMethodCallHandler(backgroundRestrictionChannel, null);
    binding.platformDispatcher.clearLocalesTestValue();
  });

  /// The app's settings as [initial] preferences hold them, and a started
  /// sync over them, stopped after the test.
  Future<(AppSettings, SharedPreferences)> started(
      [Map<String, Object> initial = const {}]) async {
    final (settings, prefs, _) = await freshSettings(initial: initial);
    final sync = AppLanguageSync(settings, prefs: () async => prefs);
    addTearDown(sync.stop);
    await sync.start();
    return (settings, prefs);
  }

  String agreed(String language) => '$language@${android.firstInstall}';

  group('the tags', () {
    test("Android's tags read as the app's language by the first one's "
        'language, whatever its script or region', () {
      expect(appLanguageOfTags(''), 'system');
      expect(appLanguageOfTags('en'), 'en');
      expect(appLanguageOfTags('en-GB'), 'en');
      expect(appLanguageOfTags('en_US'), 'en');
      expect(appLanguageOfTags('zh'), 'zh');
      expect(appLanguageOfTags('zh-Hans-CN'), 'zh');
      expect(appLanguageOfTags('zh-TW'), 'zh');
      expect(appLanguageOfTags(' ZH-cn ,en'), 'zh');
      expect(appLanguageOfTags('en-US,zh-CN'), 'en');
      // A language the app does not have reads as Follow system, whatever
      // comes after it: the app then shows what Flutter resolves from the
      // locales Android hands it.
      expect(appLanguageOfTags('fr-FR'), 'system');
      expect(appLanguageOfTags('fr-FR,zh-CN'), 'system');
      expect(appLanguageOfTags('und'), 'system');
    });

    test('the app gives Android its own language, or none', () {
      expect(tagsOfAppLanguage('en'), 'en');
      expect(tagsOfAppLanguage('zh'), 'zh');
      expect(tagsOfAppLanguage('system'), '');
      expect(tagsOfAppLanguage('fr'), '');
    });
  });

  test('Android 12 and lower: nothing is read, sent or written', () async {
    android.tags = null;
    final (settings, prefs) = await started({'settings.app_language': 'zh'});
    expect(settings.appLanguage, 'zh');
    expect(android.sets, isEmpty);
    expect(prefs.getString(appLanguageAndroidPrefsKey), isNull);
    await settings.setAppLanguage('en');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle();
    expect(android.sets, isEmpty);
    expect(prefs.getString(appLanguageAndroidPrefsKey), isNull);
  });

  group('at launch', () {
    test("this version's first launch hands Android the language picked in "
        'the app before', () async {
      final (settings, prefs) = await started({'settings.app_language': 'zh'});
      expect(android.sets, ['zh']);
      expect(android.tags, 'zh');
      expect(settings.appLanguage, 'zh');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('zh'));
    });

    test('nothing picked on either side: nothing is sent', () async {
      final (settings, prefs) = await started();
      expect(android.sets, isEmpty);
      expect(settings.appLanguage, 'system');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('system'));
    });

    test('a language Android kept before the first agreement becomes the '
        "app's", () async {
      // Picked in Android's settings after the update, before the app ran.
      android.tags = 'en-US';
      final (settings, prefs) = await started({'settings.app_language': 'zh'});
      expect(settings.appLanguage, 'en');
      expect(prefs.getString('settings.app_language'), 'en');
      expect(android.sets, isEmpty);
      expect(android.tags, 'en-US', reason: "Android's own tag is kept");
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('en'));
    });

    test("a pick in Android's settings while the app was closed becomes the "
        "app's", () async {
      android.tags = 'zh-Hans-CN';
      final (settings, prefs) = await started({
        'settings.app_language': 'system',
        appLanguageAndroidPrefsKey: agreed('system'),
      });
      expect(settings.appLanguage, 'zh');
      expect(android.sets, isEmpty);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('zh'));
      await _settle();
      expect(android.gets, 1, reason: 'the language taken is not read back');
    });

    test("System default in Android's settings gives the app back to the "
        "system's language", () async {
      android.tags = '';
      final (settings, prefs) = await started({
        'settings.app_language': 'zh',
        appLanguageAndroidPrefsKey: agreed('zh'),
      });
      expect(settings.appLanguage, 'system');
      expect(android.sets, isEmpty);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('system'));
    });

    test('in step on both sides: nothing changes', () async {
      android.tags = 'en-GB';
      final (settings, prefs) = await started({
        'settings.app_language': 'en',
        appLanguageAndroidPrefsKey: agreed('en'),
      });
      expect(settings.appLanguage, 'en');
      expect(android.sets, isEmpty);
      expect(android.tags, 'en-GB');
    });

    // Preferences restored from a backup after a reinstall, or brought to
    // a new phone, carry another install's agreement, while Android there
    // may have no language for the app: the language the user picked stays
    // and goes to Android, where this install's own agreement would read
    // as System default picked.
    test("another install's agreement counts as none", () async {
      android.tags = '';
      final (settings, prefs) = await started({
        'settings.app_language': 'zh',
        appLanguageAndroidPrefsKey: 'zh@1600000000000',
      });
      expect(settings.appLanguage, 'zh');
      expect(android.sets, ['zh']);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('zh'));
    });

    test('an agreement written without an install time is taken as it is',
        () async {
      android.tags = '';
      final (settings, prefs) = await started({
        'settings.app_language': 'zh',
        appLanguageAndroidPrefsKey: 'zh',
      });
      expect(settings.appLanguage, 'system');
      expect(android.sets, isEmpty);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('system'));
    });

    test('a channel that fails changes nothing, and the launch goes on',
        () async {
      android.broken = true;
      final (settings, prefs) = await started({'settings.app_language': 'zh'});
      expect(settings.appLanguage, 'zh');
      expect(android.sets, isEmpty);
      expect(prefs.getString(appLanguageAndroidPrefsKey), isNull);
    });
  });

  group('while the app runs', () {
    test("a pick in Android's settings arrives with the new locales",
        () async {
      final (settings, prefs) = await started();
      android.tags = 'en-GB';
      binding.platformDispatcher.localesTestValue = const [Locale('en', 'GB')];
      await _settle();
      expect(settings.appLanguage, 'en');
      expect(android.sets, isEmpty, reason: 'nothing sent back');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('en'));

      android.tags = 'zh-Hans-CN';
      binding.platformDispatcher.localesTestValue = const [
        Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
        Locale('en', 'GB'),
      ];
      await _settle();
      expect(settings.appLanguage, 'zh');
      expect(android.sets, isEmpty);
    });

    test('a pick that changed none of the locales is read when the app comes '
        'back', () async {
      final (settings, _) = await started();
      android.tags = 'zh-CN';
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle();
      expect(settings.appLanguage, 'zh');
      expect(android.sets, isEmpty);
    });

    test('a pick in the app goes to Android, and Follow system clears it',
        () async {
      final (settings, prefs) = await started();
      await settings.setAppLanguage('en');
      await _settle();
      expect(android.sets, ['en']);
      expect(android.tags, 'en');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('en'));

      // Android's configuration change for it: nothing more to do.
      binding.platformDispatcher.localesTestValue = const [Locale('en')];
      await _settle();
      expect(android.sets, ['en']);
      expect(settings.appLanguage, 'en');

      await settings.setAppLanguage('zh');
      await settings.setAppLanguage('system');
      await _settle();
      expect(android.sets.last, '');
      expect(android.tags, '');
      expect(settings.appLanguage, 'system');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('system'));
    });

    test('another setting changing sends nothing', () async {
      final (settings, _) = await started();
      final gets = android.gets;
      await settings.setLookbackDays(5);
      await settings.setUnits('imperial');
      await _settle();
      expect(android.gets, gets);
      expect(android.sets, isEmpty);
    });

    test('quick picks in the app end on the last one', () async {
      final (settings, prefs) = await started();
      final first = settings.setAppLanguage('en');
      final second = settings.setAppLanguage('zh');
      await Future.wait([first, second]);
      await _settle();
      expect(android.tags, 'zh');
      expect(settings.appLanguage, 'zh');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('zh'));
    });

    test('a set Android did not make is tried again', () async {
      final (settings, prefs) = await started();
      android.refuse = true;
      await settings.setAppLanguage('zh');
      await _settle();
      expect(android.sets, ['zh']);
      expect(android.tags, '');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('system'),
          reason: 'not agreed: the app still differs from Android');
      expect(settings.appLanguage, 'zh', reason: "the app's pick stands");

      android.refuse = false;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle();
      expect(android.sets, ['zh', 'zh']);
      expect(android.tags, 'zh');
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('zh'));
    });

    test('once stopped, nothing is read or sent', () async {
      final (settings, prefs, _) = await freshSettings();
      final sync = AppLanguageSync(settings, prefs: () async => prefs);
      await sync.start();
      sync.stop();
      final gets = android.gets;
      await settings.setAppLanguage('en');
      android.tags = 'zh';
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      binding.platformDispatcher.localesTestValue = const [Locale('zh')];
      await _settle();
      expect(android.gets, gets);
      expect(android.sets, isEmpty);
      expect(settings.appLanguage, 'en');
    });
  });
}
