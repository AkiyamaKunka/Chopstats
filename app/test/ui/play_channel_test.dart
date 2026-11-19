// The Google Play build (owner decision 1, 2026-11-13) ships WITHOUT broad
// photo access; the GitHub APK keeps everything. One switch,
// `--dart-define=CHOPSTATS_CHANNEL=play` (core/app_channel.dart), and the
// tests run either build through debugAppChannelOverride.
//
// In the Play build nothing reads the photo library on its own: Watch
// Camera Roll, the Meta glasses switch and Photo Coverage are gone from
// Settings, Diagnostics says which build it is, and no copy points to what
// the build lacks. The move off Watch Camera Roll for a GitHub install it
// replaces is play_upgrade_test.dart; Log and Leftovers' picker-only path
// is in add_flow_system_picker_test and leftover_flow_test.
import 'package:calorie_tracker/core/app_channel.dart';
import 'package:calorie_tracker/core/outcome_kind.dart' show AnalysisErrorKind;
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/ui/coach_strings.dart';
import 'package:calorie_tracker/ui/diagnostics.dart';
import 'package:calorie_tracker/ui/outcome_text.dart' show outcomeSnackbar;
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/diagnostics_screen.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final _en = AppLocalizationsEn();
final _zh = AppLocalizationsZh();

/// Counts every question put to the library: the Play build asks none.
class _CountingLibrary implements PhotoLibrary {
  int fullAccessAsks = 0;
  int permissionRequests = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<bool> hasFullAccess() async {
    fullAccessAsks++;
    return false;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }
}

