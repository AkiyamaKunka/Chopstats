// Review of PR 74: every request to the own server reads the saved address
// and upload key as it is built. With the address changed before the key
// (the address field saves as the key field is tapped), Settings' still
// mounted Restaurant nutrition group asked the new host what it supports
// at once, with the previous server's key. The key now goes only to the
// host it was saved for: the group asks nothing until the new server's key
// is pasted (and asks once it rests), the key field says which host the
// key was saved for, and one tap makes it the new address's key.
import 'dart:convert';

import 'package:calorie_tracker/core/ai_consent.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/di.dart' show createSettingsStore;
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/screens/settings/restaurant_section.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

void main() {
  group('the Restaurant group\'s check, wired as di.dart wires it', () {
    late AppSettings settings;
    late List<String> seen; // 'host <- key'
    late ServerAnalyzer server;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await settings.setProvider(AiProvider.server);
      await settings.setServerBaseUrl('https://a.example');
      await settings.setServerApiKey('key-a');
      await settings.setAiConsent(aiConsentRoute('server', 'claude'),
          granted: true);
      seen = [];
      server = ServerAnalyzer(settings, client: MockClient((req) async {
        seen.add('${req.url.host} <- ${req.headers['X-API-Key']}');
        return http.Response(
            jsonEncode({
              'ok': true,
              'features': {'restaurant_lookup': true, 'lookup_jobs': true},
            }),
            200);
      }));
    });

    Future<void> openSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controls = RestaurantAssistControls(
        lookupSupport: () => const LookupSupport(
          supported: true,
          recipient: LookupRecipient.claudePlan,
          locationAllowed: true,
          recipientHostTag: '0a1b2c3d',
        ),
        clearLearnedPlaces: () async => true,
        serverState: () async =>
            assistServerStateOf(await server.serverFeatures()),
      );
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SettingsScreen(
            settings: createSettingsStore(settings),
            analyzer: FakeAnalyzer(),
            dao: FakeDao(),
            requestPhotoPermission: () async => true,
            changes: settings,
            restaurantAssist: controls,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(RestaurantAssistSection), findsOneWidget);
    }

    testWidgets('a new address saved before its key: the new host is asked '
        'nothing with the old key; the new key is asked with, once it rests',
        (tester) async {
      await openSettings(tester);
      expect(seen, ['a.example <- key-a']);

      // What the address field's save does as the key field is tapped.
      await settings.setServerBaseUrl('https://b.example');
      await tester.pumpAndSettle();
      expect(seen, ['a.example <- key-a'],
          reason: 'key-a was saved for a.example');

      // The new server's key, typed: saved per keystroke, asked once.
      for (final typed in ['k', 'ke', 'key-b']) {
        await settings.setServerApiKey(typed);
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(seen, hasLength(1), reason: 'not per keystroke');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(seen, ['a.example <- key-a', 'b.example <- key-b']);
    });

    testWidgets('the same server at a new address: asked once the key is '
        'made its own', (tester) async {
      await openSettings(tester);
      await settings.setServerBaseUrl('https://203.0.113.5');
      await tester.pumpAndSettle();
      expect(seen, hasLength(1));
      await settings.bindServerKeyToAddress();
      await tester.pumpAndSettle();
      expect(seen, ['a.example <- key-a', '203.0.113.5 <- key-a']);
    });
  });

  group('Settings › Your own server', () {
    FakeSettings keyFromAnotherServer() =>
        FakeSettings(keys: {'server': 'key-a'})
          ..provider = 'server'
          ..serverBaseUrl = 'https://b.example'
          ..keySavedFor = 'a.example';

    Future<void> open(WidgetTester tester, FakeSettings settings,
        {Locale locale = const Locale('en'),
        Future<({String? url, String? error})> Function()? start}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SubscriptionProviderPage(
          settings: settings,
          startClaudeAuth: start,
          completeClaudeAuth: start == null ? null : (_) async => null,
          openUrl: (_) async => true,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('the key field says the key was saved for another host; '
        'one tap makes it this address\'s', (tester) async {
      final settings = keyFromAnotherServer();
      await open(tester, settings);
      expect(find.text('Saved for a.example: not sent to the address above.'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('serverKeyUseHereRow')));
      await tester.pumpAndSettle();
      expect(settings.bindServerKeyCalls, 1);
      expect(find.textContaining('Saved for a.example'), findsNothing);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsNothing);
    });

    testWidgets('pasting this server\'s key clears it; saving the same key '
        'again does not', (tester) async {
      final settings = keyFromAnotherServer();
      await open(tester, settings);
      final field = find.byKey(const Key('serverUploadKeyField'));
      // A tap outside re-saves the field as it is: still a.example's key.
      await tester.tap(field);
      await tester.pump();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(settings.keySavedFor, 'a.example');
      expect(find.textContaining('Saved for a.example'), findsOneWidget);
      await tester.enterText(field, 'key-b');
      await tester.pumpAndSettle();
      expect(settings.apiKey, 'key-b');
      expect(find.textContaining('Saved for a.example'), findsNothing);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsNothing);
    });

    testWidgets('zh: the line and the row', (tester) async {
      await open(tester, keyFromAnotherServer(), locale: const Locale('zh'));
      expect(find.text('为 a.example 保存：不会发送到上面的地址。'), findsOneWidget);
      expect(find.text('将此密钥用于 b.example'), findsOneWidget);
    });

    testWidgets('Connect Claude says so and sends nothing, asking nothing',
        (tester) async {
      final settings = keyFromAnotherServer()..aiConsent = {};
      var starts = 0;
      await open(tester, settings, start: () async {
        starts++;
        return (url: null, error: 'stop here');
      });
      await tester.tap(find.byKey(const Key('connectClaudeButton')));
      await tester.pumpAndSettle();
      expect(starts, 0);
      expect(find.byKey(const Key('aiConsentDialog')), findsNothing);
      expect(
          find.text("Your server upload key was saved for another server "
              "address, and Chopstats sends it only there. In AI Provider › "
              "Your own server, paste this server's key or use the saved "
              'one for it.'),
          findsOneWidget);
      expect(AppLocalizationsZh().errServerKeyOtherHost,
          contains('另一个服务器地址'));
    });
  });
}
