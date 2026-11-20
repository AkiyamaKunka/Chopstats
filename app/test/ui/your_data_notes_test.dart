// Settings › Your Data: what Android's own backup holds (privacy lane
// item 4), Google's health reminder on both platforms (Health Content and
// Services policy: apps remind users to consult a professional; the full
// disclaimer is for the store description), and the warning before
// Android's 25 MB backup limit (item 5).
import 'dart:io' show FileSystemException;

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/backup/file_pick_channel.dart';
import 'package:calorie_tracker/ui/screens/settings/data_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart' show pumpApp;
import 'fakes.dart';

class _NoPicker implements FilePicker {
  @override
  Future<PickedFiles> pickJsonFiles() async => const PickedFiles([]);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final zh = lookupAppLocalizations(const Locale('zh'));

  Future<void> pump(WidgetTester tester,
          {String platform = 'android',
          Locale locale = const Locale('en'),
          Future<int?> Function()? backupSetBytes}) =>
      pumpApp(
          tester,
          Scaffold(
            body: ListView(children: [
              DataSection(
                dao: FakeDao(),
                onOpenPrivacyPolicy: () {},
                platform: platform,
                androidBackupNote: platform == 'android',
                filePicker: _NoPicker(),
                backupSetBytes: backupSetBytes,
              ),
            ]),
          ),
          locale: locale,
          size: const Size(390, 1400));

  group('the Android footer says what Android\'s backup holds', () {
    test('the log may go to the Google account; the keys do not; Save to '
        'Device is the way to move phones', () {
      final e = en.backupAndroidFooter;
      expect(e, contains('Google account'));
      expect(e, contains('not your API keys'));
      expect(e, contains('Save to Device'));
      expect(e, contains('Import merges'));
      final z = zh.backupAndroidFooter;
      expect(z, contains('Google 账户'));
      expect(z, contains('不包括 API Key'),
          reason: 'the zh strings call it API Key everywhere');
      expect(z, contains('保存到设备'));
      expect(z, contains('导入会合并'));
    });

    // Owner decision 5 (2026-11-20): Android's cloud backup only when it
    // is end-to-end encrypted, which needs a screen lock and Android 9 or
    // later (res/xml/data_extraction_rules.xml, res/xml-v28 and res/xml
    // backup_rules.xml). The footer shows on every Android version, and
    // Android 8.1 and earlier back up none of the log (review of #72).
    test('it says the backup is end-to-end encrypted and needs a screen '
        'lock and Android 9, without which the log is not backed up', () {
      final e = en.backupAndroidFooter;
      expect(e, contains('end-to-end encrypted'));
      expect(e, contains('screen lock (PIN, pattern or password)'));
      expect(e, contains('On Android 9 and later that backup is end-to-end '
          'encrypted'));
      expect(e, contains('without a screen lock, or on Android 8.1 and '
          'earlier, your log is not backed up'));
      final z = zh.backupAndroidFooter;
      expect(z, contains('端到端加密'));
      expect(z, contains('屏幕锁定（PIN 码、图案或密码）'));
      expect(z, contains('在 Android 9 及以上版本上，这份备份会用手机的屏幕锁定'));
      expect(z, contains('没有设置屏幕锁定时，或在 Android 8.1 及更早的版本上，'
          '饮食记录不会被备份'));
    });

    testWidgets('shown on Android', (tester) async {
      await pump(tester);
      expect(find.text(en.backupAndroidFooter), findsOneWidget);
    });
  });

  group('the health reminder', () {
    test('a short "not medical advice — ask a professional" line, both '
        'languages', () {
      expect(en.settingsHealthReminder,
          'Chopstats does not give medical advice. For decisions about your '
          'health or diet, consult a healthcare professional.');
      expect(zh.settingsHealthReminder,
          '筷拍不提供医疗建议。涉及健康或饮食的决定，请咨询医疗专业人士。');
    });

    for (final platform in ['android', 'ios']) {
      for (final (locale, l) in [
        (const Locale('en'), en),
        (const Locale('zh'), zh),
      ]) {
        testWidgets('under Your Data on $platform (${locale.languageCode})',
            (tester) async {
          await pump(tester, platform: platform, locale: locale);
          final line = find.byKey(const Key('healthReminder'));
          expect(line, findsOneWidget);
          expect(
              find.descendant(
                  of: line, matching: find.text(l.settingsHealthReminder)),
              findsOneWidget);
          // Its own line, under the section, not inside its footer.
          expect(
              tester.getTopLeft(line).dy,
              greaterThan(tester
                  .getTopLeft(find.byKey(const Key('privacyPolicyRow')))
                  .dy));
        });
      }
    }
  });

  group('the 25 MB backup limit (Android)', () {
    const mb = 1024 * 1024;
    final warning = find.byKey(const Key('backupSizeNearLimit'));

    for (final (locale, l) in [
      (const Locale('en'), en),
      (const Locale('zh'), zh),
    ]) {
      testWidgets('over 20 MB: a line recommending Save to Device '
          '(${locale.languageCode})', (tester) async {
        await pump(tester,
            locale: locale, backupSetBytes: () async => 21 * mb + mb ~/ 2);
        expect(warning, findsOneWidget);
        expect(
            find.descendant(
                of: warning,
                matching: find.text(l.backupSizeNearLimit('21.5 MB'))),
            findsOneWidget);
      });
    }

    testWidgets('at 20 MB or under: no line', (tester) async {
      await pump(tester, backupSetBytes: () async => 20 * mb);
      expect(warning, findsNothing);
    });

    testWidgets('iPhone: never (its backup is iCloud Backup, with no such '
        'limit)', (tester) async {
      await pump(tester,
          platform: 'ios', backupSetBytes: () async => 30 * mb);
      expect(warning, findsNothing);
    });

    testWidgets('a size that cannot be read: no line', (tester) async {
      await pump(tester, backupSetBytes: () async => null);
      expect(warning, findsNothing);
      await pump(tester,
          backupSetBytes: () async => throw const FileSystemException('x'));
      expect(warning, findsNothing);
    });
  });
}
