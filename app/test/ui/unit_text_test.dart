// Chinese lines that end in a number and its unit (2026-11-25): the line
// '米饭（约200克） → 米饭（约100克）：260 → 130 千卡' in Edit meal's Correct
// with a note card wrapped as '…130 千' / '卡' on an iPhone 17 Pro Max.
// ICU may break Chinese between any two ideographs and after any space;
// lib/ui/unit_text.dart draws a no-break space or a word joiner where a
// number meets its unit, and a word joiner inside 千卡, and leaves what
// screen readers get exactly as it was.
//
// The layout checks read real line breaks (TextPainter line boundaries,
// the same ICU rules the phones use) with the iPhone fonts where this
// machine has them, the test font elsewhere (CI): line breaks fall
// differently with each, and every check below holds with either.
import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/meal_correction.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/unit_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

const _nb = noBreakSpace;
const _wj = wordJoiner;

/// What must never be split across lines: a number's last digit and the
/// unit right after it (with or without a space), and 千卡 on its own,
/// as the app's strings have them (lib/ui/unit_text.dart's list) and as
/// they are drawn (a no-break space or word joiner after the number, word
/// joiners inside the unit).
final RegExp _held = () {
  String unit(String u) => u.split('').join('$_wj?');
  const cjk = ['千卡', '大卡', '千克', '毫克', '公斤', '毫升', '公里', '克', '升'];
  return RegExp('[0-9?][ $_nb$_wj]?(?:${cjk.map(unit).join('|')})'
      '|[0-9?][ $_nb](?:kcal|kg|mg|ml|mL|km|g)(?![A-Za-z])'
      '|${unit('千卡')}');
}();

/// A held run as [keepUnitsTogether] draws it: a no-break space or word
/// joiner right after the number, a word joiner between the unit's
/// characters (千卡 alone too).
bool _joined(String run) =>
    (run.startsWith('千') || RegExp('^[0-9?][$_nb$_wj]').hasMatch(run)) &&
    !RegExp(r'[\u4e00-\u9fff]{2}').hasMatch(run);

List<TextRange> _ranges(RegExp re, String s) => [
      for (final m in re.allMatches(s)) TextRange(start: m.start, end: m.end)
    ];

/// The runs of [text] at [ranges] that [span], laid out [width] wide,
/// splits across lines. [like]: lay it out as that paragraph does (its
/// scaler, strut, height behaviour…); with [asDrawn], [span] is that
/// paragraph's own text, and the copy must come out its height.
List<String> _splits(
    InlineSpan span, double width, String text, List<TextRange> ranges,
    {RenderParagraph? like, bool asDrawn = false}) {
  final painter = TextPainter(
    text: span,
    textDirection: like?.textDirection ?? TextDirection.ltr,
    textAlign: like?.textAlign ?? TextAlign.start,
    textScaler: like?.textScaler ?? TextScaler.noScaling,
    maxLines: like?.maxLines,
    locale: like?.locale,
    strutStyle: like?.strutStyle,
    textWidthBasis: like?.textWidthBasis ?? TextWidthBasis.parent,
    textHeightBehavior: like?.textHeightBehavior,
  )..layout(maxWidth: width);
  try {
    if (asDrawn) expect(painter.height, moreOrLessEquals(like!.size.height));
    return [
      for (final r in ranges)
        if (painter.getLineBoundary(TextPosition(offset: r.start)).end < r.end)
          r.textInside(text),
    ];
  } finally {
    painter.dispose();
  }
}

/// [span]'s width on one line, and the width of its longest unbreakable
/// run (TextPainter.minIntrinsicWidth).
({double width, double minimum}) _widths(InlineSpan span) {
  final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
    ..layout();
  final out = (width: painter.width, minimum: painter.minIntrinsicWidth);
  painter.dispose();
  return out;
}

