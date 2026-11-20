// Photo Coverage under each platform's 'Meta glasses photos' default (owner
// decision 8: off on Android until the user turns it on), with the real
// settings, intake, pipeline and auditor over real SQLite.
//
// Switched off, automatic intake lets a glasses photo go before hashing
// it, with no ledger row on purpose (turning the switch on lets the
// look-back pick it up). The audit read only the ledger, so it called
// every such photo "never scanned", never covered the window, and its Log
// all sent them to the AI as deliberate photos: unchecked, non-food ones
// included (review of #72).
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ui/fakes.dart' show FakeAnalyzer;
import 'watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Friday 2026-11-20, 19:30 local.
  final now = DateTime(2026, 11, 20, 19, 30);
  late Database db;
  late SqfliteMealsDao dao;
  late FakePhotoLibrary library;
  late FakeAnalyzer analyzer;
  late int analyses;
  late AppSettings settings;

  setUp(() async {
    db = await openAppDatabase(path: inMemoryDatabasePath);
    dao = SqfliteMealsDao(db, clock: () => now);
    library = FakePhotoLibrary();
    analyses = 0;
    analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {
            'is_food': true,
            'meal_description': 'Tonkotsu ramen',
            'total_calories': 720,
          },
          isFood: true,
          wall: Duration.zero)
      ..onAnalyze = () async => analyses++;
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await db.close();
  });

  /// A fresh install's (or an upgrade's: the switch was never touched)
  /// settings on [platform].
  Future<void> install(TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(), keyStore: _Keys());
  }

  /// The launch catch-up over the look-back window, with the switch wired
  /// as di.dart wires it.
  Future<void> catchUp() async {
    final intake = LibraryPhotoIntake(
        lookbackDays: () => 2, library: library, clock: () => now);
    PhotoPipeline(
            dao: dao,
            analyzer: analyzer,
            hasher: (b) async => originalBytesMd5(b),
            thumbnailer: (_) async => null,
            clock: () => now,
            includeGlasses: () => settings.watchGlasses)
        .bind(intake);
    await intake.backfillScan();
  }

  /// Photo Coverage, wired as di.dart wires it.
  Future<CoverageReport> check() => CoverageAuditor(
          library: library,
          dao: dao,
          hasher: (b) async => originalBytesMd5(b),
          clock: () => now,
          includeGlasses: () => settings.watchGlasses)
      .audit(lookbackDays: 2);

  /// A photo the Meta AI app imported from the glasses at lunch.
  FakeAsset glassesLunch() {
    final a = FakeAsset('1000000042', 'photo-42_singular_display_fullPicture.HEIC',
        DateTime(2026, 11, 20, 12, 10), bytesOf(42, 64));
    library.assets.add(a);
    return a;
  }

  test('Android: the scan leaves a glasses photo alone, and the check '
      'neither calls it never scanned nor offers it to Log all', () async {
    await install(TargetPlatform.android);
    expect(settings.watchGlasses, isFalse);
    final photo = glassesLunch();
    await catchUp();
    expect(analyses, 0, reason: 'nothing went to the AI');
    expect(await dao.photoStatus(originalBytesMd5(photo.bytes!)), isNull,
        reason: 'no ledger row, so the switch can still bring it in');

    final report = await check();
    expect(report.missing, isEmpty,
        reason: 'Log all sends every "never scanned" photo to the AI');
    expect(report.glassesOff.single.assetId, photo.id);
    expect(report.logged, isEmpty);
    expect(report.fullyCovered, isTrue);
  });

  test('Android, the switch turned on: the next catch-up logs it, and the '
      'check counts it logged', () async {
    await install(TargetPlatform.android);
    final photo = glassesLunch();
    await catchUp();
    await settings.setWatchGlasses(true);
    await catchUp();
    expect(analyses, 1);

    final report = await check();
    expect(report.logged.single.assetId, photo.id);
    expect(report.glassesOff, isEmpty);
    expect(report.missing, isEmpty);
  });

  test('iPhone (on by default): logged, as before', () async {
    await install(TargetPlatform.iOS);
    expect(settings.watchGlasses, isTrue);
    final photo = glassesLunch();
    await catchUp();
    expect(analyses, 1);

    final report = await check();
    expect(report.logged.single.assetId, photo.id);
    expect(report.glassesOff, isEmpty);
    expect(report.fullyCovered, isTrue);
  });
}
