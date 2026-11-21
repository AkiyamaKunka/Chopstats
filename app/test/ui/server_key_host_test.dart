// Review of PR 74: every request to the own server reads the saved address
// and upload key as it is built. With the address changed before the key
// (the address field saves as the key field is tapped), Settings' still
// mounted Restaurant nutrition group asked the new host what it supports
// at once, with the previous server's key. The key now goes only to the
// host it was saved for: the group asks nothing until the new server's key
// is pasted (and asks once it rests), the key field is empty and says which
// host the key was saved for, and one tap makes it the new address's key.
import 'dart:async';
import 'dart:convert';

import 'package:calorie_tracker/core/ai_consent.dart';
import 'package:calorie_tracker/core/server_transport.dart'
    show serverKeyHostOf;
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
import 'package:calorie_tracker/ui/services.dart' show SettingsStore;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Recheck of the fix above: with the address moved to another host, the
  // obscured key field still held the previous server's key. Any edit of it
  // was a new key, bound to the new host: a paste at the caret (iOS's Paste
  // in the focused field, Android's long-press past the dots, a keyboard's
  // clipboard chip) or one backspace, and the Restaurant group still
  // mounted under the page asked the new host with it once it rested.
  group('the key field after the address moves, on the page over Settings',
      () {
    const keyA = 'key-a-0123456789';
    late AppSettings settings;
    late List<String> seen; // 'host <- key'
    late ServerAnalyzer server;
    late String clipboard;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await settings.setProvider(AiProvider.server);
      await settings.setServerBaseUrl('https://a.example');
      await settings.setServerApiKey(keyA);
      await settings.setAiConsent(aiConsentRoute('server', 'claude'),
          granted: true);
      seen = [];
      clipboard = 'key-b';
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

    final keyField = find.byKey(const Key('serverUploadKeyField'));
    final keyEditable =
        find.descendant(of: keyField, matching: find.byType(EditableText));
    String keyText(WidgetTester tester) =>
        tester.widget<EditableText>(keyEditable).controller.text;
    const savedForA = 'Saved for a.example: not sent to the address above.';

    /// Settings with the Restaurant group, as di.dart wires it, and the
    /// server page pushed over it with the same store.
    Future<void> openServerPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => switch (call.method) {
                'Clipboard.hasStrings' => {'value': true},
                'Clipboard.getData' => {'text': clipboard},
                _ => null,
              });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final store = createSettingsStore(settings);
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
            settings: store,
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
      expect(seen, ['a.example <- $keyA']);
      unawaited(Navigator.of(tester.element(find.byType(SettingsScreen)))
          .push(MaterialPageRoute<void>(
              builder: (_) => SubscriptionProviderPage(settings: store))));
      await tester.pumpAndSettle();
      expect(keyText(tester), keyA);
    }

    /// The address field's edit, saved as the key field is tapped.
    Future<void> moveAddress(WidgetTester tester, String url) async {
      await tester.enterText(find.byKey(const Key('serverUrlField')), url);
      await tester.tap(keyField);
      await tester.pumpAndSettle();
    }

    /// Past the rest the Restaurant group waits after a key edit.
    Future<void> rest(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
    }

    /// Long-press in the field (past the dots, where there are any), then
    /// the toolbar's Paste.
    Future<void> longPressPaste(WidgetTester tester) async {
      await tester.longPress(keyEditable);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
    }

    /// What a keyboard's clipboard chip does: [text] at the caret.
    Future<void> commitAtCaret(WidgetTester tester, String text) async {
      final value = tester.state<EditableTextState>(keyEditable)
          .textEditingValue;
      tester.testTextInput
          .updateEditingValue(value.replaced(value.selection, text));
      await tester.pumpAndSettle();
    }

    void expectOnlyKeyB() {
      expect(settings.serverApiKey, 'key-b');
      expect(settings.serverKeyHost, 'b.example');
      final toB = seen.where((s) => s.startsWith('b.example ')).toList();
      expect(toB, isNotEmpty, reason: 'the new key is asked with');
      expect(toB, everyElement('b.example <- key-b'),
          reason: 'nothing of a.example\'s key goes to b.example');
    }

    for (final platform in const [
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      testWidgets('${platform.name}: long-press and Paste in the field at '
          'the new address sends b.example the pasted key alone',
          (tester) async {
        await openServerPage(tester);
        await moveAddress(tester, 'https://b.example');
        expect(settings.serverBaseUrl, 'https://b.example');
        expect(keyText(tester), isEmpty,
            reason: 'a.example\'s key is not in the field to be edited');
        expect(find.text(savedForA), findsOneWidget);
        expect(find.byKey(const Key('serverKeyUseHereRow')), findsOneWidget);
        await longPressPaste(tester);
        await rest(tester);
        expectOnlyKeyB();
        expect(find.textContaining('Saved for'), findsNothing);
      }, variant: TargetPlatformVariant.only(platform));
    }

    testWidgets('a keyboard commit at the caret sends b.example the '
        'committed key alone', (tester) async {
      await openServerPage(tester);
      await moveAddress(tester, 'https://b.example');
      await commitAtCaret(tester, 'key-b');
      await rest(tester);
      expectOnlyKeyB();
    });

    testWidgets('the untouched field: a tap outside, Done and a backspace '
        'keep a.example\'s key for a.example and send b.example nothing',
        (tester) async {
      await openServerPage(tester);
      await moveAddress(tester, 'https://b.example');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(keyField);
      await tester.pump();
      // Blank page below the sections (the back button is top left).
      await tester.tapAt(const Offset(400, 3150));
      await rest(tester);
      expect(settings.serverApiKey, keyA);
      expect(settings.serverKeyHost, 'a.example');
      expect(find.text(savedForA), findsOneWidget);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsOneWidget);
      expect(seen, ['a.example <- $keyA']);
    });

    testWidgets('the address moved back puts the key back in the field; so '
        'does Use this key', (tester) async {
      await openServerPage(tester);
      await moveAddress(tester, 'https://b.example');
      await moveAddress(tester, 'https://a.example');
      expect(keyText(tester), keyA);
      expect(find.text(savedForA), findsNothing);

      await moveAddress(tester, 'https://203.0.113.5');
      expect(keyText(tester), isEmpty);
      await tester.tap(find.byKey(const Key('serverKeyUseHereRow')));
      await tester.pumpAndSettle();
      expect(settings.serverKeyHost, '203.0.113.5');
      expect(keyText(tester), keyA);
      expect(seen.last, '203.0.113.5 <- $keyA');
    });

    testWidgets('the same server\'s key pasted at its new address is that '
        'address\'s key, as Use this key makes it', (tester) async {
      clipboard = keyA;
      await openServerPage(tester);
      await moveAddress(tester, 'https://203.0.113.5');
      expect(keyText(tester), isEmpty);
      await longPressPaste(tester);
      await rest(tester);
      expect(settings.serverApiKey, keyA);
      expect(settings.serverKeyHost, '203.0.113.5');
      expect(find.textContaining('Saved for'), findsNothing);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsNothing);
      expect(seen, ['a.example <- $keyA', '203.0.113.5 <- $keyA']);
    });
  });

  // Recheck of the fix above: the field was emptied only when saving the
  // address flipped serverKeyForOtherAddress, which an address naming no
  // host never does ('' after clearing the field, or 'https://', stored as
  // 'https:'). There the field still held a.example's key: a paste at the
  // caret or one backspace saved a key with no host, bound to the next
  // address saved and sent there. A setup link confirmed with the page open
  // left both fields on the previous server, its key edited at the caret
  // into the link's host's key. One rule now, in the store: whatever is
  // done in the field, key A's text goes to no host but a.example and is
  // saved for no other.
  group('key A\'s text and the key field, from every angle', () {
    const keyA = 'key-a-0123456789';
    late AppSettings settings;
    late SharedPreferences prefs;
    late MemoryKeyStore keys;
    late SettingsStore store;
    late List<String> seen; // 'host <- key'
    late ServerAnalyzer server;
    late String clipboard;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      keys = MemoryKeyStore();
      settings = await AppSettings.load(prefs: prefs, keyStore: keys);
      await settings.setProvider(AiProvider.server);
      await settings.setServerBaseUrl('https://a.example');
      await settings.setServerApiKey(keyA);
      await settings.setAiConsent(aiConsentRoute('server', 'claude'),
          granted: true);
      store = createSettingsStore(settings);
      seen = [];
      clipboard = 'key-b';
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

    final keyField = find.byKey(const Key('serverUploadKeyField'));
    final keyEditable =
        find.descendant(of: keyField, matching: find.byType(EditableText));
    final urlField = find.byKey(const Key('serverUrlField'));
    String keyText(WidgetTester tester) =>
        tester.widget<EditableText>(keyEditable).controller.text;
    String urlText(WidgetTester tester) => tester
        .widget<EditableText>(
            find.descendant(of: urlField, matching: find.byType(EditableText)))
        .controller
        .text;
    String savedFor(String host) =>
        'Saved for $host: not sent to the address above.';

    /// Whether [text] carries eight characters of key A in a row: the key,
    /// the key edited at the caret, the key one character short.
    bool carriesKeyA(String? text) {
      if (text == null) return false;
      for (var i = 0; i + 8 <= keyA.length; i++) {
        if (text.contains(keyA.substring(i, i + 8))) return true;
      }
      return false;
    }

    /// No request to a host outside [hosts] carried key A's text, and the
    /// key saved for any other host (or for none yet) does not carry it:
    /// in memory, nor as the next launch (or a background run) loads it
    /// from the store.
    Future<void> expectKeyAOnlyAt(Set<String> hosts) async {
      for (final s in seen) {
        final [host, key] = s.split(' <- ');
        if (!hosts.contains(host)) {
          expect(carriesKeyA(key), isFalse, reason: 'sent $s');
        }
      }
      final stored = await AppSettings.load(prefs: prefs, keyStore: keys);
      for (final s in [settings, stored]) {
        if (!hosts.contains(s.serverKeyHost)) {
          expect(carriesKeyA(s.serverApiKey), isFalse,
              reason: 'saved for ${s.serverKeyHost}: ${s.serverApiKey}');
        }
      }
      expect((stored.serverApiKey, stored.serverKeyHost),
          (settings.serverApiKey, settings.serverKeyHost),
          reason: 'stored as it is in memory');
    }

    /// Settings with the Restaurant group, as di.dart wires it, and the
    /// server page pushed over it with the same store.
    Future<void> openServerPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => switch (call.method) {
                'Clipboard.hasStrings' => {'value': true},
                'Clipboard.getData' => {'text': clipboard},
                _ => null,
              });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
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
            settings: store,
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
      expect(seen, ['a.example <- $keyA']);
      unawaited(Navigator.of(tester.element(find.byType(SettingsScreen)))
          .push(MaterialPageRoute<void>(
              builder: (_) => SubscriptionProviderPage(settings: store))));
      await tester.pumpAndSettle();
      expect(keyText(tester), keyA);
    }

    /// The address field's edit, saved as the key field is tapped.
    Future<void> moveAddress(WidgetTester tester, String url) async {
      await tester.enterText(urlField, url);
      await tester.tap(keyField);
      await tester.pumpAndSettle();
    }

    /// Past the rest the Restaurant group waits after a key edit.
    Future<void> rest(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
    }

    /// What a keyboard's clipboard chip does: the clipboard at the caret.
    Future<void> pasteAtCaret(WidgetTester tester) async {
      final value =
          tester.state<EditableTextState>(keyEditable).textEditingValue;
      tester.testTextInput
          .updateEditingValue(value.replaced(value.selection, clipboard));
      await tester.pumpAndSettle();
    }

    /// One backspace at the caret.
    Future<void> deleteOne(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
    }

    /// Select All, then Paste, from a keyboard's shortcuts.
    Future<void> selectAllPaste(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    final edits = <String, Future<void> Function(WidgetTester)>{
      'a paste at the caret': pasteAtCaret,
      'one backspace': deleteOne,
      'Select All + Paste': selectAllPaste,
    };

    // Each place the address can leave a.example for: another host, and
    // an address naming none.
    for (final (move, name) in const [
      ('https://b.example', 'b.example'),
      ('https://c.example', 'another host'),
      ('', 'the address cleared'),
      ('https://', '"https://"'),
    ]) {
      for (final MapEntry(key: editName, value: edit) in edits.entries) {
        testWidgets('$name, then $editName in the key field, then '
            'https://b.example: key A goes to no host but a.example',
            (tester) async {
          await openServerPage(tester);
          await moveAddress(tester, move);
          expect(keyText(tester), isEmpty,
              reason: 'a.example\'s key is not in the field to be edited');
          expect(find.text(savedFor('a.example')), findsOneWidget);
          expect(find.byKey(const Key('serverKeyUseHereRow')),
              serverKeyHostOf(move) == null ? findsNothing : findsOneWidget,
              reason: 'no host to use it for');
          await edit(tester);
          await rest(tester);
          if (move != 'https://b.example') {
            await moveAddress(tester, 'https://b.example');
            await rest(tester);
          }
          await expectKeyAOnlyAt({'a.example'});
          final pasted = editName != 'one backspace';
          final keptAt = serverKeyHostOf(move) ?? 'b.example';
          if (!pasted) {
            // The field was empty: nothing to delete, nothing saved.
            expect(settings.serverApiKey, keyA);
            expect(settings.serverKeyHost, 'a.example');
            expect(keyText(tester), isEmpty);
            expect(find.text(savedFor('a.example')), findsOneWidget);
            expect(seen, ['a.example <- $keyA']);
          } else {
            // The pasted key alone, for the address it was pasted at; at
            // an address naming no host, for the first one saved after.
            expect(settings.serverApiKey, 'key-b');
            expect(settings.serverKeyHost, keptAt);
            expect(seen, ['a.example <- $keyA', '$keptAt <- key-b']);
            expect(keyText(tester), keptAt == 'b.example' ? 'key-b' : isEmpty);
          }
        });
      }
    }

    for (final (move, name) in const [
      ('https://b.example', 'another host'),
      ('', 'the address cleared'),
      ('https://', '"https://"'),
    ]) {
      testWidgets('$name and back to a.example: the key is back in the field',
          (tester) async {
        await openServerPage(tester);
        await moveAddress(tester, move);
        expect(keyText(tester), isEmpty);
        await deleteOne(tester);
        await moveAddress(tester, 'https://a.example');
        expect(keyText(tester), keyA);
        expect(find.textContaining('Saved for'), findsNothing);
        expect(settings.serverKeyHost, 'a.example');
        await rest(tester);
        await expectKeyAOnlyAt({'a.example'});
      });
    }

    testWidgets('the same server under a new name: Use this key, then '
        'b.example gets only what is pasted there', (tester) async {
      await openServerPage(tester);
      await moveAddress(tester, 'https://a2.example');
      await tester.tap(find.byKey(const Key('serverKeyUseHereRow')));
      await tester.pumpAndSettle();
      expect(settings.serverKeyHost, 'a2.example');
      expect(keyText(tester), keyA);
      expect(seen.last, 'a2.example <- $keyA');
      await moveAddress(tester, 'https://b.example');
      expect(keyText(tester), isEmpty);
      expect(find.text(savedFor('a2.example')), findsOneWidget);
      for (final edit in edits.values) {
        await edit(tester);
        await rest(tester);
      }
      await expectKeyAOnlyAt({'a.example', 'a2.example'});
      expect(settings.serverApiKey, 'key-b');
      expect(settings.serverKeyHost, 'b.example');
      expect(seen.last, 'b.example <- key-b');
    });

    testWidgets('a setup link confirmed with the page open: both fields show '
        'the link\'s server, and editing its key carries none of key A',
        (tester) async {
      await openServerPage(tester);
      await store.applyServerSetup(
          serverBackend: 'claude',
          serverBaseUrl: 'https://b.example',
          apiKey: 'key-link');
      await tester.pumpAndSettle();
      expect(urlText(tester), 'https://b.example');
      expect(keyText(tester), 'key-link');
      await tester.tap(keyField);
      await tester.pumpAndSettle();
      clipboard = 'zz';
      for (final edit in edits.values) {
        await edit(tester);
        await rest(tester);
        await expectKeyAOnlyAt({'a.example'});
      }
      expect(settings.serverKeyHost, 'b.example');
      expect(settings.serverApiKey, 'zz');
      expect(seen.where((s) => s.startsWith('b.example ')), isNotEmpty);
    });

    testWidgets('a key edit landing between a setup link\'s write and its '
        'notice is refused, not saved for the link\'s host', (tester) async {
      await openServerPage(tester);
      await tester.tap(keyField);
      await tester.pumpAndSettle();
      clipboard = 'zz';
      // The link's address and key are in the store before its first
      // await; the page hears of them after it.
      unawaited(store.applyServerSetup(
          serverBackend: 'claude',
          serverBaseUrl: 'https://b.example',
          apiKey: 'key-link'));
      final value =
          tester.state<EditableTextState>(keyEditable).textEditingValue;
      tester.testTextInput
          .updateEditingValue(value.replaced(value.selection, clipboard));
      await tester.pumpAndSettle();
      await rest(tester);
      await expectKeyAOnlyAt({'a.example'});
      expect(settings.serverApiKey, 'key-link');
      expect(settings.serverKeyHost, 'b.example');
      expect(keyText(tester), 'key-link');
    });

    testWidgets('a setup link confirmed over an address edit not saved yet: '
        'leaving the page keeps the link\'s address', (tester) async {
      await openServerPage(tester);
      // Typed, the field keeping its focus: not saved yet.
      await tester.enterText(urlField, 'https://c.example');
      await tester.pump();
      await store.applyServerSetup(
          serverBackend: 'claude',
          serverBaseUrl: 'https://b.example',
          apiKey: 'key-link');
      await tester.pumpAndSettle();
      expect(urlText(tester), 'https://b.example');
      expect(keyText(tester), 'key-link');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionProviderPage), findsNothing);
      expect(settings.serverBaseUrl, 'https://b.example');
      expect(settings.serverApiKey, 'key-link');
      expect(settings.serverKeyHost, 'b.example');
      await rest(tester);
      await expectKeyAOnlyAt({'a.example'});
    });
  });

  // Recheck of the rule above: the key's host was kept in the preferences,
  // the key in the keychain. An iPhone reinstall keeps keychain items and
  // drops the preferences, so key A loaded bound to no host: in the field
  // at '' and at the first address saved, then bound to it, and a paste at
  // the caret saved key A + key B for b.example. The host is stored with
  // the key now; a key stored as plain text (1.7.0 and earlier) that a
  // first launch finds has no known host: never shown or sent, until the
  // user taps Use this key for the address (review of 2026-11-20).
  group('after a reinstall that kept the key and dropped the preferences',
      () {
    const keyA = 'key-a-0123456789';
    late AppSettings settings;
    late SharedPreferences prefs;
    late MemoryKeyStore keys;
    late SettingsStore store;
    late List<String> seen; // 'host <- key'
    late ServerAnalyzer server;
    late String clipboard;

    /// Key A's secure item as this version stores it, saved for a.example.
    Future<String> itemSavedForA() async {
      SharedPreferences.setMockInitialValues({});
      final saved = MemoryKeyStore();
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: saved);
      await s.setServerBaseUrl('https://a.example');
      await s.setServerApiKey(keyA);
      return saved.data['server_api_key_item']!;
    }

    /// The reinstalled app's first launch: no preferences ([prefsLeft]
    /// for an update in place instead), [item] (this version's) or
    /// [legacy] (1.7.0's plain text) still in the store. The user picks the
    /// plan again and allows it.
    Future<void> reinstall(
        {String? item,
        String? legacy,
        Map<String, Object> prefsLeft = const {}}) async {
      SharedPreferences.setMockInitialValues(prefsLeft);
      prefs = await SharedPreferences.getInstance();
      keys = MemoryKeyStore();
      if (item != null) keys.data['server_api_key_item'] = item;
      if (legacy != null) keys.data['server_api_key'] = legacy;
      settings = await AppSettings.load(prefs: prefs, keyStore: keys);
      await settings.setProvider(AiProvider.server);
      await settings.setAiConsent(aiConsentRoute('server', 'claude'),
          granted: true);
      store = createSettingsStore(settings);
      seen = [];
      clipboard = 'key-b';
      server = ServerAnalyzer(settings, client: MockClient((req) async {
        seen.add('${req.url.host} <- ${req.headers['X-API-Key']}');
        return http.Response(
            jsonEncode({
              'ok': true,
              'features': {'restaurant_lookup': true, 'lookup_jobs': true},
            }),
            200);
      }));
    }

    final keyField = find.byKey(const Key('serverUploadKeyField'));
    final keyEditable =
        find.descendant(of: keyField, matching: find.byType(EditableText));
    final urlField = find.byKey(const Key('serverUrlField'));
    final useHere = find.byKey(const Key('serverKeyUseHereRow'));
    String keyText(WidgetTester tester) =>
        tester.widget<EditableText>(keyEditable).controller.text;
    final savedForA =
        find.text('Saved for a.example: not sent to the address above.');
    final savedWithoutAddress = find.text('Saved without its server address: '
        'not sent anywhere until you use it for one.');

    bool carriesKeyA(String? text) {
      if (text == null) return false;
      for (var i = 0; i + 8 <= keyA.length; i++) {
        if (text.contains(keyA.substring(i, i + 8))) return true;
      }
      return false;
    }

    /// No request to a host but a.example carried key A's text, and no key
    /// bound to any other host (or to none) carries it: in memory, and as
    /// the next launch loads it from the store.
    Future<void> expectKeyAOnlyAtA() async {
      for (final s in seen) {
        final [host, key] = s.split(' <- ');
        if (host != 'a.example') {
          expect(carriesKeyA(key), isFalse, reason: 'sent $s');
        }
      }
      final next = await AppSettings.load(prefs: prefs, keyStore: keys);
      for (final s in [settings, next]) {
        if (s.serverKeyHost != 'a.example') {
          expect(carriesKeyA(s.serverKeyForAddress), isFalse);
          expect(carriesKeyA(s.serverKeyFor('b.example')), isFalse);
          if (s.serverKeyHost != null) {
            expect(carriesKeyA(s.serverApiKey), isFalse,
                reason: 'saved for ${s.serverKeyHost}: ${s.serverApiKey}');
          }
        }
      }
    }

    /// Settings with the Restaurant group, as di.dart wires it, and the
    /// server page pushed over it with the same store, at ''.
    Future<void> openServerPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => switch (call.method) {
                'Clipboard.hasStrings' => {'value': true},
                'Clipboard.getData' => {'text': clipboard},
                _ => null,
              });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
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
            settings: store,
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
      unawaited(Navigator.of(tester.element(find.byType(SettingsScreen)))
          .push(MaterialPageRoute<void>(
              builder: (_) => SubscriptionProviderPage(settings: store))));
      await tester.pumpAndSettle();
      expect(settings.serverBaseUrl, '');
    }

    Future<void> moveAddress(WidgetTester tester, String url) async {
      await tester.enterText(urlField, url);
      await tester.tap(keyField);
      await tester.pumpAndSettle();
    }

    Future<void> rest(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
    }

    Future<void> pasteAtCaret(WidgetTester tester) async {
      await tester.tap(keyField);
      await tester.pumpAndSettle();
      final value =
          tester.state<EditableTextState>(keyEditable).textEditingValue;
      tester.testTextInput
          .updateEditingValue(value.replaced(value.selection, clipboard));
      await tester.pumpAndSettle();
    }

    Future<void> deleteOne(WidgetTester tester) async {
      await tester.tap(keyField);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
    }

    Future<void> selectAllPaste(WidgetTester tester) async {
      await tester.tap(keyField);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    final edits = <String, Future<void> Function(WidgetTester)>{
      'a paste at the caret': pasteAtCaret,
      'one backspace': deleteOne,
      'Select All + Paste': selectAllPaste,
    };

    for (final (lost, kind) in const [
      (false, 'key A stored with its host'),
      (true, 'key A stored as plain text (no known host)'),
    ]) {
      Future<void> reinstallKeyA() async => lost
          ? reinstall(legacy: keyA)
          : reinstall(item: await itemSavedForA());

      /// The line under the field names a.example for a key stored with
      /// its host, and says a key with no known host was saved without its
      /// address; at an address naming a host, the row makes it that
      /// address's.
      void expectEmptyField(WidgetTester tester, {required bool atHost}) {
        expect(keyText(tester), isEmpty,
            reason: 'key A is not in the field to be edited');
        expect(savedForA, lost ? findsNothing : findsOneWidget);
        expect(savedWithoutAddress, lost ? findsOneWidget : findsNothing);
        expect(useHere, atHost ? findsOneWidget : findsNothing);
      }

      for (final MapEntry(key: editName, value: edit) in edits.entries) {
        for (final atB in [false, true]) {
          final where = atB ? 'at https://b.example' : 'at \'\', then '
              'https://b.example';
          testWidgets('$kind: $editName $where: b.example gets only what is '
              'pasted', (tester) async {
            await reinstallKeyA();
            await openServerPage(tester);
            expectEmptyField(tester, atHost: false);
            if (atB) {
              await moveAddress(tester, 'https://b.example');
              expectEmptyField(tester, atHost: true);
            }
            await edit(tester);
            await rest(tester);
            if (!atB) {
              await moveAddress(tester, 'https://b.example');
              await rest(tester);
            }
            await expectKeyAOnlyAtA();
            if (editName == 'one backspace') {
              // The field was empty: nothing deleted, nothing saved.
              if (lost) {
                expect(settings.serverKeyHostUnknown, isTrue);
                expect(settings.serverApiKey, isNull);
              } else {
                expect(settings.serverApiKey, keyA);
                expect(settings.serverKeyHost, 'a.example');
              }
              expectEmptyField(tester, atHost: true);
              expect(seen, isEmpty);
            } else {
              expect(settings.serverApiKey, 'key-b');
              expect(settings.serverKeyHost, 'b.example');
              expect(settings.serverKeyHostUnknown, isFalse);
              expect(keyText(tester), 'key-b');
              expect(find.textContaining('Saved for'), findsNothing);
              expect(savedWithoutAddress, findsNothing);
              expect(seen, ['b.example <- key-b']);
            }
          });
        }
      }

      testWidgets('$kind: at a.example the field '
          '${lost ? 'stays empty' : 'is filled again'}', (tester) async {
        await reinstallKeyA();
        await openServerPage(tester);
        await moveAddress(tester, 'https://b.example');
        await deleteOne(tester);
        await moveAddress(tester, 'https://a.example');
        await rest(tester);
        if (lost) {
          // Nothing says it is a.example's: only the user can.
          expectEmptyField(tester, atHost: true);
          expect(seen, isEmpty);
        } else {
          expect(keyText(tester), keyA);
          expect(find.textContaining('Saved for'), findsNothing);
          expect(seen, ['a.example <- $keyA']);
        }
        await expectKeyAOnlyAtA();
      });

      testWidgets('$kind: Use this key makes it '
          '${lost ? 'the address\'s' : 'the same server\'s new name\'s'}, by '
          'the tap alone', (tester) async {
        await reinstallKeyA();
        await openServerPage(tester);
        await moveAddress(tester, 'https://a2.example');
        await rest(tester);
        expect(seen, isEmpty);
        expectEmptyField(tester, atHost: true);
        await tester.tap(useHere);
        await tester.pumpAndSettle();
        expect(settings.serverKeyHost, 'a2.example');
        expect(settings.serverKeyHostUnknown, isFalse);
        expect(keyText(tester), keyA);
        // From no key to key A, at one address, the Restaurant group asks
        // once the key rests, as for a key pasted there.
        await rest(tester);
        expect(seen, ['a2.example <- $keyA']);
        await moveAddress(tester, 'https://b.example');
        expect(keyText(tester), isEmpty);
        for (final edit in edits.values) {
          await edit(tester);
          await rest(tester);
        }
        final toB = seen.where((s) => s.startsWith('b.example ')).toList();
        expect(toB, isNotEmpty);
        for (final s in toB) {
          expect(carriesKeyA(s), isFalse, reason: 'sent $s');
        }
        expect((settings.serverApiKey, settings.serverKeyHost),
            ('key-b', 'b.example'));
      });

      testWidgets('$kind: a setup link confirmed with the page open fills '
          'both fields with the link\'s server', (tester) async {
        await reinstallKeyA();
        await openServerPage(tester);
        await store.applyServerSetup(
            serverBackend: 'claude',
            serverBaseUrl: 'https://b.example',
            apiKey: 'key-link');
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<EditableText>(find.descendant(
                    of: urlField, matching: find.byType(EditableText)))
                .controller
                .text,
            'https://b.example');
        expect(keyText(tester), 'key-link');
        clipboard = 'zz';
        for (final edit in edits.values) {
          await edit(tester);
          await rest(tester);
        }
        await expectKeyAOnlyAtA();
        expect((settings.serverApiKey, settings.serverKeyHost),
            ('zz', 'b.example'));
        expect(seen.first, 'b.example <- key-link');
        expect(seen.last, 'b.example <- zz');
      });
    }

    // Review of 2026-11-20, PN-1: an update in place from 1.7.0 whose
    // address field had been cleared (1.7.0 saves ''), the key kept as
    // plain text. No first launch and no address, so the key loaded as one
    // typed before any address: the field held it masked at b.example, the
    // address saved as the key field is tapped bound it there, and the
    // Restaurant group asked b.example at once with key A.
    testWidgets('an update from 1.7.0 with the address cleared: b.example is '
        'asked nothing with key A, the field says it was saved without its '
        'address, and Use this key alone makes it b.example\'s',
        (tester) async {
      await reinstall(legacy: keyA, prefsLeft: {
        'settings.provider': 'server',
        'settings.server_backend': 'claude',
        'settings.server_base_url': '',
        'settings.ai_consent_routes': <String>['server:claude'],
      });
      expect(settings.serverKeyHostUnknown, isTrue);
      await openServerPage(tester);
      expect(keyText(tester), isEmpty);
      expect(savedWithoutAddress, findsOneWidget);
      expect(useHere, findsNothing, reason: "'' names no host");
      await moveAddress(tester, 'https://b.example');
      await rest(tester);
      expect(seen, isEmpty, reason: 'key A goes nowhere');
      expect(keyText(tester), isEmpty);
      expect(savedWithoutAddress, findsOneWidget);
      expect(useHere, findsOneWidget);
      await expectKeyAOnlyAtA();
      // The next launch, with b.example saved: still not b.example's.
      final next = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(next.serverKeyHostUnknown, isTrue);
      expect(next.serverKeyFor('b.example'), isNull);

      await tester.tap(useHere);
      await tester.pumpAndSettle();
      expect((settings.serverApiKey, settings.serverKeyHost),
          (keyA, 'b.example'));
      expect(keyText(tester), keyA);
      expect(savedWithoutAddress, findsNothing);
      expect(useHere, findsNothing);
      await rest(tester);
      expect(seen, ['b.example <- $keyA']);
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

    testWidgets('pasting this server\'s key clears it; a tap outside the '
        'empty field does not, nor deletes the key', (tester) async {
      final settings = keyFromAnotherServer();
      await open(tester, settings);
      final field = find.byKey(const Key('serverUploadKeyField'));
      // a.example's key is not in the field to be edited in place.
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      // A tap outside saves the field only after an edit: still
      // a.example's key, and still saved.
      final updates = settings.updateCalls;
      await tester.tap(field);
      await tester.pump();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(settings.updateCalls, updates);
      expect(settings.apiKey, 'key-a');
      expect(settings.keySavedFor, 'a.example');
      expect(find.textContaining('Saved for a.example'), findsOneWidget);
      await tester.enterText(field, 'key-b');
      await tester.pumpAndSettle();
      expect(settings.apiKey, 'key-b');
      expect(find.textContaining('Saved for a.example'), findsNothing);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsNothing);
    });

    testWidgets('picking another plan leaves a.example\'s key out of the '
        'field', (tester) async {
      final settings = keyFromAnotherServer();
      await open(tester, settings);
      await tester.tap(find.byKey(const Key('planChoice-glm')));
      await tester.pumpAndSettle();
      expect(settings.serverBackend, 'glm');
      final field = find.byKey(const Key('serverUploadKeyField'));
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(settings.keySavedFor, 'a.example');
    });

    // The field follows the store without waiting for it to report: the
    // address saved as the key field is tapped empties the field in the
    // same step, and an edit the store refuses (the address moved under
    // the page) is not left in the field.
    FakeSettings keyAtItsHost() => _QuietSettings(keys: {'server': 'key-a'})
      ..provider = 'server'
      ..serverBaseUrl = 'https://a.example'
      ..keySavedFor = 'a.example';
    final keyField = find.byKey(const Key('serverUploadKeyField'));
    String keyText(WidgetTester tester) =>
        tester.widget<TextField>(keyField).controller!.text;

    testWidgets('the address saved as the key field is tapped empties it at '
        'once, before the store reports the change', (tester) async {
      final settings = keyAtItsHost() as _QuietSettings;
      await open(tester, settings);
      expect(keyText(tester), 'key-a');
      settings.hold = true;
      await tester.enterText(
          find.byKey(const Key('serverUrlField')), 'https://b.example');
      await tester.tap(keyField);
      await tester.pump();
      expect(settings.serverBaseUrl, 'https://b.example');
      expect(settings.held, greaterThan(0), reason: 'not reported yet');
      expect(keyText(tester), isEmpty);
      settings.release();
      await tester.pumpAndSettle();
      expect(keyText(tester), isEmpty);
      expect(find.text('Saved for a.example: not sent to the address above.'),
          findsOneWidget);
    });

    testWidgets('an edit the store refuses is not left in the field',
        (tester) async {
      final settings = keyAtItsHost() as _QuietSettings;
      await open(tester, settings);
      settings.hold = true;
      // Moved under the page, unreported (as between a setup link's write
      // and its notice).
      settings.serverBaseUrl = 'https://b.example';
      await tester.tap(keyField);
      await tester.pump();
      final editable = find.descendant(
          of: keyField, matching: find.byType(EditableText));
      final value = tester.state<EditableTextState>(editable).textEditingValue;
      tester.testTextInput
          .updateEditingValue(value.replaced(value.selection, 'x'));
      await tester.pump();
      expect(settings.keyFieldWrites.single,
          ('key-ax', 'https://a.example', false));
      expect(settings.apiKey, 'key-a');
      expect(keyText(tester), isEmpty,
          reason: 'filled again with what the store shows at b.example');
      // The field now edits b.example's key.
      tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: 'key-b',
              selection: TextSelection.collapsed(offset: 5)));
      await tester.pump();
      expect(settings.keyFieldWrites.last,
          ('key-b', 'https://b.example', true));
      expect(settings.apiKey, 'key-b');
    });

    testWidgets('zh: the line and the row', (tester) async {
      await open(tester, keyFromAnotherServer(), locale: const Locale('zh'));
      expect(find.text('为 a.example 保存：不会发送到上面的地址。'), findsOneWidget);
      expect(find.text('将此密钥用于 b.example'), findsOneWidget);
    });

    // A key saved without its server address (review of 2026-11-20):
    // not the upload key, so the store's key is empty; the line says why
    // the field is empty, and the row is the one way to make it this
    // address's.
    FakeSettings keyWithNoKnownHost({String url = 'https://b.example'}) =>
        FakeSettings(keys: {})
          ..provider = 'server'
          ..serverBaseUrl = url
          ..keyOfUnknownHost = 'key-a';
    const savedWithoutAddress = 'Saved without its server address: not sent '
        'anywhere until you use it for one.';

    testWidgets('a key saved without its server address: the field is empty '
        'and says so; one tap makes it this address\'s', (tester) async {
      final settings = keyWithNoKnownHost();
      await open(tester, settings);
      expect(keyText(tester), isEmpty);
      expect(find.text(savedWithoutAddress), findsOneWidget);
      expect(find.textContaining('Saved for'), findsNothing);
      // A tap outside the empty field saves nothing and keeps it.
      final updates = settings.updateCalls;
      await tester.tap(keyField);
      await tester.pump();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(settings.updateCalls, updates);
      expect(settings.keyFieldWrites, isEmpty);
      expect(settings.serverKeyHostUnknown, isTrue);
      await tester.tap(find.byKey(const Key('serverKeyUseHereRow')));
      await tester.pumpAndSettle();
      expect(settings.bindServerKeyCalls, 1);
      expect(settings.apiKey, 'key-a');
      expect(keyText(tester), 'key-a');
      expect(find.text(savedWithoutAddress), findsNothing);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsNothing);
    });

    testWidgets('a key saved without its server address, at an address '
        'naming none: the line, and no row until there is one',
        (tester) async {
      final settings = keyWithNoKnownHost(url: '');
      await open(tester, settings);
      expect(find.text(savedWithoutAddress), findsOneWidget);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsNothing);
      await tester.enterText(
          find.byKey(const Key('serverUrlField')), 'https://b.example');
      await tester.tap(keyField);
      await tester.pumpAndSettle();
      expect(find.text(savedWithoutAddress), findsOneWidget);
      expect(find.text('Use this key for b.example'), findsOneWidget);
    });

    testWidgets('a key saved without its server address: what is pasted '
        'replaces it', (tester) async {
      final settings = keyWithNoKnownHost();
      await open(tester, settings);
      await tester.enterText(keyField, 'key-b');
      await tester.pumpAndSettle();
      expect(settings.apiKey, 'key-b');
      expect(settings.serverKeyHostUnknown, isFalse);
      expect(find.text(savedWithoutAddress), findsNothing);
      expect(find.byKey(const Key('serverKeyUseHereRow')), findsNothing);
    });

    testWidgets('zh: the line for a key saved without its server address',
        (tester) async {
      await open(tester, keyWithNoKnownHost(), locale: const Locale('zh'));
      expect(
          find.text('保存时没有记下服务器地址：'
              '在你把它用于某个地址之前，不会发送到任何地方。'),
          findsOneWidget);
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

/// A store that holds back its change notices while [hold] is set: what the
/// page does before the store reports a change (or without a report).
class _QuietSettings extends FakeSettings {
  _QuietSettings({super.keys});

  bool hold = false;
  int held = 0;

  @override
  void notifyListeners() {
    if (hold) {
      held++;
      return;
    }
    super.notifyListeners();
  }

  void release() {
    hold = false;
    if (held > 0) {
      held = 0;
      super.notifyListeners();
    }
  }
}
