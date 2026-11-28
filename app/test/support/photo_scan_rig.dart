/// The app engine's automatic photo path, as ui/di.dart wires it, on fakes:
/// the real LibraryPhotoIntake over a fake photo library, bound to the real
/// PhotoPipeline over the in-memory ledger, both reporting to one
/// PhotoScanStatus (Today's "Checking photos" row).
///
/// For the tests of that row's facts: what the row is told, in which order
/// photos reach the model, and what the ledger answers for a photo offered
/// twice.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:calorie_tracker/services/photo/scan_status.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary;
import '../ui/fakes.dart';

/// A model reply: a meal of [kcal] called [name].
AnalysisOutcome foodReply(String name, num kcal) => AnalysisOutcome(
      analysis: {
        'is_food': true,
        'meal_description': name,
        'total_calories': kcal,
        'total_protein_g': 20,
        'total_carbs_g': 50,
        'total_fat_g': 10,
        'food_items': [
          {'name': name, 'estimated_calories': kcal},
        ],
      },
      isFood: true,
      wall: Duration.zero,
    );

/// A model reply: no food in the photo.
const AnalysisOutcome notFoodReply = AnalysisOutcome(
    analysis: {'is_food': false}, isFood: false, wall: Duration.zero);

/// The own server answered "busy" through every retry (ServerAnalyzer's
/// line for a 503 with retry:true, whose reason is the server's).
const AnalysisOutcome serverBusyReply = AnalysisOutcome(
    error: 'The server cannot analyze right now: Claude is busy with another '
        'analysis.',
    retryable: true,
    wall: Duration.zero);

/// Nothing could be reached (the analyzers' line for a transient failure).
const AnalysisOutcome unreachableReply = AnalysisOutcome(
    error: 'Error contacting the provider (network or service issue).',
    retryable: true,
    wall: Duration.zero);

/// A model reply: the remains of the meal at [index] of the recent meals
/// it was shown, [left] of it uneaten.
AnalysisOutcome leftoverReply({int index = 0, double left = 0.5}) =>
    AnalysisOutcome(
      analysis: {
        'is_food': true,
        'leftover_of': index,
        'confidence': 0.95,
        'leftover_fraction': left,
        'note': 'the same plate, half left',
      },
      isFood: true,
      wall: Duration.zero,
    );

/// Answers each photo by its first byte ([script]); one with no entry is
/// not food. Records what was sent, in order, and the recent meals each
/// photo was sent with.
class ScriptedAnalyzer extends FakeAnalyzer {
  final Map<int,
          AnalysisOutcome Function(List<Map<String, dynamic>> recentMeals)>
      script = {};

  /// The first byte of each photo sent, in order.
  final List<int> sent = [];

  /// The recent meals (their descriptions) each photo was sent with.
  final Map<int, List<String>> recentSeen = {};

  /// Awaited inside each send, before it answers.
  Future<void> Function(int photo)? onSend;

  @override
  Future<AnalysisOutcome> analyzePhoto(Uint8List originalBytes,
      {List<Map<String, dynamic>>? recentMeals}) async {
    final n = originalBytes.first;
    final recent = recentMeals ?? const <Map<String, dynamic>>[];
    sent.add(n);
    recentSeen[n] = [for (final m in recent) '${m['meal_description']}'];
    await onSend?.call(n);
    return (script[n] ?? (_) => notFoodReply)(recent);
  }
}

/// What the row would show, as one line.
String shownOf(PhotoScanStatus s) => switch (s.phase) {
      PhotoScanPhase.idle => 'idle',
      PhotoScanPhase.checking => 'checking ${s.current}/${s.total}',
      PhotoScanPhase.waiting => 'waiting ${s.waitingCount}'
          '${s.waitingKind == null ? '' : ' ${s.waitingKind!.name}'}',
    };

class PhotoScanRig {
  /// [checkedThrough]: the watermark the estimate compares with (null:
  /// none stored). [lateImports]: a change-history cursor, for the
  /// late-import pass. [dao]: an earlier session's ledger and meals.
  PhotoScanRig(
      {this.lookbackDays = 3,
      DateTime Function()? clock,
      DateTime? Function()? checkedThrough,
      LateImportCursor? lateImports,
      FakeDao? dao,
      ScriptedAnalyzer? analyzer,
      FakePhotoLibrary? library})
      : dao = dao ?? FakeDao(),
        analyzer = analyzer ?? ScriptedAnalyzer(),
        library = library ?? FakePhotoLibrary() {
    status.addListener(() => row.add(shownOf(status)));
    intake = LibraryPhotoIntake(
        lookbackDays: () => lookbackDays,
        library: this.library,
        clock: clock ?? DateTime.now,
        lateImports: lateImports,
        loggedAssetIds: this.dao.loggedAssetIds,
        scanStatus: status,
        checkedThrough: checkedThrough);
    // As AppServices.init hands the status to the pipeline.
    pipeline = PhotoPipeline(
        dao: this.dao,
        analyzer: this.analyzer,
        hasher: (bytes) async => 'hash-${bytes.first}',
        thumbnailer: (_) async => null,
        scanReports: scanStatusReports(status),
        onOutcome: (photo, o) => outcomes.add((photo.assetId, o)));
    pipeline.bind(intake);
  }

  final int lookbackDays;
  final FakePhotoLibrary library;
  final FakeDao dao;
  final ScriptedAnalyzer analyzer;
  final PhotoScanStatus status = PhotoScanStatus();
  late final LibraryPhotoIntake intake;
  late final PhotoPipeline pipeline;

  /// Every change of what the row shows, in order.
  final List<String> row = [];

  /// Every verdict the pipeline reached, in order: (asset id, outcome).
  final List<(String, PhotoOutcome)> outcomes = [];

  /// The ids of the photos the pipeline was handed, in order.
  List<String> get offered => [for (final (id, _) in outcomes) id];

  /// A photo taken at [at], numbered [n] (its bytes, so its ledger hash).
  FakeAsset photo(String id, int n, DateTime at) => FakeAsset(
      id, 'IMG_$id.HEIC', at, Uint8List.fromList([n, 0, 0]),
      onRead: () => _read(id));

  /// The ids of the originals read, in order.
  final List<String> reads = [];

  /// What the row showed as each original was read, in order.
  final List<String> rowAtRead = [];

  void _read(String id) {
    reads.add(id);
    rowAtRead.add(shownOf(status));
  }

  /// The app's catch-up scan (foregroundCatchUp asks for the newest day
  /// first, with a checkpoint for each covered photo).
  Future<DateTime?> catchUp(
          {bool Function()? shouldContinue,
          Future<void> Function(DateTime safeFrontier)? onCovered}) =>
      intake.backfillScan(
          newestDayFirst: true,
          shouldContinue: shouldContinue,
          onCovered: onCovered);
}

/// Yesterday at [hour]:[minute], local: always in the past, whenever the
/// test runs, and inside every meal-dating window.
DateTime yesterdayAt(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - 1, hour, minute);
}

/// Two days ago at [hour]:[minute], local.
DateTime twoDaysAgoAt(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - 2, hour, minute);
}
