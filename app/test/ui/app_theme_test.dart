/// The run-7 theme as screens actually get it: neutral dialogs and sheets
/// (they were seed-tinted pink, U9), floating snackbars, an accent FAB, no
/// surface tint anywhere, iOS type on the right font family, a pill-less
/// 56-pt tab bar that survives the largest text size, and accessors that
/// never throw in a bare MaterialApp.
library;

import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/theme/app_theme.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart' show GroupedPage;
import 'package:flutter/cupertino.dart'
    show CupertinoPageTransition, CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import '../support/back_gesture.dart';
import 'fakes.dart';

Color _materialColorIn(WidgetTester tester, Finder of) => tester
    .widget<Material>(
        find.descendant(of: of, matching: find.byType(Material)).first)
    .color!;

Widget _launcher(void Function(BuildContext) onPressed) => Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
              key: const Key('open'),
              onPressed: () => onPressed(context),
              child: const Text('open')),
        ),
      ),
    );

void main() {
  for (final (brightness, dialog, sheet, accent) in const [
    (Brightness.light, Color(0xFFFFFFFF), Color(0xFFF2F2F7), Color(0xFFA64B2A)),
    (Brightness.dark, Color(0xFF2C2C2E), Color(0xFF1C1C1E), Color(0xFFF2A07B)),
  ]) {
    group('$brightness', () {
      testWidgets('an AlertDialog is the neutral elevated surface',
          (tester) async {
        await pumpApp(
            tester,
            _launcher((c) => showDialog<void>(
                context: c,
                builder: (_) => const AlertDialog(
                    title: Text('Delete this meal?'),
                    content: Text('It cannot be undone.')))),
            brightness: brightness);
        await tester.tap(find.byKey(const Key('open')));
        await tester.pumpAndSettle();
        expect(_materialColorIn(tester, find.byType(Dialog)), dialog,
            reason: 'was #F7E4DF / #322825 (seed-tinted)');
        final title = tester.widget<RichText>(find.descendant(
            of: find.text('Delete this meal?'), matching: find.byType(RichText)));
        expect(title.text.style?.fontSize, 17,
            reason: 'iOS alert title, not M3 24-pt bold');
        expect(title.text.style?.fontWeight, FontWeight.w600);
        final body = tester.widget<RichText>(find.descendant(
            of: find.text('It cannot be undone.'),
            matching: find.byType(RichText)));
        expect(body.text.style?.color, AppColors.forBrightness(brightness).label,
            reason: 'dialog body text in the label colour');
      });

      testWidgets('a modal sheet is the neutral sheet surface with a handle',
          (tester) async {
        await pumpApp(
            tester,
            _launcher((c) => showModalBottomSheet<void>(
                context: c,
                builder: (_) => const SizedBox(height: 200, child: Text('x')))),
            brightness: brightness);
        await tester.tap(find.byKey(const Key('open')));
        await tester.pumpAndSettle();
        expect(_materialColorIn(tester, find.byType(BottomSheet)), sheet,
            reason: 'was #FFF1ED / #231917 (seed-tinted)');
        // The drag handle: a default for every sheet, not per call site.
        final handle = find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byWidgetPredicate((w) =>
                w is Container &&
                w.constraints?.maxWidth == 36 &&
                w.constraints?.maxHeight == 5));
        expect(handle, findsOneWidget);
      });

      testWidgets('the FAB is the accent capsule', (tester) async {
        await pumpApp(
            tester,
            Scaffold(
              floatingActionButton: FloatingActionButton.extended(
                  key: const Key('fab'),
                  onPressed: () {},
                  icon: const Icon(Icons.add),
                  label: const Text('Log')),
            ),
            brightness: brightness);
        final material = tester.widget<Material>(find
            .descendant(
                of: find.byKey(const Key('fab')),
                matching: find.byType(Material))
            .first);
        expect(material.color, accent, reason: 'was the pale seed container');
        expect(material.shape, isA<StadiumBorder>());
        expect(tester.getSize(find.byKey(const Key('fab'))).height,
            greaterThanOrEqualTo(50));
      });

      testWidgets('a snackbar floats on the inverse surface',
          (tester) async {
        await pumpApp(
            tester,
            _launcher((c) => ScaffoldMessenger.of(c)
                .showSnackBar(const SnackBar(content: Text('Saved')))),
            brightness: brightness);
        await tester.tap(find.byKey(const Key('open')));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find
            .descendant(
                of: find.byType(SnackBar), matching: find.byType(Material))
            .first);
        expect(rect.left, 16, reason: 'floating: inset from the edges');
        expect(rect.right, 390 - 16.0);
        expect(
            _materialColorIn(tester, find.byType(SnackBar)),
            AppColors.forBrightness(brightness).inverseSurface);
      });
    });
  }

  test('no surface tint anywhere, and no seed tone on any surface role', () {
    for (final b in Brightness.values) {
      for (final hc in [false, true]) {
        final t = AppTheme.build(b, highContrast: hc);
        final s = t.colorScheme;
        expect(s.surfaceTint, Colors.transparent);
        for (final tint in [
          t.appBarTheme.surfaceTintColor,
          t.cardTheme.surfaceTintColor,
          t.dialogTheme.surfaceTintColor,
          t.bottomSheetTheme.surfaceTintColor,
          t.navigationBarTheme.surfaceTintColor,
          t.popupMenuTheme.surfaceTintColor,
          t.datePickerTheme.surfaceTintColor,
          t.menuTheme.style?.surfaceTintColor?.resolve({}),
        ]) {
          expect(tint, Colors.transparent);
        }
        // Every surface and container role is an Apple neutral: equal
        // R, G and B within a hair (#F2F2F7 / #EEEEF0 carry a 5-step blue
        // lift, as Apple's own greys do).
        for (final role in [
          s.surface,
          s.surfaceDim,
          s.surfaceBright,
          s.surfaceContainerLowest,
          s.surfaceContainerLow,
          s.surfaceContainer,
          s.surfaceContainerHigh,
          s.surfaceContainerHighest,
          s.secondaryContainer,
          s.tertiaryContainer,
          t.scaffoldBackgroundColor,
          t.dialogTheme.backgroundColor!,
          t.bottomSheetTheme.backgroundColor!,
          t.navigationBarTheme.backgroundColor!,
        ]) {
          final r = (role.r * 255).round(),
              g = (role.g * 255).round(),
              bl = (role.b * 255).round();
          expect((r - g).abs() <= 6 && (bl - r).abs() <= 6, isTrue,
              reason: '$b hc=$hc: $role is tinted');
        }
      }
    }
  });

  test('cards sit flush in the gutter, clipped, flat', () {
    final t = AppTheme.build(Brightness.light);
    expect(t.cardTheme.margin, EdgeInsets.zero,
        reason: 'M3 default 4 put cards 4 pt inside the 16-pt gutter');
    expect(t.cardTheme.clipBehavior, Clip.antiAlias);
    expect(t.cardTheme.elevation, 0);
  });

  testWidgets('AppColors, AppTypography and AppNumerals fall back without '
      'the extensions (a bare MaterialApp)', (tester) async {
    for (final b in Brightness.values) {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: b),
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle(); // past AnimatedTheme's lerp
      expect(AppColors.of(ctx), same(AppColors.forBrightness(b)));
      expect(ctx.colors.page, AppColors.forBrightness(b).page);
      expect(ctx.type.title2.fontSize, 22);
      expect(ctx.type.muted(null).color,
          AppColors.forBrightness(b).secondaryLabel);
      expect(ctx.nums.hero.fontSize, 34);
      expect(ctx.nums.chip.fontFeatures,
          contains(const FontFeature.tabularFigures()));
    }
  });

  group('type scale', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('iOS: 17-pt titleLarge on the TEXT family, 34-pt on DISPLAY', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final text = AppTheme.build(Brightness.light).textTheme;
      expect(text.titleLarge?.fontFamily, 'CupertinoSystemText',
          reason: "Flutter's iOS typography puts titleLarge on Display");
      expect(text.bodyLarge?.fontFamily, 'CupertinoSystemText');
      expect(text.headlineMedium?.fontFamily, 'CupertinoSystemDisplay');
      expect(text.headlineSmall?.fontFamily, 'CupertinoSystemDisplay');
    });

    // The Latin roles: (style, size, line height, weight, Apple tracking).
    List<(TextStyle?, double, double, FontWeight, double)> latinRoles(
            ThemeData t) =>
        [
          (t.textTheme.headlineMedium, 34.0, 41.0, FontWeight.w700, 0.40),
          (t.textTheme.titleLarge, 17.0, 22.0, FontWeight.w600, -0.43),
          (t.textTheme.titleSmall, 15.0, 20.0, FontWeight.w600, -0.23),
          (t.textTheme.bodyLarge, 17.0, 22.0, FontWeight.w400, -0.43),
          (t.textTheme.bodyMedium, 15.0, 20.0, FontWeight.w400, -0.23),
          (t.textTheme.bodySmall, 13.0, 18.0, FontWeight.w400, -0.08),
          (t.textTheme.labelSmall, 12.0, 16.0, FontWeight.w500, 0.0),
          (t.extension<AppTypography>()!.title2, 22.0, 28.0, FontWeight.w700,
              0.35),
          (t.extension<AppTypography>()!.callout, 16.0, 21.0,
              FontWeight.w400, -0.31),
          (t.extension<AppNumerals>()!.hero, 34.0, 41.0, FontWeight.w700,
              0.40),
          (t.extension<AppNumerals>()!.value, 17.0, 22.0, FontWeight.w600,
              -0.43),
        ];

    test('iOS: Apple sizes, line heights and tracking (Latin)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      for (final (style, size, line, weight, tracking)
          in latinRoles(AppTheme.build(Brightness.light))) {
        expect(style?.fontSize, size);
        expect(style!.height! * size, closeTo(line, 0.001));
        expect(style.fontWeight, weight);
        expect(style.letterSpacing, tracking);
        expect(style.leadingDistribution, TextLeadingDistribution.even);
      }
    });

    // Owner decision 6 (2026-11-20): Apple's tracking table is for SF.
    // Android sets Roboto at its own spacing (letterSpacing 0); the sizes
    // and line heights stay the same on both.
    test('Android: the same sizes and line heights, Roboto at its own '
        'spacing (no tracking)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final b in Brightness.values) {
        for (final (style, size, line, weight, _)
            in latinRoles(AppTheme.build(b))) {
          expect(style?.fontSize, size);
          expect(style!.height! * size, closeTo(line, 0.001));
          expect(style.fontWeight, weight);
          expect(style.letterSpacing, 0, reason: '$b ${style.fontSize}');
          expect(style.leadingDistribution, TextLeadingDistribution.even);
        }
      }
      final t = AppTheme.build(Brightness.light, highContrast: true);
      expect(t.extension<AppNumerals>()!.chip.letterSpacing, 0);
      expect(t.extension<AppTypography>()!.caption2.letterSpacing, 0);
      expect(t.textTheme.titleMedium!.letterSpacing, 0);
    });

    // The iPhone layout harness (support/app_theme_harness.dart) measures
    // what the iPhone draws, SF with Apple's tracking, whatever platform
    // the test runs: flutter_test's default is Android, where the app sets
    // no tracking. The platform's behaviour stays the test's own.
    test("the iPhone layout harness keeps Apple's tracking on any test "
        'platform', () {
      for (final platform in [
        null, // flutter_test's default: Android
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        for (final b in Brightness.values) {
          final t = iphoneAppTheme(b);
          expect(t.platform, platform ?? TargetPlatform.android);
          for (final (style, _, _, _, tracking) in latinRoles(t)) {
            expect(style!.letterSpacing, tracking,
                reason: '$platform $b ${style.fontSize}');
          }
          expect(t.textTheme.headlineMedium!.letterSpacing, 0.40);
          expect(t.extension<AppNumerals>()!.hero.letterSpacing, 0.40);
          final zh = iphoneAppTheme(b, cjk: true);
          for (final s in [
            zh.textTheme.headlineMedium,
            zh.textTheme.titleLarge,
            zh.textTheme.bodyLarge,
            zh.extension<AppTypography>()!.title2,
            zh.extension<AppNumerals>()!.hero,
          ]) {
            expect(s!.letterSpacing, 0, reason: '$platform $b zh');
          }
        }
      }
    });

    test('Chinese takes no tracking anywhere', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final t = AppTheme.build(Brightness.light, cjk: true);
      final text = t.textTheme;
      for (final s in [
        text.headlineMedium,
        text.titleLarge,
        text.titleMedium,
        text.bodyLarge,
        text.bodyMedium,
        text.bodySmall,
        t.extension<AppTypography>()!.title2,
        t.extension<AppNumerals>()!.hero,
      ]) {
        expect(s?.letterSpacing, 0);
      }
    });

    test('the theme never sets appBarTheme.titleTextStyle (it would shrink '
        'every expanded large title to 17 pt)', () {
      expect(AppTheme.build(Brightness.light).appBarTheme.titleTextStyle,
          isNull);
    });
  });

  group('press feedback', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('iOS: no ripple; plain buttons dim to 40% while pressed', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final t = AppTheme.build(Brightness.light);
      expect(t.splashFactory, NoSplash.splashFactory);
      // A translucent wash that lands on the highlight token over a cell,
      // and only dims a coloured surface (the FAB) instead of covering it.
      for (final (b, c) in [
        (Brightness.light, AppColors.light),
        (Brightness.dark, AppColors.dark),
      ]) {
        final h = AppTheme.build(b).highlightColor;
        expect(h.a, lessThan(0.25));
        final over = Color.alphaBlend(h, c.cell);
        for (final (got, want) in [
          (over.r, c.highlight.r),
          (over.g, c.highlight.g),
          (over.b, c.highlight.b),
        ]) {
          expect(got, closeTo(want, 0.03), reason: '$b');
        }
      }
      final fg = t.textButtonTheme.style!.foregroundColor!;
      expect(fg.resolve({}), AppColors.light.accent);
      expect(fg.resolve({WidgetState.pressed}),
          AppColors.light.accent.withValues(alpha: 0.4));
      expect(t.textButtonTheme.style!.overlayColor!.resolve({WidgetState.pressed}),
          Colors.transparent);
    });

    test('Android keeps its ripple and overlay', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final t = AppTheme.build(Brightness.light);
      expect(t.splashFactory, isNot(NoSplash.splashFactory));
      expect(t.textButtonTheme.style!.foregroundColor!
              .resolve({WidgetState.pressed}),
          AppColors.light.accent);
    });
  });

  testWidgets('destructive: a quiet fill with a danger label',
      (tester) async {
    for (final b in Brightness.values) {
      await pumpApp(
          tester,
          Scaffold(
            body: Center(
              child: Builder(
                builder: (c) => FilledButton(
                    key: const Key('delete'),
                    style: AppButtonStyles.destructive(c),
                    onPressed: () {},
                    child: const Text('Delete')),
              ),
            ),
          ),
          brightness: b);
      final c = AppColors.forBrightness(b);
      final m = tester.widget<Material>(find
          .descendant(
              of: find.byKey(const Key('delete')),
              matching: find.byType(Material))
          .first);
      expect(m.color, c.fill);
      expect(m.textStyle?.color, c.danger);
    }
  });

  testWidgets('the tab bar: 56 pt, no pill, no overflow at 3.1x on a '
      '375-pt phone (en and zh)', (tester) async {
    await loadIphoneFonts();
    for (final (locale, labels) in const [
      (Locale('en'), ['Today', 'History', 'Body', 'Settings']),
      (Locale('zh'), ['今天', '历史', '身体', '设置']),
    ]) {
      await pumpApp(
          tester,
          Scaffold(
            bottomNavigationBar: NavigationBar(
              selectedIndex: 0,
              destinations: [
                for (final l in labels)
                  NavigationDestination(icon: const Icon(Icons.today), label: l),
              ],
            ),
          ),
          size: const Size(375, 667),
          locale: locale,
          scale: 3.1);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(NavigationBar)).height, 56);
      final theme = Theme.of(tester.element(find.byType(NavigationBar)));
      expect(theme.navigationBarTheme.indicatorColor, Colors.transparent);
    }
  });

  testWidgets('the app passes the high-contrast themes (iOS Increase '
      'Contrast)', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.byType(NavigationBar)));
    expect(theme.colorScheme.primary, AppColors.lightHighContrast.accent);
    expect(theme.extension<AppColors>(), same(AppColors.lightHighContrast));
  });

  testWidgets('the app shell: neutral page, chrome tab bar under a hairline',
      (tester) async {
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.byType(NavigationBar)));
    expect(theme.scaffoldBackgroundColor, AppColors.light.page);
    final hairline = tester.widget<DecoratedBox>(find
        .ancestor(
            of: find.byType(NavigationBar),
            matching: find.byType(DecoratedBox))
        .first);
    expect(hairline.position, DecorationPosition.foreground,
        reason: "the bar's own Material would cover a background line");
    final border = (hairline.decoration as BoxDecoration).border! as Border;
    expect(border.top.color, AppColors.light.separator);
  });

  testWidgets('the startup error screen wears the app theme',
      (tester) async {
    await tester.pumpWidget(
        StartupErrorApp(error: 'boom', onRetry: () async {}));
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, isNull);
    expect(Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor,
        AppColors.light.page);
    expect(
        find.ancestor(
            of: find.text('Retry'), matching: find.byType(FilledButton)),
        findsOneWidget);
    expect(find.byKey(const Key('startupRetry')), findsOneWidget);
  });

  // Owner decision 6 (2026-11-20): Android moves and scrolls like Android
  // (predictive back, stretch overscroll; the spacing is under 'type
  // scale'). iOS keeps exactly what it had.
  group('the platform split', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);
    final both = TargetPlatformVariant(
        {TargetPlatform.android, TargetPlatform.iOS});
    bool onAndroid() => defaultTargetPlatform == TargetPlatform.android;

    test('page transitions: the predictive-back builder on Android, the '
        'Cupertino slide on iOS', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        for (final b in Brightness.values) {
          final t = AppTheme.build(b);
          final builders = t.pageTransitionsTheme.builders;
          expect(builders[TargetPlatform.iOS],
              isA<CupertinoPageTransitionsBuilder>());
          final android = builders[TargetPlatform.android];
          expect(android, isA<PredictiveBackPageTransitionsBuilder>());
          // Behind the fade, the page tone (the default is the cell's).
          expect((android! as PredictiveBackPageTransitionsBuilder)
              .fallbackColor, AppColors.forBrightness(b).page);
          expect(builders[t.platform],
              same(platform == TargetPlatform.android ? android
                  : builders[TargetPlatform.iOS]));
        }
      }
    });

    Widget pushB(BuildContext c) => const Scaffold(body: Text('page b'));

    Future<void> openB(WidgetTester tester) async {
      await pumpApp(
          tester,
          _launcher((c) => Navigator.of(c)
              .push(MaterialPageRoute<void>(builder: pushB))));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.text('page b'), findsOneWidget);
    }

    testWidgets('Android: the back gesture shows the page underneath as it '
        'moves, and its end pops', (tester) async {
      await openB(tester);
      expect(find.byType(CupertinoPageTransition), findsNothing);
      await backGestureStart(tester);
      await backGestureProgress(tester, 0.35);
      expect(predictiveBackTransition, findsWidgets,
          reason: 'the preview follows the gesture');
      expect(tester.getTopLeft(find.text('page b')).dx, greaterThan(0));
      expect(find.byKey(const Key('open')), findsOneWidget,
          reason: 'the page underneath shows');
      await backGestureCommit(tester);
      expect(find.text('page b'), findsNothing);
      expect(find.byKey(const Key('open')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('Android: a gesture let go early leaves the page where it was',
        (tester) async {
      await openB(tester);
      await backGestureStart(tester);
      await backGestureProgress(tester, 0.2);
      await backGestureCancel(tester);
      expect(find.text('page b'), findsOneWidget);
      expect(tester.getTopLeft(find.text('page b')).dx, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('iOS: the Cupertino slide, and the edge swipe pops',
        (tester) async {
      await openB(tester);
      expect(find.byType(CupertinoPageTransition), findsWidgets);
      await tester.dragFrom(const Offset(4, 400), const Offset(380, 0));
      await tester.pumpAndSettle();
      expect(find.text('page b'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    /// The physics of the first CustomScrollView under [of], parent last.
    List<Type> physicsChain(WidgetTester tester, Finder of) {
      final scrollable = find
          .descendant(
              of: find.descendant(
                  of: of, matching: find.byType(CustomScrollView)).first,
              matching: find.byType(Scrollable))
          .first;
      return [
        for (ScrollPhysics? p =
                tester.state<ScrollableState>(scrollable).position.physics;
            p != null;
            p = p.parent)
          p.runtimeType,
      ];
    }

    testWidgets('scrolling in the app: Android clamps and stretches at the '
        'ends; iOS bounces, with no indicator', (tester) async {
      await tester.pumpWidget(
          CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
      await tester.pumpAndSettle();
      final chain = physicsChain(tester, find.byType(HomeShell));
      if (onAndroid()) {
        expect(chain, contains(ClampingScrollPhysics));
        expect(chain, isNot(contains(BouncingScrollPhysics)));
        expect(find.byType(StretchingOverscrollIndicator), findsWidgets);
      } else {
        expect(chain, contains(BouncingScrollPhysics));
        expect(chain, contains(AlwaysScrollableScrollPhysics));
        expect(find.byType(StretchingOverscrollIndicator), findsNothing);
      }
      expect(find.byType(GlowingOverscrollIndicator), findsNothing);
    }, variant: both);

    testWidgets('a grouped subpage scrolls as the app does: no bounce on '
        'Android', (tester) async {
      await tester.pumpWidget(
          CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(HomeShell))).push(
          MaterialPageRoute<void>(
              builder: (_) => const GroupedPage(
                  title: 'Sub', children: [SizedBox(height: 40)])));
      await tester.pumpAndSettle();
      final chain = physicsChain(tester, find.byType(GroupedPage));
      if (onAndroid()) {
        expect(chain, contains(ClampingScrollPhysics));
        expect(chain, isNot(contains(BouncingScrollPhysics)));
      } else {
        expect(chain.first, BouncingScrollPhysics,
            reason: "the grouped table's own bounce");
        expect(chain, contains(AlwaysScrollableScrollPhysics));
      }
    }, variant: both);
  });
}
