// Android push (ui lane, 2026-11-13): with 3-button navigation, switching
// the phone between light and dark while the app ran left a light bar
// under the dark app, and the reverse (UX run screenshots 57-59; a cold
// start was fine, 58). MainActivity handles uiMode itself, so the window
// kept its launch-time bar, and the app never set a navigation-bar style.
// The shell now styles the bar from the theme it shows (the tab bar's
// colour, buttons in its contrast); the status bar stays with the app
// bars. iPhone has no such bar and gets no style.
//
// Android 15 and later (QA 2026-11-20): the app draws edge to edge and
// Flutter's engine no longer sets the bar's colour. Android took the light
// launch window for a light bar and forced dark buttons, so a switch to
// dark with 3-button navigation left dark buttons on the dark bar on
// Android 16 (A36-1); and with the contrast scrim off, a screen with no tab
// bar showed its form under the buttons at rest (A36-2). The colour now
// also goes to MainActivity, which sets it on the window from Android 15
// (ending the forced buttons, and tinting the scrim), and the scrim is on:
// Android draws it behind the 3-button bar only.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart' show AppColors;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _transparent = Color(0x00000000);
const _systemBars = MethodChannel(systemBarsChannelName);

Finder _navBarRegion() => find.byWidgetPredicate((w) =>
    w is AnnotatedRegion<SystemUiOverlayStyle> &&
    w.value.systemNavigationBarIconBrightness != null);

Color _chrome(Brightness theme) =>
    (theme == Brightness.dark ? AppColors.dark : AppColors.light).chrome;

/// What the app told Android about its bars, in order: each overlay style
/// Flutter sent (`style:` and its buttons' brightness) and each colour
/// handed to MainActivity (`color:` and its ARGB in hex).
class _Bars {
  final List<String> calls = [];

  List<String> get colors =>
      [for (final c in calls) if (c.startsWith('color:')) c];

  static String color(Color c) =>
      'color:${c.toARGB32().toRadixString(16)}';

  void listen(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
        final style = (call.arguments as Map).cast<String, Object?>();
        calls.add('style:${style['systemNavigationBarIconBrightness']}');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_systemBars, (call) async {
      expect(call.method, 'navigationBarColor');
      final args = (call.arguments as Map).cast<String, Object?>();
      calls.add(color(Color(args['color'] as int)));
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(_systemBars, null);
    });
  }
}

