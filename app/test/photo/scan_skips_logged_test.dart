// The iOS background run's scan counts a photo a meal already names covered
// WITHOUT reading it (LibraryPhotoIntake.scanSkipsLogged, 2026-11-28).
//
// That run starts an hour behind its watermark, so each one read and hashed
// the photos it had logged last time again before it reached a new one, out
// of the 15 s in which it may start a photo. These tests hold the rule that
// makes the skip safe: only a photo a meal names is skipped, and the
// frontier (so the watermark) ends exactly where it would have with every
// photo read.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:flutter_test/flutter_test.dart';

class _Asset implements LibraryAsset {
  _Asset(this.id, this.createDateTime, this._reads);
  @override
  final String id;
  @override
  final DateTime createDateTime;
  final List<String> _reads;

  @override
  Future<String> fileName() async => '$id.HEIC';

  @override
  Future<Uint8List?> originBytes() async {
    _reads.add(id);
    return Uint8List.fromList(id.codeUnits);
  }
}

class _Library implements PhotoLibrary {
  final List<_Asset> assets = [];

  /// The ids whose original was read, in order.
  final List<String> reads = [];

  void add(String id, DateTime created) =>
      assets.add(_Asset(id, created, reads));

  @override
  Future<List<LibraryAsset>> imagesCreatedAfter(
    DateTime cutoff, {
    int limit = 500,
  }) async => [
    for (final a in assets)
      if (!a.createDateTime.isBefore(cutoff)) a,
  ];

  @override
  Future<bool> hasFullAccess() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<Uint8List?> thumbnailByAssetId(
    String assetId, {
    int size = 160,
  }) async => null;
  @override
  Future<Uint8List?> originBytesByAssetId(String assetId) async => null;
  @override
  Future<List<LibraryAsset>> recentImages(int limit) async => const [];
  @override
  Future<Map<String, LibraryAsset?>> imagesByIds(List<String> ids) async =>
      const {};
  @override
  Future<void> startChangeNotify(void Function() onChange) async {}
  @override
  Future<void> stopChangeNotify() async {}
}

