// Today's "Checking photos" row (2026-11-28), measured on an iPhone SE
// (375×667) with the app's real theme and the iPhone's own fonts, in en
// and zh.
//
// On 2026-11-27 Today read "0 kcal" for a 40-second visit while the
// catch-up was working through a day's photos, and said nothing when the
// busy server refused one. The row under the totals says so now:
//   - while a scan sends photos that had no verdict: "Checking photos:
//     3 of 12" over "Keep Chopstats open.";
//   - for a moment after: "12 photos checked.";
//   - when photos could not be sent: how many are not checked yet, why,
//     in the app's own reason words, and Retry.
// It never moves the totals card, opens and closes without a jump, reads
// whole at the largest text size, and a screen reader hears it once when
// it comes and once when it changes to what the scan came to, never once
// per photo.
import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/scan_status.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:calorie_tracker/ui/widgets/meal_card.dart';
import 'package:calorie_tracker/ui/widgets/photo_scan_row.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

const _se = Size(375, 667);
const _row = Key('photoScanRow');
const _line = Key('photoScanLine');
const _text = Key('photoScanText');
const _retry = Key('photoScanRetry');
const _hero = Key('todayHero');

Meal _meal(int id, String title, num kcal) {
  final date = isoDate(DateTime.now());
  return Meal(
    id: id,
    date: date,
    time: '12:00 PM',
    timestamp: '${date}T12:00:00',
    source: 'app_watch',
    imageHash: 'h$id',
    analysis: {
      'is_food': true,
      'meal_description': title,
      'total_calories': kcal,
      'total_protein_g': 20,
      'total_carbs_g': 50,
      'total_fat_g': 10,
    },
  );
}

Widget _today(FakeDao dao, PhotoScanStatus? status,
        {Future<void> Function()? onRetry}) =>
    Scaffold(
        body: TodayScreen(dao: dao, scanStatus: status, onRetryScan: onRetry));

/// The row's sentence as laid out.
RenderParagraph _paragraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(find
        .descendant(of: find.byKey(_text), matching: find.byType(RichText))
        .first);

/// The rounded cell of the card keyed [key], inside its margin.
Rect _cell(WidgetTester tester, Key key) => tester.getRect(find
    .descendant(of: find.byKey(key), matching: find.byType(Material))
    .first);

/// Past the row's open or close (the spinner never settles).
Future<void> _pumpMotion(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(AppMotion.standard + const Duration(milliseconds: 50));
}

/// A scan that found three unchecked photos and is sending the first.
PhotoScan _checking(PhotoScanStatus status) {
  final scan = status.begin(expected: ['a', 'b', 'c']);
  status.checking('a');
  return scan;
}

/// Three photos let go because the server could not be reached.
void _waiting(PhotoScanStatus status,
    {AnalysisErrorKind kind = AnalysisErrorKind.network, int count = 3}) {
  final scan = status.begin(expected: [for (var i = 0; i < count; i++) 'w$i']);
  for (var i = 0; i < count; i++) {
    status.finished('w$i', ScanVerdict.waiting, kind: kind);
  }
  scan.end();
}

