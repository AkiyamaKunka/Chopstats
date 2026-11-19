// The Google Play build installed over a GitHub install (one package, one
// signer: it updates in place, meal log and settings kept). The GitHub
// install may have had Watch Camera Roll on; the Play build has no such
// feature (core/app_channel.dart). Its first launch turns the setting off,
// the job sync cancels the job (background_glue_test), and the app shell
// shows ONE notice saying so and how to log photos instead. Nothing is
// lost.
import 'package:calorie_tracker/core/app_channel.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/play_channel.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

final _en = AppLocalizationsEn();
final _zh = AppLocalizationsZh();

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {'gemini_api_key': 'k'};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Future<(AppSettings, SharedPreferences)> _load(
  Map<String, Object> values,
) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  return (await AppSettings.load(prefs: prefs, keyStore: _Keys()), prefs);
}

/// A GitHub install with Watch Camera Roll on and a few other settings.
const _githubInstall = <String, Object>{
  'settings.watcher_enabled': true,
  'settings.lookback_days': 5,
  'settings.watch_glasses': false,
  'settings.report_time': '20:30',
};

void main() {
  tearDown(() => debugAppChannelOverride = null);

  group('the move off Watch Camera Roll (retireWatchCameraRoll)', () {
    test('the GitHub APK: nothing changes', () async {
      final (settings, prefs) = await _load(_githubInstall);
      expect(await retireWatchCameraRoll(settings, prefs), isFalse);
      expect(settings.watcherEnabled, isTrue);
      expect(watchRetiredNoticeOwed(prefs), isFalse);
      expect(prefs.getBool(watchRetiredNoticePrefsKey), isNull);
    });

    test('the Play build over a GitHub install with it on: off, on disk '
        'too, the notice owed, and nothing else touched', () async {
      debugAppChannelOverride = AppChannel.play;
      final (settings, prefs) = await _load(_githubInstall);
      expect(await retireWatchCameraRoll(settings, prefs), isTrue);
      expect(settings.watcherEnabled, isFalse);
      expect(watchRetiredNoticeOwed(prefs), isTrue);
      // What the next launch reads.
      final reloaded = await AppSettings.load(prefs: prefs, keyStore: _Keys());
      expect(reloaded.watcherEnabled, isFalse);
      expect(reloaded.lookbackDays, 5);
      expect(reloaded.watchGlasses, isFalse);
      expect(reloaded.reportTime, '20:30');
      expect(reloaded.activeApiKey, 'k');
    });

    test('once only: a second launch changes nothing, and the notice stays '
        'owed until it was shown', () async {
      debugAppChannelOverride = AppChannel.play;
      final (settings, prefs) = await _load(_githubInstall);
      await retireWatchCameraRoll(settings, prefs);
      expect(await retireWatchCameraRoll(settings, prefs), isFalse);
      expect(watchRetiredNoticeOwed(prefs), isTrue);
      await watchRetiredNoticeShown(prefs);
      expect(watchRetiredNoticeOwed(prefs), isFalse);
      expect(await retireWatchCameraRoll(settings, prefs), isFalse);
      expect(watchRetiredNoticeOwed(prefs), isFalse);
    });

    test('a fresh Play install, or one with it off: no notice', () async {
      debugAppChannelOverride = AppChannel.play;
      final (settings, prefs) = await _load({
        'settings.watcher_enabled': false,
      });
      expect(await retireWatchCameraRoll(settings, prefs), isFalse);
      expect(watchRetiredNoticeOwed(prefs), isFalse);
    });

    test('the GitHub APK never owes the notice, even with the flag left by '
        'a Play build it replaced', () async {
      final (_, prefs) = await _load({watchRetiredNoticePrefsKey: true});
      expect(watchRetiredNoticeOwed(prefs), isFalse);
      debugAppChannelOverride = AppChannel.play;
      expect(watchRetiredNoticeOwed(prefs), isTrue);
    });
  });

  group('the one notice over the shell', () {
    late bool owed;
    late int shownCalls;

    setUp(() {
      owed = true;
      shownCalls = 0;
    });

    UiServices services({bool withNotice = true}) => UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: FakeSettings(apiKey: 'k'),
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      watchRetiredNotice: withNotice
          ? OwedNotice(
              pending: () => owed,
              shown: () async {
                shownCalls++;
                owed = false;
              },
            )
          : null,
    );

    Future<void> launch(
      WidgetTester tester,
      UiServices s, {
      Locale locale = const Locale('en'),
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeShell(services: s),
        ),
      );
      await tester.pumpAndSettle();
    }

    final notice = find.byKey(const Key('watchRetiredNotice'));

    for (final (locale, l) in [
      (const Locale('en'), _en as AppLocalizations),
      (const Locale('zh'), _zh as AppLocalizations),
    ]) {
      testWidgets('[${locale.languageCode}] said once: what changed, that '
          'nothing was lost, and how to log photos instead', (tester) async {
        final s = services();
        await launch(tester, s, locale: locale);
        expect(notice, findsOneWidget);
        expect(find.text(l.watchRetiredTitle), findsOneWidget);
        expect(find.text(l.watchRetiredBody), findsOneWidget);
        await tester.tap(find.byKey(const Key('watchRetiredOk')));
        await tester.pumpAndSettle();
        expect(notice, findsNothing);
        expect(shownCalls, 1);

        // Never again: a return to the app, or a later launch.
        final shell =
            tester.state(find.byType(HomeShell)) as WidgetsBindingObserver;
        shell.didChangeAppLifecycleState(AppLifecycleState.paused);
        shell.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(notice, findsNothing);
        await tester.pumpWidget(const SizedBox());
        await launch(tester, s, locale: locale);
        expect(notice, findsNothing);
        expect(shownCalls, 1);
      });
    }

    testWidgets('dismissed any other way, it is forgotten too', (tester) async {
      await launch(tester, services());
      expect(notice, findsOneWidget);
      await tester.tapAt(const Offset(4, 4)); // the barrier
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
      expect(shownCalls, 1);
      expect(owed, isFalse);
    });

    testWidgets('nothing owed (a fresh Play install), or no notice at all '
        '(the GitHub APK): nothing shown', (tester) async {
      owed = false;
      await launch(tester, services());
      expect(notice, findsNothing);
      await tester.pumpWidget(const SizedBox());
      owed = true;
      await launch(tester, services(withNotice: false));
      expect(notice, findsNothing);
      expect(shownCalls, 0);
    });
  });
}