void main() {
  tearDown(() => debugAppChannelOverride = null);

  group('Settings', () {
    late _CountingLibrary library;

    Future<void> pump(
      WidgetTester tester,
      FakeSettings settings, {
      Locale locale = const Locale('en'),
    }) async {
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      library = _CountingLibrary();
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SettingsScreen(
              settings: settings,
              analyzer: FakeAnalyzer(),
              dao: FakeDao(),
              photoIntake: FakeIntake(),
              requestPhotoPermission: library.requestPermission,
              photoLibrary: library,
              coverage: CoverageAuditor(
                library: library,
                dao: FakeDao(),
                hasher: (b) async => 'h${b.length}',
              ),
              processPhoto: (p) async =>
                  const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'),
              lastBackgroundScan: () async => DateTime(2026, 11, 19, 9),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    const photoRows = [
      Key('watcherToggle'),
      Key('watchGlassesToggle'),
      Key('coverageCheckTile'),
    ];

    testWidgets('the GitHub APK: the Photos group as before', (tester) async {
      await pump(tester, FakeSettings(apiKey: 'k', watcherEnabled: true));
      for (final row in photoRows) {
        expect(find.byKey(row), findsOneWidget, reason: '$row');
      }
      expect(find.byKey(const Key('backgroundScanRow')), findsOneWidget);
      expect(find.text(_en.settingsRowLookback), findsOneWidget);
    });

    testWidgets('the Play build: no Photos group at all, and the library is '
        'never asked anything', (tester) async {
      debugAppChannelOverride = AppChannel.play;
      await pump(tester, FakeSettings(apiKey: 'k'));
      for (final row in photoRows) {
        expect(find.byKey(row), findsNothing, reason: '$row');
      }
      expect(find.byKey(const Key('backgroundScanRow')), findsNothing);
      expect(find.byKey(const Key('photosAllowAllLink')), findsNothing);
      expect(find.text(_en.settingsRowWatch), findsNothing);
      expect(find.text(_en.settingsRowLookback), findsNothing);
      expect(find.text(_en.settingsRowCoverage), findsNothing);
      expect(find.textContaining(_en.settingsPhotosFooter(2)), findsNothing);
      expect(library.fullAccessAsks, 0);
      expect(library.permissionRequests, 0);
      // Everything else is where it was.
      expect(find.byKey(const Key('aiProviderRow')), findsOneWidget);
      expect(find.byKey(const Key('summaryToggle')), findsOneWidget);
    });

    testWidgets('the Play build\'s first-run card points to Log and sharing, '
        'not to Watch Camera Roll', (tester) async {
      debugAppChannelOverride = AppChannel.play;
      await pump(tester, FakeSettings(apiKey: ''));
      expect(find.text(_en.settingsWelcomeBodyPlay), findsOneWidget);
      expect(find.textContaining(_en.settingsRowWatch), findsNothing);
    });

    testWidgets('the Play build\'s Stop sharing names no Watch Camera Roll', (
      tester,
    ) async {
      debugAppChannelOverride = AppChannel.play;
      await pump(tester, FakeSettings(apiKey: 'k'));
      await tester.tap(find.byKey(const Key('aiStopSharingRow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('aiStopSharingDialog')), findsOneWidget);
      expect(find.text(_en.aiStopSharingBodyPlay('Gemini')), findsOneWidget);
      expect(find.textContaining(_en.settingsRowWatch), findsNothing);
    });
  });

  testWidgets("Today's empty hint in the Play build: Log and sharing, no "
      'Watch Camera Roll', (tester) async {
    debugAppChannelOverride = AppChannel.play;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TodayScreen(dao: FakeDao())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_en.todayEmptyHintPlay), findsOneWidget);
    expect(find.textContaining(_en.settingsRowWatch), findsNothing);
  });

  group('Diagnostics', () {
    ProviderDiagnostics diag() => ProviderDiagnostics(
      settings: FakeSettings(apiKey: 'k'),
      analyzer: FakeAnalyzer(),
      l10n: _en,
    );

    Future<void> pump(WidgetTester tester, AppChannel? channel) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiagnosticsScreen(
            diagnostics: diag(),
            channel: channel,
            loadBackgroundRuns: () async => const [],
            loadLateImports: () async => null,
            loadGlassesChecks: () async => const [],
            loadBackupSize: () async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says which build this is', (tester) async {
      await pump(tester, AppChannel.play);
      expect(find.text(_en.diagChannelPlay), findsOneWidget);
      await pump(tester, AppChannel.github);
      expect(find.text(_en.diagChannelGithub), findsOneWidget);
      await pump(tester, null); // the iPhone
      expect(find.byKey(const Key('diagChannel')), findsNothing);
    });

    testWidgets('the Play build has no background scan or glasses intake to '
        'report', (tester) async {
      await pump(tester, AppChannel.github);
      expect(find.byKey(const Key('diagBackgroundRuns')), findsOneWidget);
      expect(find.byKey(const Key('diagGlassesCheck')), findsOneWidget);
      await pump(tester, AppChannel.play);
      expect(find.byKey(const Key('diagBackgroundRuns')), findsNothing);
      expect(find.byKey(const Key('diagGlassesCheck')), findsNothing);
    });
  });

  group('no copy points to what the Play build lacks', () {
    test('the summary card for a day with nothing logged', () {
      for (final lang in ['en', 'zh']) {
        final l = localizationsFor(lang);
        expect(coachStringsFor(lang).empty, l.coachEmpty);
        expect(summaryDayNamingFor(lang).empty, l.coachEmptyOnDay);
        debugAppChannelOverride = AppChannel.play;
        final strings = coachStringsFor(lang);
        expect(strings.empty, l.coachEmptyPlay);
        expect(strings.emptyYesterday, l.coachEmptyYesterdayPlay);
        expect(summaryDayNamingFor(lang).empty, l.coachEmptyOnDayPlay);
        debugAppChannelOverride = null;
      }
      for (final text in [
        _en.coachEmptyPlay,
        _en.coachEmptyYesterdayPlay,
        _en.coachEmptyOnDayPlay,
      ]) {
        expect(text, isNot(contains('automatically')));
      }
      for (final text in [
        _zh.coachEmptyPlay,
        _zh.coachEmptyYesterdayPlay,
        _zh.coachEmptyOnDayPlay,
      ]) {
        expect(text, isNot(contains('自动')));
      }
    });

    test(
      "the own server's final refusals: no Photo Coverage to retry from",
      () {
        PhotoOutcome failed(AnalysisErrorKind kind, String message) =>
            PhotoOutcome(
              PhotoOutcomeKind.failed,
              message,
              errorKind: kind,
              retryable: false,
            );
        final rejected = failed(
          AnalysisErrorKind.serverRejected,
          'HTTP 400 schema',
        );
        final final_ = failed(
          AnalysisErrorKind.serverError,
          'server error: boom',
        );
        expect(
          outcomeSnackbar(_en, rejected),
          contains(_en.settingsRowCoverage),
        );
        expect(outcomeSnackbar(_en, final_), contains(_en.settingsRowCoverage));
        debugAppChannelOverride = AppChannel.play;
        for (final l in [_en as AppLocalizations, _zh as AppLocalizations]) {
          for (final o in [rejected, final_]) {
            expect(
              outcomeSnackbar(l, o),
              isNot(contains(l.settingsRowCoverage)),
            );
          }
        }
      },
    );

    test(
      'every Play variant leaves out Watch Camera Roll and Photo Coverage',
      () {
        for (final l in [_en as AppLocalizations, _zh as AppLocalizations]) {
          for (final text in [
            l.todayEmptyHintPlay,
            l.settingsWelcomeBodyPlay,
            l.aiStopSharingBodyPlay('X'),
            l.aiStopSharingBodyWithLookupsPlay('X'),
            l.errServerFailedFinalPlay('why'),
            l.errServerRejectedPlay('400'),
          ]) {
            expect(text, isNot(contains(l.settingsRowWatch)), reason: text);
            expect(text, isNot(contains(l.settingsRowCoverage)), reason: text);
          }
          // The notice names the switch it turned off, and both ways in.
          expect(l.watchRetiredTitle, contains(l.settingsRowWatch));
          expect(l.watchRetiredBody, contains(l.fabLog));
          expect(l.watchRetiredBody, contains(l.addFromPhotos));
          expect(l.todayEmptyHintPlay, contains(l.fabLog));
        }
        expect(_en.watchRetiredBody, contains('Google Play'));
        expect(_zh.watchRetiredBody, contains('Google Play'));
        expect(_zh.settingsWelcomeBodyPlay, contains('中国大陆用户'));
      },
    );
  });
}
