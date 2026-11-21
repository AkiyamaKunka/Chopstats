// A36-2's other half (review NAV-1, 2026-11-20). From Android 15 the app
// draws edge to edge, and with 3-button navigation the bar's contrast scrim
// (the tab bar's colour at 80%, app.dart _SystemNavBarStyle) covers the
// bottom 48 dp of every screen. A screen without the tab bar whose scroll
// ended 8 to 32 dp above the screen's bottom kept its last line, or its
// last row of photos, under the buttons however far it scrolled: a
// Settings subpage's last footer, Diagnostics' last card (a failing stage's
// fix hint), Coverage, Usual foods, the leftover and add-photo grids. Each
// scroll now ends past the system's bottom inset (scrollEndInset), and its
// viewport still reaches the screen's bottom, so the gesture bar stays
// edge to edge.

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/ui/diagnostics.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/coverage_screen.dart';
import 'package:calorie_tracker/ui/screens/diagnostics_screen.dart';
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;
import 'fakes.dart';

/// A 1080x2400 phone at 2.625: 411 x 914 dp.
const _physical = Size(1080, 2400);
const _ratio = 2.625;
const _height = 2400 / _ratio;

/// The system's bottom inset, in physical pixels: the 3-button bar (48 dp)
/// and the gesture bar (24 dp).
const _threeButton = 126.0;
const _gesture = 63.0;

String _today() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)}';
}

Meal _leftoverMeal(int id) => Meal(
      id: id,
      date: _today(),
      time: '${(8 + id % 12).toString().padLeft(2, '0')}:${10 + id}',
      timestamp: '${_today()}T08:00:00',
      source: 'app_watch',
      imageHash: 'h$id',
      analysis: {
        'is_food': true,
        'meal_description': 'Cafeteria tray $id',
        'total_calories': 600 + id,
        'total_protein_g': 40,
        'total_carbs_g': 90,
        'total_fat_g': 20,
        'food_items': [
          {'name': 'Rice (~200 g)', 'estimated_calories': 300},
        ],
      },
    );

FakePicker _manyPhotos() => FakePicker()
  ..photos = [
    for (var i = 0; i < 30; i++)
      IntakePhoto(Uint8List.fromList(List.filled(16, i)), 'p$i', 'P$i.jpg',
          capturedAt: DateTime(2026, 11, 20, 12, i)),
  ];

/// One screen without the tab bar, built and brought to the state whose
/// end is checked; [cells] are what it ends with when that is not text (a
/// grid of photos without thumbnails).
typedef _Case = ({
  String name,
  Future<void> Function(WidgetTester tester) open,
  Finder? cells,
});

final List<_Case> _cases = [
  (
    name: 'a Settings subpage (GroupedPage)',
    open: (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: GroupedPage(title: 'Subscription', children: [
          for (var i = 0; i < 12; i++)
            GroupedSection(
              header: 'Section $i',
              footer: 'The footer of section $i, the page ends with one.',
              children: [
                GroupedRow(title: 'Row $i a'),
                GroupedRow(title: 'Row $i b'),
              ],
            ),
        ]),
      ));
      await tester.pumpAndSettle();
    },
    cells: null,
  ),
  (
    name: 'Diagnostics after a run, with the backup size',
    open: (tester) async {
      final diagnostics = ProviderDiagnostics(
        settings: FakeSettings(),
        analyzer: FakeAnalyzer()
          ..nextTextIntent = {'ok': true}
          ..nextPhotoOutcome = const AnalysisOutcome(
              analysis: {'is_food': false, 'reason': 'a test disc'},
              isFood: false,
              wall: Duration.zero),
        l10n: AppLocalizationsEn(),
        client: MockClient((_) async => http.Response('ok', 404)),
        testImage: () => Uint8List.fromList(List.filled(32, 9)),
      );
      await tester.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(
          diagnostics: diagnostics,
          loadBackgroundRuns: () async => [],
          loadLateImports: () async => null,
          loadGlassesChecks: () async => [],
          loadBackupSize: () async => 3 * 1024 * 1024,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('runDiagnostics')));
      await tester.pumpAndSettle();
    },
    cells: null,
  ),
  (
    name: 'Photo Coverage after a check',
    open: (tester) async {
      final dao = FakeDao();
      final library = FakePhotoLibrary()
        ..assets = [
          for (var i = 1; i <= 40; i++)
            FakeAsset('a$i', 'IMG_$i.jpg', DateTime(2026, 7, 26, 8, i),
                bytesOf(i)),
        ];
      await tester.pumpWidget(MaterialApp(
        home: CoverageScreen(
          auditor: CoverageAuditor(
              library: library,
              dao: dao,
              hasher: (b) async => 'h${b.first}',
              clock: () => DateTime(2026, 7, 26, 12)),
          processPhoto: (_) async =>
              const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'),
          requestPhotoPermission: () async => true,
          initialLookbackDays: 2,
          ensureConsent: (_) async => true,
          library: library,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('runCoverageCheck')));
      await tester.pumpAndSettle();
    },
    cells: null,
  ),
  (
    name: 'Usual foods',
    open: (tester) async {
      final dao = FakeDao();
      var id = 10;
      for (var food = 0; food < 20; food++) {
        for (final day in ['2026-11-03', '2026-11-05']) {
          dao.seed(foodMeal(
              id: id++,
              date: day,
              time: '12:${(10 + food).toString().padLeft(2, '0')} PM',
              description: 'Usual dish $food',
              items: [foodItem('Usual dish $food', 300 + food)]));
        }
      }
      DateTime clock() => DateTime(2026, 11, 7, 12, 30);
      final usual = await makeUsualFoods(dao, clock: clock);
      await tester.pumpWidget(
          MaterialApp(home: UsualFoodsScreen(usual: usual, now: clock)));
      await tester.pumpAndSettle();
    },
    cells: null,
  ),
  (
    name: 'Leftovers: the meal list',
    open: (tester) async {
      final dao = FakeDao();
      for (var i = 1; i <= 20; i++) {
        dao.put(_leftoverMeal(i));
      }
      await tester.pumpWidget(MaterialApp(
          home: LeftoverScreen(
              services: makeServices(dao: dao, picker: _manyPhotos()))));
      await tester.pumpAndSettle();
    },
    cells: null,
  ),
  (
    name: 'Leftovers: the photo grid',
    open: (tester) async {
      final dao = FakeDao()..put(_leftoverMeal(1));
      await tester.pumpWidget(MaterialApp(
          home: LeftoverScreen(
              services: makeServices(dao: dao, picker: _manyPhotos()))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('leftoverMeal-1')));
      await tester.pumpAndSettle();
    },
    cells: find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('leftoverPhoto-')),
  ),
  (
    name: 'Add photo: the grid',
    open: (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: AddPhotoScreen(services: makeServices(picker: _manyPhotos()))));
      await tester.pumpAndSettle();
    },
    cells: find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('recentPhoto')),
  ),
  (
    name: 'Edit meal',
    open: (tester) async {
      final dao = FakeDao()
        ..seed(foodMeal(id: 1, date: '2026-11-20', items: [
          for (var i = 0; i < 6; i++) foodItem('Item $i', 100),
        ]));
      await tester.pumpWidget(MaterialApp(
          home: MealEditorScreen(dao: dao, meal: dao.meals.first)));
      await tester.pumpAndSettle();
    },
    cells: null,
  ),
];

