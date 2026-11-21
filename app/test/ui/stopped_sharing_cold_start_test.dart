/// Android QA Q2: with sharing stopped for the user's own server (Settings
/// › Stop Sharing), a cold start still sent POST /api/auth_check with the
/// upload key. The shell builds Settings at launch (its tabs sit in an
/// IndexedStack), and the Restaurant nutrition group asked the server what
/// it supports. The consent says nothing is sent before Allow and nothing
/// more after Stop Sharing.
///
/// Wired as di.dart wires it: the real AppSettings behind the production
/// store adapter, the real ServerAnalyzer, and the group's serverState as
/// di.dart builds it, over an HTTP client that counts every request that
/// would reach the network.
library;

import 'dart:convert';

import 'package:calorie_tracker/core/ai_consent.dart' show aiConsentRoute;
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/di.dart' show createSettingsStore;
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/screens/settings/restaurant_section.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

void main() {
  late AppSettings settings;
  late List<http.BaseRequest> seen;
  late ServerAnalyzer server;
  final route = aiConsentRoute('server', 'claude');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: MemoryKeyStore());
    await settings.setProvider(AiProvider.server);
    await settings.setServerBaseUrl('https://bitewise.example.test');
    await settings.setServerApiKey('upload-key');
    seen = [];
    server = ServerAnalyzer(settings, client: MockClient((req) async {
      seen.add(req);
      return http.Response(
          jsonEncode({
            'ok': true,
            'features': {'restaurant_lookup': false, 'lookup_jobs': true},
          }),
          200);
    }));
  });

  Future<void> coldStart(WidgetTester tester) async {
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
      // As di.dart builds it.
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
    expect(find.byType(RestaurantAssistSection), findsOneWidget,
        reason: 'the group that asks is built');
  }

  testWidgets('sharing stopped: a cold start sends nothing to the server, '
      'not even the free check; Allow again and it asks once', (tester) async {
    await settings.setAiConsent(route, granted: true);
    await settings.setAiConsent(route, granted: false); // Stop Sharing
    await coldStart(tester);
    expect(seen, isEmpty, reason: 'no request, so no upload key');
    expect(
        find.textContaining('Restaurant lookup is turned off on your server.'),
        findsNothing);

    await settings.setAiConsent(route, granted: true);
    await tester.pumpAndSettle();
    expect(seen.map((r) => '${r.method} ${r.url.path}'),
        ['POST /api/auth_check']);
    expect(find.textContaining('Restaurant lookup is turned off on your server.'),
        findsOneWidget,
        reason: 'what the server said, once it may be asked');
  });

  testWidgets('never allowed: a cold start sends nothing', (tester) async {
    await coldStart(tester);
    expect(seen, isEmpty);
  });

  testWidgets('allowed: the check goes out as before, once', (tester) async {
    await settings.setAiConsent(route, granted: true);
    await coldStart(tester);
    expect(seen.map((r) => r.url.path), ['/api/auth_check']);
    expect(seen.single.headers['X-API-Key'], 'upload-key');
  });
}
