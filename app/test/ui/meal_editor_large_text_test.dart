// The meal editor at enlarged text (run-7 E2E-2, the A10 note). An
// outlined field draws its floated label centred on its top border at
// 0.75x, so half the label sits ABOVE the field's box: about 26 pt at AX5.
// With 8-pt gaps the labels (热量 / 蛋白质 / 碳水 …) covered the 总计 header
// and the field above them, the first one was clipped under the app bar,
// and the one-line description showed only 'Pan-fried du'.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/meal_correction.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

const _desc = 'Pan-fried dumplings with millet porridge';

Meal _meal() => Meal(
  id: 1,
  date: '2026-10-31',
  time: '08:05 AM',
  timestamp: '2026-10-31T08:05:00.000',
  source: 'app_photo',
  imageHash: 'h1',
  analysis: const {
    'is_food': true,
    'meal_description': _desc,
    'total_calories': 640,
    'total_protein_g': 23,
    'total_carbs_g': 77,
    'total_fat_g': 26,
    'food_items': [
      {
        'name': 'Pan-fried pork dumplings (8 pieces)',
        'estimated_calories': 480,
        'protein_g': 18,
        'carbs_g': 52,
        'fat_g': 22,
      },
      {
        'name': 'Millet porridge',
        'estimated_calories': 160,
        'protein_g': 5,
        'carbs_g': 25,
        'fat_g': 4,
      },
    ],
  },
);

