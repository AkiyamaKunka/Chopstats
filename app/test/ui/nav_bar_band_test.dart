// QA KAA-1 (PR #75 device QA, 2026-11-20): with 3-button navigation on
// Android 15 and 16, Edit meal at its first scroll still had its last item
// under the buttons. Android's contrast scrim (the tab bar's colour at
// 80%, system_nav_bar_test.dart) dimmed the field, but its text showed
// through: about 1.6:1 against the bar in light, 1.9:1 in dark. The app
// now paints the bar's height in the scrim's colour itself, opaque, above
// its navigator (NavBarBand, app.dart _SystemNavBarStyle), so nothing of a
// screen shows under the buttons; each scroll still ends past the bar
// (scroll_end_inset_test.dart). The gesture bar gets no band: the screens
// stay edge to edge under it. The band takes the colour Android is given,
// dimmed with it under a dialog or the analyzing overlay, which reach
// neither.

import 'dart:ui' as ui;

import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart' show AppColors;
import 'package:calorie_tracker/ui/widgets/nav_bar_band.dart';
import 'package:calorie_tracker/ui/widgets/states.dart' show AnalyzingOverlay;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The QA phones: 1080x2400 at 2.625 (411 x 914 dp).
const _physical = Size(1080, 2400);
const _ratio = 2.625;
const _height = 2400 / _ratio;

/// The emulators' insets in physical pixels (`dumpsys window`, API 35 and
/// 36). 3-button: a 126 px bar (48 dp), no side gestures, the bar's own
/// gesture area. Gesture: a 63 px bar (24 dp), 78 px back-gesture edges
/// on both sides (about 30 dp), an 84 px bottom gesture area.
const _threeButtonBar = 126.0;
const _gestureBar = 63.0;

enum _Nav { threeButton, gesture, none }

void _phone(WidgetTester tester, _Nav nav) {
  tester.view.physicalSize = _physical;
  tester.view.devicePixelRatio = _ratio;
  switch (nav) {
    case _Nav.threeButton:
      tester.view.padding = const FakeViewPadding(bottom: _threeButtonBar);
      tester.view.viewPadding = const FakeViewPadding(bottom: _threeButtonBar);
      tester.view.systemGestureInsets =
          const FakeViewPadding(bottom: _threeButtonBar);
    case _Nav.gesture:
      tester.view.padding = const FakeViewPadding(bottom: _gestureBar);
      tester.view.viewPadding = const FakeViewPadding(bottom: _gestureBar);
      tester.view.systemGestureInsets =
          const FakeViewPadding(left: 78, right: 78, bottom: 84);
    case _Nav.none:
      break;
  }
  addTearDown(tester.view.reset);
}

AppColors _colors(Brightness theme) =>
    theme == Brightness.dark ? AppColors.dark : AppColors.light;

Color _chrome(Brightness theme) => _colors(theme).chrome;

/// The tab bar's colour under a dialog's barrier (the theme's scrim).
Color _dimmed(Brightness theme) =>
    Color.alphaBlend(_colors(theme).scrim, _colors(theme).chrome);

Finder get _band => find.byType(NavBarBand);

const _screen = Key('screen');

String _today() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)}';
}

/// The app on [dao]'s meals, inside a boundary the screen is captured
/// from.
Future<void> _pumpApp(WidgetTester tester, {FakeDao? dao}) async {
  await tester.pumpWidget(RepaintBoundary(
    key: _screen,
    child: CalorieTrackerApp(
        services: makeServices(dao: dao, settings: FakeSettings())),
  ));
  await tester.pumpAndSettle();
}

/// One meal of six items on Today: at rest, Edit meal has items in the
/// bar's rows, as QA's four-item meal had on the phones.
FakeDao _mealOfSix() => FakeDao()
  ..seed(foodMeal(id: 1, date: _today(), items: [
    foodItem('Rice (~200 g)', 260),
    foodItem('Chicken (~120 g)', 200),
    foodItem('Broccoli (~80 g)', 30),
    foodItem('Sesame dressing (~15 g)', 66),
    foodItem('Miso soup (~200 ml)', 40),
    foodItem('Green tea (~300 ml)', 2),
  ]));

/// The screen as the phone shows it, in physical pixels: RGBA rows.
Future<({ByteData bytes, int width, int height})> _capture(
    WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_screen));
  final image =
      (await tester.runAsync(() => boundary.toImage(pixelRatio: _ratio)))!;
  final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
  final size = (width: image.width, height: image.height);
  image.dispose();
  return (bytes: bytes, width: size.width, height: size.height);
}

