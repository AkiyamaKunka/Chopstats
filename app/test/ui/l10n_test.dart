/// The Chinese localization CONTRACT (user request 2026-08-02): the
/// language setting actually re-locales the running app — at boot and
/// LIVE from the Settings picker, no restart. Every other suite pumps
/// bare MaterialApps and rides the English fallback; only this one proves
/// the real delegate + locale wiring in app.dart.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;

import 'fakes.dart';

void main() {
  testWidgets('appLanguage=zh boots the whole shell in Chinese',
      (tester) async {
    final settings = FakeSettings()..appLanguage = 'zh';
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: settings)));
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsWidgets); // tab + large title
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('身体'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
    // The task's title, which Android's Recents shows (RECENTS-1).
    expect(tester.widget<Title>(find.byType(Title)).title, '筷拍');
  });

  testWidgets('History day labels speak the app language '
      '(user-reported: weekdays stayed English in zh)', (tester) async {
    final dao = FakeDao();
    // Three CALENDAR days back (the constructor) — 72 elapsed hours is a
    // different day in the hour around a DST change.
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day - 3);
    dao.put(Meal(
      id: 1,
      date: isoDate(day),
      time: '8:05 AM',
      timestamp: '${isoDate(day)}T08:05:00',
      source: 'app_photo',
      imageHash: '',
      analysis: const {
        'is_food': true,
        'total_calories': 380,
        'meal_description': 'Soy milk',
      },
    ));
    final settings = FakeSettings()..appLanguage = 'zh';
    await tester.pumpWidget(CalorieTrackerApp(
        services: makeServices(dao: dao, settings: settings)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    // A zh user must see 星期X, never 'Saturday' — and 千卡, never 'kcal'.
    expect(find.textContaining('星期'), findsWidgets);
    expect(find.textContaining('千卡'), findsWidgets);
    expect(find.textContaining('kcal'), findsNothing);
    for (final en in const [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ]) {
      expect(find.textContaining(en), findsNothing);
    }
  });

  testWidgets('picking 中文 in Settings re-locales the app in place',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(); // 'system' → en under the test locale
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: settings)));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsWidgets);
    expect(tester.widget<Title>(find.byType(Title)).title, 'Chopstats');

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('languageRow')));
    await tester.tap(find.byKey(const Key('languageRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language-zh')));
    await tester.pumpAndSettle();

    expect(settings.appLanguage, 'zh');
    expect(find.text('今天'), findsOneWidget); // tab label, live
    expect(find.text('Today'), findsNothing);
    expect(tester.widget<Title>(find.byType(Title)).title, '筷拍',
        reason: "the task's title follows, live (RECENTS-1)");

    // And back — the switch is symmetric, not a one-way door.
    await tester.ensureVisible(find.byKey(const Key('languageRow')));
    await tester.tap(find.byKey(const Key('languageRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language-en')));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('今天'), findsNothing);
    expect(tester.widget<Title>(find.byType(Title)).title, 'Chopstats');
  });

  testWidgets('a Traditional-Chinese phone gets the Chinese app, titled 筷拍',
      (tester) async {
    // Flutter gives zh-Hant-TW the app's one Chinese (Locale('zh')).
    tester.platformDispatcher.localesTestValue = const [
      Locale.fromSubtags(
          languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
    ];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(CalorieTrackerApp(services: makeServices()));
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsWidgets);
    expect(tester.widget<Title>(find.byType(Title)).title, '筷拍');
  });

  // Android's Recents names the app "<launcher label> <task title>" when
  // the two differ. The label follows the phone's language from res/, the
  // title the app's language (appTitleFor), so they must agree in every
  // language res/ names. Android does not give a Traditional-script phone
  // (zh-Hant: Taiwan, Hong Kong, Macau) values-zh, while Flutter gives it
  // the app's Chinese: without values-b+zh+Hant, Recents read "Chopstats
  // 筷拍" there (RECENTS-TW-1, 2026-11-24).
  test('every launcher label is the task title in its language', () {
    final labels = <String, String>{};
    for (final dir in Directory('android/app/src/main/res')
        .listSync()
        .whereType<Directory>()) {
      final folder = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      final strings = File('${dir.path}/strings.xml');
      if (!folder.startsWith('values') || !strings.existsSync()) continue;
      final m = RegExp(r'<string name="app_name">([^<]*)</string>')
          .firstMatch(strings.readAsStringSync());
      if (m != null) labels[folder] = m.group(1)!;
    }
    expect(labels.keys,
        containsAll(['values', 'values-zh', 'values-b+zh+Hant']));
    for (final MapEntry(key: folder, value: label) in labels.entries) {
      expect(appTitleFor(_resLocale(folder)), label, reason: folder);
    }
    // And the phones each folder serves, as Flutter resolves them.
    expect(appTitleFor(const Locale('en', 'US')), labels['values']);
    expect(appTitleFor(const Locale('zh', 'CN')), labels['values-zh']);
    expect(
        appTitleFor(const Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hant', countryCode: 'HK')),
        labels['values-b+zh+Hant']);
  });
}

/// The locale an Android res folder names: values (the default, English
/// here), values-zh, values-zh-rTW, values-b+zh+Hant.
Locale _resLocale(String folder) {
  if (folder == 'values') return const Locale('en');
  final q = folder.substring('values-'.length);
  if (q.startsWith('b+')) {
    final parts = q.substring(2).split('+');
    return Locale.fromSubtags(
        languageCode: parts.first,
        scriptCode: parts.skip(1).where((p) => p.length == 4).firstOrNull,
        countryCode: parts.skip(1).where((p) => p.length != 4).firstOrNull);
  }
  final parts = q.split('-r');
  return Locale.fromSubtags(
      languageCode: parts.first,
      countryCode: parts.length > 1 ? parts[1] : null);
}
