// iOS: where the app shows whether the next background scan is scheduled
// (2026-11-28): Settings › Photos › Background scan, the 'Recent background
// scans' card, and the shell's hook that asks iOS again on every return to
// the app and every leave.
//
// On 2026-11-27 an iPhone logged a noon meal at 23:05, and nothing on the
// phone could say whether iOS had been holding a request for a background
// scan at all: the Settings row showed only when the last one ran.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/background_runs.dart';
import 'package:calorie_tracker/services/photo/background_schedule.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/diagnostics.dart';
import 'package:calorie_tracker/ui/screens/diagnostics_screen.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart' show RowBadge;

import 'fakes.dart';

final _checked = DateTime(2026, 11, 27, 22, 24);

BackgroundSchedule _held() => BackgroundSchedule(at: _checked, scheduled: true);

BackgroundSchedule _refused([String why = BackgroundRefusal.unavailable]) =>
    BackgroundSchedule(
      at: _checked,
      scheduled: false,
      refusal: why,
      submitted: true,
    );

Widget _app(Widget home, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: home),
);

void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('Settings › Photos › Background scan', () {
    final lastRun = DateTime(
      _checked.year,
      _checked.month,
      _checked.day,
      8,
      33,
    );

    Widget settings({
      BackgroundSchedule? schedule,
      bool refreshOn = true,
      bool watcher = true,
      bool probe = true,
      Locale? locale,
    }) => _app(
      SettingsScreen(
        key: UniqueKey(),
        settings: FakeSettings(apiKey: 'k', watcherEnabled: watcher),
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        requestPhotoPermission: () async => true,
        lastBackgroundScan: () async => lastRun,
        backgroundRefreshEnabled: () async => refreshOn,
        backgroundSchedule: probe ? () async => schedule : null,
        openSystemSettings: () async {},
      ),
      locale: locale,
    );

    final row = find.byKey(const Key('backgroundScanRow'));
    const en = 'The next background scan is not scheduled';

    Color badge(WidgetTester tester) => tester
        .widget<RowBadge>(
          find.descendant(of: row, matching: find.byType(RowBadge)),
        )
        .color;

    testWidgets('iOS refused the request: the row reads "Not scheduled" in '
        'red, and the footer says why and what happens now', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(settings(schedule: _refused()));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('Not scheduled')),
        findsOneWidget,
        reason: 'the last run\'s time says nothing about the next one',
      );
      expect(badge(tester), Theme.of(tester.element(row)).colorScheme.error);
      expect(
        find.textContaining(
          '$en: iOS is not taking background requests '
          'from Chopstats right now. Chopstats asks again each time you '
          'open or leave it; until then, new photos are logged when you '
          'open the app.',
        ),
        findsOneWidget,
      );
      // Still under it: when iOS runs a scan it does hold a request for.
      expect(
        find.textContaining('iOS decides when the background scan runs'),
        findsOneWidget,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets(
      'any other refusal is said with the code iOS gave',
      (tester) async {
        _tallView(tester);
        await tester.pumpWidget(
          settings(schedule: _refused(BackgroundRefusal.notPermitted)),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: row, matching: find.text('Not scheduled')),
          findsOneWidget,
        );
        expect(
          find.textContaining('$en: iOS refused the request (notPermitted).'),
          findsOneWidget,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('iOS holds a request, or was never asked: the last run\'s '
        'time, as before, and no such line', (tester) async {
      _tallView(tester);
      for (final quiet in [
        settings(schedule: _held()),
        settings(schedule: null),
        settings(probe: false),
      ]) {
        await tester.pumpWidget(quiet);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: row, matching: find.text('Not scheduled')),
          findsNothing,
        );
        expect(
          find.descendant(of: row, matching: find.textContaining('8:33 AM')),
          findsOneWidget,
        );
        expect(find.textContaining(en), findsNothing);
        expect(
          badge(tester),
          Theme.of(tester.element(row)).colorScheme.secondary,
        );
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    // iOS refuses every request while Background App Refresh is off: the
    // red Off, whose chevron leads to the switch, already is the answer.
    testWidgets('Background App Refresh off: the Off remedy wins, and with '
        'Watch Camera Roll off there is no row', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(settings(schedule: _refused(), refreshOn: false));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('Off')),
        findsOneWidget,
      );
      expect(find.text('Not scheduled'), findsNothing);
      expect(find.textContaining(en), findsNothing);

      await tester.pumpWidget(settings(schedule: _refused(), watcher: false));
      await tester.pumpAndSettle();
      expect(row, findsNothing);
      expect(find.textContaining(en), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a return to the app reads iOS\'s answer again: the row '
        'clears itself once a request is held', (tester) async {
      _tallView(tester);
      BackgroundSchedule now = _refused();
      await tester.pumpWidget(
        _app(
          SettingsScreen(
            settings: FakeSettings(apiKey: 'k', watcherEnabled: true),
            analyzer: FakeAnalyzer(),
            dao: FakeDao(),
            requestPhotoPermission: () async => true,
            lastBackgroundScan: () async => lastRun,
            backgroundRefreshEnabled: () async => true,
            backgroundSchedule: () async => now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Not scheduled'), findsOneWidget);
      now = _held();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Not scheduled'), findsNothing);
      expect(find.textContaining(en), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('in Chinese', (tester) async {
      _tallView(tester);
      await tester.pumpWidget(
        settings(schedule: _refused(), locale: const Locale('zh')),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('未安排')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          '下一次后台扫描还没有安排上：iOS 目前不接受筷拍的后台扫描申请。每次打开或离开筷拍时，筷拍都会重新申请；',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(
        settings(
          schedule: _refused(BackgroundRefusal.tooManyPending),
          locale: const Locale('zh'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('iOS 拒绝了筷拍的申请（tooManyPendingTaskRequests）。'),
        findsOneWidget,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    test(
      'the footer line: "unavailable" names no code, anything else does',
      () {
        final l = AppLocalizationsEn();
        expect(
          backgroundNotScheduledLine(l, BackgroundRefusal.unavailable),
          l.backgroundScanNotScheduledUnavailable,
        );
        expect(
          backgroundNotScheduledLine(l, null),
          l.backgroundScanNotScheduledUnavailable,
        );
        expect(
          backgroundNotScheduledLine(l, 'error 7'),
          l.backgroundScanNotScheduledRefused('error 7'),
        );
      },
    );
  });

  group('Recent background scans: the request for the next one', () {
    ProviderDiagnostics diag() => ProviderDiagnostics(
      settings: FakeSettings(),
      analyzer: FakeAnalyzer(),
      l10n: AppLocalizationsEn(),
      testImage: () => throw UnimplementedError(),
    );

    final run = BackgroundRunRecord(
      start: DateTime.utc(2026, 11, 27, 0, 33),
      end: DateTime.utc(2026, 11, 27, 0, 33, 9),
      platform: 'ios',
      stage: BackgroundRunStage.done,
      stopReason: BackgroundStop.done,
    );

    Future<void> pump(
      WidgetTester tester,
      BackgroundSchedule? schedule, {
      List<BackgroundRunRecord>? runs,
      Locale? locale,
    }) async {
      _tallView(tester);
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiagnosticsScreen(
            // A new page each time: it reads its records once.
            key: UniqueKey(),
            diagnostics: diag(),
            loadBackgroundRuns: () async => runs ?? [run],
            loadBackgroundSchedule: () async => schedule,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final line = find.byKey(const Key('diagBackgroundSchedule'));
    final stamp = localStamp(_checked);

    testWidgets('held: scheduled, and when the app last asked', (tester) async {
      await pump(tester, _held());
      expect(
        tester.widget<Text>(line).data,
        'Next scan: scheduled. iOS holds the request and picks the time. '
        'Checked $stamp.',
      );
      // Above the runs: whether a next one can come at all.
      expect(
        tester.getTopLeft(line).dy,
        lessThan(tester.getTopLeft(find.text('Finished.')).dy),
      );
    });

    testWidgets('refused: not scheduled, why, in the error colour', (
      tester,
    ) async {
      await pump(tester, _refused());
      final text = tester.widget<Text>(line);
      expect(
        text.data,
        'Next scan: not scheduled. iOS is not taking background requests '
        'from Chopstats right now. Checked $stamp.',
      );
      expect(
        text.style?.color,
        Theme.of(tester.element(line)).colorScheme.error,
      );
      await pump(tester, _refused(BackgroundRefusal.tooManyPending));
      expect(
        tester.widget<Text>(line).data,
        'Next scan: not scheduled. iOS refused the request '
        '(tooManyPendingTaskRequests). Checked $stamp.',
      );
    });

    testWidgets('shown with no run recorded yet too, and in Chinese', (
      tester,
    ) async {
      await pump(
        tester,
        _refused(),
        runs: const [],
        locale: const Locale('zh'),
      );
      expect(find.text('还没有后台扫描记录。'), findsOneWidget);
      expect(
        tester.widget<Text>(line).data,
        '下一次扫描：未安排。iOS 目前不接受筷拍的后台扫描申请。检查时间：$stamp。',
      );
      await pump(tester, _held(), locale: const Locale('zh'));
      expect(
        tester.widget<Text>(line).data,
        '下一次扫描：已安排。iOS 已收下申请，何时运行由 iOS 决定。检查时间：$stamp。',
      );
    });

    testWidgets('never asked (Android, an older record): no line', (
      tester,
    ) async {
      await pump(tester, null);
      expect(line, findsNothing);
      expect(find.text('Finished.'), findsOneWidget);
    });

    testWidgets('a probe that throws leaves the line out, not the card', (
      tester,
    ) async {
      _tallView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: DiagnosticsScreen(
            diagnostics: diag(),
            loadBackgroundRuns: () async => [run],
            loadBackgroundSchedule: () async => throw StateError('store'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(line, findsNothing);
      expect(find.text('Finished.'), findsOneWidget);
    });

    test('one line per answer, in both languages', () {
      for (final l in <AppLocalizations>[
        AppLocalizationsEn(),
        AppLocalizationsZh(),
      ]) {
        final lines = {
          backgroundScheduleLine(l, _held()),
          backgroundScheduleLine(l, _refused()),
          backgroundScheduleLine(l, _refused(BackgroundRefusal.notPermitted)),
        };
        expect(lines, hasLength(3));
        for (final text in lines) {
          expect(text, contains(stamp));
        }
      }
    });
  });

  // app.dart: the request used to be made at a cold start only.
  group('HomeShell keeps the request alive', () {
    UiServices services(Future<void> Function()? keep) => UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: FakeSettings(watcherEnabled: false),
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      keepBackgroundScan: keep,
    );

    testWidgets('asked again on every return to the app and every leave', (
      tester,
    ) async {
      final asked = <AppLifecycleState>[];
      AppLifecycleState? now;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(services: services(() async => asked.add(now!))),
        ),
      );
      // Legal lifecycle order: inactive → hidden → paused → … → resumed.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        now = state;
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      expect(asked, [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.resumed,
      ], reason: 'never for inactive: a system alert over the app is that');
    });

    testWidgets('a hook that throws changes nothing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            services: services(() async => throw StateError('channel')),
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    // Android has no hook at all (di.dart hands the shell null there).
    testWidgets('no hook (Android): nothing to call', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: HomeShell(services: services(null))),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