void main() {
  final now = DateTime(2026, 11, 27, 22, 24);
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(2026, 11, 27, hour, minute);

  late _Library library;

  /// The ids a meal names, and every question asked about them.
  late Set<String> meals;
  late List<List<String>> asked;

  /// What the sink was handed, with the safeFrontier of each.
  late List<(String, DateTime?)> offered;

  /// Ids the sink releases (a retryable verdict).
  late Set<String> releases;

  /// What the run's record would hear.
  late List<int> skipped;

  setUp(() {
    library = _Library();
    meals = {};
    asked = [];
    offered = [];
    releases = {};
    skipped = [];
  });

  LibraryPhotoIntake intake({
    bool skips = true,
    Future<Set<String>> Function(List<String> ids)? lookup,
    bool noLookup = false,
    Duration? timeout,
  }) {
    final it = LibraryPhotoIntake(
      lookbackDays: () => 2,
      library: library,
      clock: () => now,
      scanSkipsLogged: skips,
      loggedAssetIds: noLookup
          ? null
          : (ids) {
              asked.add(List.of(ids));
              return (lookup ?? (ids) async => meals.intersection(ids.toSet()))(
                ids,
              );
            },
      onScanSkippedLogged: skipped.add,
      loggedTimeout: timeout ?? loggedLookupTimeout,
    );
    it.attachSink((photo, safeFrontier) async {
      offered.add((photo.assetId, safeFrontier));
      return !releases.contains(photo.assetId);
    });
    return it;
  }

  group('a photo a meal already names', () {
    test('is not read: only the new photo is, and the frontier still covers '
        'both', () async {
      library
        ..add('lunch', at(12))
        ..add('dinner', at(19));
      meals = {'lunch'};
      final frontier = await intake().backfillScan();
      expect(library.reads, ['dinner'], reason: 'lunch is logged: no read');
      expect(offered, [('dinner', at(19))]);
      expect(frontier, at(19));
      expect(asked, [
        ['lunch', 'dinner'],
      ], reason: 'one question for the whole scan');
      expect(skipped, [1]);
    });

    test('with nothing new, nothing is read at all, and the frontier is the '
        'newest of them', () async {
      library
        ..add('breakfast', at(8))
        ..add('lunch', at(12));
      meals = {'breakfast', 'lunch'};
      final frontier = await intake().backfillScan(since: at(7));
      expect(library.reads, isEmpty);
      expect(offered, isEmpty);
      expect(frontier, at(12));
      expect(skipped, [2]);
    });

    // The watermark must end where it would have with every photo read:
    // the reservation answers "already logged" for these, a terminal
    // verdict, so reading them covers them too.
    test('the frontier and every safeFrontier are the ones a scan that '
        'reads them reaches', () async {
      void fill() => library
        ..add('a', at(8))
        ..add('new1', at(9))
        ..add('b', at(12))
        ..add('new2', at(13))
        ..add('c', at(19));
      meals = {'a', 'b', 'c'};
      fill();
      final withSkip = await intake().backfillScan();
      final skipOffers = [
        for (final o in offered)
          if (!meals.contains(o.$1)) o,
      ];
      final readsWithSkip = List.of(library.reads);

      library = _Library();
      offered = [];
      fill();
      final withoutSkip = await intake(skips: false).backfillScan();
      final plainOffers = [
        for (final o in offered)
          if (!meals.contains(o.$1)) o,
      ];
      expect(withSkip, withoutSkip);
      expect(withSkip, at(19));
      expect(skipOffers, plainOffers);
      expect(skipOffers, [('new1', at(9)), ('new2', at(13))]);
      expect(readsWithSkip, ['new1', 'new2']);
      expect(library.reads, ['a', 'new1', 'b', 'new2', 'c']);
    });

    test(
      'never carries the frontier past a photo that still needs a retry',
      () async {
        library
          ..add('logged1', at(8))
          ..add('released', at(9))
          ..add('logged2', at(12))
          ..add('new', at(13));
        meals = {'logged1', 'logged2'};
        releases = {'released'};
        final frontier = await intake().backfillScan();
        expect(frontier, at(8), reason: 'it halts in front of the release');
        expect(offered, [
          ('released', at(9)),
          // Behind the release: the last frontier that is safe, never its own.
          ('new', at(8)),
        ]);
        expect(library.reads, ['released', 'new']);
      },
    );

    test(
      'costs none of the time budget: it is covered even once the budget '
      'is spent, and the budget is asked only about photos to read',
      () async {
        library
          ..add('logged', at(12))
          ..add('new', at(13));
        meals = {'logged'};
        var budgetAsked = 0;
        final frontier = await intake().backfillScan(
          shouldContinue: () {
            budgetAsked++;
            return false;
          },
        );
        expect(library.reads, isEmpty);
        expect(frontier, at(12), reason: 'covered; the new photo is not');
        expect(budgetAsked, 1, reason: 'asked for the new photo only');
      },
    );

    test('is asked about once and counted once, whatever the passes '
        '(newest day first)', () async {
      library
        ..add('yesterday', DateTime(2026, 11, 26, 20))
        ..add('lunch', at(12))
        ..add('dinner', at(19));
      meals = {'yesterday', 'lunch'};
      final frontier = await intake().backfillScan(newestDayFirst: true);
      expect(library.reads, ['dinner']);
      expect(frontier, at(19));
      expect(
        asked.expand((ids) => ids).toList()..sort(),
        ['dinner', 'lunch', 'yesterday'],
        reason: 'each id asked about once: $asked',
      );
      expect(skipped.fold<int>(0, (a, b) => a + b), 2);
    });

    test('is not marked seen: nothing is remembered that the meals table '
        'does not say', () async {
      library.add('lunch', at(12));
      meals = {'lunch'};
      final it = intake();
      await it.backfillScan();
      // The meal is deleted; the next scan of the same intake reads the
      // photo, and the ledger (its 'deleted' row) answers.
      meals = {};
      await it.backfillScan();
      expect(library.reads, ['lunch']);
      expect(offered, [('lunch', at(12))]);
    });
  });

  group('nothing is skipped that a meal does not name', () {
    test('a lookup that throws: every photo is read, as before', () async {
      library
        ..add('lunch', at(12))
        ..add('dinner', at(19));
      final frontier = await intake(
        lookup: (_) async => throw StateError('database is locked'),
      ).backfillScan();
      expect(library.reads, ['lunch', 'dinner']);
      expect(frontier, at(19));
      expect(skipped, isEmpty);
    });

    test('a lookup that never answers is given up on, and every photo is '
        'read', () async {
      library
        ..add('lunch', at(12))
        ..add('dinner', at(19));
      final frontier = await intake(
        lookup: (_) => Completer<Set<String>>().future,
        timeout: const Duration(milliseconds: 20),
      ).backfillScan();
      expect(library.reads, ['lunch', 'dinner']);
      expect(frontier, at(19));
    });

    test('ids the lookup names that the scan did not ask about change '
        'nothing; an empty answer reads everything', () async {
      library
        ..add('lunch', at(12))
        ..add('dinner', at(19));
      await intake(lookup: (_) async => {'someone-else'}).backfillScan();
      expect(library.reads, ['lunch', 'dinner']);
      expect(skipped, isEmpty);
    });

    test('no lookup at all (nothing known): everything is read', () async {
      library.add('lunch', at(12));
      await intake(noLookup: true).backfillScan();
      expect(library.reads, ['lunch']);
    });
  });

  // The app's own engine, and Android's background run.
  group('switched off (the default)', () {
    test('a photo a meal names is read like any other, and the meals are '
        'not even asked', () async {
      library
        ..add('lunch', at(12))
        ..add('dinner', at(19));
      meals = {'lunch'};
      final frontier = await intake(skips: false).backfillScan();
      expect(library.reads, ['lunch', 'dinner']);
      expect(offered.map((o) => o.$1), ['lunch', 'dinner']);
      expect(frontier, at(19));
      expect(asked, isEmpty);
      expect(skipped, isEmpty);
    });

    test('an intake built without the argument does not skip', () {
      expect(
        LibraryPhotoIntake(
          lookbackDays: () => 2,
          library: library,
        ).scanSkipsLogged,
        isFalse,
      );
    });
  });

  test(
    'a photo this session already handled is not asked about again',
    () async {
      library.add('lunch', at(12));
      final it = intake();
      await it.backfillScan(); // read and delivered: seen from now on
      library.add('dinner', at(19));
      await it.backfillScan();
      expect(asked, [
        ['lunch'],
        ['dinner'],
      ]);
      expect(library.reads, ['lunch', 'dinner']);
    },
  );
}
