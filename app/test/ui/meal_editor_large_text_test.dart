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

/// [_meal] with [desc] as its description and [name] as its first item's.
Meal _mealWith({required String desc, required String name}) {
  final m = _meal();
  final items = [...m.analysis['food_items'] as List];
  items[0] = {...items[0] as Map<String, Object?>, 'name': name};
  return Meal(
    id: m.id,
    date: m.date,
    time: m.time,
    timestamp: m.timestamp,
    source: m.source,
    imageHash: m.imageHash,
    analysis: {...m.analysis, 'meal_description': desc, 'food_items': items},
  );
}

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

  // The keyboard up to answer the AI: the reply under the button (its
  // question, or an answer it could not use) shows too, above Save and the
  // keyboard, where the field's top down to it fits. Revealed only to the
  // button, the question's line ends sat under Save and its last line
  // under the keyboard (iPhone check, 2026-11-24). The keyboard comes up
  // at once, or frame by frame as a phone raises it. Where it does not fit
  // (the test font, without the iPhone fonts, wraps far more), the button
  // still shows above the keyboard.
  const question = MealNoteOutcome(
      reply: MealUnclear('你说的是哪一种：猪肉饺子还是小米粥？如果是饺子，'
          '是只吃了一半，还是一半都不到呢？'));
  const unusable = MealNoteOutcome(reply: MealReplyUnusable());
  for (final (locale, outcome, steps) in [
    (const Locale('zh'), question, 1),
    (const Locale('zh'), question, 6),
    (const Locale('en'), unusable, 1),
    (const Locale('en'), unusable, 6),
  ]) {
    testWidgets('${locale.languageCode} at 1.00x on 390 pt, the keyboard up '
        'to answer (${steps == 1 ? 'at once' : 'over $steps frames'}): the '
        'reply shows above Save and the keyboard', (tester) async {
      final dao = FakeDao()..seed(_mealWithNotes());
      await pumpApp(
        tester,
        MealEditorScreen(
            dao: dao,
            meal: dao.meals.first,
            settings: FakeSettings(),
            noteCorrector: FakeExecutor()..nextNoteOutcome = outcome),
        size: phone,
        locale: locale,
      );
      final field = find.byKey(const Key('mealNoteField'));
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      while (field.evaluate().isEmpty) {
        expect(list.position.pixels, lessThan(list.position.maxScrollExtent));
        list.position.jumpTo(list.position.pixels + 200);
        await tester.pump();
      }
      await tester.enterText(field, 'only half the rice');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final reply = find.byKey(const Key('mealNoteReply'));
      expect(reply, findsOneWidget);
      // Looked back up the form, then down to the field: at the bottom edge.
      await Scrollable.ensureVisible(tester.element(field), alignment: 1);
      await tester.pumpAndSettle();
      await tester.showKeyboard(field);
      for (var i = 1; i <= steps; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard * i / steps);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      final top = tester.getRect(find.byType(AppBar)).bottom;
      final keyboardTop = phone.height - keyboard;
      final text = tester.getRect(
          find.descendant(of: field, matching: find.byType(EditableText)));
      final send = tester.getRect(find.byKey(const Key('mealNoteSend')));
      final save = tester.getRect(find.byKey(const Key('saveMealButton')));
      final note = tester.getRect(find.byKey(const Key('mealNoteReplyNote')));
      expect(text.top, greaterThanOrEqualTo(top - 0.5),
          reason: "the note's text is under the app bar");
      expect(send.bottom, lessThanOrEqualTo(keyboardTop + 0.5),
          reason: 'the button is under the keyboard');
      // The field's top (its floated label 12 pt above) down to the
      // reply's end, a little air and Save's band: what the reveal fits.
      final fits = note.bottom + 8 + (keyboardTop - save.top) -
              (tester.getRect(field).top - 12) <=
          keyboardTop - top;
      if (haveIphoneFonts) expect(fits, isTrue);
      if (!fits) return;
      expect(tester.getRect(reply).bottom, lessThanOrEqualTo(save.top + 0.5),
          reason: "the reply's end is under Save, or the keyboard");
    });
  }

  // An answer lands in view at every text size. At AX5 the header, the
  // tall field and its footer filled the screen, the header went to the
  // top, and the card or the reply landed below the fold (iPhone check,
  // 2026-11-24). Where the header down to the answer fits above Save, the
  // header goes to the top (meal_note_editor_test pins that); where it
  // does not, the answer's own top does. Checked only for what holds with
  // either font: the answer's first lines show between the app bar and
  // Save.
  for (final (locale, scale) in [
    (const Locale('en'), 1.0),
    (const Locale('en'), 53 / 17), // AX5
    (const Locale('zh'), 53 / 17),
  ]) {
    testWidgets('${locale.languageCode} at ${scale.toStringAsFixed(2)}x on '
        '390 pt: the card, then a reply, land in view', (tester) async {
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
          reason: 'Six dumplings instead of eight.',
        )));
      await pumpApp(
        tester,
        MealEditorScreen(
            dao: dao,
            meal: dao.meals.first,
            settings: FakeSettings(),
            noteCorrector: executor),
        size: const Size(390, 844),
        locale: locale,
        scale: scale,
      );
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      // Typed, then sent as on the phone: with the keyboard's send key
      // (the field focused, its top revealed), or with the button
      // scrolled just into view, right above Save.
      Future<void> send(String note, {required bool sendKey}) async {
        final field = find.byKey(const Key('mealNoteField'));
        list.position.jumpTo(0);
        await tester.pump();
        while (field.evaluate().isEmpty) {
          expect(list.position.pixels, lessThan(list.position.maxScrollExtent));
          list.position.jumpTo(list.position.pixels + 200);
          await tester.pump();
        }
        await tester.enterText(field, note);
        await tester.pumpAndSettle();
        if (sendKey) {
          await tester.testTextInput.receiveAction(TextInputAction.send);
        } else {
          final button = find.byKey(const Key('mealNoteSend'));
          await Scrollable.ensureVisible(tester.element(button), alignment: 1);
          await tester.pumpAndSettle();
          final under = tester.getRect(button).bottom -
              tester.getRect(find.byKey(const Key('saveMealButton'))).top +
              8;
          list.position.jumpTo(list.position.pixels + under);
          await tester.pumpAndSettle();
          await tester.tap(button);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      void expectInView(Finder first, String what) {
        final top = tester.getRect(find.byType(AppBar)).bottom;
        final save =
            tester.getRect(find.byKey(const Key('saveMealButton'))).top;
        final r = tester.getRect(first);
        expect(r.top, greaterThanOrEqualTo(top - 0.5),
            reason: '$what starts above the screen');
        expect(r.bottom, lessThanOrEqualTo(save + 0.5),
            reason: '$what lands below the fold, or under Save');
      }

      await send('only six dumplings', sendKey: true);
      final card = find.byKey(const Key('mealNoteChanges'));
      expect(card, findsOneWidget, reason: 'the card landed below the fold');
      // The card's title, its first line.
      expectInView(
          find.descendant(of: card, matching: find.byType(Text)).first,
          "the card's title");

      executor.nextNoteOutcome = const MealNoteOutcome(
          reply: MealUnclear('Was the porridge sweetened?'));
      await send('the porridge', sendKey: false);
      expectInView(find.byKey(const Key('mealNoteReply')), 'the reply');
    });
  }

  // With no keyboard up, an iPhone with a home indicator floats Save 50 pt
  // over the screen's bottom, not 16 (the Scaffold adds the 34-pt inset).
  // The fit check counted 16, so an answer ending in those 34 pt sent the
  // header to the top and left the answer's last line under Save (iPhone
  // check at AX1, 2026-11-24). A first, tall run measures the section as
  // laid out and where Save floats; the second is sized so the header
  // down to the reply's end is 17 pt taller than what shows above Save.
  // The reply must then show whole between the app bar and Save, with
  // either font.
  for (final (locale, scale, note, question) in [
    (
      const Locale('zh'),
      28 / 17, // AX1
      '饺子只吃了一半，豆浆也只喝了半杯',
      '你说的是哪一种：猪肉饺子还是小米粥？如果是饺子，是只吃了一半，还是一半都不到呢？'
    ),
    (
      const Locale('en'),
      1.0,
      'only half the dumplings, and half a glass of soy milk',
      'Which one do you mean, the dumplings or the porridge? If the '
          'dumplings, was it half of them or fewer?'
    ),
  ]) {
    testWidgets('${locale.languageCode} at ${scale.toStringAsFixed(2)}x with '
        'a home indicator: a reply that would end under Save shows whole',
        (tester) async {
      const width = 402.0; // iPhone 17 Pro
      const insets = EdgeInsets.only(top: 62, bottom: 34);
      final reply = find.byKey(const Key('mealNoteReplyNote'));
      final save = find.byKey(const Key('saveMealButton'));
      Future<void> answer(double height) async {
        await tester.pumpWidget(const SizedBox());
        final dao = FakeDao()..seed(_mealWithNotes());
        final executor = FakeExecutor()
          ..nextNoteOutcome = MealNoteOutcome(reply: MealUnclear(question));
        await pumpApp(
          tester,
          MealEditorScreen(
              dao: dao,
              meal: dao.meals.first,
              settings: FakeSettings(),
              noteCorrector: executor),
          size: Size(width, height),
          locale: locale,
          scale: scale,
          padding: insets,
        );
        final list =
            tester.state<ScrollableState>(find.byType(Scrollable).first);
        final field = find.byKey(const Key('mealNoteField'));
        while (field.evaluate().isEmpty) {
          expect(list.position.pixels, lessThan(list.position.maxScrollExtent));
          list.position.jumpTo(list.position.pixels + 200);
          await tester.pump();
        }
        await tester.enterText(field, note);
        await tester.pumpAndSettle();
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(reply, findsOneWidget);
      }

      const tall = 3000.0;
      await answer(tall);
      final span = tester.getRect(reply).bottom -
          tester.getRect(find.byKey(const Key('mealNoteHeader'))).top;
      final saveHeight = tester.getRect(save).height;
      final lift = tall - tester.getRect(save).bottom;
      expect(lift, greaterThan(kFloatingActionButtonMargin + 30),
          reason: 'Save floats over the home indicator');
      final appBar = tester.getRect(find.byType(AppBar)).bottom;

      await answer(appBar + span - 17 + saveHeight + lift);
      final shown = tester.getRect(reply);
      expect(shown.top, greaterThanOrEqualTo(appBar - 0.5),
          reason: 'the reply starts above the screen');
      expect(shown.bottom, lessThanOrEqualTo(tester.getRect(save).top + 0.5),
          reason: 'the reply ends under Save');
    });
  }

  // A hardware keyboard: the note's field takes the focus with no keyboard
  // on screen, so Save stays 50 pt over the bottom of a phone with a home
  // indicator. The reveal counted 16, and Correct with AI sat under Save.
  testWidgets('en at 2.00x on 430 pt with a home indicator, the note '
      'focused with no keyboard on screen: the button shows clear of Save',
      (tester) async {
    const size = Size(430, 932);
    final dao = FakeDao()..seed(_mealWithNotes());
    await pumpApp(
      tester,
      MealEditorScreen(
          dao: dao,
          meal: dao.meals.first,
          settings: FakeSettings(),
          noteCorrector: FakeExecutor()),
      size: size,
      scale: 2.0,
      padding: const EdgeInsets.only(top: 59, bottom: 34),
    );
    final field = find.byKey(const Key('mealNoteField'));
    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    while (field.evaluate().isEmpty) {
      expect(list.position.pixels, lessThan(list.position.maxScrollExtent));
      list.position.jumpTo(list.position.pixels + 200);
      await tester.pump();
    }
    // Scrolled just far enough to see the field: at the bottom edge.
    await Scrollable.ensureVisible(tester.element(field), alignment: 1);
    await tester.pumpAndSettle();
    await tester.showKeyboard(field);
    await tester.pumpAndSettle();

    final top = tester.getRect(find.byType(AppBar)).bottom;
    final block = tester.getRect(field).top - 12;
    final send = tester.getRect(find.byKey(const Key('mealNoteSend')));
    final save = tester.getRect(find.byKey(const Key('saveMealButton')));
    final text = tester.getRect(
        find.descendant(of: field, matching: find.byType(EditableText)));
    expect(text.top, greaterThanOrEqualTo(top - 0.5),
        reason: "the note's text is under the app bar");
    // Where the field's top down to the button and past Save is taller
    // than the screen (the test font, without the iPhone fonts, wraps far
    // more), the note's text is what stays in view.
    final fits = send.bottom + 8 + (size.height - save.top) - block <=
        size.height - top;
    if (haveIphoneFonts) expect(fits, isTrue);
    if (!fits) return;
    expect(send.left < save.right && save.left < send.right, isTrue,
        reason: 'at 2x the button reaches under Save');
    expect(send.bottom, lessThanOrEqualTo(save.top + 0.5),
        reason: 'the Save button covers it');
  });

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

  RenderEditable editableAt(WidgetTester tester, String key) => tester
      .state<EditableTextState>(find.descendant(
          of: find.byKey(Key(key)), matching: find.byType(EditableText)))
      .renderEditable;

  testWidgets('at the default size the fields are one line, 8 pt apart, as '
      'before', (tester) async {
    final dao = FakeDao()
      ..seed(_mealWith(desc: 'Dumplings', name: 'Dumplings (8)'));
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(390, 4000),
    );
    // They wrap at every size, but a description or item name that fits
    // draws one line, so its field is as high as before; so does an empty
    // one (a new meal, an added row).
    void expectOneLine(String key) {
      final editable = editableAt(tester, key);
      expect(
        editable.size.height,
        moreOrLessEquals(editable.preferredLineHeight, epsilon: 0.01),
        reason: '$key "${editable.text?.toPlainText()}" is one line high',
      );
    }

    for (final key in ['editorDescription', 'itemName0']) {
      expectOneLine(key);
    }
    for (final key in ['editorDescription', 'itemName0']) {
      await tester.enterText(find.byKey(Key(key)), '');
      await tester.pump();
      expectOneLine(key);
    }
    expect(
      tester.getTopLeft(find.byKey(const Key('editorProtein'))).dy -
          tester.getBottomLeft(find.byKey(const Key('editorCalories'))).dy,
      8,
    );
  });

  // The AI ends each item name with the portion it assumed ('(~170 g)').
  // On one line that was what got cut: 'Caesar salad, croutons, parmesan
  // (~170 g' on a 6.9-inch iPhone at the default size, more on a 375-pt
  // one. The long ones wrap now, whole, and Return still finishes the
  // field: a text keyboard with Done, the text one paragraph.
  testWidgets('at the default size on 375 pt a long item name and '
      'description wrap, whole, and Return still finishes them',
      (tester) async {
    const name = 'Caesar salad, croutons, parmesan (~170 g)';
    const desc = 'Caesar salad with croutons and parmesan, and an iced tea';
    final dao = FakeDao()..seed(_mealWith(desc: desc, name: name));
    await pumpApp(
      tester,
      MealEditorScreen(dao: dao, meal: dao.meals.first),
      size: const Size(375, 4000),
    );
    for (final (key, text) in [('itemName0', name), ('editorDescription', desc)]) {
      final editable = editableAt(tester, key);
      expect(editable.text?.toPlainText(), text);
      expect(
        editable.size.height,
        greaterThan(editable.preferredLineHeight * 1.5),
        reason: '"$text" shows on more than one line',
      );
      // Every glyph, the closing ')' too, is inside the field.
      for (final box in editable.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: text.length))) {
        expect(box.right, lessThanOrEqualTo(editable.size.width + 0.5),
            reason: '"$text" runs past the field');
      }

      final field = find.byKey(Key(key));
      await tester.showKeyboard(field);
      final input = tester.testTextInput.setClientArgs!;
      expect((input['inputType'] as Map)['name'], 'TextInputType.text',
          reason: '$key asks for a one-line keyboard');
      expect(input['inputAction'], 'TextInputAction.done');
      final focus = tester
          .widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)))
          .focusNode;
      expect(focus.hasFocus, isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(focus.hasFocus, isFalse, reason: 'Return finished $key');
      expect(editable.text?.toPlainText(), text);
      // A newline that gets in anyway (a paste) is dropped.
      await tester.enterText(field, 'Caesar salad\n(~170 g)');
      await tester.pump();
      expect(editable.text?.toPlainText(), 'Caesar salad(~170 g)');
    }
  });
}