/// The pixels of rows [top] to [bottom] (physical) that are not [color].
int _offColour(({ByteData bytes, int width, int height}) shot, int top,
    int bottom, Color color) {
  final want = [
    (color.r * 255).round(),
    (color.g * 255).round(),
    (color.b * 255).round(),
    255,
  ];
  var off = 0;
  for (var y = top; y < bottom; y++) {
    for (var x = 0; x < shot.width; x++) {
      final i = (y * shot.width + x) * 4;
      for (var k = 0; k < 4; k++) {
        if (shot.bytes.getUint8(i + k) != want[k]) {
          off++;
          break;
        }
      }
    }
  }
  return off;
}

/// The colours handed to MainActivity (sendNavigationBarColor), in order.
List<int> _listenToSystemBars(WidgetTester tester) {
  const channel = MethodChannel(systemBarsChannelName);
  final sent = <int>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    sent.add((call.arguments as Map)['color'] as int);
    return true;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return sent;
}

/// Opens Edit meal for Today's meal, as QA did: a tap on its card.
Future<void> _openEditMeal(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('mealCardTitle')));
  await tester.pumpAndSettle();
  expect(find.byType(MealEditorScreen), findsOneWidget);
}

/// The editor's text that lies in the bar's rows at rest: what QA saw
/// through the scrim.
List<Rect> _textUnderBar(WidgetTester tester, double barTop) => [
      for (final e in find
          .descendant(
              of: find.byType(MealEditorScreen),
              matching: find.byWidgetPredicate(
                  (w) => w is RichText || w is EditableText))
          .evaluate())
        if (_box(e) case final r when r.bottom > barTop && r.top < _height) r,
    ];

