/// The ring a meal card gets when the user asked to see that meal
/// (widgets/reveal_highlight.dart): lit by a new trigger, gone after its
/// time, without a fade under Reduce Motion, and invisible to taps and to
/// screen readers.
library;

import 'package:calorie_tracker/ui/widgets/reveal_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Object? trigger, {VoidCallback? onTap, bool still = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: still),
        child: Scaffold(
          body: Center(
            child: RevealHighlight(
              trigger: trigger,
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
      ),
    );

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

  testWidgets('Reduce Motion: lit for the same time, with no fade',
      (tester) async {
    await tester.pumpWidget(_host(null, still: true));
    await tester.pumpWidget(_host(1, still: true));
    expect(_state(tester).lit, isTrue);
    await tester.pump(RevealHighlight.duration - const Duration(milliseconds: 100));
    expect(_state(tester).lit, isTrue);
    await tester.pumpAndSettle();
    expect(_state(tester).lit, isFalse);
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
    await tester.pumpAndSettle();
    handle.dispose();
  });
}
