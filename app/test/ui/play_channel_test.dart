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
import 'dart:typed_data';

import 'package:calorie_tracker/core/app_channel.dart';
import 'package:calorie_tracker/core/contracts.dart'
    show AnalysisOutcome, KeyProbe, KeyProbeResult;
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
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart'
    show ProviderSettingsPage;
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
      // Android: why Meta glasses photos starts off (owner decision 8).
      expect(find.textContaining(_en.watchGlassesAndroidNote), findsOneWidget);
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
      // No glasses switch, so no line about its default either.
      expect(find.textContaining(_en.watchGlassesAndroidNote), findsNothing);
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

    // Nothing in the Play build keeps a photo or retries it on its own: no
    // watcher, no catch-up, no Photo Coverage. A photo picked or shared
    // during the pause is not analyzed and says so (outcome_text.dart), so
    // the footer says to add it again (review, 2026-11-19).
    testWidgets("the paused-analysis footer: the Play build's says to add "
        'the photo again, not that it is kept and retried', (tester) async {
      FakeSettings paused() => FakeSettings(apiKey: 'k')..isQuotaPaused = true;
      await pump(tester, paused());
      expect(find.text(_en.settingsAiFooterPaused), findsOneWidget);
      debugAppChannelOverride = AppChannel.play;
      await pump(tester, paused());
      expect(find.text(_en.settingsAiFooterPausedPlay), findsOneWidget);
      expect(find.text(_en.settingsAiFooterPaused), findsNothing);
      await pump(tester, paused(), locale: const Locale('zh'));
      expect(find.text(_zh.settingsAiFooterPausedPlay), findsOneWidget);
    });
  });

  testWidgets("the AI Provider page's pause banner in the Play build, with "
      'and without the time the pause lifts', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Future<String> banner(DateTime? until, {String lang = 'en'}) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(lang),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProviderSettingsPage(
            settings: FakeSettings(apiKey: 'k')
              ..isQuotaPaused = true
              ..quotaPauseUntil = until,
            analyzer: FakeAnalyzer(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('quotaPauseBanner')),
              matching: find.byType(Text),
            ),
          )
          .data!;
    }

    final until = DateTime(2026, 11, 19, 23, 30);
    expect(await banner(null), _en.providerQuotaPaused);
    expect(await banner(until), _en.providerQuotaPausedUntil('11:30 PM'));
    debugAppChannelOverride = AppChannel.play;
    expect(await banner(null), _en.providerQuotaPausedPlay);
    expect(await banner(until), _en.providerQuotaPausedUntilPlay('11:30 PM'));
    expect(await banner(null, lang: 'zh'), _zh.providerQuotaPausedPlay);
    final zh = await banner(until, lang: 'zh');
    expect(zh, startsWith('分析已暂停到 '));
    expect(zh, contains('11:30'));
    expect(
      zh,
      endsWith(
        _zh.providerQuotaPausedUntilPlay('').split(' — ').skip(1).join(' — '),
      ),
    );
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

  // Nothing in the Play build keeps a photo for later or retries it on its
  // own: there is no watcher, no catch-up and no Photo Coverage. The lines
  // that said so (review, 2026-11-19) have Play wording.
  group('no promise of a kept or retried photo in the Play build', () {
    test("Test This Provider's fix lines: rate limit, temporary photo "
        'failure, quota pause', () async {
      Future<Map<String, String?>> fixes(AppLocalizations l) async {
        final analyzer = FakeAnalyzer()
          ..nextTextIntent = {'ok': true}
          ..nextPhotoOutcome = const AnalysisOutcome(
            error: 'The provider is busy.',
            retryable: true,
            wall: Duration.zero,
          )
          ..onProbeKey = (_) async => const KeyProbe(
            KeyProbeResult.rateLimited,
            message: 'Rate limit hit.',
          );
        final results = await ProviderDiagnostics(
          settings: FakeSettings(apiKey: 'k')..isQuotaPaused = true,
          analyzer: analyzer,
          l10n: l,
          client: MockClient((_) async => http.Response('ok', 404)),
          testImage: () => Uint8List(32),
        ).run().toList();
        return {for (final r in results) r.stage: r.fix};
      }

      final github = await fixes(_en);
      expect(github[_en.diagStageAuth], _en.diagFixWaitRateLimit);
      expect(github[_en.diagStagePhoto], _en.diagFixPhotoTemp);
      expect(github[_en.diagStageQuota], _en.diagFixQuota);
      debugAppChannelOverride = AppChannel.play;
      for (final l in [_en as AppLocalizations, _zh as AppLocalizations]) {
        final play = await fixes(l);
        expect(play[l.diagStageAuth], l.diagFixWaitRateLimitPlay);
        expect(play[l.diagStagePhoto], l.diagFixPhotoTempPlay);
        expect(play[l.diagStageQuota], l.diagFixQuotaPlay);
      }
    });

    test("a shared photo's permanent failure: not 'kept for retry'", () {
      const failed = PhotoOutcome(
        PhotoOutcomeKind.failed,
        'This photo could not be processed (it could not be decoded).',
        errorKind: AnalysisErrorKind.badPhoto,
        shared: true,
      );
      expect(
        outcomeSnackbar(_en, failed),
        _en.outcomeFailedKeptMsg(_en.errBadPhoto),
      );
      debugAppChannelOverride = AppChannel.play;
      for (final l in [_en as AppLocalizations, _zh as AppLocalizations]) {
        expect(
          outcomeSnackbar(l, failed),
          l.outcomeFailedKeptMsgPlay(l.errBadPhoto),
        );
      }
    });

    test('the Play wording promises nothing kept or retried, and the pause '
        'lines keep everything else', () {
      for (final (l, kept, words) in [
        (
          _en as AppLocalizations,
          'New photos are kept and retried automatically.',
          ['kept', 'retried', 'automatic'],
        ),
        (_zh as AppLocalizations, '新照片会保留并自动重试。', ['保留', '自动']),
      ]) {
        final pauses = {
          l.settingsAiFooterPaused: l.settingsAiFooterPausedPlay,
          l.providerQuotaPaused: l.providerQuotaPausedPlay,
          l.providerQuotaPausedUntil('T'): l.providerQuotaPausedUntilPlay('T'),
        };
        for (final MapEntry(key: original, value: play) in pauses.entries) {
          final at = original.indexOf(kept);
          expect(at, isNonNegative, reason: original);
          expect(play, startsWith(original.substring(0, at)), reason: play);
          expect(
            play,
            endsWith(original.substring(at + kept.length)),
            reason: play,
          );
        }
        for (final text in [
          ...pauses.values,
          l.diagFixWaitRateLimitPlay,
          l.diagFixPhotoTempPlay,
          l.diagFixQuotaPlay,
          l.outcomeFailedKeptMsgPlay('R'),
        ]) {
          for (final word in words) {
            expect(text, isNot(contains(word)), reason: text);
          }
          expect(text, isNot(contains(l.settingsRowCoverage)), reason: text);
        }
      }
    });
  });
}