Rect _box(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  group('threeButtonBarHeight', () {
    Future<double> heightFor(WidgetTester tester, MediaQueryData data) async {
      late double h;
      await tester.pumpWidget(MediaQuery(
        data: data,
        child: Builder(builder: (context) {
          h = threeButtonBarHeight(context);
          return const SizedBox.shrink();
        }),
      ));
      return h;
    }

    testWidgets('a 3-button bar: its height; gesture navigation or no bar: 0',
        (tester) async {
      expect(
          await heightFor(
              tester,
              const MediaQueryData(
                  viewPadding: EdgeInsets.only(bottom: 48),
                  padding: EdgeInsets.only(bottom: 48),
                  systemGestureInsets: EdgeInsets.only(bottom: 48))),
          48);
      // Gesture navigation: both side edges are the back gesture's.
      expect(
          await heightFor(
              tester,
              const MediaQueryData(
                  viewPadding: EdgeInsets.only(bottom: 24),
                  padding: EdgeInsets.only(bottom: 24),
                  systemGestureInsets:
                      EdgeInsets.only(left: 29.7, right: 29.7, bottom: 32))),
          0);
      // Below Android 15 the app does not draw under the bar: no inset.
      expect(await heightFor(tester, const MediaQueryData()), 0);
      // The keyboard up: the padding goes, the bar is still there (under
      // the keyboard), and the band stays put rather than flicker.
      expect(
          await heightFor(
              tester,
              const MediaQueryData(
                  viewPadding: EdgeInsets.only(bottom: 48),
                  viewInsets: EdgeInsets.only(bottom: 300),
                  systemGestureInsets: EdgeInsets.only(bottom: 48))),
          48);
    });
  });

  for (final theme in Brightness.values) {
    testWidgets('Android, 3-button bar, $theme: an opaque band in the tab '
        "bar's colour lies under the buttons, across the screen",
        (tester) async {
      _phone(tester, _Nav.threeButton);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = theme;
      await _pumpApp(tester);
      expect(tester.getRect(_band),
          Rect.fromLTRB(0, _height - 48, _physical.width / _ratio, _height));
      expect(_chrome(theme).a, 1.0, reason: 'opaque');
      expect(_band, paints..rect(color: _chrome(theme)));
    });
  }

  testWidgets('Android, 3-button bar: the band follows a light/dark switch '
      'while the app runs', (tester) async {
    _phone(tester, _Nav.threeButton);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await _pumpApp(tester);
    expect(_band, paints..rect(color: _chrome(Brightness.light)));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(_band, paints..rect(color: _chrome(Brightness.dark)));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(_band, paints..rect(color: _chrome(Brightness.light)));
  });

  testWidgets('Android, gesture bar: no band, the screens stay edge to edge',
      (tester) async {
    _phone(tester, _Nav.gesture);
    await _pumpApp(tester);
    expect(tester.getSize(_band).height, 0);
    expect(_band, paintsNothing);
  });

  testWidgets('Android below 15 (no bottom inset): no band', (tester) async {
    _phone(tester, _Nav.none);
    await _pumpApp(tester);
    expect(tester.getSize(_band).height, 0);
    expect(_band, paintsNothing);
  });

  testWidgets('iPhone: no band', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _phone(tester, _Nav.threeButton); // a home indicator's inset, say
    await _pumpApp(tester);
    expect(_band, findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android, 3-button bar: a touch in the band reaches the '
      'screen under it', (tester) async {
    _phone(tester, _Nav.threeButton);
    await _pumpApp(tester);
    var taps = 0;
    Navigator.of(tester.element(find.byType(HomeShell))).push(
        MaterialPageRoute<void>(
            builder: (_) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox.expand())));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(_physical.width / _ratio / 2, _height - 24));
    expect(taps, 1);
  });

  for (final theme in Brightness.values) {
    testWidgets('Android, 3-button bar, $theme: a dialog and the analyzing '
        'overlay dim the band with the app, and it is the colour Android '
        'gets', (tester) async {
      _phone(tester, _Nav.threeButton);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = theme;
      final sent = _listenToSystemBars(tester);
      await _pumpApp(tester);
      final shell = tester.element(find.byType(HomeShell));

      /// The band paints [color], the colour MainActivity got last.
      void expectBand(Color color, {String? reason}) {
        expect(_band, paints..rect(color: color), reason: reason);
        expect(sent.last, color.toARGB32(),
            reason: 'the band and Android\'s scrim take one colour');
      }

      expectBand(_chrome(theme));
      final closed = showDialog<void>(
          context: shell,
          builder: (_) => const AlertDialog(content: Text('Sure?')));
      await tester.pumpAndSettle();
      expectBand(_dimmed(theme), reason: 'the barrier is under the band');
      Navigator.of(tester.element(find.text('Sure?'))).pop();
      await tester.pumpAndSettle();
      await closed;
      expectBand(_chrome(theme));

      final analyzing = ValueNotifier<bool>(false);
      Navigator.of(shell).push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Add photo')),
                body: ValueListenableBuilder<bool>(
                  valueListenable: analyzing,
                  builder: (_, on, _) => Stack(children: [
                    const Center(child: Text('Grid')),
                    if (on)
                      const Positioned.fill(
                          child: AnalyzingOverlay(label: 'Analyzing…')),
                  ]),
                ),
              )));
      await tester.pumpAndSettle();
      expectBand(_chrome(theme), reason: 'a pushed screen is no barrier');
      analyzing.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expectBand(_dimmed(theme));
      analyzing.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expectBand(_chrome(theme));
    });
  }

  for (final theme in Brightness.values) {
    testWidgets('Android, 3-button bar, $theme: Edit meal at rest shows '
        'nothing under the buttons (KAA-1), and still scrolls its last item '
        'clear of them', (tester) async {
      _phone(tester, _Nav.threeButton);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = theme;
      await _pumpApp(tester, dao: _mealOfSix());
      await _openEditMeal(tester);
      const barTop = _height - 48;
      expect(_textUnderBar(tester, barTop), isNotEmpty,
          reason: 'at rest, item fields lie in the bar\'s rows: the case '
              'QA found');
      final shot = await _capture(tester);
      expect(shot.height, greaterThanOrEqualTo(2400));
      // The bar's rows, 2274 to 2400 (its edge rows left out): every pixel
      // is the band's colour, so no field, border or text shows under the
      // buttons.
      expect(_offColour(shot, 2275, 2399, _chrome(theme)), 0);
      // The rows just above it are the screen's own (its fields).
      expect(_offColour(shot, 2200, 2274, _chrome(theme)), greaterThan(0));

      // The end of the scroll: the last control ends above the band —
      // Correct with AI, the note's button, since the shell's executor
      // corrects a meal from a note (it was Add item before).
      final scroll = tester.state<ScrollableState>(find
          .descendant(
              of: find.byType(MealEditorScreen),
              matching: find.byType(Scrollable))
          .first);
      // The list estimates its end until it has laid out its last child
      // (the note's block, one child): jump until the end holds.
      for (var end = -1.0; end != scroll.position.maxScrollExtent;) {
        end = scroll.position.maxScrollExtent;
        scroll.position.jumpTo(end);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const Key('mealNoteSend')), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('mealNoteSend'))).bottom,
          lessThanOrEqualTo(barTop));
      expect(tester.getRect(find.byKey(const Key('addItemRow'))).bottom,
          lessThanOrEqualTo(barTop));
    });
  }

  testWidgets('Android, gesture bar: Edit meal at rest runs under the bar, '
      'edge to edge, with no band', (tester) async {
    _phone(tester, _Nav.gesture);
    await _pumpApp(tester, dao: _mealOfSix());
    await _openEditMeal(tester);
    const barTop = _height - 24;
    expect(_textUnderBar(tester, barTop), isNotEmpty);
    expect(tester.getSize(_band).height, 0);
    final shot = await _capture(tester);
    // The gesture bar's rows, 2337 to 2400, show the screen.
    expect(_offColour(shot, 2338, 2399, _chrome(Brightness.light)),
        greaterThan(0));
  });
}
