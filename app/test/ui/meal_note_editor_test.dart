// Edit meal's "Correct with a note" (owner 2026-11-24): the note and the
// meal as the form shows it go to the AI as text; the answer FILLS the form
// with the changes listed, and nothing is written until Save — the
// editor's existing compare-and-set. The notes of the corrections the
// saved form still holds are kept with the meal (analysis.user_notes),
// shown under the note, removable, and sent again with a later note as
// already applied.
import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:math' show min;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/meal_correction.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'fakes.dart';

DateTime _clock() => DateTime(2026, 11, 24, 19, 5);

/// When a note is sent: the editor's clock, in UTC.
final _sentAt = _clock().toUtc().toIso8601String();

const _rice = {
  'name': 'Steamed rice (~200 g)',
  'estimated_calories': 260,
  'protein_g': 5,
  'carbs_g': 57,
  'fat_g': 0.5,
};
const _pork = {
  'name': 'Braised pork (~120 g)',
  'estimated_calories': 400,
  'protein_g': 27,
  'carbs_g': 13,
  'fat_g': 25.5,
  'brand': '',
  'published': false,
  'user': {
    'set': true,
    'at': '2026-11-20T12:00:00.000Z',
    'n': [400, 27, 13, 25.5],
    'qty': 1,
  },
};

Map<String, dynamic> _analysis({List<Object?>? notes}) => {
      'is_food': true,
      'meal_description': 'Braised pork with rice',
      'total_calories': 660,
      'total_protein_g': 32,
      'total_carbs_g': 70,
      'total_fat_g': 26,
      'food_items': [_rice, _pork],
      'capture': {'device': 'phone'},
      'estimate_confidence': 'medium',
      kUserNotesKey: ?notes,
    };

Meal _meal({List<Object?>? notes}) => Meal(
      id: 1,
      date: '2026-11-24',
      time: '12:30 PM',
      timestamp: '2026-11-24T12:30:00.000',
      source: MealSource.appPhoto,
      imageHash: 'h1',
      analysis: _analysis(notes: notes),
    );

/// [_meal] with eight foods: on a phone its note section lies far past what
/// the list builds from the form's top.
Meal _longMeal() => Meal(
      id: 1,
      date: '2026-11-24',
      time: '12:30 PM',
      timestamp: '2026-11-24T12:30:00.000',
      source: MealSource.appPhoto,
      imageHash: 'h1',
      analysis: {
        ..._analysis(),
        'food_items': [
          _rice,
          _pork,
          for (var i = 1; i <= 6; i++)
            {
              'name': 'Side dish $i',
              'estimated_calories': 50,
              'protein_g': 1,
              'carbs_g': 5,
              'fat_g': 2,
            },
        ],
      },
    );

MealNoteOutcome _corrected(MealCorrectionProposal p) =>
    MealNoteOutcome(reply: MealCorrected(p));

/// "only half the rice".
final _halfRice = _corrected(const MealCorrectionProposal(
  changed: {
    0: MealCorrectionItem(
        name: 'Steamed rice (~100 g)',
        calories: 130,
        protein: 2.5,
        carbs: 28.5,
        fat: 0.3),
  },
  reason: 'Halved the rice; the pork is as before.',
));

/// "I didn't eat the pork".
final _noPork = _corrected(const MealCorrectionProposal(
  removed: {1},
  reason: 'Removed the pork.',
));

/// "add a fried egg".
final _egg = _corrected(const MealCorrectionProposal(
  added: [
    MealCorrectionItem(
        name: 'Fried egg (1 large, ~50 g)',
        calories: 90,
        protein: 6.3,
        carbs: 0.4,
        fat: 7),
  ],
  reason: 'Added a fried egg.',
));

class _Rig {
  _Rig(this.dao, this.executor, this.settings);
  final FakeDao dao;
  final FakeExecutor executor;
  final FakeSettings settings;
  bool? popped;
}

Finder _key(String k) => find.byKey(Key(k));

Future<_Rig> _open(
  WidgetTester tester, {
  Meal? meal,
  FakeSettings? settings,
  FakeExecutor? executor,
  bool corrector = true,
  bool withSettings = true,
  bool newMeal = false,
  Locale? locale,
}) async {
  tester.view.physicalSize = const Size(1400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // A fresh tree: a route an earlier call pushed must not stay on top.
  await tester.pumpWidget(const SizedBox());
  final dao = FakeDao();
  if (!newMeal) dao.seed(meal ?? _meal());
  final rig = _Rig(dao, executor ?? FakeExecutor(),
      settings ?? FakeSettings(apiKey: 'k'));
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            rig.popped = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                    builder: (_) => MealEditorScreen(
                          dao: dao,
                          meal: newMeal ? null : dao.meals.first,
                          now: _clock,
                          settings: withSettings ? rig.settings : null,
                          noteCorrector: corrector ? rig.executor : null,
                        )));
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return rig;
}

Future<void> _type(WidgetTester tester, String note) async {
  await tester.enterText(_key('mealNoteField'), note);
  await tester.pump();
}

Future<void> _send(WidgetTester tester) async {
  await tester.tap(_key('mealNoteSend'));
  await tester.pumpAndSettle();
}

String _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(_key(key)).controller!.text;

bool _readOnly(WidgetTester tester, String key) =>
    tester.widget<TextField>(_key(key)).readOnly;

/// The Save button's fill as drawn.
Color? _saveColor(WidgetTester tester) => tester
    .widget<Material>(find
        .descendant(of: _key('saveMealButton'), matching: find.byType(Material))
        .first)
    .color;

Future<void> _save(WidgetTester tester) async {
  await tester.tap(_key('saveMealButton'));
  await tester.pumpAndSettle();
}

/// Scrolls the editor's form until [k] is built, then into view. Pumps
/// frames only: a request's spinner never settles.
Future<void> _reveal(WidgetTester tester, String k) async {
  final position = tester
      .state<ScrollableState>(find
          .descendant(
              of: find.byType(MealEditorScreen),
              matching: find.byType(Scrollable))
          .first)
      .position;
  if (_key(k).evaluate().isEmpty) {
    position.jumpTo(0);
    await tester.pump();
    while (_key(k).evaluate().isEmpty &&
        position.pixels < position.maxScrollExtent) {
      position.jumpTo(min(position.pixels + 200, position.maxScrollExtent));
      await tester.pump();
    }
  }
  await tester.ensureVisible(_key(k));
  await tester.pump();
}