void main() {
  setUpAll(loadIphoneFonts);

  group('Today', () {
    testWidgets('shows no row without a scan, nor with no status at all',
        (tester) async {
      final status = PhotoScanStatus();
      await pumpApp(tester, _today(FakeDao(), status), size: _se);
      expect(find.byKey(_row), findsNothing);
      // A scan that only walks photos checked before: still nothing.
      status.begin(expected: ['a', 'b']).end();
      await _pumpMotion(tester);
      expect(find.byKey(_row), findsNothing);

      await pumpApp(tester, _today(FakeDao(), null), size: _se);
      expect(find.byKey(_row), findsNothing);
      expect(find.byType(PhotoScanRow), findsNothing);
    });

    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: the row comes up under the totals, which do not '
          'move, counts as photos finish, says what the scan came to, and '
          'goes', (tester) async {
        final status = PhotoScanStatus();
        final dao = FakeDao();
        await pumpApp(tester, _today(dao, status),
            size: _se, locale: Locale(lang));
        final hero = tester.getRect(find.byKey(_hero));
        final emptyTop = tester.getRect(find.byKey(const Key('todayEmpty'))).top;

        final scan = _checking(status);
        await tester.pump();
        expect(tester.getRect(find.byKey(_hero)), hero,
            reason: 'not in the first frame of its opening');
        await _pumpMotion(tester);
        expect(tester.getRect(find.byKey(_hero)), hero,
            reason: 'nor once it is open');
        expect(
            find.text(lang == 'en'
                ? 'Checking photos: 1 of 3'
                : '正在检查照片：第 1 张，共 3 张'),
            findsOneWidget);
        expect(find.text(lang == 'en' ? 'Keep Chopstats open.' : '请保持筷拍打开。'),
            findsOneWidget);
        final row = tester.getRect(find.byKey(_row));
        expect(row.top, greaterThanOrEqualTo(hero.bottom));
        // The cell itself, inside the card's margin: the cards' one gutter.
        final cell = _cell(tester, _row);
        expect(cell.left, _cell(tester, _hero).left);
        expect(cell.right, _cell(tester, _hero).right);
        expect(cell.left, 16);
        expect(tester.getRect(find.byKey(const Key('todayEmpty'))).top,
            greaterThan(emptyTop),
            reason: 'what is under the row made room for it');
        expect(_paragraph(tester).didExceedMaxLines, isFalse);

        // The first photo is a meal: its card lands under the row.
        dao.seed(_meal(1, 'Noodles', 650));
        status.finished('a', ScanVerdict.checked);
        // As the meals-changed signal does in the shell.
        unawaited(tester
            .state<TodayScreenState>(find.byType(TodayScreen))
            .reload());
        await _pumpMotion(tester);
        expect(
            find.text(lang == 'en'
                ? 'Checking photos: 2 of 3'
                : '正在检查照片：第 2 张，共 3 张'),
            findsOneWidget);
        expect(tester.getRect(find.byType(MealCard)).top,
            greaterThanOrEqualTo(tester.getRect(find.byKey(_row)).bottom));
        expect(tester.getRect(find.byKey(_hero)).top, hero.top);

        // The other two are not food: checked all the same, and no error.
        status.checking('b');
        status.finished('b', ScanVerdict.checked);
        status.checking('c');
        status.finished('c', ScanVerdict.checked);
        scan.end();
        await _pumpMotion(tester);
        expect(find.text(lang == 'en' ? '3 photos checked.' : '已检查 3 张照片。'),
            findsOneWidget);
        expect(find.byKey(_retry), findsNothing);

        await tester.pump(PhotoScanRow.doneFor);
        await tester.pumpAndSettle();
        expect(find.byKey(_row), findsNothing, reason: 'gone after a moment');
        expect(tester.getRect(find.byKey(_hero)).top, hero.top);
      }, skip: !haveIphoneFonts);
    }

    testWidgets('one photo reads as one', (tester) async {
      final status = PhotoScanStatus();
      await pumpApp(tester, _today(FakeDao(), status), size: _se);
      final scan = status.begin(expected: ['a']);
      status.checking('a');
      await _pumpMotion(tester);
      expect(find.text('Checking 1 photo'),
          findsOneWidget);
      status.finished('a', ScanVerdict.checked);
      scan.end();
      await _pumpMotion(tester);
      expect(find.text('1 photo checked.'), findsOneWidget);
      await tester.pump(PhotoScanRow.doneFor);
      await tester.pumpAndSettle();
    });

    testWidgets('opens over AppMotion.standard, and at once with animations '
        'off', (tester) async {
      final status = PhotoScanStatus();
      await pumpApp(tester, _today(FakeDao(), status), size: _se);
      final emptyTop = tester.getRect(find.byKey(const Key('todayEmpty'))).top;
      final scan = _checking(status);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = tester.getRect(find.byKey(const Key('todayEmpty'))).top;
      await _pumpMotion(tester);
      final open = tester.getRect(find.byKey(const Key('todayEmpty'))).top;
      expect(mid, greaterThan(emptyTop));
      expect(mid, lessThan(open), reason: 'it slides, it does not jump');
      scan.end();

      final still = PhotoScanStatus();
      await pumpApp(
          tester,
          MediaQuery(
              data: const MediaQueryData(
                  size: _se, disableAnimations: true),
              child: _today(FakeDao(), still)),
          size: _se);
      final before = tester.getRect(find.byKey(const Key('todayEmpty'))).top;
      _checking(still);
      await tester.pump();
      await tester.pump();
      final first = tester.getRect(find.byKey(const Key('todayEmpty'))).top;
      await tester.pump(const Duration(seconds: 1));
      expect(first, greaterThan(before));
      expect(tester.getRect(find.byKey(const Key('todayEmpty'))).top, first,
          reason: 'Reduce Motion: no slide');
    });
  });

  group('photos that could not be sent', () {
    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: the row says how many are not checked yet and why, '
          'in the app\'s own reason words, with Retry', (tester) async {
        final status = PhotoScanStatus();
        await pumpApp(tester, _today(FakeDao(), status, onRetry: () async {}),
            size: _se, locale: Locale(lang));
        final hero = tester.getRect(find.byKey(_hero));
        _waiting(status, kind: AnalysisErrorKind.serverBusy);
        await _pumpMotion(tester);
        expect(
            find.text(lang == 'en'
                ? '3 photos are not checked yet (your server is busy with '
                    'another analysis).'
                : '还有 3 张照片没有检查（你的服务器正在处理另一张照片）。'),
            findsOneWidget);
        expect(find.descendant(
                of: find.byKey(_retry),
                matching: find.text(lang == 'en' ? 'Retry' : '重试')),
            findsOneWidget);
        expect(tester.getRect(find.byKey(_hero)), hero);
        expect(_paragraph(tester).didExceedMaxLines, isFalse);
        final button = tester.getRect(find.byKey(_retry));
        expect(button.height, greaterThanOrEqualTo(44));
        expect(button.top,
            greaterThanOrEqualTo(tester.getRect(find.byKey(_text)).bottom));
        // It stays: this is what used to be silent.
        await tester.pump(PhotoScanRow.doneFor * 3);
        expect(find.byKey(_row), findsOneWidget);
      }, skip: !haveIphoneFonts);
    }

    testWidgets('each reason, one photo, and a photo with no reason to give',
        (tester) async {
      Future<String> lineFor(void Function(PhotoScanStatus) fill) async {
        final status = PhotoScanStatus();
        await pumpApp(tester, _today(FakeDao(), status), size: _se);
        fill(status);
        await _pumpMotion(tester);
        return tester.widget<Text>(find.byKey(_text)).data!;
      }

      expect(await lineFor((s) => _waiting(s, count: 1)),
          '1 photo is not checked yet (network or service issue).');
      expect(
          await lineFor((s) => _waiting(s,
              kind: AnalysisErrorKind.rateLimited, count: 2)),
          '2 photos are not checked yet (the provider is rate-limiting).');
      expect(
          await lineFor((s) => _waiting(s,
              kind: AnalysisErrorKind.serverError, count: 2)),
          '2 photos are not checked yet (your server could not analyze it).');
      // Another run of the app holds it: no reason, no error words.
      expect(
          await lineFor((s) => _waiting(s,
              kind: AnalysisErrorKind.none, count: 1)),
          '1 photo is not checked yet.');
      expect(
          await lineFor((s) => _waiting(s,
              kind: AnalysisErrorKind.none, count: 4)),
          '4 photos are not checked yet.');
      // No Retry without a way to retry.
      expect(find.byKey(_retry), findsNothing);
    });

    testWidgets('Retry starts the catch-up once, waits for it, and Today '
        'then shows what it logged', (tester) async {
      final status = PhotoScanStatus();
      final dao = FakeDao();
      var retries = 0;
      final running = Completer<void>();
      await pumpApp(
          tester,
          _today(dao, status, onRetry: () {
            retries++;
            return running.future;
          }),
          size: _se);
      _waiting(status, count: 2);
      await _pumpMotion(tester);
      expect(find.text(
              '2 photos are not checked yet (network or service issue).'),
          findsOneWidget);

      await tester.tap(find.byKey(_retry));
      await tester.pump();
      expect(retries, 1);
      expect(tester.widget<FilledButton>(find.byKey(_retry)).onPressed, isNull,
          reason: 'not twice while it runs');
      await tester.tap(find.byKey(_retry), warnIfMissed: false);
      expect(retries, 1);

      // The catch-up takes both up, logs one, and ends.
      final scan = status.begin(expected: ['w0', 'w1'], wholeWindow: true);
      await _pumpMotion(tester);
      expect(find.text('Checking photos: 1 of 2'),
          findsOneWidget);
      expect(find.byKey(_retry), findsNothing);
      status.checking('w0');
      dao.seed(_meal(1, 'Noodles', 650));
      status.finished('w0', ScanVerdict.checked);
      status.checking('w1');
      status.finished('w1', ScanVerdict.checked);
      scan.end();
      expect(find.byType(MealCard), findsNothing,
          reason: 'this test\'s meal was written behind the screen\'s back');
      running.complete();
      await _pumpMotion(tester);
      expect(find.byType(MealCard), findsOneWidget,
          reason: 'Today re-reads the list when the retry is over');
      expect(find.text('2 photos checked.'), findsOneWidget);
      await tester.pump(PhotoScanRow.doneFor);
      await tester.pumpAndSettle();
      expect(find.byKey(_row), findsNothing);
    });

    testWidgets('a Retry that fails the same way leaves the row and its '
        'button as they were', (tester) async {
      final status = PhotoScanStatus();
      await pumpApp(
          tester,
          _today(FakeDao(), status,
              onRetry: () async => throw StateError('no catch-up')),
          size: _se);
      _waiting(status, count: 1);
      await _pumpMotion(tester);
      await tester.tap(find.byKey(_retry));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('1 photo is not checked yet (network or service '
          'issue).'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(_retry)).onPressed,
          isNotNull);
    });
  });

  group('a screen reader', () {
    test('the label it is told is the row\'s two lines, in both languages, '
        'and holds no number', () {
      for (final l in [AppLocalizationsEn(), AppLocalizationsZh()]) {
        expect(l.todayScanCheckingLabel, endsWith(l.todayScanKeepOpen),
            reason: l.localeName);
        expect(l.todayScanCheckingLabel, isNot(contains(RegExp(r'\d'))),
            reason: 'a count in it would be announced for every photo');
      }
      expect(AppLocalizationsEn().todayScanCheckingLabel,
          'Checking photos. Keep Chopstats open.');
      expect(AppLocalizationsZh().todayScanCheckingLabel, '正在检查照片。请保持筷拍打开。');
    });

    testWidgets('hears the row once when it comes and once when it changes '
        'to what the scan came to: the label it announces does not count',
        (tester) async {
      final handle = tester.ensureSemantics();
      final status = PhotoScanStatus();
      await pumpApp(tester, _today(FakeDao(), status), size: _se);
      final announced = <String>[];
      void note() {
        final node = tester.getSemantics(find.byKey(_line));
        expect(node.flagsCollection.isLiveRegion, isTrue);
        // Both engines announce a live region when its LABEL changes.
        if (announced.isEmpty || announced.last != node.label) {
          announced.add(node.label);
        }
      }

      final scan = status.begin(expected: ['a', 'b', 'c']);
      status.checking('a');
      await _pumpMotion(tester);
      note();
      expect(tester.getSemantics(find.byKey(_line)).value, '1 of 3');
      final values = <String>[];
      for (final id in ['a', 'b', 'c']) {
        status.checking(id);
        await tester.pump();
        note();
        values.add(tester.getSemantics(find.byKey(_line)).value);
        status.finished(id, ScanVerdict.checked);
        await tester.pump();
        if (id != 'c') note();
      }
      expect(values, ['1 of 3', '2 of 3', '3 of 3'],
          reason: 'the count is the node\'s value, read when it is focused');
      scan.end();
      await _pumpMotion(tester);
      note();
      expect(announced, [
        'Checking photos. Keep Chopstats open.',
        '3 photos checked.',
      ]);
      await tester.pump(PhotoScanRow.doneFor);
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('hears how many are not checked yet as the scan\'s end, and '
        'Retry is a button', (tester) async {
      final handle = tester.ensureSemantics();
      final status = PhotoScanStatus();
      await pumpApp(tester, _today(FakeDao(), status, onRetry: () async {}),
          size: _se);
      final scan = status.begin(expected: ['a', 'b']);
      status.checking('a');
      await _pumpMotion(tester);
      expect(tester.getSemantics(find.byKey(_line)).label,
          'Checking photos. Keep Chopstats open.');
      status.finished('a', ScanVerdict.waiting,
          kind: AnalysisErrorKind.network);
      status.checking('b');
      status.finished('b', ScanVerdict.checked);
      scan.end();
      await _pumpMotion(tester);
      final node = tester.getSemantics(find.byKey(_line));
      expect(node.label,
          '1 photo is not checked yet (network or service issue).');
      expect(node.flagsCollection.isLiveRegion, isTrue);
      final retry = tester.getSemantics(find.byKey(_retry));
      expect(retry.label, 'Retry');
      expect(retry.flagsCollection.isButton, isTrue);
      handle.dispose();
    });
  });

  group('the largest text size (3.1x), iPhone SE', () {
    // There the totals card is taller than the screen, so the row starts
    // below the fold: scrolled to, as the meals under it are.
    Future<void> scrollToRow(WidgetTester tester) async {
      await tester.pump();
      await tester.scrollUntilVisible(find.byKey(_row), 200,
          scrollable: find.byType(Scrollable).first);
      await _pumpMotion(tester);
    }

    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: both lines read whole, Retry sits under its line, '
          'and nothing overflows', (tester) async {
        final status = PhotoScanStatus();
        await pumpApp(tester, _today(FakeDao(), status, onRetry: () async {}),
            size: _se, locale: Locale(lang), scale: 3.1);
        final hero = tester.getRect(find.byKey(_hero));

        // A count of two digits on both sides, the widest it gets.
        final scan = status.begin(
            expected: [for (var i = 0; i < 12; i++) 'p$i']);
        for (var i = 0; i < 9; i++) {
          status.finished('p$i', ScanVerdict.checked);
        }
        status.checking('p9');
        await _pumpMotion(tester);
        expect(tester.getRect(find.byKey(_hero)), hero,
            reason: 'the totals did not move');
        await scrollToRow(tester);
        expect(tester.takeException(), isNull);
        expect(
            find.text(lang == 'en'
                ? 'Checking photos: 10 of 12'
                : '正在检查照片：第 10 张，共 12 张'),
            findsOneWidget);
        var p = _paragraph(tester);
        expect(p.didExceedMaxLines, isFalse);
        // The card's width less its padding, the spinner and the gap.
        expect(p.size.width, lessThanOrEqualTo(_se.width - 32 - 32 - 34));
        final caption = tester.renderObject<RenderParagraph>(find
            .descendant(
                of: find.byKey(const Key('photoScanCaption')),
                matching: find.byType(RichText))
            .first);
        expect(caption.didExceedMaxLines, isFalse);
        expect(caption.localToGlobal(Offset.zero).dy,
            greaterThanOrEqualTo(p.localToGlobal(Offset.zero).dy + p.size.height),
            reason: 'the second line sits under the first, whole');
        expect(tester.getSize(find.byKey(_hero)).height,
            closeTo(hero.height, 0.01));
        var row = tester.getRect(find.byKey(_row));
        expect(row.left, greaterThanOrEqualTo(0));
        expect(row.right, lessThanOrEqualTo(_se.width));

        for (var i = 9; i < 12; i++) {
          status.finished('p$i', ScanVerdict.waiting,
              kind: AnalysisErrorKind.serverBusy);
        }
        scan.end();
        await _pumpMotion(tester);
        await tester.scrollUntilVisible(find.byKey(_retry), 200,
            scrollable: find.byType(Scrollable).first);
        await _pumpMotion(tester);
        expect(tester.takeException(), isNull);
        p = _paragraph(tester);
        expect(p.didExceedMaxLines, isFalse);
        expect(
            p.text.toPlainText(),
            lang == 'en'
                ? '3 photos are not checked yet (your server is busy with '
                    'another analysis).'
                : '还有 3 张照片没有检查（你的服务器正在处理另一张照片）。');
        final button = tester.getRect(find.byKey(_retry));
        row = tester.getRect(find.byKey(_row));
        expect(button.top,
            greaterThanOrEqualTo(tester.getRect(find.byKey(_text)).bottom));
        expect(button.left, greaterThanOrEqualTo(row.left));
        expect(button.right, lessThanOrEqualTo(row.right));
        expect(button.height, greaterThanOrEqualTo(44));
        final label = tester.renderObject<RenderParagraph>(find
            .descendant(
                of: find.byKey(_retry), matching: find.byType(RichText))
            .first);
        expect(label.didExceedMaxLines, isFalse);
      }, skip: !haveIphoneFonts);
    }
  });

  group('each platform\'s own look', () {
    testWidgets('the iPhone\'s activity indicator on iOS, Material\'s ring on '
        'Android', (tester) async {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final status = PhotoScanStatus();
          await pumpApp(tester, _today(FakeDao(), status), size: _se);
          final scan = _checking(status);
          await _pumpMotion(tester);
          final spinner = find.byKey(const Key('photoScanSpinner'));
          expect(
              find.descendant(
                  of: spinner,
                  matching: find.byType(CupertinoActivityIndicator)),
              platform == TargetPlatform.iOS ? findsOneWidget : findsNothing);
          expect(
              find.descendant(
                  of: spinner,
                  matching: find.byType(CircularProgressIndicator)),
              platform == TargetPlatform.iOS ? findsNothing : findsOneWidget);
          scan.end();
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  });

  testWidgets('the app shell hands Today the engine\'s scan status and its '
      'Retry', (tester) async {
    final status = PhotoScanStatus();
    var retries = 0;
    await tester.pumpWidget(CalorieTrackerApp(
        services: makeServices(
            photoScanStatus: status,
            retryPhotoScan: () async => retries++)));
    await tester.pumpAndSettle();
    _waiting(status, count: 1);
    await _pumpMotion(tester);
    expect(find.text('1 photo is not checked yet (network or service '
        'issue).'), findsOneWidget);
    await tester.tap(find.byKey(_retry));
    await tester.pump();
    await tester.pump();
    expect(retries, 1);
  });
}