/// The screen's own vertical scroll: the tallest one.
ScrollableState _mainScroll(WidgetTester tester) {
  final all = tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .where((s) => s.position.axis == Axis.vertical)
      .toList()
    ..sort((a, b) => b.position.viewportDimension
        .compareTo(a.position.viewportDimension));
  expect(all, isNotEmpty);
  return all.first;
}

/// Jumps [scroll] to its end until the end holds (a lazy list's extent
/// grows as it builds its last rows).
Future<void> _toEnd(WidgetTester tester, ScrollableState scroll) async {
  double? last;
  for (var i = 0; i < 20; i++) {
    final max = scroll.position.maxScrollExtent;
    scroll.position.jumpTo(max);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    if (max == last && scroll.position.pixels == max) return;
    last = max;
  }
}

Rect _rectOf(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  void inset(WidgetTester tester, double bottom) {
    tester.view.physicalSize = _physical;
    tester.view.devicePixelRatio = _ratio;
    tester.view.padding = FakeViewPadding(bottom: bottom);
    tester.view.viewPadding = FakeViewPadding(bottom: bottom);
    addTearDown(tester.view.reset);
  }

  for (final c in _cases) {
    for (final (bar, bottom) in const [
      ('3-button bar', _threeButton),
      ('gesture bar', _gesture),
    ]) {
      testWidgets('Android, $bar: ${c.name} scrolls its last content clear '
          'of the bar, and still runs edge to edge', (tester) async {
        inset(tester, bottom);
        await c.open(tester);
        final scroll = _mainScroll(tester);
        final viewport = _rectOf(scroll.context as Element);
        expect(viewport.bottom, closeTo(_height, 0.01),
            reason: 'the scroll reaches the bottom of the screen, under '
                'the bar: edge to edge, no SafeArea');
        await _toEnd(tester, scroll);
        expect(scroll.position.maxScrollExtent, greaterThan(0),
            reason: 'the case must scroll for its end to be in question');
        final content = find.descendant(
            of: find.byWidget(scroll.widget),
            matching: c.cells ??
                find.byWidgetPredicate((w) => w is RichText || w is RawImage));
        final rects = [
          for (final e in content.evaluate())
            if (_rectOf(e) case final r when r.top < _height && r.bottom > 0)
              r,
        ];
        expect(rects, isNotEmpty);
        final lowest =
            rects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
        final barTop = _height - bottom / _ratio;
        expect(lowest, lessThanOrEqualTo(barTop + 0.01),
            reason: 'its last content ends above the bar, out from under '
                'its scrim and buttons');
      });
    }
  }

  testWidgets('iPhone: the end padding stays as it was (no system inset '
      'added)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    inset(tester, 102); // the home indicator, 34 pt at 3x
    late double end;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        end = scrollEndInset(context);
        return const SizedBox.shrink();
      }),
    ));
    expect(end, 32);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: the end padding is the base past the bottom inset, '
      'none added under the keyboard', (tester) async {
    inset(tester, _threeButton);
    late double end;
    late double small;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        end = scrollEndInset(context);
        small = scrollEndInset(context, 8);
        return const SizedBox.shrink();
      }),
    ));
    expect(end, closeTo(32 + 48, 0.01));
    expect(small, closeTo(8 + 48, 0.01));
    // The keyboard up: the engine reports the bar's inset as view padding
    // only, and padding (what the keyboard leaves) as none.
    tester.view.viewInsets = const FakeViewPadding(bottom: 800);
    tester.view.padding = FakeViewPadding.zero;
    await tester.pump();
    expect(end, 32);
  });
}