/// A phone (by default 6.1-inch, 390 x 844 pt) at 3x, the note's field in
/// view.
Future<void> _onPhone(WidgetTester tester,
    {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpAndSettle();
  await _reveal(tester, 'mealNoteField');
}

bool _noteFocused(WidgetTester tester) =>
    tester.widget<TextField>(_key('mealNoteField')).focusNode!.hasFocus;

void main() {
  setUpAll(() => initializeDateFormatting('zh'));

  group('where it shows', () {
    testWidgets('a stored meal opened with the settings and a corrector',
        (tester) async {
      await _open(tester);
      expect(_key('mealNoteHeader'), findsOneWidget);
      expect(find.text('Correct with a note'), findsOneWidget);
      expect(_key('mealNoteField'), findsOneWidget);
      expect(find.text('Your note'), findsOneWidget);
      expect(
          find.text("Your note and this meal's description, foods, numbers "
              'and earlier notes go to Gemini. Nothing is saved until you '
              'tap Save.'),
          findsOneWidget);
      // Below every food and Add item: the description stays first.
      expect(tester.getTopLeft(_key('mealNoteHeader')).dy,
          greaterThan(tester.getTopLeft(_key('addItemRow')).dy));
    });

    testWidgets('never without a corrector or the settings, nor on a new meal',
        (tester) async {
      for (final (name, corrector, withSettings, newMeal) in [
        ('no corrector', false, true, false),
        ('no settings', true, false, false),
        ('a new meal', true, true, true),
      ]) {
        await _open(tester,
            corrector: corrector, withSettings: withSettings, newMeal: newMeal);
        expect(_key('mealNoteHeader'), findsNothing, reason: name);
        expect(_key('mealNoteField'), findsNothing, reason: name);
      }
    });
  });

  group('sending', () {
    testWidgets('Send waits for a note; it sends the form as shown, with '
        'unsaved typing, and nothing else', (tester) async {
      final rig = await _open(tester);
      expect(tester.widget<ButtonStyleButton>(_key('mealNoteSend')).onPressed,
          isNull);
      // Typing in the form first: what is sent is what the form shows.
      await tester.enterText(_key('itemCal1'), '380');
      await tester.pump();
      await _type(tester, '  only half   the rice ');
      expect(tester.widget<ButtonStyleButton>(_key('mealNoteSend')).onPressed,
          isNotNull);
      rig.executor.nextNoteOutcome =
          const MealNoteOutcome(reply: MealNoChange(''));
      await _send(tester);
      final (input, note) = rig.executor.correctedNotes.single;
      expect(note, 'only half the rice');
      expect(input.description, 'Braised pork with rice');
      expect([for (final i in input.items) [i.name, ...i.numbers]], [
        ['Steamed rice (~200 g)', 260, 5, 57, 0.5],
        ['Braised pork (~120 g)', 380, 27, 13, 25.5],
      ]);
      expect(input.totals.numbers, [640, 32, 70, 26]);
      expect(input.earlierNotes, isEmpty);
      expect(rig.dao.fieldUpdates, isEmpty);
    });

    testWidgets("the keyboard's send key sends", (tester) async {
      final rig = await _open(tester);
      await tester.showKeyboard(_key('mealNoteField'));
      await tester.enterText(_key('mealNoteField'), 'add a fried egg');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(rig.executor.correctedNotes.single.$2, 'add a fried egg');
    });

    testWidgets('a form Save would refuse shows its errors and sends nothing',
        (tester) async {
      final rig = await _open(tester);
      await tester.enterText(_key('itemCal0'), 'abc');
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(_key('editorErrors'), findsOneWidget);
      expect(rig.executor.correctedNotes, isEmpty);
    });

    testWidgets('what cannot be sent is said first, with no question and no '
        'model call', (tester) async {
      final rig = await _open(tester);
      rig.executor.noteRefusalText = '⏸️ Daily quota reached.';
      rig.settings.aiConsentVersions = {'gemini': 2}; // would be asked
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<Text>(_key('mealNoteReply')).data,
          '⏸️ Daily quota reached.');
      expect(rig.executor.correctedNotes, isEmpty);

      // The own server at an http:// address, or its key saved for
      // another address.
      rig.executor.noteRefusalText = null;
      rig.settings
        ..provider = 'server'
        ..serverBaseUrl = 'http://10.0.0.5'
        ..keysByProvider['server'] = 'upload';
      await _send(tester);
      expect(tester.widget<Text>(_key('mealNoteReply')).data,
          startsWith('❌ Your server address'));
      rig.settings
        ..serverBaseUrl = 'https://a.example'
        ..keySavedFor = 'b.example';
      await _send(tester);
      expect(tester.widget<Text>(_key('mealNoteReply')).data, startsWith('❌'));
      expect(tester.widget<Text>(_key('mealNoteReply')).data,
          isNot(contains('https://')));
      expect(find.byType(AlertDialog), findsNothing);
      expect(rig.executor.correctedNotes, isEmpty);
    });

    testWidgets('an older grant is asked at the note; Not now sends nothing '
        'and keeps the note', (tester) async {
      final rig = await _open(
          tester, settings: FakeSettings(apiKey: 'k')
            ..aiConsentVersions = {'gemini': 2});
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(_key('mealNoteConsentDialog'), findsOneWidget);
      await tester.tap(_key('mealNoteConsentNotNow'));
      await tester.pumpAndSettle();
      expect(rig.executor.correctedNotes, isEmpty);
      expect(find.text('Nothing was sent.'), findsOneWidget);
      expect(_field(tester, 'mealNoteField'), 'only half the rice');
      await _send(tester);
      await tester.tap(_key('mealNoteConsentAllow'));
      await tester.pumpAndSettle();
      expect(rig.executor.correctedNotes, hasLength(1));
      expect(rig.settings.aiConsentVersion('gemini'), 3);
    });
  });

  group('while the AI answers', () {
    testWidgets('the form is read-only, Save waits, the cards are busy, and '
        'Stop unlocks it; a late answer is dropped', (tester) async {
      final rig = await _open(tester);
      final gate = Completer<void>();
      rig.executor
        ..onCorrect = (() => gate.future)
        ..nextNoteOutcome = _halfRice;
      final saveColor = _saveColor(tester);
      await tester.showKeyboard(_key('mealNoteField'));
      await _type(tester, 'only half the rice');
      await tester.tap(_key('mealNoteSend'));
      await tester.pump();
      // Save waits, and looks it, as the other locked controls do.
      expect(_saveColor(tester), isNot(saveColor));
      expect(_key('mealNoteAsking'), findsOneWidget);
      expect(find.text('Asking Gemini…'), findsOneWidget);
      expect(_key('mealNoteSend'), findsNothing);
      for (final k in [
        'editorDescription',
        'editorCalories',
        'editorProtein',
        'itemName0',
        'itemCal0',
        'itemFat1',
        'mealNoteField',
      ]) {
        expect(_readOnly(tester, k), isTrue, reason: k);
      }
      for (final k in ['editorDateButton', 'editorTimeButton', 'addItemRow']) {
        expect(tester.widget<ButtonStyleButton>(_key(k)).onPressed, isNull,
            reason: k);
      }
      expect(tester.widget<IconButton>(_key('removeItem0')).onPressed, isNull);
      expect(
          tester
              .widget<FloatingActionButton>(_key('saveMealButton'))
              .onPressed,
          isNull);
      expect(tester.testTextInput.isVisible, isFalse,
          reason: 'the keyboard goes down');
      // Delete stays (it asks first).
      expect(tester.widget<IconButton>(_key('deleteMealButton')).onPressed,
          isNotNull);

      await tester.tap(_key('mealNoteStop'));
      await tester.pump();
      expect(_readOnly(tester, 'editorCalories'), isFalse);
      expect(_key('mealNoteSend'), findsOneWidget);
      expect(_saveColor(tester), saveColor);
      gate.complete();
      await tester.pumpAndSettle();
      expect(_field(tester, 'itemName0'), 'Steamed rice (~200 g)',
          reason: 'the late answer is dropped');
      expect(_key('mealNoteChanges'), findsNothing);
      expect(_field(tester, 'mealNoteField'), 'only half the rice');
      expect(rig.dao.fieldUpdates, isEmpty);
    });

    // iPhone check, 2026-11-24: the note field tapped once while the AI
    // answered, and as the answer landed the keyboard came up on the
    // emptied field, over the card, with Save floating over it (4/4).
    // A read-only field still took the focus, and the form unlocking let
    // it open the keyboard. Now the note's field takes no focus while the
    // AI answers, and a field of the form that did is let go as the answer
    // lands: nothing could be typed meanwhile.
    for (final (name, outcome, answer) in [
      ('a correction', _halfRice, 'mealNoteChanges'),
      (
        'a question',
        const MealNoteOutcome(reply: MealUnclear('Which rice?')),
        'mealNoteReplyNote'
      ),
      (
        'an error',
        const MealNoteOutcome(
            error: '❌ Error contacting AI. Please try again.'),
        'mealNoteReplyNote'
      ),
    ]) {
      testWidgets('$name lands with no keyboard over it, whatever field '
          'was tapped while the AI answered', (tester) async {
        for (final tapped in ['mealNoteField', 'itemCal1', 'editorDescription']) {
          final rig = await _open(tester);
          await _onPhone(tester);
          final gate = Completer<void>();
          rig.executor
            ..onCorrect = (() => gate.future)
            ..nextNoteOutcome = outcome;
          await _type(tester, 'only half the rice');
          await tester.tap(_key('mealNoteSend'));
          await tester.pump();
          expect(tester.testTextInput.isVisible, isFalse);
          await _reveal(tester, tapped);
          await tester.tap(_key(tapped));
          await tester.pump();
          expect(tester.testTextInput.isVisible, isFalse,
              reason: '$tapped is read-only');
          expect(_noteFocused(tester), isFalse,
              reason: 'the note field takes no focus while the AI answers');
          gate.complete();
          await tester.pumpAndSettle();

          // A field that asks for the keyboard gets it, as on the phone.
          final raised = tester.testTextInput.isVisible;
          if (raised) {
            tester.view.viewInsets = const FakeViewPadding(bottom: 336 * 3);
            await tester.pumpAndSettle();
          }
          final top = tester.getRect(find.byType(AppBar)).bottom;
          final bottom = min(tester.getRect(_key('saveMealButton')).top,
              844 - tester.view.viewInsets.bottom / 3);
          expect(_key(answer), findsOneWidget,
              reason: '$tapped: the list scrolled the answer far out of view');
          final landed = tester.getRect(_key(answer));
          expect(landed.top, greaterThanOrEqualTo(top - 0.5),
              reason: '$tapped: the answer starts above the screen');
          expect(landed.top + 40, lessThanOrEqualTo(bottom),
              reason: '$tapped: the answer is under the keyboard or Save');
          expect(raised, isFalse,
              reason: '$tapped: the keyboard came up as the answer landed');
          expect(_noteFocused(tester), isFalse, reason: tapped);

          // The note can still be typed: a tap now brings the keyboard.
          await _reveal(tester, 'mealNoteField');
          await tester.tap(_key('mealNoteField'));
          await tester.pump();
          expect(tester.testTextInput.isVisible, isTrue);
          expect(_noteFocused(tester), isTrue);
          tester.view.resetViewInsets();
        }
      }, variant: TargetPlatformVariant(
          const {TargetPlatform.iOS, TargetPlatform.android}));
    }

    testWidgets('Stop: a field tapped while the AI answered brings no '
        'keyboard up either', (tester) async {
      for (final tapped in ['mealNoteField', 'itemCal1']) {
        final rig = await _open(tester);
        await _onPhone(tester);
        final gate = Completer<void>();
        rig.executor
          ..onCorrect = (() => gate.future)
          ..nextNoteOutcome = _halfRice;
        await _type(tester, 'only half the rice');
        await tester.tap(_key('mealNoteSend'));
        await tester.pump();
        await _reveal(tester, tapped);
        await tester.tap(_key(tapped));
        await tester.pump();
        await _reveal(tester, 'mealNoteStop');
        await tester.tap(_key('mealNoteStop'));
        await tester.pump();
        await tester.pump();
        expect(tester.testTextInput.isVisible, isFalse, reason: tapped);
        expect(_noteFocused(tester), isFalse, reason: tapped);
        gate.complete();
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse, reason: tapped);
      }
    }, variant: TargetPlatformVariant(
        const {TargetPlatform.iOS, TargetPlatform.android}));

    testWidgets('Back asks, and Discard closes with nothing written',
        (tester) async {
      final rig = await _open(tester);
      final gate = Completer<void>();
      rig.executor
        ..onCorrect = (() => gate.future)
        ..nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await tester.tap(_key('mealNoteSend'));
      await tester.pump();
      // The spinner turns until the answer: pump, never settle.
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_key('discardChangesDialog'), findsOneWidget);
      await tester.tap(_key('discardChangesDiscard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('open'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
      expect(rig.dao.updates, isEmpty);
    });

    testWidgets('Delete still deletes (it asks first)', (tester) async {
      final rig = await _open(tester);
      final gate = Completer<void>();
      rig.executor
        ..onCorrect = (() => gate.future)
        ..nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await tester.tap(_key('mealNoteSend'));
      await tester.pump();
      await tester.tap(_key('deleteMealButton'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(_key('confirmDeleteMeal'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(rig.dao.deletedIds, [1]);
      expect(rig.popped, isTrue);
      gate.complete();
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
    });
  });

  group('the answer fills the form', () {
    testWidgets('the new numbers show with what changed; nothing is written '
        'until Save, which writes once through the compare-and-set',
        (tester) async {
      final rig = await _open(tester);
      final openRaw = rig.dao.rawOf(rig.dao.meals.first);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);

      expect(_field(tester, 'itemName0'), 'Steamed rice (~100 g)');
      expect(_field(tester, 'itemCal0'), '130');
      expect(_field(tester, 'itemPro0'), '2.5');
      expect(_field(tester, 'itemName1'), 'Braised pork (~120 g)');
      expect(_field(tester, 'editorCalories'), '530');
      expect(_field(tester, 'editorProtein'), '29.5');
      expect(_field(tester, 'editorCarbs'), '41.5');
      expect(_field(tester, 'editorFat'), '25.8');
      expect(_field(tester, 'mealNoteField'), '', reason: 'the note is used');
      expect(_key('mealNoteChanges'), findsOneWidget);
      for (final line in [
        'Changed from your note — not saved yet',
        'Your note: only half the rice',
        'Total: 660 → 530 kcal',
        'Protein: 32 → 29.5 g',
        'Carbs: 70 → 41.5 g',
        'Fat: 26 → 25.8 g',
        'Steamed rice (~200 g) → Steamed rice (~100 g): 260 → 130 kcal',
        '1 other food unchanged',
        '💬 Halved the rice; the pork is as before.',
        'Check the numbers above, then tap Save.',
      ]) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
      expect(rig.dao.fieldUpdates, isEmpty, reason: 'nothing written yet');

      await _save(tester);
      expect(rig.dao.compareMisses, 0);
      final (id, analysis, date, time) = rig.dao.fieldUpdates.single;
      expect(id, 1);
      expect((date, time), ('2026-11-24', '12:30 PM'));
      final items = analysis!['food_items'] as List;
      // The AI's row: its numbers, no usual-foods mark.
      expect(items[0], {
        'name': 'Steamed rice (~100 g)',
        'estimated_calories': 130,
        'protein_g': 2.5,
        'carbs_g': 28.5,
        'fat_g': 0.3,
      });
      // The row the note did not concern: every key as stored.
      expect(items[1], _pork);
      expect(analysis['total_calories'], 530);
      expect(analysis['capture'], {'device': 'phone'});
      expect(analysis['estimate_confidence'], 'medium');
      expect(analysis[kUserNotesKey], [
        {'text': 'only half the rice', 'at': _sentAt},
      ]);
      expect(rig.dao.meals.first.corrected, isTrue);
      expect(rig.popped, isTrue);
      expect(openRaw, isNot(rig.dao.rawOf(rig.dao.meals.first)));
    });

    testWidgets('on a phone, the answer brings the section to the top: the '
        'field, the button and the card show together', (tester) async {
      final rig = await _open(tester);
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      await tester.pumpAndSettle();
      rig.executor.nextNoteOutcome = _halfRice;
      await tester.scrollUntilVisible(_key('mealNoteField'), 200,
          scrollable: find
              .descendant(
                  of: find.byType(MealEditorScreen),
                  matching: find.byType(Scrollable))
              .first);
      await _type(tester, 'only half the rice');
      await _send(tester);
      final appBar = tester.getRect(find.byType(AppBar));
      final header = tester.getRect(_key('mealNoteHeader'));
      expect(header.top, greaterThanOrEqualTo(appBar.bottom));
      expect(header.top, lessThan(appBar.bottom + 40),
          reason: 'the section starts at the top of the form');
      final card = tester.getRect(_key('mealNoteChanges'));
      expect(card.top, lessThan(2400 / 2.75),
          reason: 'the card starts on screen');
      expect(rig.dao.fieldUpdates, isEmpty);
    });

    testWidgets('the form scrolled to its top while the AI answered: the '
        'answer is still brought into view', (tester) async {
      for (final (outcome, answer) in [
        (_halfRice, 'mealNoteChanges'),
        (
          const MealNoteOutcome(reply: MealUnclear('Which rice?')),
          'mealNoteReplyNote'
        ),
      ]) {
        final rig = await _open(tester, meal: _longMeal());
        await _onPhone(tester);
        final gate = Completer<void>();
        rig.executor
          ..onCorrect = (() => gate.future)
          ..nextNoteOutcome = outcome;
        await _type(tester, 'only half the rice');
        await tester.tap(_key('mealNoteSend'));
        await tester.pump();
        await _reveal(tester, 'editorDescription');
        expect(find.byKey(const Key('mealNoteHeader'), skipOffstage: false),
            findsNothing,
            reason: 'the note section is out of what the list built');
        gate.complete();
        await tester.pumpAndSettle();
        expect(_key(answer), findsOneWidget, reason: answer);
        final top = tester.getRect(find.byType(AppBar)).bottom;
        final landed = tester.getRect(_key(answer));
        expect(landed.top, greaterThanOrEqualTo(top - 0.5), reason: answer);
        expect(landed.top + 40,
            lessThanOrEqualTo(tester.getRect(_key('saveMealButton')).top),
            reason: answer);
      }
    });

    testWidgets('a number the user then changes on the AI row is theirs; '
        'the note is kept', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      await tester.enterText(_key('itemCal0'), '125');
      await tester.pump();
      await _save(tester);
      final analysis = rig.dao.fieldUpdates.single.$2!;
      final rice = (analysis['food_items'] as List)[0] as Map;
      expect(rice['estimated_calories'], 125);
      expect((rice['user'] as Map)['n'], [125, 2.5, 28.5, 0.3]);
      expect(analysis[kUserNotesKey], hasLength(1));
    });

    testWidgets('an added food, and a meal with only totals', (tester) async {
      var rig = await _open(tester);
      rig.executor.nextNoteOutcome = _egg;
      await _type(tester, 'add a fried egg');
      await _send(tester);
      expect(_field(tester, 'itemName2'), 'Fried egg (1 large, ~50 g)');
      expect(_field(tester, 'editorCalories'), '750');
      expect(find.text('Added Fried egg (1 large, ~50 g), 90 kcal'),
          findsOneWidget);
      expect(find.text('2 other foods unchanged'), findsOneWidget);

      rig = await _open(tester,
          meal: Meal(
              id: 1,
              date: '2026-11-24',
              time: '08:00 AM',
              timestamp: '2026-11-24T08:00:00.000',
              source: MealSource.appManual,
              analysis: const {
                'is_food': true,
                'meal_description': 'Coffee and a pastry',
                'total_calories': 420,
                'total_protein_g': 8,
                'total_carbs_g': 50,
                'total_fat_g': 20,
              }));
      rig.executor.nextNoteOutcome = _corrected(const MealCorrectionProposal(
        totals: MealCorrectionTotals(
            calories: 300, protein: 8, carbs: 35, fat: 14),
      ));
      await _type(tester, 'no pastry, just a small one');
      await _send(tester);
      expect(_field(tester, 'editorCalories'), '300');
      expect(_field(tester, 'editorCarbs'), '35');
      expect(find.text('Total: 420 → 300 kcal'), findsOneWidget);
      await _save(tester);
      final analysis = rig.dao.fieldUpdates.single.$2!;
      expect(analysis['total_calories'], 300);
      expect(analysis[kUserNotesKey], [
        {'text': 'no pastry, just a small one', 'at': _sentAt},
      ]);
    });
  });

  group('Undo', () {
    testWidgets('puts back the form and the note, unsent again: Save asks '
        'first, then keeps no note', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      await tester.tap(_key('mealNoteUndo'));
      await tester.pumpAndSettle();
      expect(_field(tester, 'itemName0'), 'Steamed rice (~200 g)');
      expect(_field(tester, 'itemCal0'), '260');
      expect(_field(tester, 'editorCalories'), '660');
      expect(_field(tester, 'mealNoteField'), 'only half the rice');
      expect(_key('mealNoteChanges'), findsNothing);
      // The note is back in the field with nothing of it in the form: a
      // save would drop it, so it asks.
      await _save(tester);
      expect(_key('mealNoteUnsentDialog'), findsOneWidget);
      await tester.tap(_key('mealNoteUnsentKeep'));
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
      expect(_field(tester, 'mealNoteField'), 'only half the rice');
      await _save(tester);
      await tester.tap(_key('mealNoteUnsentSave'));
      await tester.pumpAndSettle();
      final analysis = rig.dao.fieldUpdates.single.$2!;
      expect(analysis.containsKey(kUserNotesKey), isFalse);
      expect((analysis['food_items'] as List)[0], _rice);
    });

    testWidgets('goes once the form no longer shows what the note left',
        (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(_key('mealNoteUndo'), findsOneWidget);
      expect(
          tester.getSemantics(_key('mealNoteUndo')).label,
          contains('Undo the changes from your note'));
      await tester.enterText(_key('itemCal1'), '390');
      await tester.pump();
      expect(_key('mealNoteUndo'), findsNothing);
    });

    testWidgets('two notes stack: the second is sent with the first as '
        'already applied, and Undo steps back through both', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      rig.executor.nextNoteOutcome = _egg;
      await _type(tester, 'add a fried egg');
      await _send(tester);
      final (second, _) = rig.executor.correctedNotes[1];
      expect(second.earlierNotes, ['only half the rice']);
      expect(second.items[0].calories, 130, reason: 'the form as it is now');
      expect(_field(tester, 'editorCalories'), '620');

      await tester.tap(_key('mealNoteUndo'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('itemName2')), findsNothing,
          reason: 'no egg row');
      expect(_field(tester, 'editorCalories'), '530');
      expect(_field(tester, 'mealNoteField'), 'add a fried egg');
      await tester.tap(_key('mealNoteUndo'));
      await tester.pumpAndSettle();
      expect(_field(tester, 'editorCalories'), '660');
      expect(_field(tester, 'mealNoteField'), 'only half the rice');
    });

    testWidgets('keeps a note typed since: only an empty field gets the '
        'note back', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      await _type(tester, 'and no sauce');
      await tester.tap(_key('mealNoteUndo'));
      await tester.pumpAndSettle();
      expect(_field(tester, 'itemCal0'), '260', reason: 'the form is back');
      expect(_field(tester, 'mealNoteField'), 'and no sauce');
    });

    testWidgets('keeps a note typed since even once it was sent, whatever '
        'its answer', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      rig.executor.nextNoteOutcome =
          const MealNoteOutcome(reply: MealUnclear('Which sauce?'));
      await _type(tester, 'and no sauce');
      await _send(tester);
      await tester.tap(_key('mealNoteUndo'));
      await tester.pumpAndSettle();
      expect(_field(tester, 'itemCal0'), '260', reason: 'the form is back');
      expect(_field(tester, 'mealNoteField'), 'and no sauce');
    });

    testWidgets("the first note's row stays the AI's through a second note "
        'and an Undo: saved with no usual mark', (tester) async {
      Map<String, dynamic> riceRow(_Rig rig) =>
          (rig.dao.fieldUpdates.single.$2!['food_items'] as List)[0]
              as Map<String, dynamic>;
      var rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      rig.executor.nextNoteOutcome = _egg;
      await _type(tester, 'add a fried egg');
      await _send(tester);
      await _save(tester);
      expect(riceRow(rig)['estimated_calories'], 130);
      expect(riceRow(rig).containsKey('user'), isFalse);

      rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      rig.executor.nextNoteOutcome = _egg;
      await _type(tester, 'add a fried egg');
      await _send(tester);
      await tester.tap(_key('mealNoteUndo'));
      await tester.pumpAndSettle();
      // The egg's note is back in the field, unsent: Save asks first.
      await _save(tester);
      await tester.tap(_key('mealNoteUnsentSave'));
      await tester.pumpAndSettle();
      expect(riceRow(rig)['estimated_calories'], 130);
      expect(riceRow(rig).containsKey('user'), isFalse);
      expect(rig.dao.fieldUpdates.single.$2![kUserNotesKey], [
        {'text': 'only half the rice', 'at': _sentAt},
      ]);
    });
  });

  group('the notes kept with the meal', () {
    testWidgets('both notes are kept, oldest first', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      rig.executor.nextNoteOutcome = _egg;
      await _type(tester, 'add a fried egg');
      await _send(tester);
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2![kUserNotesKey], [
        {'text': 'only half the rice', 'at': _sentAt},
        {'text': 'add a fried egg', 'at': _sentAt},
      ]);
    });

    testWidgets('a correction undone in the form by hand is not kept',
        (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _egg;
      await _type(tester, 'add a fried egg');
      await _send(tester);
      await tester.tap(_key('removeItem2'));
      await tester.pumpAndSettle();
      await _save(tester);
      final analysis = rig.dao.fieldUpdates.single.$2!;
      expect(analysis['food_items'], [_rice, _pork]);
      expect(analysis.containsKey(kUserNotesKey), isFalse);
    });

    testWidgets('a note typed back to the old numbers is not kept',
        (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      await tester.enterText(_key('itemName0'), 'Steamed rice (~200 g)');
      for (final (k, v) in [
        ('itemCal0', '260'),
        ('itemPro0', '5'),
        ('itemCarb0', '57'),
        ('itemFat0', '0.50'),
      ]) {
        await tester.enterText(_key(k), v);
      }
      await tester.pump();
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2!.containsKey(kUserNotesKey),
          isFalse);
    });

    testWidgets('an answer that changed nothing is not kept', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome =
          const MealNoteOutcome(reply: MealUnclear('Which rice?'));
      await _type(tester, 'the rice');
      await _send(tester);
      await _save(tester); // the note was sent: no unsent question
      expect(_key('mealNoteUnsentDialog'), findsNothing);
      expect(rig.dao.fieldUpdates.single.$2!.containsKey(kUserNotesKey),
          isFalse);
    });

    final stored = [
      {'text': 'the pork was lean', 'at': '2026-11-20T12:00:00.000Z'},
      {'text': 'no sauce', 'at': '2026-11-21T08:00:00.000Z'},
    ];

    testWidgets('shown oldest first with their dates, and sent again as '
        'already applied', (tester) async {
      final rig = await _open(tester, meal: _meal(notes: stored));
      expect(_key('mealNoteSavedHeader'), findsOneWidget);
      expect(find.text('Notes on this meal'), findsOneWidget);
      expect(tester.widget<Text>(_key('mealNoteSavedText0')).data,
          'the pork was lean');
      expect(tester.widget<Text>(_key('mealNoteSavedText1')).data, 'no sauce');
      expect(find.text('Nov 20'), findsOneWidget);
      expect(find.text('Nov 21'), findsOneWidget);
      expect(
          tester.getTopLeft(_key('mealNoteSaved0')).dy,
          lessThan(tester.getTopLeft(_key('mealNoteSaved1')).dy));
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(rig.executor.correctedNotes.single.$1.earlierNotes,
          ['the pork was lean', 'no sauce']);
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2![kUserNotesKey], [
        ...stored,
        {'text': 'only half the rice', 'at': _sentAt},
      ]);
    });

    testWidgets('removing one is an unsaved change: Back asks, Discard keeps '
        'it, Save removes it, and it is not sent again', (tester) async {
      var rig = await _open(tester, meal: _meal(notes: stored));
      expect(
          tester.widget<IconButton>(_key('mealNoteRemove0')).tooltip,
          'Remove this note');
      await tester.tap(_key('mealNoteRemove0'));
      await tester.pumpAndSettle();
      expect(find.text('the pork was lean'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_key('discardChangesDialog'), findsOneWidget);
      await tester.tap(_key('discardChangesDiscard'));
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
      expect(rig.dao.meals.first.analysis[kUserNotesKey], stored);

      rig = await _open(tester, meal: _meal(notes: stored));
      await tester.tap(_key('mealNoteRemove0'));
      await tester.pumpAndSettle();
      rig.executor.nextNoteOutcome =
          const MealNoteOutcome(reply: MealNoChange('Already right.'));
      await _type(tester, 'the sauce was on the side');
      await _send(tester);
      expect(rig.executor.correctedNotes.single.$1.earlierNotes, ['no sauce']);
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2![kUserNotesKey], [stored[1]]);

      rig = await _open(tester, meal: _meal(notes: stored));
      await tester.tap(_key('mealNoteRemove0'));
      await tester.pumpAndSettle();
      await tester.tap(_key('mealNoteRemove1'));
      await tester.pumpAndSettle();
      expect(_key('mealNoteSavedHeader'), findsNothing);
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2!.containsKey(kUserNotesKey),
          isFalse);
    });

    testWidgets('a save that changes no note keeps them exactly as stored',
        (tester) async {
      final raw = [
        ...stored,
        {'odd': 'an entry from an import'},
      ];
      final rig = await _open(tester, meal: _meal(notes: raw));
      await tester.enterText(_key('editorDescription'), 'Pork and rice');
      await tester.pump();
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2![kUserNotesKey], raw);
    });

    testWidgets('a food the note removed is kept while it stays gone, and '
        'not once the user types it back', (tester) async {
      Future<void> removePork(_Rig rig) async {
        rig.executor.nextNoteOutcome = _noPork;
        await _type(tester, "I didn't eat the pork");
        await _send(tester);
        expect(_key('itemName1'), findsNothing);
        // Another number changed: Undo is no longer offered.
        await tester.enterText(_key('itemCal0'), '250');
        await tester.pump();
        expect(_key('mealNoteUndo'), findsNothing);
      }

      var rig = await _open(tester);
      await removePork(rig);
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2![kUserNotesKey], [
        {'text': "I didn't eat the pork", 'at': _sentAt},
      ]);

      rig = await _open(tester);
      await removePork(rig);
      await tester.tap(_key('addItemRow'));
      await tester.pumpAndSettle();
      for (final (k, v) in [
        ('itemName1', 'Braised pork (~120 g)'),
        ('itemCal1', '400'),
        ('itemPro1', '27'),
        ('itemCarb1', '13'),
        ('itemFat1', '25.5'),
      ]) {
        await tester.enterText(_key(k), v);
      }
      await tester.pump();
      await _save(tester);
      final analysis = rig.dao.fieldUpdates.single.$2!;
      expect([for (final i in analysis['food_items'] as List) i['name']],
          ['Steamed rice (~200 g)', 'Braised pork (~120 g)']);
      expect(analysis.containsKey(kUserNotesKey), isFalse);
    });

    testWidgets('a correction undone by hand is not sent again as applied',
        (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _egg;
      await _type(tester, 'add a fried egg');
      await _send(tester);
      await tester.tap(_key('removeItem2'));
      await tester.pumpAndSettle();
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(rig.executor.correctedNotes.last.$1.earlierNotes, isEmpty);
    });

    testWidgets('removed, a note is gone from the whole meal: a copy an '
        "earlier build kept in a leftover deduction's snapshot goes too",
        (tester) async {
      final withCopy = Meal(
        id: 1,
        date: '2026-11-24',
        time: '12:30 PM',
        timestamp: '2026-11-24T12:30:00.000',
        source: MealSource.appPhoto,
        imageHash: 'h1',
        analysis: {
          ..._analysis(notes: stored),
          'leftover': {
            'applied_total': 660,
            'leftover_photo_md5': 'f00d',
            'original': {..._analysis(notes: stored), 'total_calories': 990},
          },
        },
      );
      final rig = await _open(tester, meal: withCopy);
      await tester.tap(_key('mealNoteRemove0'));
      await tester.pumpAndSettle();
      await tester.tap(_key('mealNoteRemove1'));
      await tester.pumpAndSettle();
      await _save(tester);
      final saved = rig.dao.fieldUpdates.single.$2!;
      for (final n in stored) {
        expect(jsonEncode(saved), isNot(contains(n['text'])));
      }
      final block = saved['leftover'] as Map;
      expect(block['applied_total'], 660);
      expect((block['original'] as Map)['total_calories'], 990);
    });
  });

  group('a meal that changed meanwhile', () {
    testWidgets('during the request: said, the newer meal shown, the note '
        'kept', (tester) async {
      final rig = await _open(tester);
      rig.executor
        ..nextNoteOutcome = _halfRice
        ..onCorrect = () async {
          final m = rig.dao.meals.first;
          rig.dao.meals[0] = Meal(
              id: m.id,
              date: m.date,
              time: m.time,
              timestamp: m.timestamp,
              source: m.source,
              imageHash: m.imageHash,
              analysis: {...m.analysis, 'total_calories': 600},
              corrected: true);
        };
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(_key('mealNoteConflict'), findsOneWidget);
      expect(find.text('This meal was just updated — please review.'),
          findsOneWidget);
      expect(_field(tester, 'editorCalories'), '600');
      expect(_field(tester, 'itemName0'), 'Steamed rice (~200 g)');
      expect(_key('mealNoteChanges'), findsNothing);
      expect(_field(tester, 'mealNoteField'), 'only half the rice');
      expect(rig.dao.fieldUpdates, isEmpty);
      // The newer meal holds nothing of the note: Save asks first.
      await _save(tester);
      expect(_key('mealNoteUnsentDialog'), findsOneWidget);
      await tester.tap(_key('mealNoteUnsentKeep'));
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
    });

    testWidgets('after the fill: Save says so, reloads and puts the note '
        'back', (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      final m = rig.dao.meals.first;
      rig.dao.meals[0] = Meal(
          id: m.id,
          date: m.date,
          time: m.time,
          timestamp: m.timestamp,
          source: m.source,
          imageHash: m.imageHash,
          analysis: {...m.analysis, 'total_calories': 600},
          corrected: true);
      await _save(tester);
      expect(_key('editorSaveConflict'), findsOneWidget);
      await tester.tap(_key('editorSaveConflictOk'));
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
      expect(_field(tester, 'editorCalories'), '600');
      expect(_field(tester, 'mealNoteField'), 'only half the rice');
      expect(_key('mealNoteChanges'), findsNothing);
      // The note is back in the field, its correction gone with the older
      // form: Save asks before it writes the newer meal without it.
      await _save(tester);
      expect(_key('mealNoteUnsentDialog'), findsOneWidget);
      await tester.tap(_key('mealNoteUnsentKeep'));
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
    });

    testWidgets('after a reload, the notes listed and kept are the newer '
        "meal's", (tester) async {
      final rig = await _open(tester, meal: _meal(notes: [
        {'text': 'the pork was lean', 'at': '2026-11-20T12:00:00.000Z'},
        {'text': 'no sauce', 'at': '2026-11-21T08:00:00.000Z'},
      ]));
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      // Meanwhile the meal was saved elsewhere with other notes.
      const newer = {'text': 'a small bowl', 'at': '2026-11-24T18:00:00.000Z'};
      final m = rig.dao.meals.first;
      rig.dao.meals[0] = Meal(
          id: m.id,
          date: m.date,
          time: m.time,
          timestamp: m.timestamp,
          source: m.source,
          imageHash: m.imageHash,
          analysis: {
            ...m.analysis,
            'total_calories': 600,
            kUserNotesKey: [newer],
          },
          corrected: true);
      await _save(tester);
      await tester.tap(_key('editorSaveConflictOk'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_key('mealNoteSavedText0')).data,
          'a small bowl');
      expect(_key('mealNoteSaved1'), findsNothing);
      // The note again, about the newer meal: Save keeps the newer
      // meal's notes and adds it.
      rig.executor.nextNoteOutcome = _halfRice;
      await _send(tester);
      expect(rig.executor.correctedNotes.last.$1.earlierNotes,
          ['a small bowl']);
      await _save(tester);
      expect(rig.dao.fieldUpdates.single.$2![kUserNotesKey], [
        newer,
        {'text': 'only half the rice', 'at': _sentAt},
      ]);
    });
  });

  group('answers that change nothing', () {
    for (final (name, outcome, text) in [
      (
        'unclear',
        const MealNoteOutcome(reply: MealUnclear('Which drink?')),
        'Nothing changed yet. The AI asks: Which drink?'
      ),
      (
        'no change',
        const MealNoteOutcome(reply: MealNoChange('That is about lunch.')),
        'Nothing changed. The AI says: That is about lunch.'
      ),
      (
        'no change, no sentence',
        const MealNoteOutcome(reply: MealNoChange('')),
        'The AI found nothing to change in this meal.'
      ),
      (
        'unusable',
        const MealNoteOutcome(reply: MealReplyUnusable()),
        "❌ The AI's answer could not be used, so nothing changed. Try "
            'saying it another way.'
      ),
      (
        'empties the meal',
        const MealNoteOutcome(reply: MealReplyUnusable(emptiesMeal: true)),
        "❌ The AI's answer would leave this meal empty, so nothing changed. "
            'To remove the meal, use Delete meal.'
      ),
      (
        'an error',
        const MealNoteOutcome(error: '❌ Error contacting AI. Please try again.'),
        '❌ Error contacting AI. Please try again.'
      ),
    ]) {
      testWidgets(name, (tester) async {
        final rig = await _open(tester);
        rig.executor.nextNoteOutcome = outcome;
        await _type(tester, 'the drink');
        await _send(tester);
        expect(tester.widget<Text>(_key('mealNoteReply')).data, text);
        expect(_field(tester, 'editorCalories'), '660');
        expect(_field(tester, 'mealNoteField'), 'the drink');
        expect(_key('mealNoteChanges'), findsNothing);
        expect(rig.dao.fieldUpdates, isEmpty);
      });
    }
  });

  group('Save with a note never sent', () {
    testWidgets('asks first: Keep editing writes nothing; Save anyway saves '
        'without the note', (tester) async {
      final rig = await _open(tester);
      await _type(tester, 'only half the rice');
      await _save(tester);
      expect(_key('mealNoteUnsentDialog'), findsOneWidget);
      expect(find.text("Your note wasn't sent"), findsOneWidget);
      await tester.tap(_key('mealNoteUnsentKeep'));
      await tester.pumpAndSettle();
      expect(rig.dao.fieldUpdates, isEmpty);
      expect(rig.executor.correctedNotes, isEmpty);
      await _save(tester);
      await tester.tap(_key('mealNoteUnsentSave'));
      await tester.pumpAndSettle();
      expect(rig.executor.correctedNotes, isEmpty, reason: 'never sent');
      final analysis = rig.dao.fieldUpdates.single.$2!;
      expect(analysis.containsKey(kUserNotesKey), isFalse);
    });

    // iPhone check, 2026-11-24: send, then Stop (or Undo the result), then
    // Save: the editor closed and the note was gone, with no question. The
    // note counted as sent from before its request, and nothing that left
    // the form without its correction took it back out.
    testWidgets('a note stopped, failed or unusable stays in the field, '
        'and Save asks before it drops it', (tester) async {
      for (final (name, outcome) in [
        ('stopped', null),
        (
          'an error',
          const MealNoteOutcome(
              error: '❌ Error contacting AI. Please try again.')
        ),
        ('unusable', const MealNoteOutcome(reply: MealReplyUnusable())),
        (
          'it would empty the meal',
          const MealNoteOutcome(reply: MealReplyUnusable(emptiesMeal: true))
        ),
      ]) {
        final rig = await _open(tester);
        final gate = Completer<void>();
        rig.executor
          ..onCorrect = (() => gate.future)
          // Stopped: an answer that would have dealt with it comes late,
          // and is dropped.
          ..nextNoteOutcome = outcome ??
              const MealNoteOutcome(reply: MealNoChange('Already right.'));
        await _type(tester, 'only half the rice');
        await tester.tap(_key('mealNoteSend'));
        await tester.pump();
        if (outcome == null) {
          await tester.tap(_key('mealNoteStop'));
          await tester.pump();
        }
        gate.complete();
        await tester.pumpAndSettle();
        expect(_field(tester, 'mealNoteField'), 'only half the rice',
            reason: name);
        await _save(tester);
        expect(_key('mealNoteUnsentDialog'), findsOneWidget, reason: name);
        await tester.tap(_key('mealNoteUnsentKeep'));
        await tester.pumpAndSettle();
        expect(rig.dao.fieldUpdates, isEmpty, reason: name);
        expect(_field(tester, 'mealNoteField'), 'only half the rice',
            reason: name);
      }
    });

    testWidgets('a note the AI answered with no change or a question was '
        'dealt with: Save does not ask, and keeps no note; sent again and '
        'stopped, it asks', (tester) async {
      for (final outcome in [
        const MealNoteOutcome(reply: MealNoChange('That is about lunch.')),
        const MealNoteOutcome(reply: MealUnclear('Which rice?')),
      ]) {
        var rig = await _open(tester);
        rig.executor.nextNoteOutcome = outcome;
        await _type(tester, 'the rice');
        await _send(tester);
        await _save(tester);
        expect(_key('mealNoteUnsentDialog'), findsNothing);
        expect(rig.dao.fieldUpdates.single.$2!.containsKey(kUserNotesKey),
            isFalse);

        // Its last send is what counts.
        rig = await _open(tester);
        rig.executor.nextNoteOutcome = outcome;
        await _type(tester, 'the rice');
        await _send(tester);
        final gate = Completer<void>();
        rig.executor.onCorrect = () => gate.future;
        await tester.tap(_key('mealNoteSend'));
        await tester.pump();
        await tester.tap(_key('mealNoteStop'));
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        await _save(tester);
        expect(_key('mealNoteUnsentDialog'), findsOneWidget);
      }
    });

    testWidgets('a filled correction makes Back ask; Discard writes nothing',
        (tester) async {
      final rig = await _open(tester);
      rig.executor.nextNoteOutcome = _halfRice;
      await _type(tester, 'only half the rice');
      await _send(tester);
      expect(_field(tester, 'mealNoteField'), '');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_key('discardChangesDialog'), findsOneWidget);
      await tester.tap(_key('discardChangesDiscard'));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(rig.dao.fieldUpdates, isEmpty);
      expect(rig.dao.meals.first.analysis, _analysis());
    });

    testWidgets('a typed note alone makes Back ask', (tester) async {
      await _open(tester);
      await _type(tester, 'only half the rice');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_key('discardChangesDialog'), findsOneWidget);
    });
  });

  testWidgets('Chinese', (tester) async {
    final rig = await _open(tester, locale: const Locale('zh'));
    expect(find.text('用一句话修正'), findsOneWidget);
    expect(find.text('你的说明'), findsOneWidget);
    await tester.showKeyboard(_key('mealNoteField')); // the hint shows
    await tester.pump();
    expect(find.text('哪里不一样？例如：「米饭只吃了一半」或「加一个煎蛋」'), findsOneWidget);
    expect(find.text('让 AI 修正'), findsOneWidget);
    rig.executor.nextNoteOutcome = _halfRice;
    await _type(tester, '米饭只吃了一半');
    await _send(tester);
    expect(find.text('已按你的说明修改，尚未保存'), findsOneWidget);
    expect(find.text('你的说明：米饭只吃了一半'), findsOneWidget);
    expect(find.text('合计：660 → 530 千卡'), findsOneWidget);
    expect(find.text('请核对上面的数字，然后点「保存」。'), findsOneWidget);
  });
}
