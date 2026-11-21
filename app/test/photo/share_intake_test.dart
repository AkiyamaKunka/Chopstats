// Deliberate intake (spec §6, §2.3): share-sheet stream + pickFromRecent,
// all deliberate=true; §6.1 extension filter; §8 25 MB cap.
import 'dart:async';
import 'dart:convert' show base64Decode, jsonEncode;
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/analyzer/normalize.dart'
    show normalizeForAnalysis;
import 'package:calorie_tracker/services/analyzer/platform_decode.dart'
    show looksLikeJpeg;
import 'package:calorie_tracker/services/backup/file_pick_channel.dart'
    show filesChannelName;
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/share_intake.dart';
import 'package:calorie_tracker/ui/ai_consent.dart' show SharedPhotoConsentGate;
import 'package:calorie_tracker/ui/photo_pipeline.dart' show PhotoPipeline;
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../ui/fakes.dart' show FakeAnalyzer, FakeDao, FakeSettings;
import 'watcher_test.dart' show FakeAsset, FakePhotoLibrary;

class FakeShareSource implements SharedMediaSource {
  final StreamController<List<String>> controller =
      StreamController<List<String>>();
  List<String> initial = [];

  @override
  Stream<List<String>> imagePathBatches() => controller.stream;

  @override
  Future<List<String>> initialImagePaths() async => initial;
}

