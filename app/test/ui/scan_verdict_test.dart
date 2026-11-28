// How the photo pipeline's verdicts count for Today's "Checking photos"
// row (2026-11-28): which ones are a photo checked, which ones leave a
// photo waiting ("not checked yet", with a reason and Retry), and which
// say nothing. And when the pipeline says a photo is being checked.
//
// The row must never show an error for a photo that was simply not food,
// and never offer a Retry that could do nothing (a pause every photo
// shares stops the catch-up itself; Settings explains those).
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/scan_status.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

PhotoOutcome _released(AnalysisErrorKind kind, {String? reason}) =>
    PhotoOutcome(PhotoOutcomeKind.failed, 'released',
        retryable: true, errorKind: kind, reason: reason);

IntakePhoto _photo({bool deliberate = false}) => IntakePhoto(
    Uint8List.fromList([7, 7, 7]), 'asset7', 'IMG_7.HEIC',
    deliberate: deliberate);

void main() {
  group('scanVerdictOf', () {
    test('a meal, leftovers deducted, not food and a failure kept as failed '
        'are all a photo checked', () {
      for (final o in const [
        PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged'),
        PhotoOutcome(PhotoOutcomeKind.leftoverApplied, 'Leftovers deducted'),
        PhotoOutcome(PhotoOutcomeKind.skipped, 'No food detected'),
        PhotoOutcome(PhotoOutcomeKind.skipped, 'No food detected',
            reason: notFoodLocalReason),
        PhotoOutcome(PhotoOutcomeKind.skipped, 'Another copy',
            reason: duplicateCaptureReason),
        PhotoOutcome(PhotoOutcomeKind.failed, 'Could not process this photo',
            errorKind: AnalysisErrorKind.badPhoto),
        PhotoOutcome(PhotoOutcomeKind.failed, 'It looks like the leftovers',
            errorKind: AnalysisErrorKind.leftoverUnsure),
      ]) {
        expect(scanVerdictOf(o), ScanVerdict.checked, reason: o.message);
      }
    });

    test('released because the analysis could not be had, or held by '
        'another run: waiting', () {
      for (final kind in const [
        AnalysisErrorKind.network,
        AnalysisErrorKind.serverBusy,
        AnalysisErrorKind.serverError,
        AnalysisErrorKind.rateLimited,
      ]) {
        expect(scanVerdictOf(_released(kind)), ScanVerdict.waiting,
            reason: kind.name);
        expect(couldNotBeHad(kind), isTrue, reason: kind.name);
      }
      expect(
          scanVerdictOf(const PhotoOutcome(
              PhotoOutcomeKind.inFlight, 'still being analyzed',
              retryable: true)),
          ScanVerdict.waiting);
    });

    test('every reason the row counts has words in both languages, taken '
        'from the app\'s own reason lines', () {
      for (final kind in AnalysisErrorKind.values.where(couldNotBeHad)) {
        for (final l in [AppLocalizationsEn(), AppLocalizationsZh()]) {
          final reason = retryReason(l, _released(kind));
          expect(reason, isNotNull, reason: '${kind.name} ${l.localeName}');
          expect(reason, isNotEmpty);
        }
      }
      expect(retryReason(AppLocalizationsEn(),
              _released(AnalysisErrorKind.serverBusy)),
          AppLocalizationsEn().reasonServerBusy);
      expect(retryReason(AppLocalizationsZh(),
              _released(AnalysisErrorKind.network)),
          AppLocalizationsZh().reasonNetwork);
    });

    test('a pause or a setting every photo shares, a hold with its own '
        'reason, and a photo logged before say nothing', () {
      for (final kind in AnalysisErrorKind.values) {
        if (couldNotBeHad(kind)) continue;
        expect(scanVerdictOf(_released(kind)), ScanVerdict.none,
            reason: kind.name);
      }
      // A hold is a hold whatever error kind rides along.
      for (final reason in const [
        backupHoldReason,
        glassesPreviewReason,
        glassesCappedReason,
        foodCheckDeferredReason,
        notAllowedReason,
        leftoverConflictReason,
      ]) {
        expect(
            scanVerdictOf(
                _released(AnalysisErrorKind.network, reason: reason)),
            ScanVerdict.none,
            reason: reason);
      }
      for (final o in const [
        PhotoOutcome(PhotoOutcomeKind.alreadyTracked, 'already logged'),
        PhotoOutcome(PhotoOutcomeKind.duplicate, 'duplicate'),
        PhotoOutcome(PhotoOutcomeKind.skipped, 'glasses off',
            reason: glassesExcludedReason),
      ]) {
        expect(scanVerdictOf(o), ScanVerdict.none, reason: o.message);
      }
    });
  });

  group('the real pipeline', () {
    late FakeDao dao;
    late FakeAnalyzer analyzer;
    late List<String> events;

    PhotoPipeline pipeline(
            {AutoScanLatch? latch,
            AiSendGate? gate,
            bool Function()? backgrounded,
            void Function(IntakePhoto)? sending}) =>
        PhotoPipeline(
            dao: dao,
            analyzer: analyzer,
            hasher: (_) async => 'hash-7',
            thumbnailer: (_) async => null,
            latch: latch,
            sendGate: gate,
            backgrounded: backgrounded,
            scanReports: PhotoTurnReports(
                sending: sending ??
                    (p) => events.add('checking ${p.assetId}'),
                ended: (p, o) => events
                    .add('${scanVerdictOf(o).name} ${o.errorKind.name}')));

    setUp(() {
      dao = FakeDao();
      events = [];
      analyzer = FakeAnalyzer()
        ..onAnalyze = () async => events.add('sent');
    });

    test('says a photo is being checked once, as it is sent, and its '
        'verdict after', () async {
      analyzer.nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': false}, isFood: false, wall: Duration.zero);
      await pipeline().process(_photo());
      expect(events, ['checking asset7', 'sent', 'checked none'],
          reason: 'not food: a photo checked, and no error');
    });

    test('says nothing for a photo it does not send: logged before, held '
        'by another run, the app in the background, the consent, the latch',
        () async {
      dao.ledger['hash-7'] = IngestionStatus.skipped;
      await pipeline().process(_photo());
      expect(events, ['none none']);

      events.clear();
      dao.ledger['hash-7'] = IngestionStatus.processing;
      await pipeline().process(_photo());
      expect(events, ['waiting none']);

      events.clear();
      dao.ledger.clear();
      await pipeline(backgrounded: () => true).process(_photo());
      await pipeline(gate: AiSendGate(allowed: () => false)).process(_photo());
      await pipeline(
              latch: AutoScanLatch(
                  blockedKind: () => AnalysisErrorKind.rejectedKey,
                  revision: () => 1,
                  block: (_, _) async {},
                  clear: () async {}))
          .process(_photo());
      expect(events, ['none unknown', 'none unknown', 'none rejectedKey']);
      expect(dao.ledger, isEmpty);
    });

    test('the analyzers\' own failure lines: unreachable, busy and '
        'rate-limited leave the photo waiting; a quota pause and a rejected '
        'key do not; an unreadable photo is a failure kept', () async {
      Future<String> verdictFor(String error, {bool retryable = true}) async {
        events.clear();
        dao.ledger.clear();
        analyzer.nextPhotoOutcome = AnalysisOutcome(
            error: error, retryable: retryable, wall: Duration.zero);
        await pipeline(
                latch: AutoScanLatch(
                    blockedKind: () => null,
                    revision: () => 1,
                    block: (_, _) async {},
                    clear: () async {}))
            .process(_photo());
        return events.last;
      }

      expect(
          await verdictFor(
              'Error contacting the provider (network or service issue).'),
          'waiting network');
      expect(
          await verdictFor('The server cannot analyze right now: Claude is '
              'busy with another analysis.'),
          'waiting serverBusy');
      expect(
          await verdictFor('The server cannot analyze right now: the plan '
              'has no usage window open.'),
          'waiting serverError');
      expect(
          await verdictFor('Provider rate/spend limit hit — will retry '
              'later.'),
          'waiting rateLimited');
      expect(await verdictFor('Analysis paused (quota) — retrying later.'),
          'none quotaPaused');
      expect(
          await verdictFor('The provider rejected the API key. Check '
              'Settings.', retryable: false),
          'none rejectedKey',
          reason: 'released and latched: Settings says the scan is paused');
      expect(
          await verdictFor(
              'Could not process this photo (decode failed and it is not a '
              'JPEG).',
              retryable: false),
          'checked badPhoto');
    });

    test('a deliberate photo is reported like any other, and a listener '
        'that throws changes nothing', () async {
      analyzer.nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true, 'meal_description': 'Soup'},
          isFood: true,
          wall: Duration.zero);
      final outcome = await pipeline(
              sending: (_) => throw StateError('listener'))
          .process(_photo(deliberate: true));
      expect(outcome.kind, PhotoOutcomeKind.saved);
      expect(events, ['sent', 'checked none']);

      final throwing = PhotoPipeline(
          dao: FakeDao(),
          analyzer: analyzer,
          hasher: (_) async => 'hash-8',
          thumbnailer: (_) async => null,
          scanReports: PhotoTurnReports(
              sending: (_) {},
              ended: (_, _) => throw StateError('listener')));
      expect((await throwing.process(_photo())).kind, PhotoOutcomeKind.saved);
    });
  });

  group('scanStatusReports (what the app engine tells the row)', () {
    const saved = PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged');
    const unreachable = PhotoOutcome(PhotoOutcomeKind.failed, 'unreachable',
        retryable: true, errorKind: AnalysisErrorKind.network);

    test('an automatic photo is counted: checking as it is sent, then its '
        'verdict, with the reason of one let go', () {
      final status = PhotoScanStatus();
      final reports = scanStatusReports(status);
      final scan = status.begin(expected: ['asset7']);
      reports.sending(_photo());
      expect(status.phase, PhotoScanPhase.checking);
      reports.ended(_photo(), unreachable);
      scan.end();
      expect(status.phase, PhotoScanPhase.waiting);
      expect(status.waitingCount, 1);
      expect(status.waitingKind, AnalysisErrorKind.network);
    });

    test('a deliberate photo is not counted, and one that got a verdict '
        'settles the same library photo if it was waiting', () {
      final status = PhotoScanStatus();
      final reports = scanStatusReports(status);
      // Picked in the add flow while nothing is being scanned.
      reports.sending(_photo(deliberate: true));
      expect(status.phase, PhotoScanPhase.idle);
      reports.ended(_photo(deliberate: true), saved);
      expect(status.phase, PhotoScanPhase.idle);
      expect(status.checkedCount, 0);

      // The scan let asset7 go; the user then picks it.
      reports.ended(_photo(), unreachable);
      expect(status.waitingCount, 1);
      // A pick that fails the same way settles nothing.
      reports.ended(_photo(deliberate: true), unreachable);
      expect(status.waitingCount, 1);
      reports.ended(_photo(deliberate: true), saved);
      expect(status.waitingCount, 0);
      expect(status.phase, PhotoScanPhase.idle);
    });
  });
}