void main() {
  void expectBarFor(Brightness theme) {
    final style = SystemChrome.latestStyle!;
    expect(style.systemNavigationBarIconBrightness,
        theme == Brightness.dark ? Brightness.light : Brightness.dark,
        reason: 'buttons readable on the $theme app');
    // The tab bar's own colour, opaque: below Android 15 the bar's own (the
    // app does not draw under it there, so a transparent one showed the
    // window colour fixed at launch under buttons that followed the new
    // theme, review 2026-11-13). Android 15+ takes it from MainActivity.
    final chrome = _chrome(theme);
    expect(style.systemNavigationBarColor, chrome);
    expect(style.systemNavigationBarColor!.a, 1.0, reason: 'opaque');
    expect(style.systemNavigationBarDividerColor, _transparent);
    // The contrast scrim: Android 15+ draws the colour at 80% behind the
    // 3-button bar (none behind the gesture bar), so no screen's content
    // sits under the buttons at rest. On the opaque bar below Android 15 it
    // changes nothing.
    expect(style.systemNavigationBarContrastEnforced, isTrue);
  }

  testWidgets('Android: the bar follows a light/dark switch while running',
      (tester) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    expectBarFor(Brightness.light);
    // The status bar is the app bar's: dark icons on the light page.
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.dark);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expectBarFor(Brightness.dark);
    expect(SystemChrome.latestStyle!.statusBarIconBrightness, Brightness.light);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expectBarFor(Brightness.light);
  });

  testWidgets('Android: the colour goes to MainActivity for each theme, once, '
      'after the style that sets the buttons', (tester) async {
    final bars = _Bars()..listen(tester);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    expect(bars.colors, [_Bars.color(_chrome(Brightness.light))],
        reason: 'the window gets the light bar colour at the first frame');

    // Frames with nothing new send nothing new: a tab switch, time.
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(bars.colors, hasLength(1));

    /// Each colour comes right after the style of its frame (the theme
    /// animates from one to the other, as Flutter's own style does), and
    /// the last is [theme]'s, after a style with [theme]'s buttons.
    void expectSwitchTo(Brightness theme) {
      final calls = bars.calls;
      expect(calls, isNotEmpty);
      expect(calls.last, _Bars.color(_chrome(theme)));
      for (var i = 0; i < calls.length; i++) {
        if (calls[i].startsWith('color:')) {
          expect(i, greaterThan(0));
          expect(calls[i - 1], startsWith('style:'),
              reason: 'a colour before its frame\'s style: $calls');
        }
      }
      expect(calls.lastWhere((c) => c.startsWith('style:')),
          theme == Brightness.dark
              ? 'style:Brightness.light'
              : 'style:Brightness.dark');
    }

    // A switch to dark while the app runs (A36-1): Flutter's style turns
    // the buttons light, then the dark colour ends Android's forced dark
    // buttons, in that order, so they are never dark on the dark bar.
    bars.calls.clear();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expectSwitchTo(Brightness.dark);
    final settled = bars.calls.length;
    await tester.pump(const Duration(seconds: 1));
    expect(bars.calls, hasLength(settled), reason: 'sent once settled');

    bars.calls.clear();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expectSwitchTo(Brightness.light);
  });

  testWidgets('Android: a screen pushed over the shell keeps the style',
      (tester) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(HomeShell));
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(appBar: AppBar(title: const Text('Sub')))));
    await tester.pumpAndSettle();
    expectBarFor(Brightness.dark);
  });

  testWidgets('Android: the startup-error screen styles it too',
      (tester) async {
    final bars = _Bars()..listen(tester);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpWidget(const StartupErrorApp(error: 'boom'));
    await tester.pumpAndSettle();
    expect(_navBarRegion(), findsOneWidget);
    expectBarFor(Brightness.dark);
    expect(bars.colors, [_Bars.color(_chrome(Brightness.dark))]);
  });

  testWidgets('iPhone: no navigation-bar style is set, nothing is sent',
      (tester) async {
    final bars = _Bars()..listen(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    expect(_navBarRegion(), findsNothing);
    await tester.pumpWidget(const StartupErrorApp(error: 'boom'));
    await tester.pumpAndSettle();
    expect(_navBarRegion(), findsNothing);
    expect(bars.colors, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  test('sendNavigationBarColor hands over the ARGB value, and never throws',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final sent = <Object?>[];
    messenger.setMockMethodCallHandler(_systemBars, (call) async {
      sent.add(call.arguments);
      return true;
    });
    await sendNavigationBarColor(AppColors.dark.chrome);
    expect(sent, [
      {'color': 0xFF161616},
    ]);
    // MainActivity missing (an old build) or failing: nothing escapes.
    messenger.setMockMethodCallHandler(_systemBars, null);
    await sendNavigationBarColor(AppColors.light.chrome);
    messenger.setMockMethodCallHandler(
        _systemBars, (call) async => throw PlatformException(code: 'boom'));
    await sendNavigationBarColor(AppColors.light.chrome);
    messenger.setMockMethodCallHandler(_systemBars, null);
  });

  // A36-2's other half: at the end of its scroll a screen with no tab bar
  // brings its last controls above a 3-button bar (48 dp on a 1080x2400
  // phone at 2.625), so nothing stays out of reach under the buttons.
  testWidgets('Android, 3-button bar: Edit meal scrolls Save and its last '
      'item above the bar', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    tester.view.padding = const FakeViewPadding(bottom: 126);
    tester.view.viewPadding = const FakeViewPadding(bottom: 126);
    addTearDown(tester.view.reset);
    final dao = FakeDao()
      ..seed(Meal(
        id: 1,
        date: '2026-11-20',
        time: '12:30 PM',
        timestamp: '2026-11-20T12:30:00.000',
        source: 'app_photo',
        imageHash: 'h1',
        analysis: {
          'is_food': true,
          'meal_description': 'Rice bowl',
          'total_calories': 650,
          'total_protein_g': 30,
          'total_carbs_g': 90,
          'total_fat_g': 15,
          'food_items': [
            for (var i = 0; i < 6; i++)
              {
                'name': 'Item $i',
                'estimated_calories': 100,
                'protein_g': 5,
                'carbs_g': 15,
                'fat_g': 2.5,
              },
          ],
        },
      ));
    await tester.pumpWidget(MaterialApp(
        home: MealEditorScreen(dao: dao, meal: dao.meals.first)));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -20000));
    await tester.pumpAndSettle();
    const height = 2400 / 2.625;
    const barTop = height - 126 / 2.625;
    for (final key in ['saveMealButton', 'addItemRow']) {
      final rect = tester.getRect(find.byKey(Key(key)));
      expect(rect.bottom, lessThanOrEqualTo(barTop), reason: key);
    }
  });
}
