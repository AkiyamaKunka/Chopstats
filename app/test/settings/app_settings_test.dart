import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart'
    show ServerAnalyzer;
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart'
    show LookupOutcomeKind;
import 'package:calorie_tracker/services/assist/clients/server_lookup_client.dart'
    show ServerLookupClient;
import 'package:calorie_tracker/services/garmin_client.dart'
    show makeGarminDailyFetch;
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../assist/clients/support.dart' show bigMacRequest;

/// In-memory stand-in for flutter_secure_storage (no platform channel in
/// unit tests).
class MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// [MemoryKeyStore] that logs each server-key write and delete with the
/// stored address at that moment.
class _OrderedKeyStore extends MemoryKeyStore {
  _OrderedKeyStore(this.prefs);
  final SharedPreferences prefs;
  final List<String> log = [];

  String get _url => '(url ${prefs.getString('settings.server_base_url')})';

  @override
  Future<void> write(String key, String value) async {
    if (key == kServerKeyItem) {
      final (k, host) = decodeServerKeyItem(value);
      log.add('write $k for $host $_url');
    } else if (key == kLegacyServerKey) {
      log.add('old name "$value" $_url');
    }
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (key == kServerKeyItem || key == kLegacyServerKey) {
      log.add('delete $key $_url');
    }
    return super.delete(key);
  }
}

/// The secure names of the server upload key: the item this version
/// stores, and the name 1.7.0 and earlier stored the key under as plain
/// text (the only one they read).
const kServerKeyItem = 'server_api_key_item';
const kLegacyServerKey = 'server_api_key';

/// What this version leaves under the old name once the key is moved: a
/// blank, which every older version trims to no key.
const kRetiredOldName = ' ';

/// The server upload key's secure item, as AppSettings stores it: the key
/// and the host it is bound to, in one value.
(String, String?) decodeServerKeyItem(String item) {
  final m = jsonDecode(item) as Map<String, dynamic>;
  expect(m.keys.toSet(), {'key', 'host'}, reason: item);
  return (m['key'] as String, m['host'] as String?);
}

/// What [keys] holds for the server upload key: (key, host), or null. Also
/// checks that the old name holds no key, which an older version would
/// read and send as one.
(String, String?)? storedServerKey(MemoryKeyStore keys) {
  expect(keyAnOlderVersionReads(keys), isNull,
      reason: 'the old name holds no key');
  final item = keys.data[kServerKeyItem];
  return item == null ? null : decodeServerKeyItem(item);
}

/// The key [keys] keeps whose server is not known, or null.
String? storedKeyOfUnknownHost(MemoryKeyStore keys) {
  final item = keys.data[kServerKeyItem];
  if (item == null) return null;
  final m = jsonDecode(item) as Map<String, dynamic>;
  if (m['hostUnknown'] != true) return null;
  expect(m, {'key': m['key'], 'host': null, 'hostUnknown': true});
  return m['key'] as String;
}

/// What 1.7.0 (android-v1.7.0, b207) and iPhone 1.6.0 load as the server
/// upload key: the old name's text, trimmed, or none when blank
/// (610df6c6 app_settings.dart:489-490).
String? keyAnOlderVersionReads(MemoryKeyStore keys) {
  final v = keys.data[kLegacyServerKey]?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// [MemoryKeyStore] whose writes of [failWrites] throw, as a keychain or
/// Keystore write can, and whose reads of [unreadable] find nothing while
/// the value stays (AndroidSecureKeyStore forgives a failed read as no
/// key; a write still overwrites it).
class _FailingKeys extends MemoryKeyStore {
  final Set<String> failWrites = {};
  final Set<String> unreadable = {};

  @override
  Future<String?> read(String key) async =>
      unreadable.contains(key) ? null : data[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites.contains(key)) {
      throw PlatformException(code: 'write failed for $key');
    }
    return super.write(key, value);
  }
}

/// One key store under two engines: each engine's reads and writes of the
/// server upload key wait for their turn in [order] ('app' or 'run' per
/// step; any order once it runs out), every other key goes at once. [log]
/// lists the server-key operations as they ran.
class _TurnTakingKeys {
  _TurnTakingKeys(this.order);
  final List<String> order;
  final Map<String, String> data = {};
  final List<String> log = [];
  int _step = 0;

  SecureKeyStore engine(String name) => _EngineKeys(this, name);

  Future<void> _turn(String engine) async {
    while (_step < order.length && order[_step] != engine) {
      await Future<void>.delayed(Duration.zero);
    }
    _step++;
  }
}

class _EngineKeys implements SecureKeyStore {
  _EngineKeys(this._keys, this._name);
  final _TurnTakingKeys _keys;
  final String _name;

  Future<void> _op(String what, String key) async {
    if (key != kServerKeyItem && key != kLegacyServerKey) return;
    await _keys._turn(_name);
    _keys.log.add('$_name $what $key');
  }

  @override
  Future<String?> read(String key) async {
    await _op('read', key);
    return _keys.data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await _op('write', key);
    _keys.data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    await _op('delete', key);
    _keys.data.remove(key);
  }
}

/// Every order of [app] 'app' steps and [run] 'run' steps.
List<List<String>> _interleavings(int app, int run) {
  if (app == 0) return [List.filled(run, 'run')];
  if (run == 0) return [List.filled(app, 'app')];
  return [
    for (final rest in _interleavings(app - 1, run)) ['app', ...rest],
    for (final rest in _interleavings(app, run - 1)) ['run', ...rest],
  ];
}