/// The zh ARB's simple strings (no plural or select) that put a unit
/// after a placeholder or hold 千卡, filled with a number.
Map<String, String> _zhUnitStrings() {
  final zh = (jsonDecode(File('lib/l10n/app_zh.arb').readAsStringSync())
      as Map<String, dynamic>);
  final out = <String, String>{};
  zh.forEach((key, value) {
    if (key.startsWith('@') || value is! String) return;
    if (value.contains(', plural') || value.contains(', select')) return;
    final filled = value.replaceAll(RegExp(r'\{\w+\}'), '1,234');
    if (_held.hasMatch(filled)) out[key] = filled;
  });
  return out;
}

final _zh = AppLocalizationsZh();
final _en = AppLocalizationsEn();

void main() {
  setUpAll(loadIphoneFonts);

  group('keepUnitsTogether', () {
    test('the reported line: 千卡 and both 克 held to their numbers', () {
      expect(
          keepUnitsTogether('米饭（约200克） → 米饭（约100克）：260 → 130 千卡'),
          '米饭（约200$_wj克） → 米饭（约100$_wj克）：260 → 130$_nb千$_wj卡');
    });

    test('a space becomes a no-break space; a touching unit gets a joiner',
        () {
      expect(keepUnitsTogether('合计：660 → 530 千卡'),
          '合计：660 → 530$_nb千$_wj卡');
      expect(keepUnitsTogether('蛋白质 20 克'), '蛋白质 20$_nb克');
      expect(keepUnitsTogether('约1,320千卡'), '约1,320$_wj千$_wj卡');
      expect(keepUnitsTogether('跑了 5 公里，消耗 450 千卡'),
          '跑了 5$_nb公$_wj里，消耗 450$_nb千$_wj卡');
      expect(keepUnitsTogether('已记录 11-24 的体重：70.5 公斤。'),
          '已记录 11-24 的体重：70.5$_nb公$_wj斤。');
      expect(keepUnitsTogether('~? 千卡'), '~?$_nb千$_wj卡');
      expect(keepUnitsTogether('590–620 千卡'), '590–620$_nb千$_wj卡');
    });

    test('千卡 with no number before it still never splits', () {
      expect(keepUnitsTogether('千卡 / 天'), '千$_wj卡 / 天');
      expect(keepUnitsTogether('食物始终使用克与千卡。'), '食物始终使用克与千$_wj卡。');
    });

    test('Latin units in Chinese lines keep their number', () {
      expect(keepUnitsTogether('590 千卡 · 蛋 25 g · 碳 46 g · 脂 34 g'),
          '590$_nb千$_wj卡 · 蛋 25${_nb}g · 碳 46${_nb}g · 脂 34${_nb}g');
      expect(keepUnitsTogether('可乐 330 ml'), '可乐 330${_nb}ml');
      // Touching, a Latin unit never breaks from its number anyway.
      expect(keepUnitsTogether('蛋 20g · 碳 50g'), '蛋 20g · 碳 50g');
      // A word that starts like a unit is not one.
      expect(keepUnitsTogether('Rice 150 grams'), 'Rice 150 grams');
    });

    test('nothing else changes: the same words, in the same order', () {
      for (final s in [
        '米饭（约200克） → 米饭（约100克）：260 → 130 千卡',
        '今天：1,850 千卡',
        '没有记录营养素分布。',
        'Total: 660 → 530 kcal',
      ]) {
        expect(
            keepUnitsTogether(s).replaceAll(_wj, '').replaceAll(_nb, ' '), s);
      }
      expect(keepUnitsTogether('没有记录营养素分布。'), '没有记录营养素分布。');
    });

    test('only Chinese draws it: English is left as it is', () {
      expect(drawnUnits(_en, 'Total: 660 → 530 kcal'),
          'Total: 660 → 530 kcal');
      expect(drawnUnits(_en, 'Rice (~150 g): ~200 kcal'),
          'Rice (~150 g): ~200 kcal');
      expect(drawnUnits(_zh, '合计：660 → 530 千卡'), '合计：660 → 530$_nb千$_wj卡');
    });
  });

  group('unitSpan', () {
    test('a span after a number keeps the unit with it', () {
      final span = unitSpan(_zh, ' 千卡 / 天', before: '1,909');
      expect(span.text, '$_nb千$_wj卡 / 天');
      expect(span.semanticsLabel, ' 千卡 / 天');
      final unchanged = unitSpan(_zh, '平均：约 ');
      expect(unchanged.text, '平均：约 ');
      expect(unchanged.semanticsLabel, isNull);
    });
  });

  group('unitText', () {
    testWidgets('English and unit-free lines are the very Text(s)',
        (tester) async {
      final en = unitText(_en, 'Total: 660 → 530 kcal', key: const Key('a'));
      expect(en.data, 'Total: 660 → 530 kcal');
      expect(en.textSpan, isNull);
      expect(en.key, const Key('a'));
      final plain = unitText(_zh, '请核对上面的数字，然后点「保存」。');
      expect(plain.data, '请核对上面的数字，然后点「保存」。');
    });

    testWidgets(
        'zh: screen readers get the string byte for byte, as Text(s) gave '
        'it, and find.text still finds it', (tester) async {
      final handle = tester.ensureSemantics();
      const line = '米饭（约200克） → 米饭（约100克）：260 → 130 千卡';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Semantics(
                container: true,
                child: const Text(line, key: Key('plain'))),
            Semantics(
                container: true,
                child: unitText(_zh, line, key: const Key('drawn'))),
          ]),
        ),
      ));
      SemanticsData data(String k) =>
          tester.getSemantics(find.byKey(Key(k))).getSemanticsData();
      expect(data('drawn').label, line);
      expect(data('drawn').label, data('plain').label);
      expect(data('drawn').attributedLabel.attributes,
          data('plain').attributedLabel.attributes);
      expect(data('drawn').textDirection, data('plain').textDirection);
      expect(data('drawn').flagsCollection, data('plain').flagsCollection);
      // What is drawn is not what is read.
      final drawn = tester.widget<RichText>(find.descendant(
          of: find.byKey(const Key('drawn')), matching: find.byType(RichText)));
      expect(drawn.text.toPlainText(includeSemanticsLabels: false),
          keepUnitsTogether(line));
      expect(find.text(line), findsNWidgets(2));
      expect(find.textContaining('千卡'), findsNWidgets(2));
      handle.dispose();
    });
  });

  testWidgets(
      'every zh string with a unit after a number: no width splits the '
      'number from its unit, or 千卡 itself', (tester) async {
    final style = iphoneAppTheme(Brightness.light, cjk: true)
        .textTheme
        .bodyMedium!;
    final strings = _zhUnitStrings();
    // The 47-odd strings of the report, and the km and kg replies.
    expect(strings.length, greaterThanOrEqualTo(45));
    var plainSplits = 0;
    for (final MapEntry(key: key, value: filled) in strings.entries) {
      final drawn = keepUnitsTogether(filled);
      // Every number + unit and every 千卡 the string holds is held.
      final runs = _ranges(_held, drawn);
      expect(runs, hasLength(_ranges(_held, filled).length),
          reason: '$key: "$filled" → "$drawn"');
      for (final r in runs) {
        final run = r.textInside(drawn);
        expect(_joined(run), isTrue, reason: '$key: "$run" in "$drawn"');
      }
      final (:width, :minimum) = _widths(TextSpan(text: drawn, style: style));
      // From the narrowest line that holds the longest unbreakable run
      // ('1,234 千卡' whole): narrower than that, a run cannot fit on any
      // line, and every line breaker splits it somewhere.
      for (var w = minimum + 0.5; w < width; w += style.fontSize! / 3) {
        expect(
            _splits(TextSpan(text: drawn, style: style), w, drawn,
                _ranges(_held, drawn)),
            isEmpty,
            reason: '$key at ${w.toStringAsFixed(1)} px: "$drawn"');
        plainSplits += _splits(TextSpan(text: filled, style: style), w,
                filled, _ranges(_held, filled))
            .length;
      }
    }
    // The same sweep splits the strings as they were: the check can fail.
    expect(plainSplits, greaterThan(0));
  });

  group('Edit meal, Correct with a note, zh at a narrow width', () {
    const rice = {
      'name': '米饭（约200克）',
      'estimated_calories': 260,
      'protein_g': 5,
      'carbs_g': 57,
      'fat_g': 0.5,
    };
    const pork = {
      'name': '红烧肉（约120克）',
      'estimated_calories': 400,
      'protein_g': 27,
      'carbs_g': 13,
      'fat_g': 25.5,
    };
    Meal meal() => Meal(
          id: 1,
          date: '2026-11-24',
          time: '12:30 PM',
          timestamp: '2026-11-24T12:30:00.000',
          source: MealSource.appPhoto,
          imageHash: 'h1',
          analysis: const {
            'is_food': true,
            'meal_description': '红烧肉配米饭',
            'total_calories': 660,
            'total_protein_g': 32,
            'total_carbs_g': 70,
            'total_fat_g': 26,
            'food_items': [rice, pork],
          },
        );
    const renamed = '米饭（约200克） → 米饭（约100克）：260 → 130 千卡';

    for (final scale in [1.0, 1.35]) {
      testWidgets(
          'at ${scale}x the card\'s lines never split a number from its '
          'unit, or 千卡; VoiceOver hears the lines as they were',
          (tester) async {
        final handle = tester.ensureSemantics();
        final dao = FakeDao()..seed(meal());
        final executor = FakeExecutor()
          ..nextNoteOutcome = const MealNoteOutcome(
              reply: MealCorrected(MealCorrectionProposal(
            changed: {
              0: MealCorrectionItem(
                  name: '米饭（约100克）',
                  calories: 130,
                  protein: 2.5,
                  carbs: 28.5,
                  fat: 0.3),
            },
            reason: '米饭减半（约100克），红烧肉不变。',
          )));
        await pumpApp(
          tester,
          MealEditorScreen(
              dao: dao,
              meal: dao.meals.first,
              settings: FakeSettings(),
              noteCorrector: executor),
          size: const Size(440, 6000), // iPhone 17 Pro Max width
          locale: const Locale('zh'),
          scale: scale,
        );
        await tester.enterText(
            find.byKey(const Key('mealNoteField')), '米饭只吃了一半');
        await tester.pump();
        await tester.tap(find.byKey(const Key('mealNoteSend')));
        await tester.pumpAndSettle();
        final card = find.byKey(const Key('mealNoteChanges'));
        expect(card, findsOneWidget);
        expect(find.text(renamed), findsOneWidget);

        var plainSplits = 0;
        var checked = 0;
        // From a 6.7-inch phone's width down past the smallest iPhone's.
        for (var w = 440.0; w >= 300; w -= 2) {
          tester.view.physicalSize = Size(w, 6000);
          await tester.pump();
          expect(tester.takeException(), isNull);
          for (final e in find
              .descendant(of: card, matching: find.byType(RichText))
              .evaluate()) {
            final p = e.renderObject! as RenderParagraph;
            final drawn = p.text.toPlainText(includeSemanticsLabels: false);
            final read = p.text.toPlainText();
            final held = _ranges(_held, drawn);
            if (held.isEmpty) continue;
            // Its own layout, as drawn: the same lines.
            expect(
                _splits(p.text, p.constraints.maxWidth, drawn, held,
                    like: p, asDrawn: true),
                isEmpty,
                reason: 'at $w pt: "$drawn"');
            checked++;
            // The line as it was, laid out at the same width.
            plainSplits += _splits(TextSpan(text: read, style: p.text.style),
                    p.constraints.maxWidth, read, _ranges(_held, read),
                    like: p)
                .length;
          }
        }
        expect(checked, greaterThan(0));
        // Unfixed, the sweep splits a unit somewhere: the test can fail.
        expect(plainSplits, greaterThan(0));

        // A screen reader hears each line exactly as the ARB words it.
        final label = tester.getSemantics(card).label;
        expect(label, contains(renamed));
        expect(label, contains('合计：660 → 530 千卡'));
        expect(label, isNot(contains(_nb)));
        expect(label, isNot(contains(_wj)));
        handle.dispose();
      });
    }
  });
}
