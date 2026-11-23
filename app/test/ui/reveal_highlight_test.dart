/// The ring a meal card gets when the user asked to see that meal
/// (widgets/reveal_highlight.dart): lit by a new trigger, gone after its
/// time, for its whole time and without a fade under Reduce Motion
/// (Android's Remove animations), invisible to taps, and said to a screen
/// reader once the card is on screen.
library;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:calorie_tracker/ui/widgets/reveal_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Object? trigger,
        {VoidCallback? onTap, String? announcement}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RevealHighlight(
            trigger: trigger,
            announcement: announcement,
            inset: const EdgeInsets.all(8),
            child: SizedBox(
              width: 200,
              height: 80,
              child: ElevatedButton(
                  onPressed: onTap, child: const Text('card')),
            ),
          ),
        ),
      ),
    );

/// The ring's painter (the RevealHighlight's own CustomPaint).
RenderObject _ringBox(WidgetTester tester) => tester.renderObject(find
    .descendant(
        of: find.byType(RevealHighlight), matching: find.byType(CustomPaint))
    .first);

RevealHighlightState _state(WidgetTester tester) =>
    tester.state<RevealHighlightState>(find.byType(RevealHighlight));

void main() {
  testWidgets('no trigger: nothing lit', (tester) async {
    await tester.pumpWidget(_host(null));
    expect(_state(tester).lit, isFalse);
  });

  testWidgets('a trigger lights it for its time, then it is gone',
      (tester) async {
    await tester.pumpWidget(_host(null));
    await tester.pumpWidget(_host(1));
    expect(_state(tester).lit, isTrue);
    await tester.pump(RevealHighlight.duration - const Duration(milliseconds: 100));
    expect(_state(tester).lit, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_state(tester).lit, isFalse);
    // The same trigger again lights nothing; a new one does.
    await tester.pumpWidget(_host(1));
    expect(_state(tester).lit, isFalse);
    await tester.pumpWidget(_host(2));
    expect(_state(tester).lit, isTrue);
    await tester.pumpAndSettle();
    expect(_state(tester).lit, isFalse);
  });

  testWidgets('a card first built with its trigger on lights as it comes',
      (tester) async {
    await tester.pumpWidget(_host(7));
    expect(_state(tester).lit, isTrue);
    await tester.pumpAndSettle();
    expect(_state(tester).lit, isFalse);
  });

  // Review of PR 80: Android's Remove animations sets the platform flag
  // MediaQuery reads, and also runs every normal AnimationController at
  // 0.05x its duration. The ring was gone after about 0.1 s. Set as the
  // phone sets it, not as a MediaQuery override alone, which leaves the
  // controllers' clock as it was.
  testWidgets('Reduce Motion (Remove animations): lit for the same time, '
      'with no fade', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_host(null));
    final context = tester.element(find.byType(RevealHighlight));
    expect(MediaQuery.disableAnimationsOf(context), isTrue);
    await tester.pumpWidget(_host(1));
    expect(_state(tester).lit, isTrue);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(_state(tester).lit, isTrue, reason: 'not cut to a twentieth');
    await tester.pump(RevealHighlight.duration -
        const Duration(milliseconds: 1100));
    expect(_state(tester).lit, isTrue);
    // At 1.9 s, painted at full strength: no fade.
    final accent = AppColors.of(context).accent;
    expect(
        _ringBox(tester),
        paints
          ..rrect()
          ..rrect(style: PaintingStyle.stroke, color: accent));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_state(tester).lit, isFalse);
    expect(_ringBox(tester), isNot(paints..rrect()));
  });

  test('the ring holds, then fades; with animations off it holds to the '
      'end, with no fade', () {
    for (final t in [0.0, 0.3, 0.6]) {
      expect(revealRingStrength(t, showing: true, still: false), 1);
    }
    final fading = [
      for (final t in [0.7, 0.8, 0.9, 0.99])
        revealRingStrength(t, showing: true, still: false),
    ];
    for (var i = 1; i < fading.length; i++) {
      expect(fading[i], lessThan(fading[i - 1]));
    }
    expect(fading.last, lessThan(0.1));
    for (final t in [0.0, 0.7, 0.99]) {
      expect(revealRingStrength(t, showing: true, still: true), 1);
    }
    expect(revealRingStrength(0.3, showing: false, still: false), 0);
    expect(revealRingStrength(0.3, showing: false, still: true), 0);
  });

  testWidgets('the card under it takes its taps, and keeps its one '
      'screen-reader node', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(_host(1, onTap: () => taps++));
    await tester.tap(find.text('card'));
    expect(taps, 1);
    final node = tester.getSemantics(find.text('card'));
    expect(node.label, 'card');
    expect(node.flagsCollection.isButton, isTrue);
    expect(find.byKey(const Key('revealAnnouncement')), findsNothing);
    await tester.pumpAndSettle();
    handle.dispose();
  });

  // Review of PR 80: the ring is only seen. A TalkBack user who pressed
  // View heard nothing name the meal, and lost their place with the
  // snackbar's button.
  testWidgets('an announcement is a live region that names the meal, takes '
      'no focus, and leaves the card its node and its taps', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(_host(1, onTap: () => taps++));
    final card = tester.element(find.text('card'));
    await tester.pumpWidget(_host(1,
        onTap: () => taps++, announcement: 'Ramen — ~600 kcal'));
    final said = tester.getSemantics(find.byKey(const Key('revealAnnouncement')));
    expect(said.label, 'Ramen — ~600 kcal');
    expect(said.flagsCollection.isLiveRegion, isTrue);
    expect(said.flagsCollection.isAccessibilityFocusBlocked, isTrue,
        reason: 'said, never landed on');
    // The card is the same card (its state kept), with its own node.
    expect(tester.element(find.text('card')), same(card));
    final node = tester.getSemantics(find.text('card'));
    expect(node.label, 'card');
    expect(node.flagsCollection.isButton, isTrue);
    await tester.tap(find.text('card'));
    expect(taps, 1);
    await tester.pumpWidget(_host(1, onTap: () => taps++));
    expect(find.byKey(const Key('revealAnnouncement')), findsNothing);
    await tester.pumpAndSettle();
    handle.dispose();
  });

  test('what is said: the meal and its calories, in the app language', () {
    final meal = Meal(
        id: 3,
        date: '2026-11-21',
        time: '12:30 PM',
        timestamp: '2026-11-21T12:30:00',
        source: 'app_photo',
        imageHash: '',
        analysis: {
          'is_food': true,
          'meal_description': 'Ramen',
          'total_calories': 1250,
        });
    expect(mealRevealLine(AppLocalizationsEn(), meal), 'Ramen — ~1,250 kcal');
    expect(mealRevealLine(AppLocalizationsZh(), meal), 'Ramen —— 约 1,250 千卡');
    final unnamed = Meal(
        id: 4,
        date: '2026-11-21',
        time: '12:30 PM',
        timestamp: '2026-11-21T12:30:00',
        source: 'manual',
        imageHash: '',
        analysis: {'is_food': true, 'total_calories': 300});
    expect(mealRevealLine(AppLocalizationsEn(), unnamed),
        '${AppLocalizationsEn().nlUnnamedMeal} — ~300 kcal');
  });
}