Future<(AppSettings, SharedPreferences, MemoryKeyStore)> freshSettings(
    {Map<String, Object> initial = const {}}) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  final keys = MemoryKeyStore();
  final s = await AppSettings.load(prefs: prefs, keyStore: keys);
  return (s, prefs, keys);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults on a fresh install', () async {
    final (s, _, _) = await freshSettings();
    expect(s.geminiApiKey, isNull);
    expect(s.model, AppSettings.defaultModel);
    expect(s.lookbackDays, 2);
    expect(s.reportTime, '21:30');
    // ON by default: the summary predates its switch (2026-10-10) and
    // every existing install, the owner's included, expects it to keep
    // arriving — the switch exists so a friend can turn it OFF.
    expect(s.summaryEnabled, isTrue);
    expect(s.watcherEnabled, isFalse);
    // Meta glasses photos: per platform, below.
    expect(s.watchGlasses, AppSettings.defaultWatchGlasses);
    expect(s.dietaryProfile, isNull);
    expect(s.quotaPauseUntil, isNull);
    expect(s.isQuotaPaused, isFalse);
  });

  // Design G3 put Meta glasses photos on by default: an iPhone checks each
  // one for food on the phone before it is sent. Android has no such
  // check, so there the switch starts off (owner decision 8, 2026-11-20).
  // Only the default changes: whatever the user set is stored and wins.
  group('the Meta glasses photos default', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    for (final (platform, byDefault) in [
      (TargetPlatform.iOS, true),
      (TargetPlatform.android, false),
    ]) {
      test('${platform.name}: ${byDefault ? 'on' : 'off'} for an install '
          'that never touched the switch', () async {
        debugDefaultTargetPlatformOverride = platform;
        expect(AppSettings.defaultWatchGlasses, byDefault);
        final (s, prefs, keys) = await freshSettings(
            initial: {'settings.watcher_enabled': true});
        expect(s.watchGlasses, byDefault);
        expect(prefs.getBool('settings.watch_glasses'), isNull,
            reason: 'a default is never written, so it can still change');
        final again = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect(again.watchGlasses, byDefault);
      });

      for (final stored in [true, false]) {
        test('${platform.name}: a stored $stored wins over the default',
            () async {
          debugDefaultTargetPlatformOverride = platform;
          final (s, _, _) =
              await freshSettings(initial: {'settings.watch_glasses': stored});
          expect(s.watchGlasses, stored);
        });
      }

      test('${platform.name}: flipping the switch stores the choice, and it '
          'survives a relaunch', () async {
        debugDefaultTargetPlatformOverride = platform;
        final (s, prefs, keys) = await freshSettings();
        await s.setWatchGlasses(!byDefault);
        expect(prefs.getBool('settings.watch_glasses'), !byDefault);
        final again = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect(again.watchGlasses, !byDefault);
      });
    }
  });

  test('setters persist and a second load sees the values', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setGeminiApiKey('  sk-test-123  ');
    await s.setModel('gemini-2.5-pro');
    await s.setLookbackDays(7);
    await s.setReportTime('08:05');
    await s.setSummaryEnabled(false);
    await s.setWatcherEnabled(true);
    await s.setWatchGlasses(false);
    await s.setDietaryProfile('vegetarian, Cantonese cuisine');
    final pause = DateTime(2026, 7, 18, 9, 30);
    await s.setQuotaPauseUntil(pause);

    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.geminiApiKey, 'sk-test-123');
    expect(again.model, 'gemini-2.5-pro');
    expect(again.lookbackDays, 7);
    expect(again.reportTime, '08:05');
    expect(again.summaryEnabled, isFalse, reason: 'off survives a relaunch');
    expect(again.watcherEnabled, isTrue);
    expect(again.watchGlasses, isFalse);
    expect(prefs.getBool('settings.watch_glasses'), isFalse,
        reason: 'the key the design names');
    expect(again.dietaryProfile, 'vegetarian, Cantonese cuisine');
    expect(again.quotaPauseUntil, pause);
  });

  test('the quota pause is stored as a UTC instant and read back local',
      () async {
    // Zone-less, a pause armed in Shanghai re-parsed in Chicago and lasted
    // 13 hours longer after the flight.
    final (s, prefs, keys) = await freshSettings();
    final pause = DateTime(2026, 10, 20, 11, 30);
    await s.setQuotaPauseUntil(pause);
    final stored = prefs.getString('settings.quota_pause_until')!;
    expect(stored, endsWith('Z'));
    expect(DateTime.parse(stored).isAtSameMomentAs(pause), isTrue);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.quotaPauseUntil, pause); // same instant, local again
  });

  test('CHANGING the key clears the quota-pause latch; re-saving it does not',
      () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setGeminiApiKey('key-A');
    final pause = DateTime.now().add(const Duration(hours: 6));
    await s.setQuotaPauseUntil(pause);

    // Same key re-entered: the pause still belongs to it — keep the latch.
    await s.setGeminiApiKey('key-A');
    expect(s.quotaPauseUntil, pause);

    // Different key: fresh project, fresh quota — a stale latch here means
    // "Key OK" with silently dead analysis for up to 12 h.
    await s.setGeminiApiKey('key-B');
    expect(s.quotaPauseUntil, isNull);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.quotaPauseUntil, isNull); // cleared in persistence too
  });

  test('API key lives only in secure storage, never in prefs', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setGeminiApiKey('sk-secret');
    expect(keys.data.values, contains('sk-secret'));
    for (final k in prefs.getKeys()) {
      expect(prefs.get(k).toString(), isNot(contains('sk-secret')));
    }
  });

  test('clearing the API key deletes it from secure storage', () async {
    final (s, _, keys) = await freshSettings();
    await s.setGeminiApiKey('sk-secret');
    await s.setGeminiApiKey('   ');
    expect(s.geminiApiKey, isNull);
    expect(keys.data, isEmpty);
  });

  test('lookbackDays clamps to 1..30 on set and on load', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setLookbackDays(0);
    expect(s.lookbackDays, 1);
    await s.setLookbackDays(99);
    expect(s.lookbackDays, 30);
    // A hand-edited out-of-range stored value clamps at load time too.
    await prefs.setInt('settings.lookback_days', 500);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.lookbackDays, 30);
  });

  test('reportTime rejects non-HH:mm values and survives bad stored data',
      () async {
    final (s, prefs, keys) = await freshSettings();
    expect(() => s.setReportTime('9pm'), throwsArgumentError);
    expect(() => s.setReportTime('25:00'), throwsArgumentError);
    expect(s.reportTime, '21:30');
    await prefs.setString('settings.report_time', 'garbage');
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.reportTime, '21:30');
  });

  test('blank model resets to the default', () async {
    final (s, _, _) = await freshSettings();
    await s.setModel('   ');
    expect(s.model, AppSettings.defaultModel);
  });

  // Spec §8's rule for every provider's model string: trimmed, blank means
  // that provider's default, kept under its own key. All nine are pinned
  // (only Gemini, Qwen and OpenRouter were), so one shared setter cannot
  // cross two providers' keys or defaults (review 171).
  group("every provider's model string", () {
    final models = <(
      String key,
      String fallback,
      String Function(AppSettings) get,
      Future<void> Function(AppSettings, String) set,
    )>[
      ('settings.model', AppSettings.defaultModel, (s) => s.model,
          (s, v) => s.setModel(v)),
      ('settings.openai_model', AppSettings.defaultOpenaiModel,
          (s) => s.openaiModel, (s, v) => s.setOpenaiModel(v)),
      ('settings.anthropic_model', AppSettings.defaultAnthropicModel,
          (s) => s.anthropicModel, (s, v) => s.setAnthropicModel(v)),
      ('settings.qwen_model', AppSettings.defaultQwenModel,
          (s) => s.qwenModel, (s, v) => s.setQwenModel(v)),
      ('settings.doubao_model', AppSettings.defaultDoubaoModel,
          (s) => s.doubaoModel, (s, v) => s.setDoubaoModel(v)),
      ('settings.glm_model', AppSettings.defaultGlmModel,
          (s) => s.glmModel, (s, v) => s.setGlmModel(v)),
      ('settings.deepseek_model', AppSettings.defaultDeepseekModel,
          (s) => s.deepseekModel, (s, v) => s.setDeepseekModel(v)),
      ('settings.xai_model', AppSettings.defaultXaiModel,
          (s) => s.xaiModel, (s, v) => s.setXaiModel(v)),
      ('settings.openrouter_model', AppSettings.defaultOpenrouterModel,
          (s) => s.openrouterModel, (s, v) => s.setOpenrouterModel(v)),
    ];

    test('a fresh install has each default', () async {
      final (s, _, _) = await freshSettings();
      for (final (key, fallback, get, _) in models) {
        expect(get(s), fallback, reason: key);
      }
    });

    test("a value is trimmed, kept under its own key and read back by a "
        "second load, and leaves every other provider's alone", () async {
      final (s, prefs, keys) = await freshSettings();
      for (final (key, _, _, set) in models) {
        await set(s, '  $key-custom  ');
      }
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      for (final (key, _, get, _) in models) {
        expect(get(s), '$key-custom', reason: key);
        expect(prefs.getString(key), '$key-custom', reason: key);
        expect(get(again), '$key-custom', reason: key);
      }
    });

    test('blank resets to the default, which is what is stored', () async {
      final (s, prefs, keys) = await freshSettings();
      for (final (key, fallback, get, set) in models) {
        await set(s, '$key-custom');
        await set(s, ' \t ');
        expect(get(s), fallback, reason: key);
        expect(prefs.getString(key), fallback, reason: key);
      }
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      for (final (key, fallback, get, _) in models) {
        expect(get(again), fallback, reason: key);
      }
    });

    test('a blank stored value loads as the default, a padded one trimmed',
        () async {
      for (final stored in ['', '   ']) {
        final (s, _, _) = await freshSettings(
            initial: {for (final (key, _, _, _) in models) key: stored});
        for (final (key, fallback, get, _) in models) {
          expect(get(s), fallback, reason: '$key = "$stored"');
        }
      }
      final (s, _, _) = await freshSettings(
          initial: {for (final (key, _, _, _) in models) key: ' $key-x '});
      for (final (key, _, get, _) in models) {
        expect(get(s), '$key-x', reason: key);
      }
    });

    test('each edit notifies once', () async {
      final (s, _, _) = await freshSettings();
      var notified = 0;
      s.addListener(() => notified++);
      for (final (key, _, _, set) in models) {
        notified = 0;
        await set(s, 'm');
        expect(notified, 1, reason: key);
      }
    });
  });

  test('blank dietary profile reads back as null', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setDietaryProfile('  ');
    expect(s.dietaryProfile, isNull);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.dietaryProfile, isNull);
  });

  test('isQuotaPaused is true only while now < pause-until', () async {
    final (s, _, _) = await freshSettings();
    await s.setQuotaPauseUntil(DateTime.now().add(const Duration(hours: 1)));
    expect(s.isQuotaPaused, isTrue);
    await s.setQuotaPauseUntil(
        DateTime.now().subtract(const Duration(seconds: 1)));
    expect(s.isQuotaPaused, isFalse);
    await s.setQuotaPauseUntil(null);
    expect(s.quotaPauseUntil, isNull);
  });

  test('the summary watermark is read fresh, so a write from the '
      'heartbeat isolate is seen past this isolate\'s cache', () async {
    final (s, prefs, _) = await freshSettings();
    expect(await s.freshSummaryPostedDate(), '');
    await s.markSummaryPosted('2026-10-07');
    expect(await s.freshSummaryPostedDate(), '2026-10-07');

    // Another engine (the WorkManager run) writes the native store; this
    // isolate's cached SharedPreferences does not see it on its own.
    SharedPreferences.setMockInitialValues(
        {'settings.summary_posted_date': '2026-10-08'});
    expect(prefs.getString('settings.summary_posted_date'), '2026-10-07',
        reason: 'precondition: the cache is stale');
    expect(await s.freshSummaryPostedDate(), '2026-10-08');
  });

  test('setters notify listeners', () async {
    final (s, _, _) = await freshSettings();
    var notifications = 0;
    s.addListener(() => notifications++);
    await s.setModel('m');
    await s.setLookbackDays(3);
    await s.setWatcherEnabled(true);
    await s.setGeminiApiKey('k');
    expect(notifications, 4);
  });

  testWidgets("repliesInChinese follows the phone's language on 'system'",
      (tester) async {
    final (s, _, _) = await freshSettings();
    await s.setAppLanguage('system');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final real = AppSettings.systemLanguageCode;
    addTearDown(() => AppSettings.systemLanguageCode = real);
    AppSettings.systemLanguageCode =
        () => tester.platformDispatcher.locale.languageCode;
    tester.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
    expect(s.repliesInChinese, isTrue);
    tester.platformDispatcher.localeTestValue = const Locale('en', 'US');
    expect(s.repliesInChinese, isFalse);
    // An explicit choice wins over the phone.
    await s.setAppLanguage('zh');
    expect(s.repliesInChinese, isTrue);
    tester.platformDispatcher.localeTestValue = const Locale('zh');
    await s.setAppLanguage('en');
    expect(s.repliesInChinese, isFalse);
  });

  group('automatic-analysis latch (rejected key / blocked region)', () {
    test('arms, persists across a load, and gates canAutoAnalyze only',
        () async {
      final (s, prefs, keys) = await freshSettings();
      await s.setGeminiApiKey('k');
      expect(s.canAutoAnalyze, isTrue);
      await s.blockAutomaticAnalysis('rejectedKey',
          revision: s.credentialRevision);
      expect(s.isAnalysisBlocked, isTrue);
      expect(s.analysisBlockedKind, 'rejectedKey');
      expect(s.canAutoAnalyze, isFalse);
      expect(s.canAnalyze, isTrue, reason: 'deliberate adds still analyze');

      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.analysisBlockedKind, 'rejectedKey');
      expect(again.canAutoAnalyze, isFalse);
      // Kind, time and provider only — nothing derived from the key.
      final stored = {
        for (final k in prefs.getKeys())
          if (k.startsWith('settings.analysis_blocked')) k: prefs.get(k),
      };
      expect(stored.keys, hasLength(3));
      expect(stored['settings.analysis_blocked_kind'], 'rejectedKey');
      expect(stored['settings.analysis_blocked_provider'], 'gemini');
      expect(DateTime.tryParse('${stored['settings.analysis_blocked_until']}'),
          isNotNull);
    });

    test('expires by itself: 24 h for a rejected key, 2 h for a region',
        () async {
      final (s, _, _) = await freshSettings();
      final now = DateTime.now();
      await s.blockAutomaticAnalysis('rejectedKey',
          now: now.subtract(const Duration(hours: 23)));
      expect(s.isAnalysisBlocked, isTrue);
      await s.blockAutomaticAnalysis('rejectedKey',
          now: now.subtract(const Duration(hours: 24, minutes: 1)));
      expect(s.isAnalysisBlocked, isFalse);
      expect(s.analysisBlockedKind, isNull);

      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.subtract(const Duration(hours: 1)));
      expect(s.analysisBlockedKind, 'regionBlocked');
      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.subtract(const Duration(hours: 2, minutes: 1)));
      expect(s.isAnalysisBlocked, isFalse);

      // An empty balance (run 7, B6): 2 h, like a region — a top-up at the
      // provider's console edits nothing here.
      await s.blockAutomaticAnalysis('billing',
          now: now.subtract(const Duration(hours: 1, minutes: 50)));
      expect(s.analysisBlockedKind, 'billing');
      await s.blockAutomaticAnalysis('billing',
          now: now.subtract(const Duration(hours: 2, minutes: 1)));
      expect(s.isAnalysisBlocked, isFalse);

      await s.blockAutomaticAnalysis('quotaPaused');
      expect(s.isAnalysisBlocked, isFalse, reason: 'only the known kinds');
    });

    test('a billing pause survives a reload and is lifted by a passing '
        'probe', () async {
      final (s, prefs, keys) = await freshSettings();
      await s.setDeepseekApiKey('k');
      await s.setProvider(AiProvider.deepseek);
      await s.blockAutomaticAnalysis('billing',
          revision: s.credentialRevision);
      expect(s.analysisBlockedKind, 'billing',
          reason: 'the trailing re-read must not erase the arm');
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.analysisBlockedKind, 'billing');
      expect(again.canAutoAnalyze, isFalse);
      await again.credentialsProven(reachedGeneration: false);
      expect(again.analysisBlockedKind, isNull);
    });

    test('an end further out than the TTL (clock set back) is no pause',
        () async {
      final (s, prefs, keys) = await freshSettings();
      final now = DateTime.now();
      // Armed while the clock read a month ahead.
      await s.blockAutomaticAnalysis('rejectedKey',
          now: now.add(const Duration(days: 30)));
      expect(s.isAnalysisBlocked, isFalse);
      expect(s.analysisBlockedUntil, isNull);
      expect(s.canAutoAnalyze, s.canAnalyze);
      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.add(const Duration(hours: 1)));
      expect(s.isAnalysisBlocked, isFalse, reason: '3 h out > 2 h TTL');
      // The same from disk, as another isolate would read it.
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.isAnalysisBlocked, isFalse);
      // A nudge of a minute or two is not skew.
      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.add(const Duration(minutes: 2)));
      expect(s.isAnalysisBlocked, isTrue);
    });

    test('EVERY credential, provider, model or server edit lifts it',
        () async {
      final (s, _, _) = await freshSettings();
      final edits = <String, Future<void> Function()>{
        'gemini key': () => s.setGeminiApiKey('k2'),
        'gemini model': () => s.setModel('gemini-x'),
        'provider': () => s.setProvider(AiProvider.openai),
        'openai key': () => s.setOpenaiApiKey('o'),
        'anthropic key': () => s.setAnthropicApiKey('a'),
        'qwen key': () => s.setQwenApiKey('q'),
        'doubao key': () => s.setDoubaoApiKey('d'),
        'glm key': () => s.setGlmApiKey('g'),
        'deepseek key': () => s.setDeepseekApiKey('ds'),
        'xai key': () => s.setXaiApiKey('x'),
        'openrouter key': () => s.setOpenrouterApiKey('or'),
        'server key': () => s.setServerApiKey('sv'),
        'server address': () => s.setServerBaseUrl('http://host.test'),
        'server plan': () => s.setServerBackend('glm'),
        'server model': () => s.setServerModel('sonnet'),
        'openai model': () => s.setOpenaiModel('m'),
        'anthropic model': () => s.setAnthropicModel('m'),
        'qwen model': () => s.setQwenModel('m'),
        'doubao model': () => s.setDoubaoModel('m'),
        'glm model': () => s.setGlmModel('m'),
        'deepseek model': () => s.setDeepseekModel('m'),
        'xai model': () => s.setXaiModel('m'),
        'openrouter model': () => s.setOpenrouterModel('m'),
      };
      for (final MapEntry(:key, :value) in edits.entries) {
        await s.blockAutomaticAnalysis('rejectedKey');
        expect(s.isAnalysisBlocked, isTrue, reason: key);
        final rev = s.credentialRevision;
        await value();
        expect(s.isAnalysisBlocked, isFalse, reason: key);
        expect(s.credentialRevision, greaterThan(rev), reason: key);
      }
    });

    test('a refusal read before a key edit is dropped (stale revision)',
        () async {
      final (s, _, _) = await freshSettings();
      final before = s.credentialRevision;
      await s.setGeminiApiKey('new-key');
      await s.blockAutomaticAnalysis('rejectedKey', revision: before);
      expect(s.isAnalysisBlocked, isFalse);
    });

    test('clearAnalysisBlock lifts it, on disk too', () async {
      final (s, prefs, keys) = await freshSettings();
      await s.blockAutomaticAnalysis('regionBlocked');
      await s.clearAnalysisBlock();
      expect(s.isAnalysisBlocked, isFalse);
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.isAnalysisBlocked, isFalse);
    });

    test('belongs to the provider that set it', () async {
      final (s, prefs, _) = await freshSettings();
      await s.blockAutomaticAnalysis('regionBlocked');
      // Another engine switched providers on disk after we armed it.
      await prefs.setString('settings.provider', AiProvider.deepseek.name);
      await prefs.setString(
          'settings.analysis_blocked_provider', AiProvider.gemini.name);
      final other = await AppSettings.load(
          prefs: prefs, keyStore: MemoryKeyStore());
      expect(other.provider, AiProvider.deepseek);
      expect(other.isAnalysisBlocked, isFalse);
    });

    test('reloadAnalysisBlock sees what the background engine wrote',
        () async {
      final (s, prefs, _) = await freshSettings();
      expect(s.isAnalysisBlocked, isFalse);
      // The background isolate armed it on disk.
      await prefs.setString('settings.analysis_blocked_until',
          DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String());
      await prefs.setString('settings.analysis_blocked_kind', 'rejectedKey');
      // A torn arm without its provider is no pause (2026-10-12): the
      // provider is written first, so it can only be missing by accident.
      await s.reloadAnalysisBlock();
      expect(s.isAnalysisBlocked, isFalse);
      expect(s.canAutoAnalyze, s.canAnalyze);
      await prefs.setString(
          'settings.analysis_blocked_provider', AiProvider.gemini.name);
      await s.reloadAnalysisBlock();
      expect(s.analysisBlockedKind, 'rejectedKey');
    });

    test('a passing key probe lifts a rejected-key pause; a region pause '
        'only when the probe reached the generation endpoint', () async {
      final (s, _, _) = await freshSettings();
      await s.blockAutomaticAnalysis('rejectedKey');
      await s.credentialsProven(reachedGeneration: false);
      expect(s.isAnalysisBlocked, isFalse);

      await s.blockAutomaticAnalysis('regionBlocked');
      await s.credentialsProven(reachedGeneration: false);
      expect(s.analysisBlockedKind, 'regionBlocked',
          reason: "the server's auth check never meets a region refusal");
      await s.credentialsProven(reachedGeneration: true);
      expect(s.isAnalysisBlocked, isFalse);
    });

    test('a passing probe lifts a pause the background engine armed on disk',
        () async {
      final (fg, _, keys) = await freshSettings();
      await fg.setGeminiApiKey('k');
      SharedPreferences.resetStatic(); // the other isolate: its own cache
      final bg = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
      await bg.blockAutomaticAnalysis('rejectedKey',
          revision: bg.credentialRevision);
      expect(fg.isAnalysisBlocked, isFalse, reason: 'stale cache');
      await fg.credentialsProven(reachedGeneration: true);
      SharedPreferences.resetStatic();
      final next = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
      expect(next.isAnalysisBlocked, isFalse);
    });

    test("a passing probe leaves another provider's pause alone", () async {
      final (s, prefs, _) = await freshSettings();
      await s.setProvider(AiProvider.deepseek);
      // Gemini's pause, still on disk from before the switch.
      await prefs.setString('settings.analysis_blocked_until',
          DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String());
      await prefs.setString('settings.analysis_blocked_kind', 'rejectedKey');
      await prefs.setString(
          'settings.analysis_blocked_provider', AiProvider.gemini.name);
      // DeepSeek's probe says nothing about Gemini's key.
      await s.credentialsProven(reachedGeneration: true);
      expect(prefs.getString('settings.analysis_blocked_provider'),
          AiProvider.gemini.name);
    });

    test('clearAnalysisBlock writes nothing when no pause is set', () async {
      // Every successful photo calls it: three removes per meal for nothing.
      final store = _CountingStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await s.clearAnalysisBlock();
      expect(store.writes, 0);
      await s.blockAutomaticAnalysis('rejectedKey');
      store.writes = 0;
      await s.clearAnalysisBlock();
      expect(store.writes, 3, reason: 'a set pause is removed');
      expect(s.isAnalysisBlocked, isFalse);
    });

    test('a reload landing between the arm\'s writes does not leave the '
        'footer saying "not paused"', () async {
      // The arm set its in-memory pause, then awaited its disk writes; a
      // resume's reloadAnalysisBlock read the half-written keys in between
      // and cleared it — and the arm's own notify then showed that.
      final store = _GatedStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await s.setGeminiApiKey('k');
      final shown = <bool>[];
      s.addListener(() => shown.add(s.isAnalysisBlocked));
      store.gate = Completer<void>();
      final arm = s.blockAutomaticAnalysis('rejectedKey',
          revision: s.credentialRevision);
      await store.gated.future; // the arm is mid-write
      await s.reloadAnalysisBlock();
      expect(s.isAnalysisBlocked, isFalse, reason: 'the race itself');
      store.gate!.complete();
      await arm;
      expect(s.isAnalysisBlocked, isTrue);
      expect(s.analysisBlockedKind, 'rejectedKey');
      expect(shown.last, isTrue, reason: 'the last notify says paused');
    });
  });

  // Design R7a (data_contracts §9a): the restaurant assist's settings.
  // Review of PR 74: the upload key went with every request to whatever
  // address was saved, so a new address saved before its key got the
  // previous server's key. The key is bound to the host it was saved for
  // (HttpsOnlyServerClient sends it nowhere else).
  group('the server upload key is bound to the host it was saved for', () {
    test('a key saved for an address is bound to its host; moving the '
        'address leaves it there', () async {
      final (s, prefs, keys) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://A.example:8443/');
      await s.setServerApiKey('key-a');
      expect(s.serverKeyHost, 'a.example');
      // One secure item holds the key and its host; nothing in the
      // preferences (an iPhone reinstall keeps the one, not the other).
      expect(storedServerKey(keys), ('key-a', 'a.example'));
      expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
      expect(s.serverKeyForOtherAddress, isFalse);
      await s.setServerBaseUrl('https://b.example');
      expect(s.serverKeyHost, 'a.example');
      expect(s.serverKeyForOtherAddress, isTrue);
      // The page saves the field again on a tap outside it and on Done:
      // the same key keeps its host.
      await s.setServerApiKey('key-a');
      expect(s.serverKeyHost, 'a.example');
      expect(storedServerKey(keys), ('key-a', 'a.example'));
      // A new key is the address's own.
      await s.setServerApiKey('key-b');
      expect(s.serverKeyHost, 'b.example');
      expect(s.serverKeyForOtherAddress, isFalse);
      expect(storedServerKey(keys), ('key-b', 'b.example'));
      // Another port on the same host is the same server.
      await s.setServerBaseUrl('https://b.example:9443');
      expect(s.serverKeyForOtherAddress, isFalse);
    });

    test('a key saved before any address binds to the first one saved',
        () async {
      final (s, prefs, keys) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerApiKey('early-key');
      expect(s.serverKeyHost, isNull);
      expect(storedServerKey(keys), ('early-key', null));
      await s.setServerBaseUrl('https://first.example');
      expect(s.serverKeyHost, 'first.example');
      expect(storedServerKey(keys), ('early-key', 'first.example'));
      await s.setServerBaseUrl('https://second.example');
      expect(s.serverKeyHost, 'first.example');
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((again.serverApiKey, again.serverKeyHost),
          ('early-key', 'first.example'));
    });

    test('the binding is written in the same step as the address or key',
        () async {
      final (s, _, _) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      // Not awaited: what a request built right now would see.
      final address = s.setServerBaseUrl('https://b.example');
      expect((s.serverBaseUrl, s.serverApiKey, s.serverKeyHost),
          ('https://b.example', 'key-a', 'a.example'));
      await address;
      final key = s.setServerApiKey('key-b');
      expect((s.serverApiKey, s.serverKeyHost), ('key-b', 'b.example'));
      await key;
    });

    test('a cleared key forgets its host', () async {
      final (s, _, keys) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      await s.setServerApiKey('');
      expect(s.serverKeyHost, isNull);
      expect(storedServerKey(keys), isNull);
      expect(keys.data.containsKey(kServerKeyItem), isFalse);
    });

    test('an update moves a key 1.7.0 stored as plain text into the item, '
        'bound to the address saved with it, once', () async {
      final (s, prefs, keys) = await freshSettings(initial: {
        'settings.provider': 'server',
        'settings.server_base_url': 'https://owner.example',
      });
      expect(s.serverKeyHost, isNull, reason: 'no key yet');
      keys.data[kLegacyServerKey] = 'old-key';
      final updated = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(updated.serverKeyHost, 'owner.example');
      expect(updated.serverKeyHostUnknown, isFalse);
      // Moved at once: the item, the old name retired (an older version
      // finds no key there), no record left.
      expect(storedServerKey(keys), ('old-key', 'owner.example'));
      expect(keys.data[kLegacyServerKey], kRetiredOldName);
      expect(keyAnOlderVersionReads(keys), isNull);
      expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
      expect(updated.serverKeyForOtherAddress, isFalse);
      // A later load reads it back, and a moved address stays refused.
      await updated.setServerBaseUrl('https://elsewhere.example');
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.serverKeyHost, 'owner.example');
      expect(again.serverKeyForOtherAddress, isTrue);
      expect(again.serverKeyFor('elsewhere.example'), isNull);
      // An iPhone reinstall keeps the item and drops the preferences: the
      // binding stays (review of 2026-11-20, UPG-1).
      SharedPreferences.setMockInitialValues({});
      final reinstalled = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
      expect((reinstalled.serverApiKey, reinstalled.serverKeyHost),
          ('old-key', 'owner.example'));
      expect(reinstalled.serverKeyHostUnknown, isFalse);
      // Use this key, on the tap.
      await again.bindServerKeyToAddress();
      expect(storedServerKey(keys), ('old-key', 'elsewhere.example'));
      final bound = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(bound.serverKeyHost, 'elsewhere.example');
    });

    // Builds before this one kept the host in the preferences, next to a
    // plain key: the record binds it, and the move keeps it.
    test('a plain key with its host recorded keeps that host', () async {
      final (_, prefs, keys) = await freshSettings(initial: {
        'settings.provider': 'server',
        'settings.server_base_url': 'https://b.example',
        'settings.server_key_host': 'a.example',
      });
      keys.data[kLegacyServerKey] = 'key-a';
      final s = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((s.serverApiKey, s.serverKeyHost), ('key-a', 'a.example'));
      expect(s.serverKeyFor('b.example'), isNull);
      expect(s.serverKeyForAddress, isNull);
      expect(storedServerKey(keys), ('key-a', 'a.example'));
      expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
    });

    // Builds before this one stored the item under the old name: read as
    // the item, moved as it is.
    test('an item stored under the old name is moved with its host', () async {
      final (_, prefs, keys) = await freshSettings(initial: {
        'settings.provider': 'server',
        'settings.server_base_url': 'https://b.example',
      });
      keys.data[kLegacyServerKey] =
          jsonEncode({'key': 'key-a', 'host': 'a.example'});
      final s = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((s.serverApiKey, s.serverKeyHost), ('key-a', 'a.example'));
      expect(s.serverKeyFor('b.example'), isNull);
      expect(storedServerKey(keys), ('key-a', 'a.example'));
    });

    test('a plain key that looks like the item is a plain key; a key whose '
        'text does is stored and read back as its text', () async {
      for (final plain in [
        '{key-a',
        '{"key":"x"}',
        '{"key":1,"host":null}',
        '{"key":"x","host":7}',
      ]) {
        final (_, prefs, keys) = await freshSettings(
            initial: {'settings.server_base_url': 'https://a.example'});
        keys.data[kLegacyServerKey] = plain;
        final s = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect((s.serverApiKey, s.serverKeyHost), (plain, 'a.example'),
            reason: plain);
        expect(storedServerKey(keys), (plain, 'a.example'), reason: plain);
      }
      const looksLikeIt = '{"key":"x","host":"evil.example"}';
      final (s, prefs, keys) = await freshSettings();
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey(looksLikeIt);
      expect(storedServerKey(keys), (looksLikeIt, 'a.example'));
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((again.serverApiKey, again.serverKeyHost),
          (looksLikeIt, 'a.example'));
      expect(again.serverKeyFor('evil.example'), isNull);
    });

    test('Use this key here binds it to the address, on the tap only',
        () async {
      final (s, _, keys) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      await s.setServerBaseUrl('https://203.0.113.5');
      final rev = s.credentialRevision;
      var notified = 0;
      s.addListener(() => notified++);
      await s.bindServerKeyToAddress();
      expect(s.serverKeyHost, '203.0.113.5');
      expect(storedServerKey(keys), ('key-a', '203.0.113.5'));
      expect(s.serverKeyForOtherAddress, isFalse);
      expect(s.credentialRevision, greaterThan(rev));
      expect(notified, 1);
      await s.bindServerKeyToAddress(); // already bound: nothing
      expect(notified, 1);
    });

    test('a setup link sets the address and its key together, notified '
        'once, bound to the link\'s host', () async {
      final (s, prefs, keys) = await freshSettings();
      await s.setProvider(AiProvider.gemini);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      final seen = <(String, String?, String?, AiProvider)>[];
      s.addListener(() => seen.add(
          (s.serverBaseUrl, s.serverApiKey, s.serverKeyHost, s.provider)));
      final setup = s.applyServerSetup(
          backend: 'glm', baseUrl: 'https://b.example/', key: ' key-b ');
      // All of it before the first await.
      expect((s.serverBaseUrl, s.serverApiKey, s.serverKeyHost),
          ('https://b.example', 'key-b', 'b.example'));
      await setup;
      expect(seen, [('https://b.example', 'key-b', 'b.example', AiProvider.server)]);
      expect(s.serverBackend, 'glm');
      expect(storedServerKey(keys), ('key-b', 'b.example'));
      final reloaded = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((reloaded.provider, reloaded.serverBaseUrl, reloaded.serverKeyHost),
          (AiProvider.server, 'https://b.example', 'b.example'));
    });

    // An app killed between two of these writes must never leave a key
    // bound (or bound at the next load) to a host it was not saved for:
    // each write is the key with its own host, in place (never absent
    // between keystrokes), and a key bound to an address is stored before
    // the address (a setup link's, and a key typed before any address).
    test('stored as one item with its host, before the address it is bound '
        'to', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final keys = _OrderedKeyStore(prefs);
      final s = await AppSettings.load(prefs: prefs, keyStore: keys);
      await s.setProvider(AiProvider.server);
      await s.setServerApiKey('early'); // before any address
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      await s.setServerApiKey('key-a2'); // the same host: in place
      await s.setServerBaseUrl('https://b.example');
      await s.setServerApiKey('key-b'); // a new host
      await s.applyServerSetup(
          backend: 'claude', baseUrl: 'https://c.example', key: 'key-c');
      expect(keys.log, [
        // The old name holds nothing an older version would send, before
        // the first item (its read may have failed, so it is overwritten).
        'old name " " (url null)',
        'write early for null (url null)',
        'write early for a.example (url null)',
        'write key-a for a.example (url https://a.example)',
        'write key-a2 for a.example (url https://a.example)',
        'write key-b for b.example (url https://b.example)',
        'write key-c for c.example (url https://b.example)',
      ]);
      expect(prefs.getString('settings.server_base_url'), 'https://c.example');
      expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
    });

    test('the automatic scan does not run with a key saved elsewhere',
        () async {
      final (s, _, _) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      expect(s.canAutoAnalyze, isTrue);
      await s.setServerBaseUrl('https://b.example');
      expect(s.canAnalyze, isTrue, reason: 'a deliberate add is told why');
      expect(s.canAutoAnalyze, isFalse);
      await s.bindServerKeyToAddress();
      expect(s.canAutoAnalyze, isTrue);
    });

    // Recheck of the binding: the server page's key field still held the
    // key saved for a.example at an address naming no host ('' or
    // 'https://'), and after a setup link confirmed with the page open;
    // edited there, it became the next host's key. One rule, here: the
    // field shows a key only at its own host (serverKeyForAddress), an edit
    // is the key for the address the field was filled at
    // (setServerKeyFromField, refused at any other host), and a request
    // carries a key's text only to the host it is saved for (serverKeyFor).
    test('the key field shows the key only at its own host, or while it is '
        'bound to none yet', () async {
      final (s, _, _) = await freshSettings();
      await s.setProvider(AiProvider.server);
      expect(s.serverKeyForAddress, isNull, reason: 'no key');
      await s.setServerApiKey('early');
      expect(s.serverKeyForAddress, 'early', reason: 'typed before an address');
      await s.setServerBaseUrl('https://a.example');
      expect(s.serverKeyForAddress, 'early');
      for (final other in ['https://b.example', '', 'https://']) {
        await s.setServerBaseUrl(other);
        expect(s.serverKeyForAddress, isNull, reason: '"$other"');
        expect(s.serverKeyHost, 'a.example');
      }
      await s.setServerBaseUrl('https://A.example:8443');
      expect(s.serverKeyForAddress, 'early', reason: 'the same host');
    });

    test('the text of a key goes only to the host it is saved for', () async {
      final (s, _, _) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerApiKey('early');
      expect(s.serverKeyFor('a.example'), isNull, reason: 'bound to none');
      await s.setServerBaseUrl('https://a.example');
      expect(s.serverKeyFor('a.example'), 'early');
      expect(s.serverKeyFor('A.Example'), 'early');
      expect(s.serverKeyFor('b.example'), isNull);
      await s.setServerBaseUrl('https://b.example');
      expect(s.serverKeyFor('b.example'), isNull);
      expect(s.serverKeyFor('a.example'), 'early');
      await s.setServerApiKey('');
      expect(s.serverKeyFor('a.example'), isNull);
    });

    test('an edit of the key field filled at another host than the saved '
        'address\'s is refused, nothing written', () async {
      final (s, _, keys) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      var notified = 0;
      s.addListener(() => notified++);
      for (final moved in ['https://b.example', '', 'https://']) {
        await s.setServerBaseUrl(moved);
        notified = 0;
        for (final edit in ['key-a-x', 'key-', 'x', '']) {
          expect(
              await s.setServerKeyFromField(edit,
                  filledAt: 'https://a.example'),
              isFalse,
              reason: '"$moved" "$edit"');
        }
        expect((s.serverApiKey, s.serverKeyHost), ('key-a', 'a.example'));
        expect(storedServerKey(keys), ('key-a', 'a.example'));
        expect(notified, 0);
      }
      // The same host on another port is the field's own.
      await s.setServerBaseUrl('https://a.example:8443');
      expect(
          await s.setServerKeyFromField('key-a2',
              filledAt: 'https://a.example'),
          isTrue);
      expect((s.serverApiKey, s.serverKeyHost), ('key-a2', 'a.example'));
      expect(storedServerKey(keys), ('key-a2', 'a.example'));
    });

    test('a field filled at another host showed nothing: what is entered '
        'there is that address\'s key, and empty deletes nothing', () async {
      final (s, _, keys) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      await s.setServerBaseUrl('https://b.example');
      final at = s.serverBaseUrl;
      // A space typed, or Done on the empty field: key-a stays a.example's.
      expect(await s.setServerKeyFromField(' ', filledAt: at), isTrue);
      expect((s.serverApiKey, s.serverKeyHost), ('key-a', 'a.example'));
      // The saved key itself, pasted: the same server at a new address.
      expect(await s.setServerKeyFromField('key-a', filledAt: at), isTrue);
      expect((s.serverApiKey, s.serverKeyHost), ('key-a', 'b.example'));
      expect(storedServerKey(keys), ('key-a', 'b.example'));
      // Shown here now: empty deletes it.
      expect(await s.setServerKeyFromField('', filledAt: at), isTrue);
      expect((s.serverApiKey, s.serverKeyHost), (null, null));
      expect(storedServerKey(keys), isNull);
      // Typed: bound here in the same step, before the first await.
      final typed = s.setServerKeyFromField('key-b', filledAt: at);
      expect((s.serverApiKey, s.serverKeyHost), ('key-b', 'b.example'));
      await typed;
      expect(storedServerKey(keys), ('key-b', 'b.example'));
    });

    test('a key entered at an address naming no host is bound to none, then '
        'to the first address saved; until then the saved key stays its '
        'host\'s', () async {
      for (final none in ['', 'https://']) {
        final (s, _, _) = await freshSettings();
        await s.setProvider(AiProvider.server);
        await s.setServerBaseUrl('https://a.example');
        await s.setServerApiKey('key-a');
        await s.setServerBaseUrl(none);
        expect(s.serverKeyForAddress, isNull, reason: '"$none"');
        expect(s.serverKeyHost, 'a.example');
        final typed = s.setServerKeyFromField('key-b', filledAt: none);
        expect((s.serverApiKey, s.serverKeyHost, s.serverKeyForAddress),
            ('key-b', null, 'key-b'));
        expect(await typed, isTrue);
        expect(s.serverKeyFor('a.example'), isNull);
        await s.setServerBaseUrl('https://b.example');
        expect(s.serverKeyHost, 'b.example');
        expect(s.serverKeyFor('b.example'), 'key-b');
      }
    });

    test('a key edit landing after a setup link\'s write, from the field '
        'filled before it, is refused', () async {
      final (s, _, _) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      final filledAt = s.serverBaseUrl;
      final link = s.applyServerSetup(
          backend: 'claude', baseUrl: 'https://b.example', key: 'key-link');
      expect(await s.setServerKeyFromField('key-a-x', filledAt: filledAt),
          isFalse);
      await link;
      expect((s.serverApiKey, s.serverKeyHost), ('key-link', 'b.example'));
      expect(s.serverKeyFor('b.example'), 'key-link');
      // The field filled again at the link's address edits the link's key.
      expect(
          await s.setServerKeyFromField('key-link2',
              filledAt: s.serverBaseUrl),
          isTrue);
      expect((s.serverApiKey, s.serverKeyHost), ('key-link2', 'b.example'));
    });

    test('from the field: a changed key lifts the quota pause; the same key '
        'made another address\'s keeps it; a re-save counts as an edit',
        () async {
      final (s, _, _) = await freshSettings();
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey('key-a');
      final until = DateTime.now().add(const Duration(hours: 2));
      await s.setQuotaPauseUntil(until);
      await s.setServerBaseUrl('https://b.example');
      await s.setServerKeyFromField('key-a', filledAt: s.serverBaseUrl);
      expect(s.serverKeyHost, 'b.example');
      expect(s.quotaPauseUntil, isNotNull, reason: 'the same key');
      final rev = s.credentialRevision;
      await s.setServerKeyFromField('key-a', filledAt: s.serverBaseUrl);
      expect(s.credentialRevision, greaterThan(rev));
      await s.setServerKeyFromField('key-b', filledAt: s.serverBaseUrl);
      expect(s.quotaPauseUntil, isNull);
    });

    // Recheck of PR 74 (after 28821da5): the key lived in the keychain and
    // its host in the preferences. An iPhone reinstall keeps keychain items
    // and drops the preferences, so the key came back bound to no host: in
    // the key field at '' and at the first address saved, then bound to
    // that address, and a paste at the caret saved key A + key B for it.
    // The host is now stored with the key. A key that an install's first
    // launch finds with no host has no known host: kept apart, never shown,
    // sent or bound to an address saved, until the user uses it for one
    // (Use this key) or enters another key.
    group('after a reinstall that kept the key and dropped the preferences',
        () {
      Future<(AppSettings, SharedPreferences, MemoryKeyStore)> reinstalled(
          {String? item, String? legacy}) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final keys = MemoryKeyStore();
        if (item != null) keys.data[kServerKeyItem] = item;
        if (legacy != null) keys.data[kLegacyServerKey] = legacy;
        final s = await AppSettings.load(prefs: prefs, keyStore: keys);
        await s.setProvider(AiProvider.server);
        return (s, prefs, keys);
      }

      final boundToA = jsonEncode({'key': 'key-a', 'host': 'a.example'});

      test('a key stored with its host keeps it: the field is empty at any '
          'other address and at one naming none, and it is sent to its own '
          'host alone', () async {
        final (s, _, _) = await reinstalled(item: boundToA);
        expect((s.serverApiKey, s.serverKeyHost), ('key-a', 'a.example'));
        for (final url in ['', 'https://', 'https://b.example']) {
          await s.setServerBaseUrl(url);
          expect(s.serverKeyForAddress, isNull, reason: '"$url"');
          expect(s.serverKeyHost, 'a.example');
          expect(s.serverKeyFor('b.example'), isNull);
        }
        await s.setServerBaseUrl('https://a.example');
        expect(s.serverKeyForAddress, 'key-a');
        expect(s.serverKeyFor('a.example'), 'key-a');
      });

      test('a key stored as plain text has no known host: kept apart, never '
          'shown, sent or bound to an address saved, at this launch or a '
          'later one, until a key is entered', () async {
        final (s, prefs, keys) = await reinstalled(legacy: 'key-a');
        expect(s.serverKeyHostUnknown, isTrue, reason: 'kept, not deleted');
        expect(s.serverApiKey, isNull, reason: 'not the upload key');
        expect(storedKeyOfUnknownHost(keys), 'key-a');
        expect(keyAnOlderVersionReads(keys), isNull);
        for (final url in [
          '',
          'https://',
          'https://b.example',
          'https://a.example',
        ]) {
          await s.setServerBaseUrl(url);
          expect(s.serverKeyForAddress, isNull, reason: '"$url"');
          expect(s.serverKeyHost, isNull);
          expect(s.serverKeyFor('a.example'), isNull);
          expect(s.serverKeyFor('b.example'), isNull);
          expect(s.activeApiKey, isNull);
          expect(s.canAnalyze, isFalse);
          expect(s.serverKeyHostUnknown, isTrue, reason: 'never bound by it');
        }

        // A later launch has preferences, and an address naming a host:
        // still no known host.
        final again = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect(again.serverKeyHostUnknown, isTrue);
        expect(again.serverApiKey, isNull);
        expect(again.serverKeyFor('a.example'), isNull);
        await again.setServerBaseUrl('https://c.example');
        expect(again.serverKeyHost, isNull);
        expect(again.serverKeyFor('c.example'), isNull);
        // A backspace in the empty field enters nothing, and keeps it.
        expect(
            await again.setServerKeyFromField('',
                filledAt: again.serverBaseUrl),
            isTrue);
        expect(again.serverKeyHostUnknown, isTrue);
        expect(storedKeyOfUnknownHost(keys), 'key-a');
        // A key entered is the address's, and replaces it.
        expect(
            await again.setServerKeyFromField('key-c',
                filledAt: again.serverBaseUrl),
            isTrue);
        expect((again.serverApiKey, again.serverKeyHost),
            ('key-c', 'c.example'));
        expect(again.serverKeyHostUnknown, isFalse);
        expect(storedServerKey(keys), ('key-c', 'c.example'));
        expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
        final third = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect(third.serverKeyFor('c.example'), 'key-c');
        expect(third.serverKeyHostUnknown, isFalse);
      });

      test('Use this key makes a key with no known host the address\'s, on '
          'the tap alone, never at an address naming none', () async {
        final (s, prefs, keys) = await reinstalled(legacy: 'key-a');
        for (final none in ['', 'https://']) {
          await s.setServerBaseUrl(none);
          await s.bindServerKeyToAddress();
          expect(s.serverKeyHostUnknown, isTrue, reason: '"$none"');
          expect(s.serverApiKey, isNull);
        }
        await s.setServerBaseUrl('https://b.example');
        expect(s.serverKeyHostUnknown, isTrue, reason: 'not by the address');
        final rev = s.credentialRevision;
        var notified = 0;
        s.addListener(() => notified++);
        await s.bindServerKeyToAddress();
        expect((s.serverApiKey, s.serverKeyHost, s.serverKeyForAddress),
            ('key-a', 'b.example', 'key-a'));
        expect(s.serverKeyHostUnknown, isFalse);
        expect(s.serverKeyFor('b.example'), 'key-a');
        expect(s.serverKeyFor('a.example'), isNull);
        expect(storedServerKey(keys), ('key-a', 'b.example'));
        expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
        expect(s.credentialRevision, greaterThan(rev));
        expect(notified, 1);
        final again = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect((again.serverApiKey, again.serverKeyHost),
            ('key-a', 'b.example'));
      });

      test('a key with no known host: pasted at an address it is that '
          'address\'s; at one naming none, bound to the next; a setup link '
          'replaces it', () async {
        final (s, _, keys) = await reinstalled(legacy: 'key-a');
        await s.setServerBaseUrl('https://b.example');
        expect(
            await s.setServerKeyFromField('key-a', filledAt: s.serverBaseUrl),
            isTrue);
        expect((s.serverKeyHost, s.serverKeyForAddress),
            ('b.example', 'key-a'));
        expect(storedServerKey(keys), ('key-a', 'b.example'));

        final (none, _, _) = await reinstalled(legacy: 'key-a');
        expect(await none.setServerKeyFromField('key-a', filledAt: ''), isTrue);
        expect(none.serverKeyForAddress, 'key-a');
        await none.setServerBaseUrl('https://d.example');
        expect(none.serverKeyFor('d.example'), 'key-a');

        final (link, _, linkKeys) = await reinstalled(legacy: 'key-a');
        await link.applyServerSetup(
            backend: 'claude', baseUrl: 'https://s.example', key: 'key-s');
        expect(
            (link.serverApiKey, link.serverKeyHost, link.serverKeyForAddress),
            ('key-s', 's.example', 'key-s'));
        expect(link.serverKeyHostUnknown, isFalse);
        expect(storedServerKey(linkKeys), ('key-s', 's.example'));
      });

      test('a key stored bound to no host yet has no known host on a first '
          'launch, at later launches too; on any other launch it is a key '
          'typed before any address', () async {
        final unbound = jsonEncode({'key': 'early', 'host': null});
        final (s, prefs, keys) = await reinstalled(item: unbound);
        expect(s.serverKeyHostUnknown, isTrue);
        expect(s.serverKeyForAddress, isNull);
        await s.setServerBaseUrl('https://b.example');
        expect(s.serverKeyHost, isNull);
        expect(s.serverKeyFor('b.example'), isNull);
        expect(storedKeyOfUnknownHost(keys), 'early');
        final again = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect(again.serverKeyHostUnknown, isTrue);
        expect(again.serverKeyFor('b.example'), isNull);

        // This version's item, and one a build before it stored under the
        // old name.
        for (final name in [kServerKeyItem, kLegacyServerKey]) {
          SharedPreferences.setMockInitialValues(
              {'settings.provider': 'server'});
          final typed = await AppSettings.load(
              prefs: await SharedPreferences.getInstance(),
              keyStore: MemoryKeyStore()..data[name] = unbound);
          expect(typed.serverKeyForAddress, 'early', reason: name);
          await typed.setServerBaseUrl('https://b.example');
          expect(typed.serverKeyFor('b.example'), 'early');
        }
      });
    });

    // Review of 2026-11-20, PN-1: 1.7.0 stored '' when the address field
    // was cleared, and kept the key as plain text. Updated in place (no
    // first launch), the key loaded as one typed before any address: in the
    // key field at any address, and bound to the first one saved, so the
    // Restaurant group asked the new address at once with the old server's
    // key, and every photo after sent it there.
    test('an update finding a plain key with no address naming a host and '
        'no record: no known host, at that launch and the next, and never '
        'sent to or bound to the next address saved', () async {
      for (final noHost in ['', 'https://']) {
        final (_, prefs, keys) = await freshSettings(initial: {
          'settings.provider': 'server',
          'settings.server_backend': 'claude',
          'settings.server_base_url': noHost,
          'settings.ai_consent_routes': <String>['server:claude'],
        });
        keys.data[kLegacyServerKey] = 'KA-old-server';
        final s = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect(s.serverKeyHostUnknown, isTrue, reason: '"$noHost"');
        expect((s.serverApiKey, s.serverKeyHost, s.serverKeyForAddress),
            (null, null, null));
        expect(storedKeyOfUnknownHost(keys), 'KA-old-server');
        expect(keyAnOlderVersionReads(keys), isNull);
        await s.setServerBaseUrl('https://someone-else.example');
        expect(s.serverKeyHostUnknown, isTrue);
        expect(s.serverKeyFor('someone-else.example'), isNull);
        expect(s.serverKeyForAddress, isNull);
        final seen = <String>[];
        await ServerAnalyzer(s, client: MockClient((req) async {
          seen.add('${req.url.host} <- ${req.headers['X-API-Key']}');
          return http.Response(jsonEncode({'ok': true, 'features': {}}), 200);
        })).serverFeatures();
        expect(seen, isEmpty);
        final next = await AppSettings.load(prefs: prefs, keyStore: keys);
        expect(next.serverKeyHostUnknown, isTrue);
        expect(next.serverKeyFor('someone-else.example'), isNull);
        expect(next.serverApiKey, isNull);
      }
    });

    // Recheck of PR 74 (after 28821da5): the background engine loads its
    // preferences as its run starts (a fresh engine per run, with its own
    // cache) and reads the key later, in AppSettings.load. A key the app
    // stored in between was paired with that earlier address and host, so
    // the scan sent a setup link's key, or a new server's first keystroke,
    // to the previous server. The key is read with its own host now, and
    // the client sends it nowhere else, whatever address the run holds.
    group('the background engine\'s load, its preferences read earlier', () {
      Future<(AppSettings, MemoryKeyStore)> appAtA() async {
        SharedPreferences.setMockInitialValues({});
        final keys = MemoryKeyStore();
        final app = await AppSettings.load(
            prefs: await SharedPreferences.getInstance(), keyStore: keys);
        await app.setProvider(AiProvider.server);
        await app.setServerBaseUrl('https://a.example');
        await app.setServerApiKey('key-a');
        await app.setAiConsent('server:claude', granted: true);
        return (app, keys);
      }

      /// The run's own cache, loaded now (the app keeps writing to disk).
      Future<SharedPreferences> runCache() async {
        SharedPreferences.resetStatic();
        return SharedPreferences.getInstance();
      }

      /// What the server is asked with, as the run's analyzer asks.
      Future<List<String>> asked(AppSettings s) async {
        final seen = <String>[];
        await ServerAnalyzer(s, client: MockClient((req) async {
          seen.add('${req.url.host} <- ${req.headers['X-API-Key']}');
          return http.Response(
              jsonEncode({
                'ok': true,
                'features': {'restaurant_lookup': true, 'lookup_jobs': true},
              }),
              200);
        })).serverFeatures();
        return seen;
      }

      test('a setup link confirmed in between: its key goes to its own '
          'server only', () async {
        final (app, keys) = await appAtA();
        final cache = await runCache();
        await app.applyServerSetup(
            backend: 'claude', baseUrl: 'https://s.example', key: 'key-link-s');
        final run = await AppSettings.load(
            prefs: cache, keyStore: keys, readOnlyKeys: true);
        expect(run.serverBaseUrl, 'https://a.example', reason: 'its cache');
        expect((run.serverApiKey, run.serverKeyHost),
            ('key-link-s', 's.example'));
        expect(run.serverKeyFor('a.example'), isNull);
        expect(run.canAutoAnalyze, isFalse);
        expect(await asked(run), isEmpty);
        final next = await AppSettings.load(
            prefs: await runCache(), keyStore: keys, readOnlyKeys: true);
        expect(await asked(next), ['s.example <- key-link-s']);
      });

      test('a new server\'s key typed after the address moved: not sent to '
          'the previous server', () async {
        final (app, keys) = await appAtA();
        final cache = await runCache();
        await app.setServerBaseUrl('https://b.example');
        await app.setServerKeyFromField('k', filledAt: app.serverBaseUrl);
        final run = await AppSettings.load(
            prefs: cache, keyStore: keys, readOnlyKeys: true);
        expect(run.serverBaseUrl, 'https://a.example');
        expect((run.serverApiKey, run.serverKeyHost), ('k', 'b.example'));
        expect(await asked(run), isEmpty);
        final next = await AppSettings.load(
            prefs: await runCache(), keyStore: keys, readOnlyKeys: true);
        expect(await asked(next), ['b.example <- k']);
      });

      test('a key stored as plain text keeps the host it was bound to '
          'whenever the run read its preferences; the run only reads, the '
          'app moves it', () async {
        // Updated in place from 1.7.0.
        SharedPreferences.setMockInitialValues({
          'settings.provider': 'server',
          'settings.server_base_url': 'https://a.example',
          'settings.ai_consent_routes': <String>['server:claude'],
        });
        final keys = MemoryKeyStore()..data[kLegacyServerKey] = 'key-a';
        final appPrefs = await SharedPreferences.getInstance();
        final early = await runCache(); // before the app's first load
        // A run before the app's first load: bound in memory, nothing moved.
        final first = await AppSettings.load(
            prefs: early, keyStore: keys, readOnlyKeys: true);
        expect((first.serverApiKey, first.serverKeyHost),
            ('key-a', 'a.example'));
        expect(keys.data, {kLegacyServerKey: 'key-a'}, reason: 'read only');
        expect(early.getKeys().where((k) => k.contains('server_key')),
            isEmpty);
        // The app's first load moves it.
        final app = await AppSettings.load(prefs: appPrefs, keyStore: keys);
        expect(app.serverKeyHost, 'a.example');
        expect(storedServerKey(keys), ('key-a', 'a.example'));
        await app.setServerBaseUrl('https://b.example');
        final late = await runCache();
        expect(late.getString('settings.server_base_url'), 'https://b.example');
        for (final (cache, sent) in [
          (early, ['a.example <- key-a']),
          (late, <String>[]),
        ]) {
          final run = await AppSettings.load(
              prefs: cache, keyStore: keys, readOnlyKeys: true);
          expect((run.serverApiKey, run.serverKeyHost), ('key-a', 'a.example'));
          expect(run.serverKeyFor('b.example'), isNull);
          expect(await asked(run), sent);
        }
      });
    });
  });

  // Review of 2026-11-20 (PN-1, UPG-1, UPG-2): a key 1.7.0 (or iPhone
  // 1.6.0) stored as plain text was never stored with its host, so a
  // reinstall or a cleared address left it bound to none, in the key field
  // at any address and bound to the next one saved. The app engine now
  // moves it into the item at its first load, under a name 1.7.0 does not
  // read; the background engine, which may load at the same moment, only
  // reads.
  group('an upload key an earlier version stored: the move into the item',
      () {
    /// Prefs as 1.7.0 left them on an own-server install.
    Map<String, Object> prefs170({String url = 'https://a.example'}) => {
          'settings.provider': 'server',
          'settings.server_backend': 'claude',
          'settings.server_base_url': url,
          'settings.ai_consent_routes': <String>['server:claude'],
        };

    // Every interleaving of the two engines' server-key reads and writes:
    // each engine finds the same key bound the same way, the background
    // engine writes nothing, and the store ends as one item.
    final scenarios = <(
      String,
      Map<String, Object>,
      Map<String, String>,
      (String, String?)?, // the upload key (key, host), or none
      String?, // the key kept with no known host
    )>[
      (
        'a plain key and the address saved with it',
        prefs170(),
        {kLegacyServerKey: 'key-a'},
        ('key-a', 'a.example'),
        null,
      ),
      (
        'a plain key and the host recorded for it (a build before this one)',
        {...prefs170(url: 'https://b.example'),
          'settings.server_key_host': 'a.example'},
        {kLegacyServerKey: 'key-a'},
        ('key-a', 'a.example'),
        null,
      ),
      (
        'a plain key, no address naming a host, no record',
        prefs170(url: ''),
        {kLegacyServerKey: 'key-a'},
        null,
        'key-a',
      ),
      (
        'a move cut short: the item and the plain key it holds',
        prefs170(url: 'https://b.example'),
        {
          kLegacyServerKey: 'key-a',
          kServerKeyItem: jsonEncode({'key': 'key-a', 'host': 'a.example'}),
        },
        ('key-a', 'a.example'),
        null,
      ),
      (
        'another key next to the item: an older version stored it after',
        prefs170(url: 'https://c.example'),
        {
          kLegacyServerKey: 'key-c',
          kServerKeyItem: jsonEncode({'key': 'key-a', 'host': 'a.example'}),
        },
        ('key-c', 'c.example'),
        null,
      ),
    ];

    for (final (name, prefs, stored, key, kept) in scenarios) {
      test('both engines loading at once, in every order: $name', () async {
        /// The app engine's load and the background engine's, together,
        /// their server-key reads and writes taking turns as [order] says.
        Future<(AppSettings, AppSettings, _TurnTakingKeys)> run(
            List<String> order) async {
          SharedPreferences.setMockInitialValues(prefs);
          final appPrefs = await SharedPreferences.getInstance();
          SharedPreferences.resetStatic();
          final runPrefs = await SharedPreferences.getInstance();
          final keys = _TurnTakingKeys(order)..data.addAll(stored);
          final loaded = await Future.wait([
            AppSettings.load(prefs: appPrefs, keyStore: keys.engine('app')),
            AppSettings.load(
                prefs: runPrefs,
                keyStore: keys.engine('run'),
                readOnlyKeys: true),
          ]);
          return (loaded[0], loaded[1], keys);
        }

        // Once in no set order, to count each engine's operations; then
        // once per order those can run in.
        final (_, _, alone) = await run(const []);
        final appOps = alone.log.where((l) => l.startsWith('app ')).length;
        final runOps = alone.log.where((l) => l.startsWith('run ')).length;
        expect(runOps, 2, reason: 'the old name, then the item');
        final orders = _interleavings(appOps, runOps);
        expect(orders.length, greaterThan(1));
        for (final order in orders) {
          final (app, bg, keys) = await run(order);
          final why = '$order: ${keys.log}';
          for (final s in [app, bg]) {
            expect(
                s.serverApiKey == null
                    ? null
                    : (s.serverApiKey!, s.serverKeyHost),
                key,
                reason: why);
            expect(s.serverKeyHostUnknown, kept != null, reason: why);
          }
          expect(keys.log.where((l) => l.startsWith('run ')),
              everyElement(startsWith('run read')),
              reason: 'the background engine only reads: $why');
          final item = jsonDecode(keys.data[kServerKeyItem]!) as Map;
          expect(item['key'], key?.$1 ?? kept, reason: why);
          expect(item['host'], key?.$2, reason: why);
          expect(item['hostUnknown'] == true, kept != null, reason: why);
          expect(keys.data[kLegacyServerKey], kRetiredOldName, reason: why);
          final after = await SharedPreferences.getInstance();
          await after.reload();
          expect(after.getKeys().where((k) => k.contains('server_key')),
              isEmpty,
              reason: why);
        }
      });
    }

    test('a key with no known host goes to no host from either engine',
        () async {
      SharedPreferences.setMockInitialValues(prefs170(url: ''));
      final keys = MemoryKeyStore()..data[kLegacyServerKey] = 'key-a';
      final app = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
      await app.setServerBaseUrl('https://b.example');
      SharedPreferences.resetStatic();
      final bg = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: keys,
          readOnlyKeys: true);
      for (final s in [app, bg]) {
        final seen = <String>[];
        final client = MockClient((req) async {
          seen.add('${req.url.host} <- ${req.headers['X-API-Key']}');
          return http.Response(jsonEncode({'ok': true}), 200);
        });
        final analyzer =
            ServerAnalyzer(s, normalizer: (b) async => b, client: client);
        expect(await makeGarminDailyFetch(s, client: client)('2026-11-20'),
            isNull);
        final lookups = ServerLookupClient(s, client: client);
        final lookup = await lookups.submit(bigMacRequest,
            expectedRecipientStamp: lookups.lookupSupport().recipientStamp);
        expect(lookup.kind, isNot(LookupOutcomeKind.pending));
        final photo = await analyzer
            .analyzePhoto(Uint8List.fromList(const [0xFF, 0xD8, 0xFF]));
        expect(photo.error, isNotNull);
        expect((await analyzer.textIntentOutcome('lunch 500 kcal')).error,
            isNotNull);
        expect(await analyzer.serverFeatures(), isNull);
        expect(await analyzer.serverLoginState(), isNull);
        final started = await analyzer.startClaudeAuth();
        expect(started.url, isNull);
        await expectLater(
            analyzer.client.post(Uri.parse('https://b.example/api/x'),
                headers: {'X-API-Key': 'key-a'}),
            throwsA(isA<http.ClientException>()),
            reason: 'refused at the client too');
        expect(seen, isEmpty);
        for (final host in ['b.example', 'a.example', '']) {
          expect(s.serverKeyFor(host), isNull);
        }
      }
    });

    test('an item write that fails leaves the plain key where it was, bound '
        'as found, and the next load binds it the same way, not to an '
        'address saved since', () async {
      SharedPreferences.setMockInitialValues(prefs170());
      final prefs = await SharedPreferences.getInstance();
      final keys = _FailingKeys()..data[kLegacyServerKey] = 'key-a';
      keys.failWrites.add(kServerKeyItem);
      final app = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((app.serverApiKey, app.serverKeyHost), ('key-a', 'a.example'));
      expect(keys.data, {kLegacyServerKey: 'key-a'}, reason: 'still usable');
      expect(prefs.getString('settings.server_key_host'), 'a.example');
      // The address moves before the next launch.
      await app.setServerBaseUrl('https://b.example');
      expect(app.serverKeyFor('b.example'), isNull);
      final bg = await AppSettings.load(
          prefs: prefs, keyStore: keys, readOnlyKeys: true);
      expect((bg.serverApiKey, bg.serverKeyHost), ('key-a', 'a.example'));
      keys.failWrites.clear();
      final next = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((next.serverApiKey, next.serverKeyHost), ('key-a', 'a.example'));
      expect(next.serverKeyFor('b.example'), isNull);
      expect(storedServerKey(keys), ('key-a', 'a.example'));
      expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
    });

    test('an item write that fails for a key with no known host keeps it so '
        'at the next load, though an address naming a host is saved by '
        'then', () async {
      SharedPreferences.setMockInitialValues(prefs170(url: ''));
      final prefs = await SharedPreferences.getInstance();
      final keys = _FailingKeys()..data[kLegacyServerKey] = 'key-a';
      keys.failWrites.add(kServerKeyItem);
      final app = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(app.serverKeyHostUnknown, isTrue);
      expect(keys.data, {kLegacyServerKey: 'key-a'});
      expect(prefs.getBool('settings.server_key_host_lost'), isTrue);
      await app.setServerBaseUrl('https://b.example');
      for (final readOnly in [true, false]) {
        if (!readOnly) keys.failWrites.clear();
        final next = await AppSettings.load(
            prefs: prefs, keyStore: keys, readOnlyKeys: readOnly);
        expect(next.serverKeyHostUnknown, isTrue, reason: '$readOnly');
        expect(next.serverApiKey, isNull);
        expect(next.serverKeyFor('b.example'), isNull);
      }
      expect(storedKeyOfUnknownHost(keys), 'key-a');
      expect(keys.data[kLegacyServerKey], kRetiredOldName);
      expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
    });

    test('a retire of the old name that fails: the item is written, the next '
        'load finishes the move', () async {
      SharedPreferences.setMockInitialValues(prefs170());
      final prefs = await SharedPreferences.getInstance();
      final keys = _FailingKeys()..data[kLegacyServerKey] = 'key-a';
      keys.failWrites.add(kLegacyServerKey);
      final app = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((app.serverApiKey, app.serverKeyHost), ('key-a', 'a.example'));
      expect(keys.data[kLegacyServerKey], 'key-a');
      expect(decodeServerKeyItem(keys.data[kServerKeyItem]!),
          ('key-a', 'a.example'));
      expect(prefs.getString('settings.server_key_host'), 'a.example',
          reason: 'kept while the old name holds the key');
      await app.setServerBaseUrl('https://b.example');
      keys.failWrites.clear();
      final next = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((next.serverApiKey, next.serverKeyHost), ('key-a', 'a.example'));
      expect(storedServerKey(keys), ('key-a', 'a.example'));
      expect(prefs.getKeys().where((k) => k.contains('server_key')), isEmpty);
    });

    test('a key stored while the old name could not be read overwrites it, '
        'so it never comes back as a newer key', () async {
      SharedPreferences.setMockInitialValues(
          prefs170(url: 'https://b.example'));
      final prefs = await SharedPreferences.getInstance();
      // An older key under the old name that this run cannot read (Android
      // forgives the failed read as no key, and keeps the value).
      final keys = _FailingKeys()..data[kLegacyServerKey] = 'key-a';
      keys.unreadable.add(kLegacyServerKey);
      final app = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(app.serverApiKey, isNull);
      await app.setServerKeyFromField('key-b', filledAt: app.serverBaseUrl);
      expect(keys.data[kLegacyServerKey], kRetiredOldName,
          reason: 'overwritten');
      keys.unreadable.clear();
      final next = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((next.serverApiKey, next.serverKeyHost), ('key-b', 'b.example'));
      expect(next.serverKeyHostUnknown, isFalse);
    });

    // UPG-2: 1.7.0 reads only the old name, and took the item's text there
    // for the key, sending it as X-API-Key. It finds no key there now.
    test('an older version installed over this one finds no key; a key it '
        'stores is the newer one at the next update', () async {
      SharedPreferences.setMockInitialValues(prefs170());
      final prefs = await SharedPreferences.getInstance();
      final keys = MemoryKeyStore()..data[kLegacyServerKey] = 'key-a';
      final s = await AppSettings.load(prefs: prefs, keyStore: keys);
      await s.setServerBaseUrl('https://c.example');
      expect(keyAnOlderVersionReads(keys), isNull,
          reason: 'it asks for the key instead of sending the item');
      // Back on 1.7.0, the user pastes c.example's key: plain text under the
      // old name, the item left as it was.
      keys.data[kLegacyServerKey] = 'key-c';
      final upgraded = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((upgraded.serverApiKey, upgraded.serverKeyHost),
          ('key-c', 'c.example'));
      expect(upgraded.serverKeyFor('a.example'), isNull);
      expect(storedServerKey(keys), ('key-c', 'c.example'));
      // The same key pasted back: the item's binding stands.
      keys.data[kLegacyServerKey] = 'key-c';
      await upgraded.setServerBaseUrl('https://d.example');
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect((again.serverApiKey, again.serverKeyHost), ('key-c', 'c.example'));
      expect(storedServerKey(keys), ('key-c', 'c.example'));
      // With no address naming a host in the older version: no known host.
      keys.data[kLegacyServerKey] = 'key-e';
      await again.setServerBaseUrl('');
      final none = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(none.serverKeyHostUnknown, isTrue);
      expect(none.serverApiKey, isNull);
      expect(storedKeyOfUnknownHost(keys), 'key-e');
    });
  });

  group('restaurant assist settings', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('defaults: Off, no location, no consent', () async {
      final (s, _, _) = await freshSettings();
      expect(s.restaurantAssist, 'off');
      expect(s.restaurantAssistLocation, isFalse);
      expect(s.restaurantAssistConsentAt, isNull);
      expect(s.restaurantAssistConsentRecipient, isNull);
    });

    test('unknown or malformed stored values read as Off / no consent',
        () async {
      for (final junk in ['on', 'true', 'ALWAYS', '', 'auto ']) {
        final (s, _, _) = await freshSettings(initial: {
          'settings.restaurant_assist': junk,
        });
        expect(s.restaurantAssist, 'off', reason: '"$junk"');
      }
      final (s, _, _) = await freshSettings(initial: {
        'settings.restaurant_assist_consent_at': 'yesterday',
        // A host where the 8 hex characters should be: never a stamp.
        'settings.restaurant_assist_consent_recipient':
            'claude_plan:my.server.example',
      });
      expect(s.restaurantAssistConsentAt, isNull);
      expect(s.restaurantAssistConsentRecipient, isNull);
    });

    test('one write, one notification; a second load sees every value',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final (s, prefs, keys) = await freshSettings();
      var notified = 0;
      s.addListener(() => notified++);
      final at = DateTime(2026, 10, 24, 12, 30);
      await s.setRestaurantAssist(
        mode: 'auto',
        location: true,
        consentAt: at,
        consentRecipient: 'claude_plan:0a1b2c3d',
      );
      expect(notified, 1,
          reason: 'the assist must never see the mode without its consent');
      expect(s.restaurantAssist, 'auto');
      expect(s.restaurantAssistLocation, isTrue);
      expect(s.restaurantAssistConsentAt, at);
      expect(s.restaurantAssistConsentRecipient, 'claude_plan:0a1b2c3d');
      // The keys the design names; the instant as UTC.
      expect(prefs.getString('settings.restaurant_assist'), 'auto');
      expect(prefs.getBool('settings.restaurant_assist_location'), isTrue);
      expect(prefs.getString('settings.restaurant_assist_consent_at'),
          at.toUtc().toIso8601String());
      expect(prefs.getString('settings.restaurant_assist_consent_recipient'),
          'claude_plan:0a1b2c3d');

      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.restaurantAssist, 'auto');
      expect(again.restaurantAssistLocation, isTrue);
      expect(again.restaurantAssistConsentAt, at);
      expect(again.restaurantAssistConsentRecipient, 'claude_plan:0a1b2c3d');

      // Null leaves a value; Always keeps the consent.
      await again.setRestaurantAssist(mode: 'always');
      expect(again.restaurantAssist, 'always');
      expect(again.restaurantAssistConsentAt, at);
      // clearConsent forgets both halves, on disk too.
      await again.setRestaurantAssist(mode: 'off', clearConsent: true);
      expect(again.restaurantAssistConsentAt, isNull);
      expect(again.restaurantAssistConsentRecipient, isNull);
      expect(prefs.getString('settings.restaurant_assist_consent_at'), isNull);
      expect(prefs.getString('settings.restaurant_assist_consent_recipient'),
          isNull);
    });

    test('an unknown mode is stored as Off; a malformed recipient stamps no '
        'consent', () async {
      final (s, prefs, _) = await freshSettings();
      await s.setRestaurantAssist(mode: 'sometimes');
      expect(s.restaurantAssist, 'off');
      expect(prefs.getString('settings.restaurant_assist'), 'off');
      await s.setRestaurantAssist(
          consentAt: DateTime(2026, 10, 24),
          consentRecipient: 'claude_plan:HOST.example');
      expect(s.restaurantAssistConsentAt, isNull);
      expect(s.restaurantAssistConsentRecipient, isNull);
    });

    test('Use photo location reads false on Android whatever is stored',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (s, prefs, _) = await freshSettings(initial: {
        'settings.restaurant_assist_location': true,
      });
      expect(s.restaurantAssistLocation, isFalse);
      await s.setRestaurantAssist(location: true);
      expect(s.restaurantAssistLocation, isFalse,
          reason: 'Android reads no photo location in v1');
      expect(prefs.getBool('settings.restaurant_assist_location'), isTrue);
    });
  });
}

/// The in-memory preferences store, holding the latch's FIRST disk write
/// until [gate] completes ([gated] says it got there).
class _GatedStore extends InMemorySharedPreferencesStore {
  _GatedStore() : super.empty();
  Completer<void>? gate;
  final gated = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final g = gate;
    if (g != null && key.endsWith('settings.analysis_blocked_provider')) {
      if (!gated.isCompleted) gated.complete();
      await g.future;
    }
    return super.setValue(valueType, key, value);
  }
}

/// The in-memory preferences store, counting writes and removes.
class _CountingStore extends InMemorySharedPreferencesStore {
  _CountingStore() : super.empty();
  int writes = 0;
  @override
  Future<bool> remove(String key) {
    writes++;
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes++;
    return super.setValue(valueType, key, value);
  }
}