Rect _global(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Each outlined field's box and the global rect of its floated label.
List<({Rect field, Rect label, String text})> _fields(WidgetTester tester) {
  final out = <({Rect field, Rect label, String text})>[];
  for (final e in find.byType(InputDecorator).evaluate()) {
    final text = (e.widget as InputDecorator).decoration.labelText;
    if (text == null) continue;
    final label = find
        .descendant(
          of: find.byElementPredicate((x) => identical(x, e)),
          matching: find.text(text),
        )
        .evaluate()
        .single;
    out.add((
      field: _global(e.renderObject! as RenderBox),
      label: _global(label.renderObject! as RenderBox),
      text: text,
    ));
  }
  return out;
}

/// [_meal] with two notes kept on it (Correct with a note).
Meal _mealWithNotes() {
  final m = _meal();
  return Meal(
    id: m.id,
    date: m.date,
    time: m.time,
    timestamp: m.timestamp,
    source: m.source,
    imageHash: m.imageHash,
    analysis: {
      ...m.analysis,
      kUserNotesKey: [
        {'text': 'only six dumplings', 'at': '2026-10-31T09:00:00.000Z'},
        {'text': 'the porridge had sugar', 'at': '2026-10-31T09:30:00.000Z'},
      ],
    },
  );
}

/// The no-overlap rule of the test above, over the whole form: no floated
/// label covers a field, a pill or any text that is not a field's or a
/// button's. Over the rows the list has built: an answer scrolls the note
/// section to the top, and where the form is taller than the surface (the
/// test font, without the iPhone fonts, wraps far more) the date row is
/// then out of the list. The check before the first send covers it.
void _expectNoLabelCovers(WidgetTester tester) {
  final fields = _fields(tester);
  final obstacles = <Rect>[
    for (final f in fields) f.field,
    for (final k in ['editorDateButton', 'editorTimeButton'])
      for (final e in find.byKey(Key(k)).evaluate())
        _global(e.renderObject! as RenderBox),
    for (final e in find.byType(Text).evaluate())
      if (e.findAncestorWidgetOfExactType<InputDecorator>() == null &&
          e.findAncestorWidgetOfExactType<ButtonStyleButton>() == null &&
          e.findAncestorWidgetOfExactType<AppBar>() == null &&
          e.findAncestorWidgetOfExactType<FloatingActionButton>() == null)
        _global(e.renderObject! as RenderBox),
  ];
  for (final f in fields) {
    for (final o in obstacles) {
      if (o == f.field) continue;
      expect(
        f.label.overlaps(o.deflate(0.5)),
        isFalse,
        reason: "'${f.text}' label ${f.label} covers $o",
      );
    }
  }
}

void main() {
  setUpAll(loadIphoneFonts);

  // Correct with a note: the section is the form's last block — its header,
  // field, footer and button, the card of what a note changed, an answer
  // that changed nothing, and the notes kept on the meal — all at enlarged
  // text, with no label over anything and nothing overflowing.
  for (final (locale, scale) in [
    (const Locale('zh'), 53 / 17), // AX5
    (const Locale('en'), 53 / 17),
    (const Locale('en'), 1.35),
  ]) {
    testWidgets('${locale.languageCode} at ${scale.toStringAsFixed(2)}x: the '
        'note section, its changes card and its reply lay out clear',
        (tester) async {
      final dao = FakeDao()..seed(_mealWithNotes());
      final executor = FakeExecutor()
        ..nextNoteOutcome = const MealNoteOutcome(
            reply: MealCorrected(MealCorrectionProposal(
          changed: {
            0: MealCorrectionItem(
                name: 'Pan-fried pork dumplings (6 pieces)',
                calories: 360,
                protein: 13.5,
                carbs: 39,
                fat: 16.5),
          },
          added: [
            MealCorrectionItem(
                name: 'Soy milk (1 glass, ~250 ml)',
                calories: 110,
                protein: 8,
                carbs: 10,
                fat: 4),
          ],
          reason: 'Six dumplings instead of eight, and a glass of soy milk.',
        )));
      await pumpApp(
        tester,
        MealEditorScreen(
            dao: dao,
            meal: dao.meals.first,
            settings: FakeSettings(),
            noteCorrector: executor),
        size: const Size(375, 12000),
        locale: locale,
        scale: scale,
      );
      expect(find.byKey(const Key('mealNoteSaved1')), findsOneWidget);
      expect(find.byKey(const Key('editorDateButton')), findsOneWidget);
      _expectNoLabelCovers(tester);

      await tester.enterText(find.byKey(const Key('mealNoteField')),
          'only six dumplings, and a glass of soy milk');
      await tester.pump();
      await tester.tap(find.byKey(const Key('mealNoteSend')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('mealNoteChanges')), findsOneWidget);
      _expectNoLabelCovers(tester);

      executor.nextNoteOutcome = const MealNoteOutcome(
          reply: MealUnclear('Was the soy milk sweetened, and how much?'));
      await tester.enterText(
          find.byKey(const Key('mealNoteField')), 'the soy milk');
      await tester.pump();
      await tester.tap(find.byKey(const Key('mealNoteSend')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('mealNoteReply')), findsOneWidget);
      _expectNoLabelCovers(tester);
      // The button's label wraps rather than overflow its row.
      final send = tester.getRect(find.byKey(const Key('mealNoteSend')));
      expect(send.right, lessThanOrEqualTo(375));
    });
  }

  // The keyboard up on the note: Correct with AI shows above it, clear of
  // the Save button where the two meet (larger text widens both). The
  // field revealed only its caret's line and 120 pt under it, and the
  // button sat half under the keyboard (device check, 2026-11-24). Where
  // the field, its footer and the button are taller than what the
  // keyboard leaves (2x on a 6.1-inch phone, AX5), the note's text stays
  // in view at the top and the rest scrolls.
  const phone = Size(390, 844); // 6.1-inch
  const large = Size(430, 932); // 6.7-inch
  const keyboard = 336.0;
  for (final (locale, scale, size, fits) in [
    (const Locale('en'), 1.0, phone, true),
    (const Locale('zh'), 1.0, phone, true),
    // Fits with the iPhone's glyphs. The test font (CI has no SF) wraps
    // the footer far more, the block outgrows what the keyboard leaves,
    // and the note's text is what stays in view.
    (const Locale('en'), 2.0, large, haveIphoneFonts),
    (const Locale('en'), 2.0, phone, false),
    (const Locale('en'), 53 / 17, phone, false), // AX5
    (const Locale('zh'), 53 / 17, phone, false),
  ]) {
    testWidgets('${locale.languageCode} at ${scale.toStringAsFixed(2)}x on '
        '${size.width.round()} pt, the keyboard up on the note: '
        '${fits ? 'the button shows above it' : 'the text stays in view'}',
        (tester) async {
      final dao = FakeDao()..seed(_mealWithNotes());
      await pumpApp(
        tester,
        MealEditorScreen(
            dao: dao,
            meal: dao.meals.first,
            settings: FakeSettings(),
            noteCorrector: FakeExecutor()),
        size: size,
        locale: locale,
        scale: scale,
      );
      final field = find.byKey(const Key('mealNoteField'));
      // Scrolled just far enough to see the field: at the bottom edge.
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      while (field.evaluate().isEmpty) {
        expect(list.position.pixels, lessThan(list.position.maxScrollExtent));
        list.position.jumpTo(list.position.pixels + 200);
        await tester.pump();
      }
      await Scrollable.ensureVisible(tester.element(field), alignment: 1);
      await tester.pumpAndSettle();
      await tester.showKeyboard(field);
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'only half the rice');
      await tester.pumpAndSettle();

      final top = tester.getRect(find.byType(AppBar)).bottom;
      final keyboardTop = size.height - keyboard;
      final text = tester.getRect(
          find.descendant(of: field, matching: find.byType(EditableText)));
      expect(text.top, greaterThanOrEqualTo(top - 0.5),
          reason: "the note's text is under the app bar");
      expect(text.top, lessThan(keyboardTop),
          reason: "the note's text is under the keyboard");
      if (!fits) return;
      final send = tester.getRect(find.byKey(const Key('mealNoteSend')));
      final save = tester.getRect(find.byKey(const Key('saveMealButton')));
      expect(send.bottom, lessThanOrEqualTo(keyboardTop + 0.5),
          reason: 'the button is under the keyboard');
      if (send.left < save.right && save.left < send.right) {
        expect(send.bottom, lessThanOrEqualTo(save.top + 0.5),
            reason: 'the Save button covers it');
      }
    });
  }

  for (final (locale, scale) in [
    (const Locale('zh'), 53 / 17), // AX5
    (const Locale('en'), 53 / 17),
    (const Locale('en'), 1.35), // xxxLarge, the largest standard size
  ]) {
    testWidgets('${locale.languageCode} at ${scale.toStringAsFixed(2)}x: no '
        'floated label covers the header or field above it', (tester) async {
      final dao = FakeDao()..seed(_meal());
      // Tall enough that every row is built and on screen.
      await pumpApp(
        tester,
        MealEditorScreen(dao: dao, meal: dao.meals.first),
        size: const Size(375, 4000),
        locale: locale,
        scale: scale,
      );
      final fields = _fields(tester);
      expect(
        fields.length,
        greaterThanOrEqualTo(10),
        reason: 'description, totals and two item rows',
      );
      final obstacles = <Rect>[
        for (final f in fields) f.field,
        for (final k in ['editorDateButton', 'editorTimeButton'])
          tester.getRect(find.byKey(Key(k))),
        for (final e in find.byType(Text).evaluate())
          // Headers and the live total; field labels, button labels and
          // the app bar are not obstacles.
          if (e.findAncestorWidgetOfExactType<InputDecorator>() == null &&
              e.findAncestorWidgetOfExactType<ButtonStyleButton>() == null &&
              e.findAncestorWidgetOfExactType<AppBar>() == null &&
              e.findAncestorWidgetOfExactType<FloatingActionButton>() == null)
            _global(e.renderObject! as RenderBox),
      ];
      for (final f in fields) {
        for (final o in obstacles) {
          if (o == f.field) continue;
          expect(
            f.label.overlaps(o.deflate(0.5)),
            isFalse,
            reason: "'${f.text}' label ${f.label} covers $o",
          );
        }
      }
    });
  }

  testWidgets('zh at AX5 on an SE: the first label clears the app bar', (
    tester,
  ) async {
    final dao = FakeDao()..seed(_meal());
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(375, 667),
      locale: const Locale('zh'),
      scale: 53 / 17,
      padding: const EdgeInsets.only(top: 20),
    );
    final first = _fields(tester).first;
    final viewport = _global(
      tester.renderObject<RenderBox>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Viewport),
        ),
      ),
    );
    expect(
      first.label.top,
      greaterThanOrEqualTo(viewport.top),
      reason: 'the floated label is not clipped by the list',
    );
  });

  // Your usual numbers (usual foods §3.4) for both foods, in run 7's
  // card: it sits right above the description, whose floated label
  // reaches up out of the field at large text.
  for (final (locale, scale) in [
    (const Locale('zh'), 53 / 17), // AX5
    (const Locale('en'), 53 / 17),
    (const Locale('en'), 1.35),
  ]) {
    testWidgets('${locale.languageCode} at ${scale.toStringAsFixed(2)}x: '
        'the usual card with two items reads in full on an SE, and no '
        'floated label covers it', (tester) async {
      final now = DateTime(2026, 10, 31, 12);
      // The user's own numbers for both foods, typed two days before.
      final dao = FakeDao()
        ..seed(foodMeal(
          id: 2,
          date: '2026-10-29',
          source: MealSource.appManual,
          items: [
            foodItem('Pan-fried pork dumplings (8 pieces)', 560,
                p: 21, c: 58, f: 27),
            foodItem('Millet porridge', 210, p: 6, c: 36, f: 4),
          ],
        ))
        ..seed(_meal());
      final usual = await makeUsualFoods(dao, clock: () => now);
      // As wide as an SE, tall enough that every row is built.
      await pumpApp(
        tester,
        MealEditorScreen(
            dao: dao, meal: dao.byId(1), now: () => now, usual: usual),
        size: const Size(375, 4000),
        locale: locale,
        scale: scale,
      );
      expect(tester.takeException(), isNull);
      final card = find.byKey(const Key('usualOfferCard'));
      expect(card, findsOneWidget);
      for (final key in ['usualOfferItem0', 'usualOfferItem1']) {
        expect(find.descendant(of: card, matching: find.byKey(Key(key))),
            findsOneWidget, reason: key);
      }
      final cardRect = tester.getRect(card);
      expect(cardRect.left, greaterThanOrEqualTo(0));
      expect(cardRect.right, lessThanOrEqualTo(375));
      for (final p in tester.renderObjectList<RenderParagraph>(
          find.descendant(of: card, matching: find.byType(RichText)))) {
        expect(p.didExceedMaxLines, isFalse,
            reason: '"${p.text.toPlainText()}" was cut');
        final r = _global(p);
        expect(r.left >= cardRect.left - 0.5 && r.right <= cardRect.right + 0.5,
            isTrue,
            reason: '"${p.text.toPlainText()}" $r leaves the card $cardRect');
      }
      for (final key in ['usualUseMine', 'usualKeepAi']) {
        final b = tester.getRect(find.byKey(Key(key)));
        expect(b.right, lessThanOrEqualTo(cardRect.right + 0.5), reason: key);
        expect(b.bottom, lessThanOrEqualTo(cardRect.bottom + 0.5),
            reason: key);
      }
      for (final f in _fields(tester)) {
        expect(f.label.overlaps(cardRect.deflate(0.5)), isFalse,
            reason: "'${f.text}' label ${f.label} covers the card $cardRect");
      }
    });
  }

  RenderEditable editableFor(WidgetTester tester, String text) => tester
      .allRenderObjects
      .whereType<RenderEditable>()
      .firstWhere((r) => r.text?.toPlainText() == text);

  testWidgets('at AX5 the description and item names wrap instead of '
      'cutting off', (tester) async {
    final dao = FakeDao()..seed(_meal());
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(375, 4000),
      locale: const Locale('zh'),
      scale: 53 / 17,
    );
    for (final text in [_desc, 'Pan-fried pork dumplings (8 pieces)']) {
      final editable = editableFor(tester, text);
      expect(
        editable.size.height,
        greaterThan(editable.preferredLineHeight * 1.5),
        reason: '"$text" shows on more than one line',
      );
    }
    final field = tester.widget<TextField>(
      find.byKey(const Key('editorDescription')),
    );
    expect(
      field.textInputAction,
      TextInputAction.done,
      reason: 'Return still finishes; the text stays one paragraph',
    );
  });

  testWidgets('at the default size the fields are one line, 8 pt apart, as '
      'before', (tester) async {
    final dao = FakeDao()..seed(_meal());
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(390, 4000),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('editorDescription')))
          .maxLines,
      1,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('editorProtein'))).dy -
          tester.getBottomLeft(find.byKey(const Key('editorCalories'))).dy,
      8,
    );
  });
}
