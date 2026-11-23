/// Android 13 and later's per-app language and the app's Language row are
/// one setting (app_language_sync.dart): a pick on either side shows on
/// the other, a language picked in the app before this version stays, and
/// Android 12 and lower see nothing new. What the phone itself is set to,
/// which the app's language hides from the app, is read for it.
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

  /// What "phone" answers: the phone's own languages and clock; null, as
  /// below Android 13.
  Map<String, Object?>? phone;

  /// "phone" calls answered.
  int phones = 0;

  int firstInstall = 1732000000000;

  /// When this install's version was installed, and which version that is.
  int lastUpdate = 1732000000005;
  int versionCode = 10;

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
      case 'phone':
        phones++;
        return phone;
    }
    throw MissingPluginException();
  }

  /// When set, "installTimes" fails.
  bool installUnreadable = false;

  Future<Object?> install(MethodCall call) async {
    if (broken || installUnreadable) {
      throw PlatformException(code: 'unavailable');
    }
    if (call.method != 'installTimes') throw MissingPluginException();
    return {
      'firstInstall': firstInstall,
      'lastUpdate': lastUpdate,
      'versionCode': versionCode,
    };
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
    PhoneSettings.reset();
  });

  /// MainActivity's clockFormatObserver: the phone's 12/24-hour switch
  /// changed.
  Future<void> phoneChanged() => messenger.handlePlatformMessage(
      appLanguageChannelName,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('phoneChanged')),
      (_) {});

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

  /// The agreement on [language] as this install stores it.
  String agreed(String language) => '$language@${android.firstInstall}'
      '@${android.lastUpdate}@${android.versionCode}';

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

  // Review of PR 79 (F2): a language picked in Android's settings reached
  // only the app engine, at its next launch. Until then the background
  // engine wrote meal cards, channel names and the model's meal names in
  // the language just turned off. It takes the pick for its run, and
  // writes nothing.
  group("the background engine's language", () {
    const zhCN = Locale.fromSubtags(
        languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN');

    test("a language picked in Android's settings since the agreement", () {
      expect(backgroundAppLanguage('en', agreed: 'en@1@2@3', first: zhCN),
          'zh');
      expect(
          backgroundAppLanguage('zh',
              agreed: 'zh@1@2@3', first: const Locale('en', 'GB')),
          'en');
      // System default picked there: the phone's language.
      expect(
          backgroundAppLanguage('zh',
              agreed: 'zh', first: const Locale('en', 'US')),
          'en');
    });

    test('nothing picked since: the stored language', () {
      expect(backgroundAppLanguage('zh', agreed: 'zh@1@2@3', first: zhCN),
          'zh');
      expect(
          backgroundAppLanguage('en',
              agreed: 'en@1@2@3', first: const Locale('en', 'GB')),
          'en');
      // A language the app does not have first: Follow system, which the
      // stored language already resolves to for every such phone.
      expect(
          backgroundAppLanguage('en',
              agreed: 'en@1@2@3', first: const Locale('fr', 'FR')),
          'en');
    });

    test('no agreement, Follow system, or a pick in the app since: the '
        'stored language', () {
      // Android 12 and lower, or the app has not run this version yet.
      expect(backgroundAppLanguage('en', first: zhCN), 'en');
      expect(backgroundAppLanguage('en', agreed: 'en@1@2@3'), 'en');
      // 'system' follows the engine's locales already.
      expect(
          backgroundAppLanguage('system', agreed: 'system@1@2@3', first: zhCN),
          'system');
      // Picked in the app after the agreement (its round cut short): the
      // app's pick is the newer one.
      expect(backgroundAppLanguage('en', agreed: 'system@1@2@3', first: zhCN),
          'en');
      expect(backgroundAppLanguage('en', agreed: 'zh@1@2@3', first: zhCN),
          'en');
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
      expect(PhoneSettings.locales, isNull);
      expect(PhoneSettings.use24HourClock.value, isNull);
    });

    // Review of PR 79 (F2, keep data): Android 15 and later keep the
    // first-install time across an uninstall that keeps the app's data,
    // but drop the app's language. The agreement still matched this
    // install's time, so Android's empty language read as System default
    // picked there, and the user's 中文 went back to Follow system.
    test('the same version installed again after an uninstall that kept the '
        "data: the language picked stays, and Android gets it", () async {
      android.tags = '';
      final before = agreed('zh');
      android.lastUpdate += 86400000; // installed again a day later
      final (settings, prefs) = await started({
        'settings.app_language': 'zh',
        appLanguageAndroidPrefsKey: before,
      });
      expect(settings.appLanguage, 'zh');
      expect(android.sets, ['zh']);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('zh'));
    });

    test("System default picked in Android's settings, then an update before "
        'the app ran: still System default', () async {
      android.tags = '';
      final before = agreed('zh');
      android.lastUpdate += 86400000;
      android.versionCode++;
      final (settings, prefs) = await started({
        'settings.app_language': 'zh',
        appLanguageAndroidPrefsKey: before,
      });
      expect(settings.appLanguage, 'system');
      expect(android.sets, isEmpty);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('system'));
    });

    test('in step after an update: the agreement is renewed for it, and '
        'nothing is sent', () async {
      android.tags = 'zh-Hans-CN';
      final before = agreed('zh');
      android.lastUpdate += 86400000;
      android.versionCode++;
      final (settings, prefs) = await started({
        'settings.app_language': 'zh',
        appLanguageAndroidPrefsKey: before,
      });
      expect(settings.appLanguage, 'zh');
      expect(android.sets, isEmpty);
      final renewed = prefs.getString(appLanguageAndroidPrefsKey);
      expect(renewed, agreed('zh'));

      // So a later uninstall that keeps the data, and the same version
      // installed again, is told apart from System default picked.
      android.tags = '';
      android.lastUpdate += 86400000;
      final (again, _) = await started({
        'settings.app_language': 'zh',
        appLanguageAndroidPrefsKey: renewed!,
      });
      expect(again.appLanguage, 'zh');
      expect(android.sets, ['zh']);
    });

    test('an agreement stored before the install was noted with it is noted '
        'with it when in step', () async {
      android.tags = 'en-GB';
      final (_, prefs) = await started({
        'settings.app_language': 'en',
        appLanguageAndroidPrefsKey: 'en@${android.firstInstall}',
      });
      expect(android.sets, isEmpty);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('en'));
    });

    test('an install that cannot be read leaves the agreement as it is',
        () async {
      android.tags = 'en-GB';
      android.installUnreadable = true;
      final (settings, prefs) = await started({
        'settings.app_language': 'en',
        appLanguageAndroidPrefsKey: agreed('en'),
      });
      expect(settings.appLanguage, 'en');
      expect(android.sets, isEmpty);
      expect(prefs.getString(appLanguageAndroidPrefsKey), agreed('en'));
    });
  });

  // Review of PR 79 (F1, F1-region, F3): once the app has a language of
  // its own, Android puts it first in the app's locales and takes the
  // FlutterView's 12/24-hour clock from it. Each round reads what the
  // phone itself is set to, for the restaurant assist's region and the
  // app's clock.
  group('what the phone itself is set to', () {
    test('read before the first frame', () async {
      android.phone = {'locales': 'en-GB,zh-Hans-CN', 'use24h': true};
      await started({'settings.app_language': 'zh'});
      expect(PhoneSettings.locales, ['en-GB', 'zh-Hans-CN']);
      expect(PhoneSettings.use24HourClock.value, isTrue);
    });

    test('read again on resume, with new locales, and when the phone\'s '
        '12/24-hour switch changes', () async {
      android.phone = {'locales': 'en-GB', 'use24h': true};
      await started();
      android.phone = {'locales': 'en-US', 'use24h': false};
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle();
      expect(PhoneSettings.locales, ['en-US']);
      expect(PhoneSettings.use24HourClock.value, isFalse);

      android.phone = {'locales': 'zh-Hans-CN,en-US', 'use24h': true};
      binding.platformDispatcher.localesTestValue = const [Locale('zh', 'CN')];
      await _settle();
      expect(PhoneSettings.locales, ['zh-Hans-CN', 'en-US']);
      expect(PhoneSettings.use24HourClock.value, isTrue);

      // MainActivity's clock observer: 'Use 24-hour format' turned off
      // while the app is in front.
      android.phone = {'locales': 'zh-Hans-CN,en-US', 'use24h': false};
      final before = android.phones;
      await phoneChanged();
      await _settle();
      expect(android.phones, before + 1);
      expect(PhoneSettings.use24HourClock.value, isFalse);
    });

    test('no answer (Android 12 and lower), or none that tells: nothing',
        () async {
      android.tags = null;
      await started();
      expect(PhoneSettings.locales, isNull);
      expect(PhoneSettings.use24HourClock.value, isNull);

      android.phone = {'locales': '', 'use24h': null};
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle();
      expect(PhoneSettings.locales, isNull);
      expect(PhoneSettings.use24HourClock.value, isNull);
    });

    test('once stopped, the clock observer starts no round', () async {
      final (settings, prefs, _) = await freshSettings();
      final sync = AppLanguageSync(settings, prefs: () async => prefs);
      await sync.start();
      sync.stop();
      final before = android.phones;
      await phoneChanged();
      await _settle();
      expect(android.phones, before);
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
