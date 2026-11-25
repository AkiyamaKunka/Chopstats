// One-click setup (2026-09-28): a bitewise://setup link must be CONFIRMED
// before it changes where photos go, then land the user on Settings with
// the server configured. Malformed links are refused with a message.
import 'dart:async';

import 'package:calorie_tracker/core/ai_consent.dart'
    show aiConsentMealNoteVersion;
import 'package:calorie_tracker/core/server_transport.dart';
import 'package:calorie_tracker/core/setup_link.dart'
    show setupLinkRepeatWindow;
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/di.dart' show createSettingsStore;
import 'package:calorie_tracker/ui/provider_names.dart'
    show providerDisplayLabel;
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

void main() {
  const key = 'k1234567890abcdef';
  final good = Uri.parse(
      'bitewise://setup?server=https%3A%2F%2F10.0.0.7&key=$key&backend=claude');

  (UiServices, FakeSettings, StreamController<Uri>) rig() {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final links = StreamController<Uri>.broadcast();
    return (
      UiServices(
        dao: FakeDao(),
        analyzer: FakeAnalyzer(),
        executor: FakeExecutor(),
        settings: settings,
        picker: FakePicker(),
        requestPhotoPermission: () async => true,
        setupLinks: links.stream,
      ),
      settings,
      links,
    );
  }

  testWidgets('a valid link asks first, then configures the server',
      (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    expect(find.textContaining('https://10.0.0.7'), findsOneWidget);
    expect(find.textContaining('••••cdef'), findsOneWidget,
        reason: 'the key is shown masked, never in full');
    // The AI is named as Settings names it, not by the link's raw id, and
    // never as a 'Plan' (owner decision R-F5, 2026-10-29).
    expect(find.textContaining('AI: Claude (server)'), findsOneWidget);
    expect(find.textContaining(': claude'), findsNothing);
    expect(find.textContaining('Plan'), findsNothing);
    // Confirming is the consent, recorded under the current text: the
    // dialog lists what that text adds, the Edit meal note.
    expect(
        find.textContaining('recent meals and a note you send in Edit meal '
            '(with that meal) to Anthropic'),
        findsOneWidget);
    expect(settings.serverBaseUrl, isNot('https://10.0.0.7'),
        reason: 'nothing changes before confirmation');

    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.provider, 'server');
    expect(settings.serverBackend, 'claude');
    expect(settings.serverBaseUrl, 'https://10.0.0.7');
    expect(settings.apiKey, key);
    // Address and key in one change (review of PR 74): written one after
    // the other, a frame between them saw the link's address with the
    // previous server's key.
    expect(settings.serverSetups, [('claude', 'https://10.0.0.7', key)]);
    expect(settings.updateCalls, 0);
    expect(settings.aiConsentWrites, [('server:claude', true)]);
    expect(settings.aiConsentVersion('server:claude'),
        greaterThanOrEqualTo(aiConsentMealNoteVersion),
        reason: 'the first note asks nothing more');
    await links.close();
  });

  // The owner's phone is Chinese: the sheet read 套餐：claude (the raw
  // backend id) while the Settings row it lands on said Claude 订阅 (since
  // R-F5, 2026-10-29: AI：你服务器上的 Claude), and
  // its 12-glyph title wrapped to an orphaned 器？ on the iPhone 17 Pro
  // (loop find 2026-10-10). The id is still what gets saved.
  testWidgets('zh: the sheet names the plan as Settings does, title fits',
      (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomeShell(services: services),
    ));
    links.add(Uri.parse(
        'bitewise://setup?server=https%3A%2F%2F10.0.0.7&key=$key&backend=glm'));
    await tester.pumpAndSettle();
    expect(find.text('用此链接配置服务器？'), findsOneWidget);
    expect(find.textContaining('AI：你服务器上的 GLM'), findsOneWidget);
    expect(find.textContaining('：glm'), findsNothing);
    expect(find.textContaining('套餐'), findsNothing);
    expect(find.textContaining('以及你在「编辑这一餐」里发送的说明（连同那一餐）'),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.serverBackend, 'glm',
        reason: 'the raw id is saved; only the sheet shows the label');
    await links.close();
  });

  testWidgets('cancel leaves settings untouched', (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.apiKey, 'old');
    expect(settings.serverBaseUrl, isNot('https://10.0.0.7'));
    await links.close();
  });

  testWidgets('a malformed link is refused, not guessed', (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(Uri.parse('bitewise://setup?server=ftp%3A%2F%2Fx&key=$key'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
    expect(find.text('That setup link is not valid.'), findsOneWidget);
    expect(settings.apiKey, 'old');
    await links.close();
  });

  // Owner decision 2026-11-13: plain http is refused everywhere. A link
  // naming an http:// server sets nothing up and says why, in both
  // languages; with the https switch off it is confirmed as before.
  final plain = Uri.parse(
      'bitewise://setup?server=http%3A%2F%2F10.0.0.7&key=$key&backend=claude');

  for (final (locale, text) in [
    (const Locale('en'), 'That setup link names a server without https://. '
        'Chopstats sends nothing to a plain http:// server, so nothing was '
        'set up.'),
    (const Locale('zh'), '这个配置链接里的服务器地址不是 https://。筷拍不会向普通的 '
        'http:// 服务器发送任何内容，所以没有进行任何设置。'),
  ]) {
    testWidgets('an http:// server link is refused and says why '
        '(${locale.languageCode})', (tester) async {
      debugRequireHttpsServerOverride = true;
      addTearDown(() => debugRequireHttpsServerOverride = null);
      final (services, settings, links) = rig();
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomeShell(services: services),
      ));
      links.add(plain);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
      expect(find.text(text), findsOneWidget);
      expect(settings.apiKey, 'old');
      expect(settings.serverBaseUrl, isNot(contains('10.0.0.7')));
      expect(settings.aiConsentWrites, isEmpty);
      await links.close();
    });
  }

  testWidgets('an http:// server link with the https switch off is '
      'confirmed as before', (tester) async {
    debugRequireHttpsServerOverride = false;
    addTearDown(() => debugRequireHttpsServerOverride = null);
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(plain);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.serverBaseUrl, 'http://10.0.0.7');
    expect(settings.apiKey, key);
    await links.close();
  });

  testWidgets('a cold-start link is handled too', (tester) async {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      initialSetupLink: () async => good,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
  });

  // Review 2026-10-25: app_links' stream also carries the link that
  // cold-started the app, which the initial-link read delivered already —
  // two confirmations for one link (simctl openurl on a cold start).
  testWidgets('a cold-start link that the stream repeats asks once',
      (tester) async {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final links = StreamController<Uri>.broadcast();
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      setupLinks: links.stream,
      initialSetupLink: () async => good,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing,
        reason: 'no second dialog behind the first');
    expect(settings.apiKey, key);
    await links.close();
  });

  // LINK-1 (2026-11-22): app_links answers every initial-link read with the
  // first link it was given, for as long as the plugin lives, and each shell
  // reads it in initState. The second shell that a bare link's route pushed
  // (RCREL-V-1), or a shell built again, asked about that link once more.
  // di.dart reads the plugin through launchLinkOnce (production_wiring_test
  // pins the line).
  for (final pushed in [true, false]) {
    testWidgets(
        'two shells in a row ask about the launch link once '
        '(${pushed ? 'the second pushed over the first' : 'the first gone'})',
        (tester) async {
      final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
      var pluginReads = 0;
      // As app_links: the same link, to every read.
      final initial = launchLinkOnce(() async {
        pluginReads++;
        return good;
      });
      var shellReads = 0;
      final services = UiServices(
        dao: FakeDao(),
        analyzer: FakeAnalyzer(),
        executor: FakeExecutor(),
        settings: settings,
        picker: FakePicker(),
        requestPhotoPermission: () async => true,
        initialSetupLink: () {
          shellReads++;
          return initial();
        },
      );
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('setupLinkConfirm')));
      await tester.pumpAndSettle();
      expect(settings.serverSetups, [('claude', 'https://10.0.0.7', key)]);

      if (pushed) {
        unawaited(Navigator.of(tester.element(find.byType(HomeShell))).push(
            MaterialPageRoute<void>(
                builder: (_) => HomeShell(services: services))));
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester
            .pumpWidget(MaterialApp(home: HomeShell(services: services)));
      }
      await tester.pumpAndSettle();
      expect(shellReads, 2, reason: 'the second shell read it too');
      expect(find.byKey(const Key('setupLinkConfirm')), findsNothing,
          reason: 'the launch link is asked about once');
      expect(settings.serverSetups, hasLength(1));
      expect(pluginReads, 1);
    });
  }

  testWidgets('the same link opened again later asks again', (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // The window is measured on the wall clock.
    await tester.runAsync(() => Future<void>.delayed(
        setupLinkRepeatWindow + const Duration(milliseconds: 50)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    expect(settings.apiKey, 'old');
    await links.close();
  });

  // iOS share sheet: receive_sharing_intent bounces the extension to the
  // host app by opening `ShareMedia-<bundle>:share`, and app_links forwards
  // that URL to us too. It is not a setup link; it must not produce the
  // "not valid" snackbar (seen on every share before this test existed).
  final shareBounce =
      Uri.parse('ShareMedia-dev.calorietracker.calorieTracker:share');

  testWidgets('the share-extension bounce URL is ignored silently (warm)',
      (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(shareBounce);
    await tester.pumpAndSettle();
    expect(find.text('That setup link is not valid.'), findsNothing);
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
    expect(settings.apiKey, 'old');
    await links.close();
  });

  testWidgets('the share-extension bounce URL is ignored silently (cold)',
      (tester) async {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      initialSetupLink: () async => shareBounce,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    await tester.pumpAndSettle();
    expect(find.text('That setup link is not valid.'), findsNothing);
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
    expect(settings.apiKey, 'old');
  });

  // Android push (ui lane, sweep C12): confirming a link while Watch
  // Camera Roll is on sends every new library photo, non-food included, to
  // the new server from then on, yet the dialog never said so (the
  // recipient-change dialog does). Every case above has the watcher off.
  group('with Watch Camera Roll on', () {
    (UiServices, FakeSettings, StreamController<Uri>) watching(
        {int lookbackDays = 3}) {
      final settings = FakeSettings(
          apiKey: 'old', watcherEnabled: true, lookbackDays: lookbackDays);
      final links = StreamController<Uri>.broadcast();
      return (
        UiServices(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          executor: FakeExecutor(),
          settings: settings,
          picker: FakePicker(),
          requestPhotoPermission: () async => true,
          setupLinks: links.stream,
        ),
        settings,
        links,
      );
    }

    // The dialog's body: the one text that shows the masked key.
    String dialogText(WidgetTester tester) => tester
        .widgetList<Text>(find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .singleWhere((t) => t.contains('••••'));

    testWidgets('the camera-roll notice leads, as in the recipient-change '
        'dialog', (tester) async {
      final (services, settings, links) = watching();
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      links.add(good);
      await tester.pumpAndSettle();
      final l = AppLocalizationsEn();
      final notice = l.watcherDisclosureBody(
          providerDisplayLabel(l, 'server', 'claude'), 3);
      final text = dialogText(tester);
      expect(text, startsWith(notice));
      expect(text.indexOf(notice), lessThan(text.indexOf('Server: ')));
      expect(text, contains(l.setupLinkSharing(
          l.aiConsentPlanCompany('claude'))));

      await tester.tap(find.byKey(const Key('setupLinkConfirm')));
      await tester.pumpAndSettle();
      expect(settings.provider, 'server');
      expect(settings.watcherEnabled, isTrue);
      await links.close();
    });

    testWidgets('zh: the notice names the plan as Settings does',
        (tester) async {
      final (services, _, links) = watching(lookbackDays: 45);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomeShell(services: services),
      ));
      links.add(Uri.parse('bitewise://setup?server=https%3A%2F%2Fmy.example'
          '&key=$key&backend=glm'));
      await tester.pumpAndSettle();
      final l = AppLocalizationsZh();
      // The lookback is clamped to 30 days, as the switch's notice is.
      expect(
          dialogText(tester),
          startsWith(l.watcherDisclosureBody(
              providerDisplayLabel(l, 'server', 'glm'), 30)));
      await links.close();
    });

    testWidgets('cancel still changes nothing', (tester) async {
      final (services, settings, links) = watching();
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      links.add(good);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.apiKey, 'old');
      expect(settings.provider, isNot('server'));
      await links.close();
    });
  });

  // Review of PR 74, recheck: a link confirmed while Settings › Your own
  // server was open left the page on top with both fields on the previous
  // server. Its key, edited at the caret, was saved as the link's host's
  // key and sent there; the address field invited typing the old address
  // back. With the real store and the shell's own dialog: the page shows
  // the link's server, and nothing of the previous key reaches it.
  for (final (start, name) in const [
    ('https://a.example', 'at the previous server'),
    ('', 'with the address cleared'),
  ]) {
    testWidgets('confirmed with the server page open $name: the page shows '
        'the link\'s address and key, and an edit carries none of the '
        'previous key', (tester) async {
      const keyA = 'key-a-0123456789';
      SharedPreferences.setMockInitialValues({});
      final app = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await app.setProvider(AiProvider.server);
      await app.setServerBaseUrl('https://a.example');
      await app.setServerApiKey(keyA);
      await app.setServerBaseUrl(start);
      final store = createSettingsStore(app);
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      await tester.pumpWidget(MaterialApp(
          home: HomeShell(
              services: UiServices(
        dao: FakeDao(),
        analyzer: FakeAnalyzer(),
        executor: FakeExecutor(),
        settings: store,
        picker: FakePicker(),
        requestPhotoPermission: () async => true,
        setupLinks: links.stream,
      ))));
      await tester.pumpAndSettle();
      unawaited(Navigator.of(tester.element(find.byType(HomeShell))).push(
          MaterialPageRoute<void>(
              builder: (_) => SubscriptionProviderPage(settings: store))));
      await tester.pumpAndSettle();
      final keyField = find.byKey(const Key('serverUploadKeyField'));
      String text(Key key) => tester
          .widget<EditableText>(find.descendant(
              of: find.byKey(key), matching: find.byType(EditableText)))
          .controller
          .text;
      // The key field focused, as when the link comes in mid-edit.
      await tester.tap(keyField);
      await tester.pumpAndSettle();

      links.add(good);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('setupLinkConfirm')));
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionProviderPage), findsOneWidget);
      expect(text(const Key('serverUrlField')), 'https://10.0.0.7');
      expect(text(const Key('serverUploadKeyField')), key);

      await tester.tap(keyField);
      await tester.pumpAndSettle();
      final value = tester
          .state<EditableTextState>(find.descendant(
              of: keyField, matching: find.byType(EditableText)))
          .textEditingValue;
      tester.testTextInput
          .updateEditingValue(value.replaced(value.selection, 'x'));
      await tester.pumpAndSettle();
      expect((app.serverApiKey, app.serverKeyHost), ('${key}x', '10.0.0.7'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(app.serverBaseUrl, 'https://10.0.0.7');
      expect((app.serverApiKey, app.serverKeyHost), ('${key}x', '10.0.0.7'));
    });
  }

  testWidgets('with the watcher off there is no camera-roll notice',
      (tester) async {
    final (services, _, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('Watch Camera Roll')),
        findsNothing);
    await links.close();
  });
}