void main() {
  final now = DateTime(2026, 7, 17, 12, 0, 0);
  final files = <String, Uint8List>{};

  Future<Uint8List?> readBytes(String path) async => files[path];

  final cleaned = <String>[];

  ShareIntake build(FakeShareSource source, FakePhotoLibrary library) =>
      ShareIntake(
          source: source,
          library: library,
          readBytes: readBytes,
          cleanup: (path) async => cleaned.add(path),
          clock: () => now);

  setUp(() {
    files.clear();
    cleaned.clear();
  });

  group('share stream', () {
    test('shared image becomes a deliberate IntakePhoto with filename date',
        () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      files['/shared/IMG_20260716_193042.jpg'] =
          Uint8List.fromList([1, 2, 3]);

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add(['/shared/IMG_20260716_193042.jpg']);
      await pumpEventQueue();

      expect(emitted, hasLength(1));
      final photo = emitted.single;
      expect(photo.deliberate, isTrue); // §2.3 deliberate re-send policy
      expect(photo.fileName, 'IMG_20260716_193042.jpg');
      expect(photo.capturedAt, DateTime(2026, 7, 16, 19, 30, 42));
      expect(photo.bytes, [1, 2, 3]);
      // Plugin contract: the container copy is deleted once consumed —
      // without this every shared photo leaks in the app group forever.
      // iOS: as it is read (its share extension reuses file names), so the
      // photo has nothing left to settle.
      expect(cleaned, ['/shared/IMG_20260716_193042.jpg']);
      expect(photo.onSettled, isNull);
      await sub.cancel();
    });

    test('rejected shares (bad extension / oversized) still clean up the copy',
        () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      files['/shared/notes.txt'] = Uint8List.fromList([1]);
      files['/shared/IMG_big.jpg'] =
          Uint8List.fromList(List.filled(maxPhotoBytes + 1, 0));

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add(['/shared/notes.txt', '/shared/IMG_big.jpg']);
      await pumpEventQueue();

      expect(emitted, isEmpty);
      expect(cleaned,
          containsAll(['/shared/notes.txt', '/shared/IMG_big.jpg']));
      await sub.cancel();
    });

    test('cold-start (initial) share is delivered first', () async {
      final source = FakeShareSource()
        ..initial = ['/shared/launch_meal.png'];
      files['/shared/launch_meal.png'] = Uint8List.fromList([9]);
      final intake = build(source, FakePhotoLibrary());

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      await pumpEventQueue();
      expect(emitted.map((p) => p.fileName), ['launch_meal.png']);
      // No filename timestamp and no asset date → capturedAt null (§6.3
      // fallback: intake-time dating happens downstream).
      expect(emitted.single.capturedAt, isNull);
      await sub.cancel();
    });

    test('unsupported extensions and unreadable/oversized files are skipped',
        () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      files['/shared/notes.txt'] = Uint8List.fromList([1]);
      files['/shared/huge.jpg'] = Uint8List(maxPhotoBytes + 1);
      // '/shared/gone.jpg' unreadable: not in the map.
      files['/shared/ok.HEIC'] = Uint8List.fromList([5]); // case-insensitive

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add([
        '/shared/notes.txt',
        '/shared/huge.jpg',
        '/shared/gone.jpg',
        '/shared/ok.HEIC',
      ]);
      await pumpEventQueue();
      expect(emitted.map((p) => p.fileName), ['ok.HEIC']);
      await sub.cancel();
    });
  });

  // Review 171, C5: on Android the plugin hands over whatever path it
  // made of the share — a sender-chosen name could climb out of the cache,
  // and a share with no stream handed over its text — and the intake read
  // it when it looked like a photo, then deleted it in every case. Only
  // MainActivity's own copies may be read or deleted there.
  group('Android: only the share folder\'s copies are read or deleted', () {
    late Directory app; // stands in for the app's private data directory
    late String folder;

    setUp(() {
      app = Directory.systemTemp.createTempSync('share_c5_');
      folder = '${app.path}/cache/$androidShareFolderName';
      Directory('$folder/1').createSync(recursive: true);
    });
    tearDown(() => app.deleteSync(recursive: true));

    File appFile(String relative, List<int> bytes) =>
        File('${app.path}/$relative')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);

    test('a path outside the folder is left alone; the copy inside is read, '
        'and deleted once its photo is settled', () async {
      final db = appFile('databases/calorie_tracker.db', [1, 2, 3]);
      final prefs =
          appFile('shared_prefs/FlutterSharedPreferences.xml', [4]);
      final private = appFile('files/private.jpg', [5]);
      final copy = File('$folder/1/IMG_20260716_193042.jpg')
        ..writeAsBytesSync([7, 7]);
      final source = FakeShareSource()
        ..initial = [
          db.path, // a share with no stream: its text became the path
          '$folder/1/../../../shared_prefs/FlutterSharedPreferences.xml',
          '$folder/1/../../../files/private.jpg',
          copy.path,
        ];
      final read = <String>[];
      final intake = ShareIntake(
          source: source,
          library: FakePhotoLibrary(),
          readBytes: (path) async {
            read.add(path);
            return File(path).readAsBytes();
          },
          // The production cleanup: a real delete.
          sharedFolder: () async => folder,
          clock: () => now);

      final photo = await intake.photos().first;
      expect(photo.fileName, 'IMG_20260716_193042.jpg');
      expect(read, [copy.path]);
      expect(copy.existsSync(), isTrue,
          reason: 'kept until the photo is settled (Q1, Q9)');
      photo.onSettled!();
      expect(copy.existsSync(), isFalse, reason: 'deleted once settled');
      expect(db.existsSync(), isTrue);
      expect(prefs.existsSync(), isTrue);
      expect(private.existsSync(), isTrue);
    });

    test('a folder that cannot be found reads and deletes nothing',
        () async {
      final copy = File('$folder/1/IMG_1.jpg')..writeAsBytesSync([7]);
      final source = FakeShareSource()..initial = [copy.path];
      final read = <String>[];
      final intake = ShareIntake(
          source: source,
          library: FakePhotoLibrary(),
          readBytes: (path) async {
            read.add(path);
            return File(path).readAsBytes();
          },
          cleanup: (path) async => cleaned.add(path),
          sharedFolder: () async => throw const FileSystemException('none'),
          clock: () => now);

      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      await pumpEventQueue();
      expect(emitted, isEmpty);
      expect(read, isEmpty);
      expect(cleaned, isEmpty);
      await sub.cancel();
    });

    test('isWithinFolder resolves . and .. and never matches a sibling',
        () {
      const f = '/data/user/0/app/cache/shared_photos';
      expect(isWithinFolder('$f/123/a.jpg', f), isTrue);
      expect(isWithinFolder('$f/./123/a.jpg', f), isTrue);
      expect(isWithinFolder('$f/123/../456/a.jpg', f), isTrue);
      expect(isWithinFolder(f, f), isFalse);
      expect(isWithinFolder('$f/..', f), isFalse);
      expect(isWithinFolder('$f/../../databases/x.db', f), isFalse);
      expect(isWithinFolder('${f}_x/a.jpg', f), isFalse);
      expect(isWithinFolder('/data/user/0/app/cache/a.jpg', f), isFalse);
      expect(isWithinFolder('shared_photos/a.jpg', f), isFalse);
      expect(isWithinFolder('/../$f/a.jpg', f), isFalse);
    });

    // The Kotlin side copies into this folder and refuses what Dart would
    // refuse by size, before the plugin sees the launch intent (read while
    // super.onCreate attaches it) or a later one.
    test('MainActivity.kt copies into the same folder, under the same cap, '
        'before the plugin sees any intent', () {
      final kotlin = File('android/app/src/main/kotlin/dev/calorietracker/'
              'calorie_tracker/MainActivity.kt')
          .readAsStringSync();
      expect(kotlin,
          contains('const val SHARE_FOLDER = "$androidShareFolderName"'));
      expect(maxPhotoBytes, 25 * 1024 * 1024);
      expect(kotlin, contains('const val MAX_SHARE_BYTES = 25L * 1024 * 1024'));
      final create = RegExp(r'override fun onCreate\(.*?\n    \}', dotAll: true)
          .firstMatch(kotlin)
          ?.group(0);
      expect(create, isNotNull);
      final copy = create!.indexOf('setIntent(withSafeShares(it))');
      expect(copy, greaterThanOrEqualTo(0));
      expect(create.indexOf('super.onCreate('), greaterThan(copy));
      final renewed =
          RegExp(r'override fun onNewIntent\(.*?\n    \}', dotAll: true)
              .firstMatch(kotlin)
              ?.group(0);
      expect(renewed, isNotNull);
      final safe = renewed!.indexOf('val safe = withSafeShares(intent)');
      expect(safe, greaterThanOrEqualTo(0));
      expect(renewed.indexOf('super.onNewIntent(safe)'), greaterThan(safe));
    });

    // The word share intake sends once it listens (R0, below) is the one
    // MainActivity answers, on the channel it serves.
    test('MainActivity.kt answers shareIntakeReady on the files channel', () {
      final kotlin = File('android/app/src/main/kotlin/dev/calorietracker/'
              'calorie_tracker/MainActivity.kt')
          .readAsStringSync();
      expect(kotlin, contains('const val FILES_CHANNEL = "$filesChannelName"'));
      expect(kotlin,
          contains('"$shareIntakeReadyMethod" -> result.success(releaseHeldShares())'));
      final factory = File('lib/services/photo/share_intake.dart')
          .readAsStringSync()
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(
          factory,
          contains('listening: Platform.isAndroid ? androidShareIntakeReady '
              ': null,'),
          reason: 'createShareIntake tells MainActivity on Android only');
    });

    // The same folder from the Dart side: the share folder in
    // path_provider's temporary directory, which on Android is the app's
    // cache directory (path_provider_android answers getTemporaryPath with
    // Context.getCacheDir), the cacheDir MainActivity copies into. Were
    // either side to move, every Android share would be refused.
    test('androidSharedPhotoFolder is the share folder in the cache '
        'directory MainActivity copies into', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const cache = '/data/user/0/dev.calorietracker.calorie_tracker/cache';
      messenger.setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'getTemporaryDirectory' ? cache : null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await androidSharedPhotoFolder(),
          '$cache/$androidShareFolderName');
      final kotlin = File('android/app/src/main/kotlin/dev/calorietracker/'
              'calorie_tracker/MainActivity.kt')
          .readAsStringSync();
      expect(kotlin,
          contains('File(File(cacheDir, SHARE_FOLDER), UUID.randomUUID()'));
    });

    // Review 171, C6: a share from the sharesheet while the app runs must
    // reach that running engine (onNewIntent, then the plugin's live stream
    // this intake listens to) rather than start a second MainActivity with
    // its own engine and services. Checked on the API 35 emulator: singleTop
    // left two MainActivity tasks after a Files › Share › Chopstats.
    test('MainActivity is singleTask and still takes image shares', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final activity =
          RegExp(r'<activity\b[^>]*android:name="\.MainActivity"[^>]*>')
              .firstMatch(manifest)
              ?.group(0);
      expect(activity, isNotNull);
      expect(activity, contains('android:launchMode="singleTask"'));
      for (final action in ['SEND', 'SEND_MULTIPLE']) {
        expect(
            RegExp('<action android:name="android.intent.action.$action"/>'
                    r'\s*<category android:name="android.intent.category.'
                    r'DEFAULT"/>\s*<data android:mimeType="image/\*"/>')
                .hasMatch(manifest),
            isTrue,
            reason: action);
      }
    });
  });

  group('§6.1 extension filter', () {
    // WebP and GIF: what Android browsers and chat apps share, and what
    // MainActivity names a nameless image stream by its MIME type
    // (IMG_<ts>.webp). The engine codec and the image package decode both;
    // iOS ImageIO decodes WebP on iOS 14+ (the app's floor is 15). AVIF
    // stays out: its decoding is unverified on either platform.
    test('accepts jpg/jpeg/png/heic/heif/tiff/webp/gif, rejects the rest',
        () {
      for (final name in [
        'a.jpg', 'a.JPEG', 'a.png', 'a.heic', 'a.HEIF', 'a.tiff', //
        'a.webp', 'IMG_1731500000000.WEBP', 'a.gif', 'a.GIF',
      ]) {
        expect(hasSupportedPhotoExtension(name), isTrue, reason: name);
      }
      for (final name in [
        'a.avif', 'a.mp4', 'a.txt', 'noext', 'a.', 'a.webp.txt', 'a.gifv'
      ]) {
        expect(hasSupportedPhotoExtension(name), isFalse, reason: name);
      }
    });

    test('a shared WebP and a shared GIF reach the pipeline; an AVIF is '
        'still dropped and its copy deleted', () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      files['/shared/IMG_1731500000000.webp'] = Uint8List.fromList([1]);
      files['/shared/lunch.gif'] = Uint8List.fromList([2]);
      files['/shared/scan.avif'] = Uint8List.fromList([3]);
      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add([
        '/shared/IMG_1731500000000.webp',
        '/shared/lunch.gif',
        '/shared/scan.avif',
      ]);
      await pumpEventQueue();
      expect(emitted.map((p) => p.fileName),
          ['IMG_1731500000000.webp', 'lunch.gif']);
      expect(emitted.every((p) => p.deliberate), isTrue);
      expect(cleaned, [
        '/shared/IMG_1731500000000.webp',
        '/shared/lunch.gif',
        '/shared/scan.avif',
      ]);
      await sub.cancel();
    });

    // An accepted type the upload chain cannot decode would fail every
    // share of it: the last resort (pure Dart, normalize.dart) reads both
    // and sends a JPEG, as every provider path labels it.
    test('the pure-Dart decoder turns a WebP and a GIF into the upload JPEG',
        () {
      // A 1x1 lossless WebP.
      final webp = base64Decode(
          'UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==');
      final gif = img.encodeGif(
          img.Image(width: 8, height: 8)..clear(img.ColorRgb8(200, 30, 30)));
      for (final (name, bytes) in [('webp', webp), ('gif', gif)]) {
        final upload = normalizeForAnalysis(bytes);
        expect(upload, isNotNull, reason: name);
        expect(looksLikeJpeg(upload!), isTrue, reason: name);
      }
    });
  });

  group('pickFromRecent', () {
    test('returns deliberate photos, newest first, honoring the limit',
        () async {
      final library = FakePhotoLibrary()
        ..assets = [
          FakeAsset('p1', 'IMG_20260717_080000.jpg',
              DateTime(2026, 7, 17, 8, 0), Uint8List.fromList([1])),
          FakeAsset('p2', 'IMG_20260716_080000.jpg',
              DateTime(2026, 7, 16, 8, 0), Uint8List.fromList([2])),
          FakeAsset('p3', 'IMG_20260715_080000.jpg',
              DateTime(2026, 7, 15, 8, 0), Uint8List.fromList([3])),
        ];
      final intake = build(FakeShareSource(), library);

      final picked = await intake.pickFromRecent(2);
      expect(picked.map((p) => p.assetId), ['p1', 'p2']);
      expect(picked.every((p) => p.deliberate), isTrue); // §2.3 reclaim rule
      expect(picked.first.capturedAt, DateTime(2026, 7, 17, 8, 0, 0));
    });

    test('permission denied → empty result', () async {
      final library = FakePhotoLibrary()..permissionGranted = false;
      final intake = build(FakeShareSource(), library);
      expect(await intake.pickFromRecent(5), isEmpty);
    });

    test('non-positive limit → empty without touching the library', () async {
      final library = FakePhotoLibrary();
      final intake = build(FakeShareSource(), library);
      expect(await intake.pickFromRecent(0), isEmpty);
      expect(library.permissionRequests, 0);
    });
  });

  // Design G2a: a shared or picked photo carries how it was taken, read
  // from its own bytes — the badge works for those too.
  group('capture (G2a)', () {
    test('a shared glasses file: recognized by its name; no asset, so no '
        'creation date and no album', () async {
      final source = FakeShareSource();
      final intake = build(source, FakePhotoLibrary());
      const path = '/shared/photo-77_singular_display_fullPicture.HEIC';
      files[path] = Uint8List.fromList([1, 2, 3]);
      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen(emitted.add);
      source.controller.add([path]);
      await pumpEventQueue();
      final capture = emitted.single.capture!;
      expect(capture.device, CaptureDevice.metaGlasses);
      expect(capture.signal, CaptureSignal.filename);
      expect(capture.createDate, isNull);
      await sub.cancel();
    });

    test('a picked photo keeps its creation date', () async {
      final created = DateTime(2026, 7, 17, 8, 0);
      final library = FakePhotoLibrary()
        ..assets = [
          FakeAsset('p1', 'IMG_1.HEIC', created, Uint8List.fromList([1])),
        ];
      final picked =
          await build(FakeShareSource(), library).pickFromRecent(1);
      expect(picked.single.capture!.createDate, created);
      expect(picked.single.capture!.device, CaptureDevice.unknown);
    });
  });

  // Review 171, C2: a 40-photo SEND_MULTIPLE was read whole before the
  // first photo's analysis ended — every original in the stream's buffer
  // at once (about 160 MB), while the pipeline processes one at a time.
  // The share stream now honours pause, and bindStream pauses it until
  // each photo's turn has ended: one original resident, plus at most one
  // read ahead.
  group('backpressure (C2): one shared original in memory at a time', () {
    late Map<String, Uint8List> held;
    late List<String> reads;

    // Android's intake: copies in the share folder, each with a path of
    // its own, may wait there for their turn.
    ShareIntake counting(FakeShareSource source) => ShareIntake(
        source: source,
        library: FakePhotoLibrary(),
        readBytes: (path) async {
          reads.add(path);
          return held[path];
        },
        cleanup: (path) async => cleaned.add(path),
        sharedFolder: () async => '/shared',
        clock: () => now);

    List<String> share(int n, {String prefix = 'IMG'}) => [
          for (var i = 0; i < n; i++)
            '/shared/${prefix}_$i.jpg',
        ]..forEach((p) => held[p] = Uint8List.fromList([p.hashCode & 0xFF, 1]));

    setUp(() {
      held = {};
      reads = [];
    });

    test('a paused listener stops the reading; resume reads on, in order',
        () async {
      final source = FakeShareSource();
      final paths = share(20);
      final emitted = <String>[];
      late StreamSubscription<IntakePhoto> sub;
      // Each photo's turn ends as it arrives, as the pipeline's would.
      sub = counting(source).photos().listen((p) {
        emitted.add(p.fileName);
        p.onSettled!();
        sub.pause();
      });
      source.controller.add(paths);
      await pumpEventQueue();
      expect(emitted, hasLength(1));
      expect(reads.length, lessThanOrEqualTo(2),
          reason: 'one handed on, at most one read ahead');
      sub.resume();
      await pumpEventQueue();
      expect(emitted, hasLength(2));
      expect(reads.length, lessThanOrEqualTo(3));
      // Keep going without pausing: everything arrives, in order.
      sub.onData((p) {
        emitted.add(p.fileName);
        p.onSettled!();
      });
      sub.resume();
      await pumpEventQueue();
      expect(emitted, [for (final p in paths) fileBaseName(p)]);
      expect(cleaned, paths,
          reason: 'every copy deleted once its photo is settled');
      await sub.cancel();
    });

    test('a batch shared while one is still read waits its turn: the order '
        'is kept and only one reader runs', () async {
      final source = FakeShareSource();
      final first = share(3, prefix: 'A');
      final second = share(3, prefix: 'B');
      final emitted = <String>[];
      late StreamSubscription<IntakePhoto> sub;
      sub = counting(source).photos().listen((p) {
        emitted.add(p.fileName);
        sub.pause();
      });
      source.controller
        ..add(first)
        ..add(second);
      await pumpEventQueue();
      expect(reads.length, lessThanOrEqualTo(2),
          reason: 'not one reader per batch');
      for (var i = 0; i < 6; i++) {
        sub.resume();
        await pumpEventQueue();
      }
      expect(emitted, [for (final p in [...first, ...second]) fileBaseName(p)]);
      await sub.cancel();
    });

    test('a live share is listened for while the launch share is still '
        'held (the plugin drops a share nobody listens for)', () async {
      final source = FakeShareSource()..initial = share(5, prefix: 'L');
      var listened = false;
      source.controller.onListen = () => listened = true;
      late StreamSubscription<IntakePhoto> sub;
      sub = counting(source).photos().listen((_) => sub.pause());
      await pumpEventQueue();
      expect(listened, isTrue);
      await sub.cancel();
    });

    test('a copy whose reading throws is skipped, and the shares after it '
        'still arrive', () async {
      final source = FakeShareSource();
      final paths = share(3);
      final intake = ShareIntake(
          source: source,
          library: FakePhotoLibrary(),
          readBytes: (path) async {
            reads.add(path);
            if (path == paths[1]) throw const FileSystemException('gone');
            return held[path];
          },
          cleanup: (path) async => cleaned.add(path),
          sharedFolder: () async => '/shared',
          clock: () => now);
      final emitted = <String>[];
      final sub = intake.photos().listen((p) {
        emitted.add(p.fileName);
        p.onSettled!();
      });
      source.controller.add(paths);
      await pumpEventQueue();
      final later = share(1, prefix: 'later');
      source.controller.add(later);
      await pumpEventQueue();
      expect(emitted,
          [fileBaseName(paths[0]), fileBaseName(paths[2]), 'later_0.jpg']);
      expect(cleaned, unorderedEquals([...paths, ...later]),
          reason: 'the unreadable one at once, the others once settled');
      await sub.cancel();
    });

    test('iOS (no share folder) reads each copy as it arrives, paused or '
        'not: its extension reuses file names', () async {
      final source = FakeShareSource();
      final paths = share(4);
      final intake = ShareIntake(
          source: source,
          library: FakePhotoLibrary(),
          readBytes: (path) async {
            reads.add(path);
            return held[path];
          },
          cleanup: (path) async => cleaned.add(path),
          clock: () => now);
      final emitted = <String>[];
      late StreamSubscription<IntakePhoto> sub;
      sub = intake.photos().listen((p) {
        emitted.add(p.fileName);
        sub.pause();
      });
      source.controller.add(paths);
      await pumpEventQueue();
      expect(reads, paths);
      expect(cleaned, paths);
      expect(emitted, hasLength(1), reason: 'the rest are buffered');
      sub.resume();
      await pumpEventQueue();
      await sub.cancel();
    });

    test('cancelled while paused: the unread copies are deleted unread; one '
        'handed on waits for its verdict', () async {
      final source = FakeShareSource();
      final paths = share(6);
      final got = <IntakePhoto>[];
      late StreamSubscription<IntakePhoto> sub;
      sub = counting(source).photos().listen((p) {
        got.add(p);
        sub.pause();
      });
      source.controller.add(paths);
      await pumpEventQueue();
      final readBefore = reads.length;
      await sub.cancel();
      await pumpEventQueue();
      expect(reads.length, readBefore, reason: 'nothing more is read');
      expect(cleaned.toSet(), paths.skip(readBefore).toSet(),
          reason: 'no unread copy left behind in the cache');
      // The photo the listener took is still being worked on: its copy
      // goes with its verdict, not with the stream (Q1, Q9).
      expect(got.map((p) => p.fileName), [fileBaseName(paths[0])]);
      expect(cleaned, isNot(contains(paths[0])));
      got.single.onSettled!();
      expect(cleaned, contains(paths[0]));
    });

    test('a 20-photo share through the consent gate and the pipeline, the '
        'first analysis held: at most 2 originals are read', () async {
      final source = FakeShareSource();
      final paths = share(20);
      final release = Completer<void>();
      var analyses = 0;
      final analyzer = FakeAnalyzer()
        ..onAnalyze = () async {
          analyses++;
          if (analyses == 1) await release.future;
        };
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: analyzer,
          hasher: (b) async => 'h${b[0]}-${b.length}',
          thumbnailer: (_) async => null);
      pipeline.bindStream(SharedPhotoConsentGate(FakeSettings())
          .gate(counting(source).photos()));
      source.controller.add(paths);
      await pumpEventQueue(times: 50);

      expect(analyses, 1);
      expect(reads.length, lessThanOrEqualTo(2),
          reason: 'the stream buffered every original while photo 1 was '
              'analyzed');

      release.complete();
      await pumpEventQueue(times: 400);
      expect(reads, paths, reason: 'all read in the end, in order');
      expect(analyses, 20);
      expect(cleaned, paths);
      await pipeline.dispose();
    });

    test('the same, wired as the app wires it (the gate told the deliveries)',
        () async {
      final source = FakeShareSource();
      final paths = share(20);
      final release = Completer<void>();
      var analyses = 0;
      final analyzer = FakeAnalyzer()
        ..onAnalyze = () async {
          analyses++;
          if (analyses == 1) await release.future;
        };
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: analyzer,
          hasher: (b) async => 'h${b[0]}-${b.length}',
          thumbnailer: (_) async => null);
      final intake = counting(source);
      pipeline.bindStream(SharedPhotoConsentGate(FakeSettings())
          .gate(intake.photos(), deliveries: intake));
      source.controller.add(paths);
      await pumpEventQueue(times: 50);
      expect(reads.length, lessThanOrEqualTo(2));
      release.complete();
      await pumpEventQueue(times: 400);
      expect(analyses, 20);
      await pipeline.dispose();
    });
  });

  // One Not now per share, through the real intake (privacy lane; review
  // finding 7): the consent question pauses the stream like the pipeline
  // does, so while it is open at most one more copy is read, and a Not now
  // has the intake delete the rest of the share unread. Each batch event
  // is one delivery: the launch share, each live share, the start-up batch
  // of copies left unread.
  group('consent: one Not now per share, the rest never read', () {
    late Map<String, Uint8List> held;
    late List<String> reads;

    ShareIntake counting(FakeShareSource source) => ShareIntake(
        source: source,
        library: FakePhotoLibrary(),
        readBytes: (path) async {
          reads.add(path);
          return held[path];
        },
        cleanup: (path) async => cleaned.add(path),
        sharedFolder: () async => '/shared',
        clock: () => now);

    List<String> share(int n, {String prefix = 'IMG'}) => [
          for (var i = 0; i < n; i++) '/shared/${prefix}_$i.jpg',
        ]..forEach((p) => held[p] = Uint8List.fromList([p.hashCode & 0xFF, 1]));

    setUp(() {
      held = {};
      reads = [];
    });

    test('Not now on a 20-photo share: one question, at most two copies read, '
        'the rest deleted unread; the next share is asked again', () async {
      final source = FakeShareSource();
      final settings = FakeSettings(apiKey: 'k')..aiConsent = {};
      final gate = SharedPhotoConsentGate(settings);
      final intake = counting(source);
      final passed = <String>[];
      final sub = gate
          .gate(intake.photos(), deliveries: intake)
          .listen((p) => passed.add(p.fileName));
      var asked = 0;
      final notSent = <int>[];
      final answer = Completer<bool>();
      Future<bool> ask() async {
        asked++;
        if (asked > 1) {
          await settings.setAiConsent('gemini', granted: true);
          return true;
        }
        final yes = await answer.future;
        if (!yes) notSent.add(gate.declineOpenQuestion());
        return yes;
      }

      gate.attach(ask);
      final first = share(20, prefix: 'A');
      source.controller.add(first);
      await pumpEventQueue(times: 50);
      expect(asked, 1);
      expect(reads.length, lessThanOrEqualTo(2),
          reason: 'the open question pauses the reading');

      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(asked, 1, reason: 'one question for the whole share');
      expect(notSent, [20]);
      expect(passed, isEmpty);
      expect(reads.length, lessThanOrEqualTo(2), reason: 'never read');
      expect(cleaned.toSet(), first.toSet(),
          reason: 'every copy deleted, read or not');

      final second = share(2, prefix: 'B');
      source.controller.add(second);
      await pumpEventQueue(times: 50);
      expect(asked, 2, reason: 'a share after the answer asks again');
      expect(passed, ['B_0.jpg', 'B_1.jpg']);
      gate.detach(ask);
      await sub.cancel();
    });

    test('a share that arrives while the question is open is declined with '
        'it, unread', () async {
      final source = FakeShareSource();
      final settings = FakeSettings(apiKey: 'k')..aiConsent = {};
      final gate = SharedPhotoConsentGate(settings);
      final intake = counting(source);
      final sub = gate.gate(intake.photos(), deliveries: intake).listen((_) {});
      final answer = Completer<bool>();
      final notSent = <int>[];
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        final yes = await answer.future;
        if (!yes) notSent.add(gate.declineOpenQuestion());
        return yes;
      }

      gate.attach(ask);
      final a = share(3, prefix: 'A');
      source.controller.add(a);
      await pumpEventQueue(times: 50);
      final b = share(4, prefix: 'B');
      source.controller.add(b);
      await pumpEventQueue(times: 50);
      expect(intake.arrivedDelivery, 2);
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(asked, 1);
      expect(notSent, [7]);
      expect(reads.any((p) => p.contains('B_')), isFalse,
          reason: 'the second share is never read');
      expect(cleaned.toSet(), {...a, ...b});
      gate.detach(ask);
      await sub.cancel();
    });

    test('each batch event is its own delivery: launch share, live share, '
        'and the photos say which', () async {
      final source = FakeShareSource()..initial = share(2, prefix: 'L');
      final intake = counting(source);
      final got = <(String, int?)>[];
      final sub = intake
          .photos()
          .listen((p) => got.add((p.fileName, p.shareDelivery)));
      await pumpEventQueue(times: 50);
      source.controller.add(share(1, prefix: 'V'));
      await pumpEventQueue(times: 50);
      expect(got, [('L_0.jpg', 1), ('L_1.jpg', 1), ('V_0.jpg', 2)]);
      expect(intake.arrivedDelivery, 2);
      expect(intake.photoCountOf(1), 2);
      expect(intake.photoCountOf(2), 1);
      await sub.cancel();
    });

    // Review of 46da8b74, low 4: a declined share's copies go at once, even
    // while the stream stays paused, and a declined delivery is never
    // waited on.
    test('declined while paused: the rest of that share is deleted unread '
        'at once', () async {
      final source = FakeShareSource();
      final intake = counting(source);
      final paths = share(6);
      late StreamSubscription<IntakePhoto> sub;
      sub = intake.photos().listen((_) => sub.pause());
      source.controller.add(paths);
      await pumpEventQueue(times: 50);
      final readBefore = reads.length;
      expect(readBefore, lessThanOrEqualTo(2));
      intake.declineDeliveries({1});
      await pumpEventQueue(times: 50);
      expect(sub.isPaused, isTrue);
      expect(reads.length, readBefore, reason: 'nothing more is read');
      expect(cleaned.toSet(), paths.toSet(), reason: 'deleted, not waiting');
      await sub.cancel();
    });

    test('a copy found unreadable is not counted as a photo', () async {
      final source = FakeShareSource();
      final intake = counting(source);
      final paths = share(3);
      held.remove(paths[1]); // reads as nothing
      final sub = intake.photos().listen((_) {});
      source.controller.add(paths);
      await pumpEventQueue(times: 50);
      expect(intake.photoCountOf(1), 2);
      await sub.cancel();
    });
  });

  // Q1, Q9 (2026-11-20): on Android a photo's copy waits on disk until the
  // photo is settled (IntakePhoto.onSettled: its verdict written, or it was
  // dropped unsent). It used to go as its bytes were read, so an engine
  // that went mid-analysis lost the photo in flight and the one read
  // ahead. share_resume_test.dart runs the whole path across two starts.
  group('Android: a copy waits for its photo\'s verdict (Q1, Q9)', () {
    late Map<String, Uint8List> held;
    late List<String> reads;

    ShareIntake android(FakeShareSource source) => ShareIntake(
        source: source,
        library: FakePhotoLibrary(),
        readBytes: (path) async {
          reads.add(path);
          return held[path];
        },
        cleanup: (path) async => cleaned.add(path),
        sharedFolder: () async => '/shared',
        clock: () => now);

    setUp(() {
      held = {};
      reads = [];
    });

    test('a photo\'s copy stays until the photo is settled, then goes, once',
        () async {
      final source = FakeShareSource();
      held['/shared/1/IMG_a.jpg'] = Uint8List.fromList([1, 2]);
      final got = <IntakePhoto>[];
      final sub = android(source).photos().listen(got.add);
      source.controller.add(['/shared/1/IMG_a.jpg']);
      await pumpEventQueue();
      expect(got, hasLength(1));
      expect(cleaned, isEmpty, reason: 'read and handed on, no verdict yet');
      got.single.onSettled!();
      expect(cleaned, ['/shared/1/IMG_a.jpg']);
      got.single.onSettled!();
      expect(cleaned, hasLength(1), reason: 'a second call does nothing');
      await sub.cancel();
    });

    test('a copy being read as a Not now covers its share is deleted once '
        'read, never handed on', () async {
      const path = '/shared/1/IMG_a.jpg';
      held[path] = Uint8List.fromList([1, 2]);
      final reading = Completer<void>();
      final source = FakeShareSource();
      final intake = ShareIntake(
          source: source,
          library: FakePhotoLibrary(),
          readBytes: (p) async {
            reads.add(p);
            await reading.future;
            return held[p];
          },
          cleanup: (p) async => cleaned.add(p),
          sharedFolder: () async => '/shared',
          clock: () => now);
      final got = <IntakePhoto>[];
      final sub = intake.photos().listen(got.add);
      source.controller.add([path]);
      await pumpEventQueue();
      expect(reads, [path], reason: 'being read');
      intake.declineDeliveries({1});
      reading.complete();
      await pumpEventQueue();
      expect(got, isEmpty);
      expect(cleaned, [path]);
      await sub.cancel();
    });

    test('a copy that gives no photo still goes as it is read: another '
        'type, over 25 MB, nothing to read', () async {
      final source = FakeShareSource();
      held['/shared/1/notes.txt'] = Uint8List.fromList([1]);
      held['/shared/2/IMG_big.jpg'] = Uint8List(maxPhotoBytes + 1);
      final paths = [
        '/shared/1/notes.txt',
        '/shared/2/IMG_big.jpg',
        '/shared/3/IMG_gone.jpg', // reads as nothing
      ];
      final got = <IntakePhoto>[];
      final sub = android(source).photos().listen(got.add);
      source.controller.add(paths);
      await pumpEventQueue();
      expect(got, isEmpty);
      expect(cleaned, paths);
      await sub.cancel();
    });

    test('a Not now deletes the copies already read (the photo asked about, '
        'the one read ahead) with the rest, before its answer returns',
        () async {
      final source = FakeShareSource();
      final paths = [for (var i = 0; i < 4; i++) '/shared/$i/IMG_$i.jpg'];
      for (final p in paths) {
        held[p] = Uint8List.fromList([p.hashCode & 0xFF, 1]);
      }
      final settings = FakeSettings(apiKey: 'k')..aiConsent = {};
      final gate = SharedPhotoConsentGate(settings);
      final intake = android(source);
      List<String>? cleanedAtAnswer;
      var readAtAnswer = 0;
      gate.attach(() async {
        await pumpEventQueue(); // the copy read ahead has landed
        readAtAnswer = reads.length;
        gate.declineOpenQuestion();
        cleanedAtAnswer = [...cleaned];
        return false;
      });
      final sub =
          gate.gate(intake.photos(), deliveries: intake).listen((_) {});
      source.controller.add(paths);
      await pumpEventQueue(times: 50);
      expect(readAtAnswer, inInclusiveRange(1, 2));
      expect(cleanedAtAnswer?.toSet(), paths.toSet(),
          reason: 'read or not, gone as the answer is given: an app stopped '
              'right after keeps none for the next start');
      expect(reads, hasLength(readAtAnswer), reason: 'nothing more is read');
      await sub.cancel();
    });
  });

  // Review 2026-11-20: with predictive back, Android 14 and later finish
  // the activity when Back reaches the root unless the home screen started
  // it, and the engine with it, mid-analysis (Q9); MainActivity keeps Back
  // in Flutter wherever it knows they would, which leaves a start it
  // cannot see (a return from Recents on Android 15 QPR1 and later, with a
  // third-party home app). The shell keeps that Back in Flutter in every
  // task while a shared photo is pending (SharedPhotosBackGuard): from the
  // moment its share arrives until the photo is settled, through every
  // read, and never on iOS.
  group('Android: photosPending, from a share\'s arrival to its last '
      'verdict', () {
    late Map<String, Uint8List> held;
    late Map<String, Completer<void>> readGates;

    ShareIntake android(FakeShareSource source, {bool iOS = false}) =>
        ShareIntake(
            source: source,
            library: FakePhotoLibrary(),
            readBytes: (path) async {
              await readGates[path]?.future;
              return held[path];
            },
            cleanup: (path) async => cleaned.add(path),
            sharedFolder: iOS ? null : () async => '/shared',
            clock: () => now);

    /// Every value [intake] says from now on, in order.
    List<bool> said(ShareIntake intake) {
      final out = <bool>[];
      intake.photosPending
          .addListener(() => out.add(intake.photosPending.value));
      return out;
    }

    setUp(() {
      held = {
        '/shared/1/IMG_a.jpg': Uint8List.fromList([1, 2]),
        '/shared/2/IMG_b.jpg': Uint8List.fromList([3, 4]),
        '/shared/2/IMG_c.jpg': Uint8List.fromList([5, 6]),
      };
      readGates = {};
    });

    test('pending until the last photo is settled, and never false in '
        'between: not while another share\'s copy is being read', () async {
      final source = FakeShareSource();
      final intake = android(source);
      final values = said(intake);
      final got = <IntakePhoto>[];
      final sub = intake.photos().listen(got.add);
      await pumpEventQueue();
      expect(intake.photosPending.value, isFalse, reason: 'nothing shared');

      source.controller.add(['/shared/1/IMG_a.jpg']);
      await pumpEventQueue();
      expect(got, hasLength(1));
      expect(intake.photosPending.value, isTrue, reason: 'a: no verdict yet');
      // A second share; its copy is still being read when a's verdict is
      // written.
      readGates['/shared/2/IMG_b.jpg'] = Completer<void>();
      source.controller.add(['/shared/2/IMG_b.jpg']);
      await pumpEventQueue();
      expect(got, hasLength(1), reason: 'b is being read');
      got.single.onSettled!();
      expect(intake.photosPending.value, isTrue,
          reason: 'b, being read, is pending too');

      readGates['/shared/2/IMG_b.jpg']!.complete();
      await pumpEventQueue();
      expect(got, hasLength(2));
      expect(intake.photosPending.value, isTrue);
      got.last.onSettled!();
      expect(intake.photosPending.value, isFalse);
      expect(values, [true, false]);
      await sub.cancel();
    });

    test('a Not now clears it before its answer returns, read copies and '
        'unread alike', () async {
      final source = FakeShareSource();
      final intake = android(source);
      late StreamSubscription<IntakePhoto> sub;
      sub = intake.photos().listen((_) => sub.pause());
      source.controller.add(['/shared/2/IMG_b.jpg', '/shared/2/IMG_c.jpg']);
      await pumpEventQueue();
      expect(intake.photosPending.value, isTrue);
      intake.declineDeliveries({1});
      expect(intake.photosPending.value, isFalse);
      await sub.cancel();
    });

    test('a copy that gives no photo holds it only while it is read',
        () async {
      final source = FakeShareSource();
      final intake = android(source);
      final values = said(intake);
      final sub = intake.photos().listen((_) {});
      held['/shared/3/notes.txt'] = Uint8List.fromList([1]);
      source.controller
          .add(['/shared/3/notes.txt', '/shared/4/IMG_gone.jpg']);
      await pumpEventQueue();
      expect(intake.photosPending.value, isFalse);
      expect(values, [true, false]);
      await sub.cancel();
    });

    test('iOS (no share folder): never pending', () async {
      final source = FakeShareSource();
      final intake = android(source, iOS: true);
      final values = said(intake);
      final got = <IntakePhoto>[];
      final sub = intake.photos().listen(got.add);
      source.controller.add(['/shared/1/IMG_a.jpg']);
      await pumpEventQueue();
      expect(got, hasLength(1));
      expect(intake.photosPending.value, isFalse);
      expect(values, isEmpty);
      await sub.cancel();
    });
  });

  // Review 2026-11-13: with the C2 backpressure, copies wait in the share
  // folder for minutes. An app killed mid-batch left the rest there for
  // good — full-size originals in the cache, never logged, nothing said
  // (MainActivity removes only EMPTY folders, and a recreated activity
  // does not hand the launch share over again). The next start logs the
  // ones shared within a day, through the same consent gate and pipeline:
  // a copy still on disk has no verdict written yet (on Android a photo's
  // copy goes only once the photo is settled). Most were never read; one
  // whose engine stopped mid-analysis may have been sent already and is
  // sent again, and the md5 photo ledger keeps it to one meal
  // (share_resume_test.dart). Older ones are deleted unread.
  group('Android: copies a killed app left unread', () {
    late Directory cache;
    late String folder;

    setUp(() {
      cache = Directory.systemTemp.createTempSync('share_stranded_');
      folder = '${cache.path}/$androidShareFolderName';
      Directory(folder).createSync(recursive: true);
    });
    tearDown(() => cache.deleteSync(recursive: true));

    // The sweep lists and stats real files, and real I/O completes outside
    // the microtask queue: a fixed number of pumps is not enough on a slow
    // runner (CI, 2026-11-14). Wait, in real time, for what the test
    // expects to happen; negative checks wait for a sentinel copy instead.
    Future<void> until(bool Function() done, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await pumpEventQueue(times: 50);
    }

    File copyAt(String id, String name, Duration age) =>
        File('$folder/$id/$name')
          ..createSync(recursive: true)
          ..writeAsBytesSync(name.codeUnits)
          ..setLastModifiedSync(now.subtract(age));

    ShareIntake android(FakeShareSource source, List<String> read) =>
        ShareIntake(
            source: source,
            library: FakePhotoLibrary(),
            readBytes: (path) async {
              read.add(path);
              try {
                return await File(path).readAsBytes();
              } catch (_) {
                return null;
              }
            },
            // The production cleanup: a real delete.
            sharedFolder: () async => folder,
            clock: () => now);

    test('are logged at the next start, oldest first, after the launch '
        'share', () async {
      final a = copyAt('u1', 'IMG_a.jpg', const Duration(hours: 2));
      final b = copyAt('u2', 'IMG_b.jpg', const Duration(hours: 1));
      final launch = copyAt('u3', 'IMG_c.jpg', Duration.zero);
      final source = FakeShareSource()..initial = [launch.path];
      final read = <String>[];
      final emitted = <String>[];
      final sub = android(source, read).photos().listen((p) {
        emitted.add(p.fileName);
        p.onSettled!();
      });
      await until(() => emitted.length >= 3, 'three copies emitted');
      expect(emitted, ['IMG_c.jpg', 'IMG_a.jpg', 'IMG_b.jpg']);
      expect(emitted.length, 3, reason: 'the launch share once, not twice');
      for (final f in [a, b, launch]) {
        expect(f.existsSync(), isFalse, reason: f.path);
      }
      await sub.cancel();
    });

    test('older than a day: deleted unread', () async {
      final old = copyAt('u1', 'IMG_old.jpg', const Duration(hours: 25));
      final read = <String>[];
      final emitted = <IntakePhoto>[];
      final sub = android(FakeShareSource(), read).photos().listen(emitted.add);
      await until(() => !old.existsSync(), 'the old copy deleted');
      expect(emitted, isEmpty);
      expect(read, isEmpty, reason: 'never read, never sent');
      expect(old.existsSync(), isFalse);
      await sub.cancel();
    });

    test('a copy written seconds ago is left to its own share', () async {
      final fresh = copyAt('u1', 'IMG_new.jpg', const Duration(seconds: 2));
      final sentinel = copyAt('u2', 'IMG_s.jpg', const Duration(hours: 1));
      final read = <String>[];
      final sub = android(FakeShareSource(), read).photos().listen((_) {});
      await until(() => read.isNotEmpty, 'the sweep reached the sentinel');
      expect(read, [sentinel.path],
          reason: 'it may still be being copied, and its own event '
              'delivers it: MainActivity holds a share that comes before '
              'share intake listens until it does (R0, below); one whose '
              'event never comes is taken by the second look (below)');
      expect(fresh.existsSync(), isTrue);
      await sub.cancel();
    });

    // Review of 46da8b74, low 1: the launch share of a cold start, then the
    // start-up batch. One Not now covers the launch share (its 2 photos,
    // said as 2), and the copies left unread get a question of their own.
    test('cold start: Not now on the launch share leaves the copies left '
        'unread to their own question', () async {
      final left = [
        for (var i = 0; i < 3; i++)
          copyAt('l$i', 'IMG_left$i.jpg', Duration(hours: 3 - i)),
      ];
      final launch = [
        copyAt('n0', 'IMG_new0.jpg', Duration.zero),
        copyAt('n1', 'IMG_new1.jpg', Duration.zero),
      ];
      final source = FakeShareSource()
        ..initial = [for (final f in launch) f.path];
      final read = <String>[];
      final intake = android(source, read);
      final settings = FakeSettings(apiKey: 'k')..aiConsent = {};
      final gate = SharedPhotoConsentGate(settings);
      final passed = <String>[];
      final notSent = <int>[];
      var asked = 0;
      gate.attach(() async {
        asked++;
        if (asked == 1) {
          // The question is open until the start-up batch has arrived.
          await until(() => intake.arrivedDelivery >= 2, 'the start-up batch');
          notSent.add(gate.declineOpenQuestion());
          return false;
        }
        settings.aiConsent = {'gemini'};
        return true;
      });
      final sub = gate.gate(intake.photos(), deliveries: intake).listen((p) {
        passed.add(p.fileName);
        p.onSettled!();
      });
      await until(() => passed.length >= 3, 'the copies left unread logged');
      expect(notSent, [2], reason: 'the launch share, not 5');
      expect(asked, 2);
      expect(passed, ['IMG_left0.jpg', 'IMG_left1.jpg', 'IMG_left2.jpg']);
      for (final f in [...launch, ...left]) {
        expect(f.existsSync(), isFalse, reason: f.path);
      }
      await sub.cancel();
    });

    // Review 2026-11-19, R1: a Not now covers a share made while its
    // question was open. Queued behind the start-up batch (which asks
    // alone), its copies used to wait until that whole batch had been
    // read; an app stopped meanwhile left them for the next start's sweep,
    // which sent them unasked once the batch's own question was answered
    // Allow. They go as the answer is given now.
    test('Not now deletes a share queued behind the start-up batch at once; '
        'the next start never sends it', () async {
      final left = [
        for (var i = 0; i < 3; i++)
          copyAt('l$i', 'IMG_left$i.jpg', Duration(hours: 3 - i)),
      ];
      final launch = copyAt('n0', 'IMG_new0.jpg', Duration.zero);
      final source = FakeShareSource()..initial = [launch.path];
      final intake = android(source, <String>[]);
      final settings = FakeSettings(apiKey: 'k')..aiConsent = {};
      final gate = SharedPhotoConsentGate(settings);
      final declined = <File>[];
      final notSent = <int>[];
      List<bool>? onDiskAtAnswer;
      var asked = 0;
      gate.attach(() async {
        asked++;
        if (asked > 1) {
          // The start-up batch's own question: Allow.
          settings.aiConsent = {'gemini'};
          return true;
        }
        // The launch share's question is open while the start-up batch
        // arrives and the user shares two more photos; then Not now.
        await until(() => intake.arrivedDelivery >= 2, 'the start-up batch');
        declined
          ..add(copyAt('x0', 'IMG_x0.jpg', Duration.zero))
          ..add(copyAt('x1', 'IMG_x1.jpg', Duration.zero));
        source.controller.add([for (final f in declined) f.path]);
        await until(() => intake.arrivedDelivery >= 3, 'the share made then');
        notSent.add(gate.declineOpenQuestion());
        onDiskAtAnswer = [for (final f in declined) f.existsSync()];
        return false;
      });
      final passed = <String>[];
      late StreamSubscription<IntakePhoto> sub;
      // The pipeline holds the first photo it gets (a long analysis).
      sub = gate.gate(intake.photos(), deliveries: intake).listen((p) {
        passed.add(p.fileName);
        sub.pause();
      });
      await until(() => passed.isNotEmpty, 'a start-up photo in the pipeline');
      expect(asked, 2);
      expect(intake.asksAlone(2), isTrue);
      expect(notSent, [3], reason: 'the launch share and the two shared then');
      expect(onDiskAtAnswer, [false, false],
          reason: 'deleted as the answer is given, not once the start-up '
              'batch in front of them has been read');

      // The app is stopped here: nothing more of this run happens. The
      // next start, 5 minutes on, with the recipient now allowed, logs what
      // is left of the start-up batch (the photo that was in the pipeline
      // included: its copy waited for a verdict), up to a copy newer than
      // any other.
      final newest = copyAt('z', 'IMG_z.jpg', const Duration(seconds: -1));
      final next = <String>[];
      final sub2 = SharedPhotoConsentGate(settings)
          .gate(ShareIntake(
                  source: FakeShareSource(),
                  library: FakePhotoLibrary(),
                  readBytes: (path) => File(path).readAsBytes(),
                  sharedFolder: () async => folder,
                  clock: () => now.add(const Duration(minutes: 5)))
              .photos())
          .listen((p) {
        next.add(p.fileName);
        p.onSettled!();
      });
      await until(() => next.contains('IMG_z.jpg'), "the next start's sweep");
      expect(next.where((n) => n.startsWith('IMG_x')), isEmpty,
          reason: 'photos answered Not now are never sent');
      expect(next, containsAll(['IMG_left0.jpg', 'IMG_left2.jpg']),
          reason: 'the one in the pipeline when the app stopped comes back');
      expect(newest.existsSync(), isFalse);
      expect(left.last.existsSync(), isFalse);
      await sub2.cancel();
      await sub.cancel();
    });

    test('a Not now deletes the copies of a share queued behind another '
        'before it returns, while the reader still waits', () async {
      // Seconds old: the start-up sweep leaves them to their own shares.
      final first = [
        for (var i = 0; i < 3; i++) copyAt('a$i', 'IMG_a$i.jpg', Duration.zero),
      ];
      final source = FakeShareSource();
      final intake = android(source, <String>[]);
      late StreamSubscription<IntakePhoto> sub;
      sub = intake.photos().listen((_) => sub.pause());
      source.controller.add([for (final f in first) f.path]);
      await until(() => sub.isPaused, 'the first photo handed on');
      final second = [
        for (var i = 0; i < 2; i++) copyAt('b$i', 'IMG_b$i.jpg', Duration.zero),
      ];
      source.controller.add([for (final f in second) f.path]);
      await until(() => intake.arrivedDelivery >= 2, 'the second share');
      intake.declineDeliveries({2});
      // No wait at all: an app stopped right after the answer keeps none.
      expect([for (final f in second) f.existsSync()], [false, false]);
      expect(first.last.existsSync(), isTrue,
          reason: 'the share not declined still waits its turn');
      expect(sub.isPaused, isTrue);
      await sub.cancel();
    });

    test('a copy both left over and in a live share is logged once',
        () async {
      final c = copyAt('u1', 'IMG_x.jpg', const Duration(minutes: 5));
      copyAt('u2', 'IMG_s.jpg', const Duration(hours: 1));
      final source = FakeShareSource();
      final read = <String>[];
      final emitted = <String>[];
      final intake = android(source, read);
      final sub = intake.photos().listen((p) => emitted.add(p.fileName));
      source.controller.add([c.path]);
      await until(() => emitted.length >= 2, 'the live copy and the sentinel');
      expect(emitted.where((n) => n == 'IMG_x.jpg'), hasLength(1),
          reason: 'logged once, not once per route');
      expect(emitted.toSet(), {'IMG_x.jpg', 'IMG_s.jpg'});
      // And counted once: a Not now's line would otherwise say one more
      // (review of 46da8b74, low 2).
      expect(
          [
            for (var d = 1; d <= intake.arrivedDelivery; d++)
              intake.photoCountOf(d)
          ].fold<int>(0, (a, b) => a + b),
          2);
      await sub.cancel();
    });

    test('only files inside the share folder are touched', () async {
      final private = File('${cache.path}/private.jpg')
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(now.subtract(const Duration(days: 3)));
      final sentinel = copyAt('u2', 'IMG_s.jpg', const Duration(hours: 1));
      final read = <String>[];
      final sub = android(FakeShareSource(), read).photos().listen((_) {});
      await until(() => read.isNotEmpty, 'the sweep reached the sentinel');
      expect(read, [sentinel.path]);
      expect(private.existsSync(), isTrue);
      await sub.cancel();
    });

    test('iOS (no share folder) sweeps nothing', () async {
      final left = copyAt('u1', 'IMG_a.jpg', const Duration(hours: 1));
      final read = <String>[];
      final sub = ShareIntake(
              source: FakeShareSource(),
              library: FakePhotoLibrary(),
              readBytes: (p) async {
                read.add(p);
                return null;
              },
              clock: () => now)
          .photos()
          .listen((_) {});
      await pumpEventQueue(times: 50);
      expect(read, isEmpty);
      expect(left.existsSync(), isTrue);
      await sub.cancel();
    });

    // Review 2026-11-19, R0: a share made after Android stopped the app's
    // process reaches MainActivity's onNewIntent in the same launch that
    // recreates it, before this engine's Dart has run. The plugin tells
    // only a listener and keeps nothing for later, and the sweep leaves a
    // copy seconds old to its own share: the meal was never logged that
    // run. MainActivity now holds such a share until share intake says it
    // listens (shareIntakeReady), then hands it to the plugin once, whose
    // event comes like any live share's (IntakeRulesTest: ShareHold).
    test('share intake says it listens once the live stream is listened '
        'to, not before, and once', () async {
      final source = FakeShareSource();
      final order = <String>[];
      source.controller.onListen = () => order.add('listen');
      final sub = ShareIntake(
              source: source,
              library: FakePhotoLibrary(),
              readBytes: (_) async => null,
              sharedFolder: () async => folder,
              listening: () async => order.add('ready'),
              clock: () => now)
          .photos()
          .listen((_) {});
      await pumpEventQueue(times: 50);
      expect(order, ['listen', 'ready']);
      await sub.cancel();
    });

    test('the share MainActivity held is logged once share intake listens, '
        'once, though the sweep saw its copy', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const plugin = MethodChannel('receive_sharing_intent/messages');
      const events = MethodChannel('receive_sharing_intent/events-media');
      const activity = MethodChannel(filesChannelName);
      // onNewIntent copied the photo 2 s before Dart listened; an earlier
      // run left a sentinel (once it is logged, the sweep has run).
      final meal = copyAt('n1', 'IMG_meal.jpg', const Duration(seconds: 2));
      copyAt('s1', 'IMG_s.jpg', const Duration(hours: 1));
      final calls = <String>[];
      var listener = false; // the plugin's event sink
      // The recreated activity's own intent is empty: no launch share.
      messenger.setMockMethodCallHandler(plugin, (call) async {
        calls.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (call) async {
        calls.add(call.method);
        listener = call.method == 'listen';
        return null;
      });
      // MainActivity hands the held share to the plugin, which tells its
      // listener, and nobody without one.
      messenger.setMockMethodCallHandler(activity, (call) async {
        calls.add(call.method);
        if (call.method != shareIntakeReadyMethod || !listener) return 0;
        await messenger.handlePlatformMessage(
            events.name,
            const StandardMethodCodec().encodeSuccessEnvelope(jsonEncode([
              {'path': meal.path, 'type': 'image', 'mimeType': 'image/jpeg'},
            ])),
            (_) {});
        return 1;
      });
      addTearDown(() {
        for (final channel in [plugin, events, activity]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      final emitted = <String>[];
      final sub = ShareIntake(
              source: ReceiveSharingIntentSource(),
              library: FakePhotoLibrary(),
              readBytes: (path) => File(path).readAsBytes(),
              sharedFolder: () async => folder,
              listening: androidShareIntakeReady,
              clock: () => now)
          .photos()
          .listen((p) {
        emitted.add(p.fileName);
        p.onSettled!();
      });
      await until(() => emitted.length >= 2, 'the held share and the sentinel');
      expect(emitted.toSet(), {'IMG_meal.jpg', 'IMG_s.jpg'});
      expect(emitted.where((n) => n == 'IMG_meal.jpg'), hasLength(1),
          reason: 'once, not once by its event and again by the sweep');
      expect(calls.indexOf('listen'), greaterThanOrEqualTo(0));
      expect(calls.indexOf(shareIntakeReadyMethod),
          greaterThan(calls.indexOf('listen')),
          reason: 'the plugin has its listener before the share is handed '
              'over');
      expect(meal.existsSync(), isFalse, reason: 'settled, so deleted');
      await sub.cancel();
    });

    test('androidShareIntakeReady asks MainActivity on the files channel; a '
        'native side without it is no error', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const activity = MethodChannel(filesChannelName);
      final calls = <String>[];
      messenger.setMockMethodCallHandler(activity, (call) async {
        calls.add(call.method);
        return 0;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(activity, null));
      await androidShareIntakeReady();
      expect(calls, [shareIntakeReadyMethod]);
      messenger.setMockMethodCallHandler(
          activity, (call) async => throw PlatformException(code: 'gone'));
      await androidShareIntakeReady();
      messenger.setMockMethodCallHandler(activity, null);
      await androidShareIntakeReady(); // MissingPluginException
    });

    // Review of the R0 fix: the share MainActivity holds goes with that
    // activity if it goes before share intake listens (Back or a swipe
    // during the cold start, a crash). Its copy stays in the share folder,
    // but a start within seconds found it too young for the sweep, and no
    // event ever came for it: the meal waited for a later start, possibly
    // a day later, or was deleted unread. The copies the sweep found too
    // young are looked at again once they are old enough
    // (strandedRecheck, shortened here; the production delay takes this
    // test 15 s).
    ShareIntake rechecking(FakeShareSource source,
            {FileBytesReader? readBytes}) =>
        ShareIntake(
            source: source,
            library: FakePhotoLibrary(),
            readBytes: readBytes ?? (path) => File(path).readAsBytes(),
            sharedFolder: () async => folder,
            recheckAfter: const Duration(milliseconds: 50),
            clock: () => now);

    test('a share held by an activity that went before share intake '
        'listened is logged in the run that starts seconds later, once',
        () async {
      expect(ShareIntake.strandedRecheck > ShareIntake.strandedMinAge, isTrue,
          reason: 'every copy too young for the sweep is old enough then');
      final orphan = copyAt('o1', 'IMG_meal.jpg', const Duration(seconds: 3));
      final sentinel = copyAt('s1', 'IMG_s.jpg', const Duration(hours: 1));
      final intake = rechecking(FakeShareSource());
      final emitted = <IntakePhoto>[];
      final sub = intake.photos().listen((p) {
        emitted.add(p);
        p.onSettled!();
      });
      await until(() => emitted.length >= 2, 'the sentinel and the meal');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect([for (final p in emitted) p.fileName],
          ['IMG_s.jpg', 'IMG_meal.jpg']);
      expect(intake.asksAlone(emitted.last.shareDelivery!), isTrue,
          reason: 'no share being made now: a question of its own');
      expect(orphan.existsSync(), isFalse, reason: 'settled, so deleted');
      expect(sentinel.existsSync(), isFalse);
      await sub.cancel();
    });

    test('the second look gives no copy twice: one whose share was handed '
        'over is not given again', () async {
      // Both seconds old when share intake starts: MainActivity handed one
      // over (its event comes), the other's activity went.
      final live = copyAt('l1', 'IMG_live.jpg', const Duration(seconds: 2));
      final orphan =
          copyAt('o1', 'IMG_orphan.jpg', const Duration(seconds: 3));
      final source = FakeShareSource();
      source.controller.add([live.path]);
      final intake = rechecking(source);
      final emitted = <IntakePhoto>[];
      // Paused from the start (a question open, say): nothing is read, so
      // both copies are still on disk for the sweep and the second look.
      final sub = intake.photos().listen((p) {
        emitted.add(p);
        p.onSettled!();
      })
        ..pause();
      await until(() => intake.arrivedDelivery >= 2, 'the second look');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(intake.arrivedDelivery, 2,
          reason: 'the live share, then the other copy alone, once');
      expect(intake.asksAlone(1), isFalse);
      expect(intake.asksAlone(2), isTrue);
      expect(intake.photoCountOf(2), 1);
      expect(live.existsSync(), isTrue);
      sub.resume();
      await until(() => emitted.length >= 2, 'both read');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect([for (final p in emitted) (p.fileName, p.shareDelivery)],
          [('IMG_live.jpg', 1), ('IMG_orphan.jpg', 2)]);
      expect(live.existsSync(), isFalse);
      expect(orphan.existsSync(), isFalse);
      await sub.cancel();
    });

    test('stopped before the second look: a copy too young for the sweep is '
        'left for the next start, unread', () async {
      final orphan =
          copyAt('o1', 'IMG_orphan.jpg', const Duration(seconds: 3));
      final sentinel = copyAt('s1', 'IMG_s.jpg', const Duration(hours: 1));
      final read = <String>[];
      late StreamSubscription<IntakePhoto> sub;
      final intake = rechecking(FakeShareSource(), readBytes: (path) async {
        read.add(path);
        unawaited(sub.cancel()); // the app goes as the sweep's copy is read
        return File(path).readAsBytes();
      });
      sub = intake.photos().listen((_) {});
      await until(() => read.isNotEmpty, 'the sweep reached the sentinel');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(read, [sentinel.path]);
      expect(intake.arrivedDelivery, 1, reason: 'no second look once stopped');
      expect(orphan.existsSync(), isTrue,
          reason: 'never deleted unread: the next start logs it');
    });
  });
}
