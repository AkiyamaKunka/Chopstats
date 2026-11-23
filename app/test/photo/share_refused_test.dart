// A share's files that give no photo (2026-11-21). They were dropped
// without a word: an AVIF or DNG, a file over 25 MB, an empty or
// unreadable copy (share intake deletes those at once), and on Android a
// video, a PDF, a file over 25 MB or a stream MainActivity could not read
// before any copy; a share of nothing else never reached Dart at all.
// Now one line follows the share's photos: how many were skipped, and the
// main reason. The usable photos go on as before (one consent question
// for the share), nothing is sent for the refused files, and a share
// whose every file was refused asks nothing. Each part below, then the
// path di.dart wires (intake → consent gate → pipeline → outcomeSnackbar),
// for a share made while the app runs and one that launched it.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/ai_consent.dart' show allAiConsentRoutes;
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart'
    show maxPhotoBytes;
import 'package:calorie_tracker/services/photo/share_intake.dart';
import 'package:calorie_tracker/ui/ai_consent.dart' show SharedPhotoConsentGate;
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../ui/fakes.dart' show FakeAnalyzer, FakeDao, FakeSettings;
import 'watcher_test.dart' show FakePhotoLibrary;

/// The plugin's side: whole batches, refusals included.
class _Source implements SharedMediaSource {
  final controller = StreamController<SharedBatch>();
  SharedBatch initial = const SharedBatch([]);

  @override
  Stream<SharedBatch> batches() => controller.stream;

  @override
  Future<SharedBatch> initialBatch() async => initial;
}

/// The share intake's side of a Not now, scripted: each delivery's photos
/// as far as is known (ShareDeliveries.photoCountOf).
class _Deliveries implements ShareDeliveries {
  final photos = <int, int>{};
  final declined = <int>{};

  @override
  int get arrivedDelivery => photos.length;

  @override
  int photoCountOf(int delivery) => photos[delivery] ?? 0;

  @override
  void declineDeliveries(Set<int> deliveries) => declined.addAll(deliveries);

  @override
  bool asksAlone(int delivery) => false;
}

final AppLocalizations en = AppLocalizationsEn();
final AppLocalizations zh = AppLocalizationsZh();

const _meal = AnalysisOutcome(
    analysis: {
      'is_food': true,
      'meal_description': 'Beef noodles',
      'total_calories': 620,
    },
    isFood: true,
    wall: Duration.zero);

RefusedShareFiles _files(List<ShareRefusal> reasons,
        [List<String> photoTypes = const []]) =>
    RefusedShareFiles(reasons, photoTypes: photoTypes);

const _type = ShareRefusal.photoType;
const _video = ShareRefusal.video;
const _file = ShareRefusal.fileType;
const _big = ShareRefusal.tooBig;
const _gone = ShareRefusal.unreadable;

/// MainActivity's refused item whose path ends in [rest], the part after
/// its folder: 'too_big', or 'file_type/cr3' for an item refused for its
/// type with its name's extension (IntakeRules.refusedSharePath).
SharedMediaFile _refusedItem(String rest) => SharedMediaFile(
    path: '$androidRefusedSharePath/$rest',
    type: SharedMediaType.file,
    mimeType: androidRefusedShareType);

/// A copy MainActivity made at [path], as the plugin reports it.
SharedMediaFile _copied(String path) => SharedMediaFile(
    path: path, type: SharedMediaType.image, mimeType: 'image/jpeg');

void main() {
  final files = <String, Uint8List>{};
  final cleaned = <String>[];
  final read = <String>[];
  setUp(() {
    files.clear();
    cleaned.clear();
    read.clear();
  });

  Future<Uint8List?> readBytes(String path) async {
    read.add(path);
    return files[path];
  }

  /// iOS's intake (no share folder: each copy read as it arrives), or
  /// Android's ([android]: the share folder '/shared', copies kept until
  /// their photo is settled, read only while the listener is not paused).
  ShareIntake intakeOf(_Source source, {bool android = false}) => ShareIntake(
      source: source,
      library: FakePhotoLibrary(),
      readBytes: readBytes,
      cleanup: (path) async => cleaned.add(path),
      sharedFolder: android ? () async => '/shared' : null,
      clock: () => DateTime(2026, 11, 21, 12));

  group('the plugin\'s items for one share', () {
    test('images are paths; MainActivity\'s refused items say why; a video '
        'or another file is refused by its kind; text and links are no '
        'file', () {
      final batch = sharedBatchOf([
        _copied('/cache/shared_photos/1/IMG_1.jpg'),
        _refusedItem('too_big'),
        _refusedItem('video'),
        _refusedItem('file_type'),
        _refusedItem('unreadable'),
        // A reason this build does not know reads as unreadable.
        _refusedItem('something_new'),
        // Typed as an image by mistake: still a refusal, never a path.
        SharedMediaFile(
            path: '$androidRefusedSharePath/too_big',
            type: SharedMediaType.image,
            mimeType: androidRefusedShareType),
        SharedMediaFile(
            path: '/x/clip.mp4',
            type: SharedMediaType.video,
            mimeType: 'video/mp4'),
        SharedMediaFile(
            path: '/x/menu.pdf',
            type: SharedMediaType.file,
            mimeType: 'application/pdf'),
        SharedMediaFile(path: 'hello', type: SharedMediaType.text),
        SharedMediaFile(path: 'https://example.com', type: SharedMediaType.url),
      ]);
      expect(batch.paths, ['/cache/shared_photos/1/IMG_1.jpg']);
      expect(batch.refused,
          [_big, _video, _file, _gone, _gone, _big, _video, _file]);
    });

    // What the Android plugin sends for a refused item (its JSONObject
    // drops the null thumbnail and duration), parsed as the plugin's Dart
    // side parses every event.
    test('a refused item as the plugin\'s JSON reads', () {
      final batch = sharedBatchOf([
        SharedMediaFile.fromMap({
          'path': '/chopstats-refused/too_big',
          'type': 'file',
          'mimeType': 'application/x-chopstats-refused',
        }),
      ]);
      expect(batch.paths, isEmpty);
      expect(batch.refused, [_big]);
    });

    // Device QA (2026-11-22, PR81-QA-3): Android has no type for a CR3,
    // 3FR, RWL, SR2, SRF or X3F, so MainActivity refuses one in a share of
    // several (no listed types) for its type, before any copy, and the
    // line called it a kind of file Chopstats can't read. Its refused item
    // now carries its name's extension, which names it as a copy of that
    // name is named; nothing else of a name is ever named.
    test('a refused item\'s extension names an image format share intake '
        'does not read, as a copy\'s name does; any other leaves it a kind '
        'of file, and the path without one reads as before', () {
      final batch = sharedBatchOf([
        _copied('/cache/shared_photos/1/IMG_1.jpg'),
        _refusedItem('file_type/cr3'),
        _refusedItem('file_type/3fr'),
        _refusedItem('file_type/rwl'),
        _refusedItem('file_type/sr2'),
        _refusedItem('file_type/srf'),
        _refusedItem('file_type/x3f'),
        _refusedItem('file_type/avif'),
        // No image format share intake names: a kind of file, as before.
        _refusedItem('file_type/txt'),
        _refusedItem('file_type/pdf'),
        _refusedItem('file_type/jpg'), // read when copied: never named
        _refusedItem('file_type/mom'), // 'Dinner.Mom': part of a name
        _refusedItem('file_type'), // the path before PR81-QA-3
        // Not as MainActivity sends an extension: never named.
        _refusedItem('file_type/CR3'),
        _refusedItem('file_type/x.cr3'),
        _refusedItem('file_type/'),
        // Only a type refusal's extension is read.
        _refusedItem('video/cr3'),
        _refusedItem('too_big/cr3'),
        // An unknown reason, or more than a reason and an extension.
        _refusedItem('something_new/cr3'),
        _refusedItem('file_type/cr3/x'),
      ]);
      expect(batch.paths, ['/cache/shared_photos/1/IMG_1.jpg']);
      expect(batch.refused, [
        ...List.filled(7, _type),
        ...List.filled(8, _file),
        _video,
        _big,
        _gone,
        _gone,
      ]);
      expect(batch.photoTypes,
          ['CR3', '3FR', 'RWL', 'SR2', 'SRF', 'X3F', 'AVIF']);
      // As the plugin's JSON reads (its Dart side parses every event so).
      final json = sharedBatchOf([
        SharedMediaFile.fromMap({
          'path': '/chopstats-refused/file_type/cr3',
          'type': 'file',
          'mimeType': 'application/x-chopstats-refused',
        }),
      ]);
      expect(json.paths, isEmpty);
      expect(json.refused, [_type]);
      expect(json.photoTypes, ['CR3']);
      // The same refusal a copy of that name gives (ShareIntake._fromPath
      // names the type from the name: sharedPhotoTypeOf).
      for (final ext in refusedPhotoExtensions) {
        final item =
            sharedBatchOf([_refusedItem('file_type/${ext.substring(1)}')]);
        expect(item.refused, [_type], reason: ext);
        expect(item.photoTypes, [sharedPhotoTypeOf('IMG_0001$ext')],
            reason: ext);
      }
    });

    test('the type a refused file\'s name gives: only an image format share '
        'intake does not read', () {
      expect(sharedPhotoTypeOf('IMG_1.avif'), 'AVIF');
      expect(sharedPhotoTypeOf('PXL_20261121.RAW-01.dng'), 'DNG');
      expect(sharedPhotoTypeOf('scan.Bmp'), 'BMP');
      expect(sharedPhotoTypeOf('_MG_0001.CR2'), 'CR2');
      expect(sharedPhotoTypeOf('B0001.3fr'), '3FR');
      for (final ext in refusedPhotoExtensions) {
        expect(hasSupportedPhotoExtension('a$ext'), isFalse, reason: ext);
        expect(sharedPhotoTypeOf('a$ext'), ext.substring(1).toUpperCase());
      }
      for (final name in [
        'IMG_1731500000000', // no extension
        'a.',
        'clip.0001', // digits only
        'a.extension',
        'a.b-c',
        'a.jp g',
        'a.ü',
        // Parts of a sender's name, never a type.
        'Lunch with.Sarah',
        'Dinner.Mom',
        'Dinner with J.Smith',
        'Pho at St.Elmo',
        'IMG_1234.copy',
        'lunch.final',
        'IMG_1234.jpg.bak',
        // Files that are no photo: a kind of file, not a photo type.
        'notes.txt',
        'clip.mp4',
        'menu.pdf',
        // Read as photos, never refused for their type.
        'scan.tif',
        'photo.jfif',
        'photo.jpe',
      ]) {
        expect(sharedPhotoTypeOf(name), isNull, reason: name);
      }
    });

    test('a .tif, .jfif or .jpe is read as the TIFF or JPEG it is', () async {
      for (final name in ['scan.tif', 'scan.TIF', 'photo.jfif', 'photo.JPE']) {
        expect(hasSupportedPhotoExtension(name), isTrue, reason: name);
      }
      final source = _Source();
      files['/shared/scan.tif'] = Uint8List.fromList([1]);
      files['/shared/photo.jfif'] = Uint8List.fromList([2]);
      files['/shared/photo.jpe'] = Uint8List.fromList([3]);
      final got = <IntakePhoto>[];
      final sub = intakeOf(source).photos().listen(got.add);
      source.controller.add(const SharedBatch(
          ['/shared/scan.tif', '/shared/photo.jfif', '/shared/photo.jpe']));
      await pumpEventQueue();
      expect(got.map((p) => p.fileName),
          ['scan.tif', 'photo.jfif', 'photo.jpe'],
          reason: 'three photos, and no note');
      await sub.cancel();
    });
  });

  group('the main reason', () {
    test('the reason of the most files; between as many, a type first',
        () {
      expect(_files([_big, _type, _big]).mainReason, _big);
      expect(_files([_gone, _type]).mainReason, _type);
      expect(_files([_big, _video]).mainReason, _video);
      expect(_files([_gone, _big]).mainReason, _big);
      expect(_files([_gone, _file]).mainReason, _file);
      expect(_files([_gone]).mainReason, _gone);
    });

    test('the types named: the type of the most files first, each once', () {
      expect(_files([_type, _type, _type], ['AVIF', 'DNG', 'DNG']).typesNamed,
          ['DNG', 'AVIF']);
      expect(_files([_type, _type], ['DNG', 'AVIF']).typesNamed,
          ['DNG', 'AVIF'],
          reason: 'as many files: the one seen first');
    });
  });

  group('share intake: one note after the share\'s photos', () {
    test('iOS: the files that gave no photo, in the order they were looked '
        'at, after the photo', () async {
      final source = _Source();
      final intake = intakeOf(source);
      files['/shared/lunch.jpg'] = Uint8List.fromList([1, 2, 3]);
      files['/shared/scan.avif'] = Uint8List.fromList([4]);
      files['/shared/big.jpg'] = Uint8List(maxPhotoBytes + 1);
      files['/shared/empty.jpg'] = Uint8List(0);
      final got = <IntakePhoto>[];
      final sub = intake.photos().listen(got.add);
      source.controller.add(const SharedBatch([
        '/shared/scan.avif',
        '/shared/lunch.jpg',
        '/shared/big.jpg',
        '/shared/empty.jpg',
        '/shared/gone.jpg', // nothing to read
      ]));
      await pumpEventQueue();
      expect(got.map((p) => p.fileName), ['lunch.jpg', '']);
      final note = got.last;
      expect(note.refused!.reasons, [_type, _big, _gone, _gone]);
      expect(note.refused!.photoTypes, ['AVIF']);
      expect(note.shareDelivery, got.first.shareDelivery);
      // A note is no photo: nothing to read, ask about or send.
      expect(note.bytes, isEmpty);
      expect(note.deliberate, isFalse);
      expect(note.onSettled, isNull);
      // The refused copies are deleted at once, as before.
      expect(cleaned, containsAll(['/shared/scan.avif', '/shared/big.jpg']));
      await sub.cancel();
    });

    test('a share with nothing refused has no note', () async {
      final source = _Source();
      files['/shared/lunch.jpg'] = Uint8List.fromList([1]);
      final got = <IntakePhoto>[];
      final sub = intakeOf(source).photos().listen(got.add);
      source.controller.add(const SharedBatch(['/shared/lunch.jpg']));
      await pumpEventQueue();
      expect(got.map((p) => p.refused), [null]);
      await sub.cancel();
    });

    test('Android: the note comes once the share\'s last file is looked at, '
        'behind its photos, paused or not', () async {
      final source = _Source();
      final intake = intakeOf(source, android: true);
      files['/shared/1/a.jpg'] = Uint8List.fromList([1]);
      files['/shared/2/b.jpg'] = Uint8List.fromList([2]);
      files['/shared/3/c.dng'] = Uint8List.fromList([3]);
      final got = <IntakePhoto>[];
      late StreamSubscription<IntakePhoto> sub;
      // Like the pipeline: paused for each photo's turn.
      sub = intake.photos().listen((p) {
        got.add(p);
        if (p.refused != null) return;
        sub.pause();
        Future<void>.delayed(const Duration(milliseconds: 5), () {
          p.onSettled!();
          sub.resume();
        });
      });
      source.controller.add(const SharedBatch(
          ['/shared/1/a.jpg', '/shared/3/c.dng', '/shared/2/b.jpg'],
          refused: [_video]));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(got.map((p) => p.fileName), ['a.jpg', 'b.jpg', '']);
      // MainActivity's refusals first (before any copy), then the copies'.
      expect(got.last.refused!.reasons, [_video, _type]);
      expect(got.last.refused!.photoTypes, ['DNG']);
      expect(intake.photosPending.value, isFalse);
      await sub.cancel();
    });

    test('Android, cold start: a launch share MainActivity refused whole is '
        'still a delivery, with no photo in it', () async {
      final source = _Source()
        ..initial = const SharedBatch([], refused: [_video, _big]);
      final intake = intakeOf(source, android: true);
      final got = <IntakePhoto>[];
      final pending = <bool>[];
      intake.photosPending.addListener(
          () => pending.add(intake.photosPending.value));
      final sub = intake.photos().listen(got.add);
      await pumpEventQueue();
      expect(got.single.refused!.reasons, [_video, _big]);
      expect(got.single.shareDelivery, 1);
      expect(intake.arrivedDelivery, 1);
      expect(intake.photoCountOf(1), 0, reason: 'no photo to count');
      expect(intake.photosPending.value, isFalse);
      expect(pending, isNot(contains(true)),
          reason: 'nothing waits on disk for it');
      expect(read, isEmpty);
      await sub.cancel();
    });

    // PR81-QA-3: MainActivity's refused CR3 is the photo type a copy of it
    // would be, named in its share's note, and still no photo: never
    // counted (ShareDeliveries.photoCountOf), never read.
    test('Android: a CR3 MainActivity refused is named in the note, ahead of '
        'the copies\' refusals, and never counted or read', () async {
      final source = _Source();
      final intake = intakeOf(source, android: true);
      files['/shared/1/a.jpg'] = Uint8List.fromList([1]);
      files['/shared/2/b.dng'] = Uint8List.fromList([2]);
      final got = <IntakePhoto>[];
      final counts = <int>[];
      final sub = intake.photos().listen((p) {
        got.add(p);
        counts.add(intake.photoCountOf(p.shareDelivery!));
        p.onSettled?.call();
      });
      source.controller.add(sharedBatchOf([
        _copied('/shared/1/a.jpg'),
        _copied('/shared/2/b.dng'),
        _refusedItem('file_type/cr3'),
        _refusedItem('file_type/pdf'),
      ]));
      await pumpEventQueue();
      expect(got.map((p) => p.fileName), ['a.jpg', '']);
      expect(got.last.refused!.reasons, [_type, _file, _type]);
      expect(got.last.refused!.photoTypes, ['CR3', 'DNG']);
      expect(counts, [1, 1], reason: 'the JPEG only');
      expect(read, ['/shared/1/a.jpg']);
      await sub.cancel();
    });

    test('Android, cold start: a launch share of RAW files MainActivity '
        'refused whole names them, with no photo to count', () async {
      final source = _Source()
        ..initial = sharedBatchOf(
            [_refusedItem('file_type/cr3'), _refusedItem('file_type/x3f')]);
      final intake = intakeOf(source, android: true);
      final got = <IntakePhoto>[];
      final sub = intake.photos().listen(got.add);
      await pumpEventQueue();
      expect(got.single.refused!.reasons, [_type, _type]);
      expect(got.single.refused!.photoTypes, ['CR3', 'X3F']);
      expect(intake.photoCountOf(1), 0, reason: 'no photo to count');
      expect(intake.photosPending.value, isFalse);
      expect(read, isEmpty);
      await sub.cancel();
    });

    test('Android, a share while the app runs: refused whole, then one with '
        'photos, each its own delivery and note', () async {
      final source = _Source();
      final intake = intakeOf(source, android: true);
      files['/shared/1/a.jpg'] = Uint8List.fromList([1]);
      final got = <IntakePhoto>[];
      final sub = intake.photos().listen((p) {
        got.add(p);
        p.onSettled?.call();
      });
      source.controller.add(const SharedBatch([], refused: [_file]));
      await pumpEventQueue();
      source.controller
          .add(const SharedBatch(['/shared/1/a.jpg'], refused: [_big]));
      await pumpEventQueue();
      expect(
          got.map((p) =>
              '${p.shareDelivery} ${p.fileName} ${p.refused?.reasons}'),
          [
            '1  [ShareRefusal.fileType]',
            '2 a.jpg null',
            '2  [ShareRefusal.tooBig]',
          ]);
      await sub.cancel();
    });

    test('a share answered Not now has no note: its own line says nothing '
        'was sent', () async {
      final source = _Source();
      final intake = intakeOf(source, android: true);
      files['/shared/1/a.jpg'] = Uint8List.fromList([1]);
      files['/shared/2/b.avif'] = Uint8List.fromList([2]);
      final got = <IntakePhoto>[];
      late StreamSubscription<IntakePhoto> sub;
      sub = intake.photos().listen((p) {
        got.add(p);
        // The question about the first photo: Not now covers its share.
        sub.pause();
        intake.declineDeliveries({p.shareDelivery!});
        sub.resume();
      });
      source.controller.add(const SharedBatch(
          ['/shared/1/a.jpg', '/shared/2/b.avif'],
          refused: [_video]));
      await pumpEventQueue();
      expect(got.map((p) => p.fileName), ['a.jpg']);
      expect(got.where((p) => p.refused != null), isEmpty);
      await sub.cancel();
    });
  });

  group('the consent gate', () {
    IntakePhoto photo(String id, int delivery) =>
        IntakePhoto(Uint8List.fromList([1, 2, 3]), id, '$id.jpg',
            deliberate: true, shareDelivery: delivery);
    IntakePhoto note(int delivery) => IntakePhoto.refusedNote(
        _files([_type], ['AVIF']),
        shareDelivery: delivery);

    test('a share whose every file was refused asks nothing, even with the '
        'recipient not allowed yet', () async {
      final gate = SharedPhotoConsentGate(FakeSettings()..aiConsent = {});
      var asked = 0;
      gate.attach(() async {
        asked++;
        return false;
      });
      final out = await gate.gate(Stream.value(note(1))).toList();
      expect(out.single.refused, isNotNull);
      expect(asked, 0);
    });

    test('the note waits behind its share\'s question, then follows the '
        'photo; after Not now it goes with the share', () async {
      final settings = FakeSettings()..aiConsent = {};
      final gate = SharedPhotoConsentGate(settings);
      final answers = <Completer<bool>>[];
      gate.attach(() async {
        final answer = Completer<bool>();
        answers.add(answer);
        final yes = await answer.future;
        if (yes) settings.aiConsent = {...allAiConsentRoutes};
        return yes;
      });
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed
          .add(p.refused == null ? p.assetId : 'note${p.shareDelivery}'));
      input
        ..add(photo('a', 1))
        ..add(note(1));
      await pumpEventQueue();
      expect(answers, hasLength(1));
      expect(passed, isEmpty, reason: 'the question is open');
      answers.last.complete(true);
      await pumpEventQueue();
      expect(passed, ['a', 'note1']);
      // Withdrawn since: the next share asks again, and its Not now takes
      // the note with the photo.
      settings.aiConsent = {};
      input
        ..add(photo('b', 2))
        ..add(note(2));
      await pumpEventQueue();
      expect(answers, hasLength(2));
      answers.last.complete(false);
      await pumpEventQueue();
      expect(passed, ['a', 'note1']);
      // A later share asks for itself, and its note follows its photo.
      input
        ..add(photo('c', 3))
        ..add(note(3));
      await pumpEventQueue();
      expect(answers, hasLength(3));
      answers.last.complete(true);
      await pumpEventQueue();
      expect(passed, ['a', 'note1', 'c', 'note3']);
      await sub.cancel();
      await input.close();
    });

    test('a Not now leaves out a share made while it was open that has no '
        'photo left to send: its note still passes', () async {
      final gate = SharedPhotoConsentGate(FakeSettings()..aiConsent = {});
      final deliveries = _Deliveries()..photos[1] = 1;
      final answer = Completer<bool>();
      final notSent = <int>[];
      gate.attach(() async {
        final yes = await answer.future;
        if (!yes) notSent.add(gate.declineOpenQuestion());
        return yes;
      });
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream, deliveries: deliveries).listen((p) =>
          passed.add(p.refused == null ? p.assetId : 'note${p.shareDelivery}'));
      input.add(photo('a', 1));
      await pumpEventQueue();
      // Made while it is asked: a share refused whole (Android, before any
      // copy), one whose only copy was read and refused (iOS reads each at
      // once), and one with a photo.
      deliveries.photos
        ..[2] = 0
        ..[3] = 0
        ..[4] = 1;
      input
        ..add(note(2))
        ..add(note(3))
        ..add(photo('d', 4))
        ..add(note(4));
      answer.complete(false);
      await pumpEventQueue();
      expect(notSent, [2], reason: 'a and d');
      expect(deliveries.declined, {1, 4});
      expect(passed, ['note2', 'note3']);
      await sub.cancel();
      await input.close();
    });
  });

  group('the pipeline', () {
    test('says the note on its turn, after the share\'s photos, and never '
        'processes it', () async {
      final dao = FakeDao();
      var analyses = 0;
      final said = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: FakeAnalyzer()
            ..nextPhotoOutcome = _meal
            ..onAnalyze = () async {
              analyses++;
              await Future<void>.delayed(const Duration(milliseconds: 10));
            },
          notify: said.add,
          hasher: (bytes) async => 'h${bytes.join('-')}',
          thumbnailer: (_) async => null);
      final stream = StreamController<IntakePhoto>();
      pipeline.bindStream(stream.stream);
      stream
        ..add(IntakePhoto(Uint8List.fromList([7]), '', 'a.jpg',
            deliberate: true, shareDelivery: 1))
        ..add(IntakePhoto.refusedNote(_files([_big]), shareDelivery: 1))
        ..add(IntakePhoto.refusedNote(_files([_video, _video]),
            shareDelivery: 2));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(said.map((o) => o.kind), [
        PhotoOutcomeKind.saved,
        PhotoOutcomeKind.refusedFiles,
        PhotoOutcomeKind.refusedFiles,
      ]);
      expect(said[1].refused!.reasons, [_big]);
      expect(said[1].shared, isTrue);
      expect(said[1].message, 'One shared file was skipped.');
      expect(said[2].message, '2 shared files were skipped.');
      expect(analyses, 1, reason: 'the notes reach no analyzer');
      expect(dao.ledger.keys, ['h7'], reason: 'nor the ledger');
      expect(pipeline.isIdle, isTrue);
      await stream.close();
      await pipeline.dispose();
    });

    test('process() turns a note into its outcome and touches nothing',
        () async {
      final dao = FakeDao();
      var analyses = 0;
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: FakeAnalyzer()..onAnalyze = () async => analyses++);
      final o = await pipeline.process(
          IntakePhoto.refusedNote(_files([_gone]), shareDelivery: 4));
      expect(o.kind, PhotoOutcomeKind.refusedFiles);
      expect(o.refused!.reasons, [_gone]);
      expect(analyses, 0);
      expect(dao.ledger, isEmpty);
      expect(glassesCheckOutcome(o), isNull);
      expect(unannouncedOutcome(o), same(o));
    });
  });

  group('the line', () {
    String line(AppLocalizations l, RefusedShareFiles r) =>
        outcomeSnackbar(l, refusedFilesOutcome(r));

    test('says how many and the main reason, as the snackbar says it', () {
      expect(line(en, _files([_type, _type], ['AVIF', 'AVIF'])),
          "2 shared files were skipped: Chopstats can't read AVIF photos yet.");
      expect(line(en, _files([_type], ['DNG'])),
          "One shared file was skipped: Chopstats can't read DNG photos yet.");
      expect(line(en, _files([_big])),
          'One shared file was skipped because it is over 25 MB.');
      expect(line(en, _files([_big, _big, _big])),
          '3 shared files were skipped because they are over 25 MB.');
      expect(line(en, _files([_video])),
          'One shared file was skipped: Chopstats logs photos, not videos.');
      expect(line(en, _files([_file])),
          "One shared file was skipped: Chopstats can't read that kind of "
          'file.');
      expect(line(en, _files([_file, _file])),
          "2 shared files were skipped: Chopstats can't read those kinds of "
          'files.');
      expect(line(en, _files([_gone])),
          'One shared file was skipped because it could not be read.');
      expect(line(en, _files([_gone, _gone])),
          '2 shared files were skipped because they could not be read.');
    });

    test('a reason that covers only some of the files says how many it '
        'covers, whichever reason it is', () {
      expect(line(en, _files([_big, _type, _big], ['AVIF'])),
          '3 shared files were skipped, 2 of them because they are over '
          '25 MB.');
      expect(line(en, _files([_big, _gone])),
          '2 shared files were skipped, one of them because it is over 25 MB.');
      expect(line(en, _files([_gone, _gone, _video])),
          '3 shared files were skipped, 2 of them because they could not be '
          'read.');
      expect(line(en, _files([_type, _type, _big], ['AVIF', 'DNG'])),
          '3 shared files were skipped, 2 of them because Chopstats can\'t '
          'read AVIF/DNG photos yet.');
      expect(
          line(
              en,
              _files([_type, _type, _type, _type, _type],
                  ['AVIF', 'DNG', 'CR2', 'NEF', 'AVIF'])),
          "5 shared files were skipped: Chopstats can't read AVIF/DNG/CR2 "
          'photos yet.',
          reason: 'at most three types named');
      // A tie: the earlier reason (a video) is said with how many it
      // covers, so the big photo is not called a video.
      expect(line(en, _files([_video, _big])),
          '2 shared files were skipped, one of them a video: Chopstats logs '
          'photos, not videos.');
      expect(line(en, _files([_video, _gone])),
          '2 shared files were skipped, one of them a video: Chopstats logs '
          'photos, not videos.');
      expect(line(en, _files([_video, _video, _big])),
          '3 shared files were skipped, 2 of them videos: Chopstats logs '
          'photos, not videos.');
      // One type among five reasons.
      expect(line(en, _files([_type, _video, _file, _big, _gone], ['DNG'])),
          '5 shared files were skipped, one of them because Chopstats can\'t '
          'read DNG photos yet.');
      expect(line(en, _files([_file, _file, _gone])),
          '3 shared files were skipped, 2 of them because Chopstats can\'t '
          'read those kinds of files.');
      expect(line(en, _files([_file, _big])),
          '2 shared files were skipped, one of them because Chopstats can\'t '
          'read that kind of file.');
      // Over 25 MB covers the most: said with its count, as before.
      expect(line(en, _files([_big, _big, _video, _file])),
          '4 shared files were skipped, 2 of them because they are over '
          '25 MB.');
    });

    test('in Chinese', () {
      expect(line(zh, _files([_type, _type], ['AVIF', 'AVIF'])),
          '有 2 个分享的文件被跳过：筷拍暂时无法读取 AVIF 格式的照片。');
      expect(line(zh, _files([_big])), '有 1 个分享的文件超过 25 MB，已跳过。');
      expect(line(zh, _files([_video])), '有 1 个分享的文件被跳过：筷拍只记录照片，不记录视频。');
      expect(line(zh, _files([_file])), '有 1 个分享的文件被跳过：筷拍无法读取这类文件。');
      expect(line(zh, _files([_file, _file])), '有 2 个分享的文件被跳过：筷拍无法读取这类文件。');
      expect(line(zh, _files([_gone, _gone])), '有 2 个分享的文件无法读取，已跳过。');
      expect(line(zh, _files([_big, _big, _type], ['DNG'])),
          '有 3 个分享的文件被跳过，其中 2 个超过 25 MB。');
      expect(line(zh, _files([_gone, _gone, _file])),
          '有 3 个分享的文件被跳过，其中 2 个无法读取。');
      expect(line(zh, _files([_type, _type, _big], ['AVIF', 'DNG'])),
          '有 3 个分享的文件被跳过，其中 2 个是筷拍暂时无法读取的 AVIF/DNG 格式照片。');
      expect(line(zh, _files([_video, _big])),
          '有 2 个分享的文件被跳过，其中 1 个是视频：筷拍只记录照片，不记录视频。');
      expect(line(zh, _files([_file, _file, _gone])),
          '有 3 个分享的文件被跳过，其中 2 个是筷拍无法读取的文件类型。');
    });

    test('never a file\'s name or path, only the type its name gives',
        () async {
      final source = _Source();
      const folder = '/shared/Trip to Mom';
      files['$folder/IMG_20261121_secret.avif'] = Uint8List.fromList([1]);
      for (final name in [
        'Lunch with.Sarah',
        'Dinner.Mom',
        'Dinner with J.Smith',
        'IMG_1234.copy',
      ]) {
        files['$folder/$name'] = Uint8List.fromList([2]);
      }
      final got = <IntakePhoto>[];
      final sub = intakeOf(source).photos().listen(got.add);
      // A share with an AVIF, then one whose names have a dot in them but
      // give no type.
      source.controller.add(const SharedBatch([
        '$folder/IMG_20261121_secret.avif',
        '$folder/menu.longextension',
      ]));
      source.controller.add(const SharedBatch([
        '$folder/Lunch with.Sarah',
        '$folder/Dinner.Mom',
        '$folder/Dinner with J.Smith',
        '$folder/IMG_1234.copy',
      ]));
      await pumpEventQueue();
      expect(got, hasLength(2));
      for (final l in [en, zh]) {
        final said = [for (final note in got) line(l, note.refused!)];
        for (final part in [
          'trip',
          'secret',
          'img_',
          '/',
          'longext',
          'sarah',
          'mom',
          'smith',
          'copy',
        ]) {
          expect(said.join('\n').toLowerCase(), isNot(contains(part)),
              reason: part);
        }
        expect(said.first, contains('AVIF'));
        expect(said.last, isNot(contains('photos yet')),
            reason: 'no type named for them');
      }
      expect(line(en, got.last.refused!),
          "4 shared files were skipped: Chopstats can't read those kinds of "
          'files.');
      await sub.cancel();
    });

    // PR81-QA-3: MainActivity sends any short extension of letters and
    // digits with an item refused for its type; share intake names only an
    // image format it does not read.
    test('a refused item\'s extension that is no such image format never '
        'reaches the line', () async {
      final source = _Source();
      final got = <IntakePhoto>[];
      final sub = intakeOf(source, android: true).photos().listen(got.add);
      const parts = ['mom', 'copy', 'txt', 'jpg', 'heic'];
      source.controller.add(sharedBatchOf([
        for (final part in parts) _refusedItem('file_type/$part'),
      ]));
      await pumpEventQueue();
      for (final l in [en, zh]) {
        final said = line(l, got.single.refused!).toLowerCase();
        for (final part in parts) {
          expect(said, isNot(contains(part)), reason: part);
        }
      }
      expect(line(en, got.single.refused!),
          "5 shared files were skipped: Chopstats can't read those kinds of "
          'files.');
      await sub.cancel();
    });
  });

  // di.dart's share path: share intake → consent gate (told the
  // deliveries) → pipeline, its notify worded by outcomeSnackbar.
  group('as the app wires it', () {
    late FakeSettings settings;
    late SharedPhotoConsentGate gate;
    late List<String> lines;
    late int asked;
    late int analyses;
    late List<bool> answers;
    late PhotoPipeline pipeline;
    late _Source source;

    Future<void> start(
        {SharedBatch? launch,
        AppLocalizations? l,
        bool android = true}) async {
      settings = FakeSettings()..aiConsent = {};
      gate = SharedPhotoConsentGate(settings);
      lines = [];
      asked = 0;
      analyses = 0;
      gate.attach(() async {
        final yes = answers[asked++];
        if (yes) settings.aiConsent = {...allAiConsentRoutes};
        return yes;
      });
      pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()
            ..nextPhotoOutcome = _meal
            ..onAnalyze = () async => analyses++,
          notify: (o) => lines.add(outcomeSnackbar(l ?? en, o)),
          hasher: (bytes) async => 'h${bytes.join('-')}',
          thumbnailer: (_) async => null);
      source = _Source();
      if (launch != null) source.initial = launch;
      final intake = intakeOf(source, android: android);
      pipeline.bindStream(gate.gate(intake.photos(), deliveries: intake));
    }

    /// The question stays open until [answer] completes; Not now words its
    /// line as the app shell does (askSharedPhotoConsent), counted into
    /// [notSent].
    void askUntil(Completer<bool> answer, List<int> notSent) {
      gate.attach(() async {
        asked++;
        final yes = await answer.future;
        if (yes) {
          settings.aiConsent = {...allAiConsentRoutes};
        } else {
          notSent.add(gate.declineOpenQuestion());
        }
        return yes;
      });
    }

    tearDown(() => pipeline.dispose());

    test('a share with an AVIF while the app runs: one question, the photo '
        'logged, then one line for the AVIF; nothing sent for it', () async {
      answers = [true];
      await start();
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      files['/shared/2/IMG_2.avif'] = Uint8List.fromList([2, 2]);
      source.controller.add(
          const SharedBatch(['/shared/1/IMG_1.jpg', '/shared/2/IMG_2.avif']));
      await pumpEventQueue(times: 100);
      expect(asked, 1);
      expect(analyses, 1);
      expect(lines, [
        'Meal logged: Beef noodles — ~620 kcal',
        "One shared file was skipped: Chopstats can't read AVIF photos yet.",
      ]);
    });

    test('a launch share MainActivity refused whole: no question, one line',
        () async {
      answers = [];
      await start(
          launch: const SharedBatch([], refused: [_video, _video, _big]));
      await pumpEventQueue(times: 100);
      expect(asked, 0);
      expect(analyses, 0);
      expect(lines, [
        '3 shared files were skipped, 2 of them videos: Chopstats logs '
            'photos, not videos.'
      ]);
    });

    test('a launch share with a photo and a file over 25 MB, in Chinese',
        () async {
      answers = [true];
      await start(
          launch: const SharedBatch(['/shared/1/IMG_1.jpg'], refused: [_big]),
          l: zh);
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      await pumpEventQueue(times: 100);
      expect(asked, 1);
      expect(analyses, 1);
      expect(lines, hasLength(2));
      expect(lines.last, '有 1 个分享的文件超过 25 MB，已跳过。');
    });

    test('a share of one AVIF while the app runs: no question, one line',
        () async {
      answers = [];
      await start();
      files['/shared/1/IMG_2.avif'] = Uint8List.fromList([2]);
      source.controller.add(const SharedBatch(['/shared/1/IMG_2.avif']));
      await pumpEventQueue(times: 100);
      expect(asked, 0);
      expect(lines, [
        "One shared file was skipped: Chopstats can't read AVIF photos yet."
      ]);
      expect(cleaned, ['/shared/1/IMG_2.avif']);
    });

    test('Not now: nothing sent and no skipped line, only the question\'s '
        'own', () async {
      answers = [false];
      await start();
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      files['/shared/2/IMG_2.avif'] = Uint8List.fromList([2, 2]);
      source.controller.add(const SharedBatch(
          ['/shared/1/IMG_1.jpg', '/shared/2/IMG_2.avif'],
          refused: [_video]));
      await pumpEventQueue(times: 100);
      expect(asked, 1);
      expect(analyses, 0);
      expect(lines, isEmpty);
    });

    // Another share's Not now covers the shares made while its question
    // is open, but not one with nothing to send: that one was never asked
    // about, and its line is the only word it gets.
    test('Android: a share refused whole while another share\'s question is '
        'open still gets its line after that share\'s Not now', () async {
      answers = [];
      await start();
      final answer = Completer<bool>();
      final notSent = <int>[];
      askUntil(answer, notSent);
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      source.controller.add(const SharedBatch(['/shared/1/IMG_1.jpg']));
      await pumpEventQueue(times: 100);
      expect(asked, 1, reason: 'the question is open');
      source.controller.add(const SharedBatch([], refused: [_big]));
      await pumpEventQueue(times: 100);
      expect(lines, isEmpty, reason: 'it waits behind the open question');
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(notSent, [1], reason: 'the photo asked about, nothing else');
      expect(asked, 1);
      expect(analyses, 0, reason: 'nothing sent');
      expect(lines, ['One shared file was skipped because it is over 25 MB.']);
    });

    // Device QA (2026-11-22, PR81-QA-1): on Android the AVIF's copy waits
    // unread while the question is open; counted as a photo, the Not now
    // covered its share, dropped its line and said "2 shared photos".
    test('Android: a share of one AVIF while another share\'s question is '
        'open gets its line after that share\'s Not now, which counts the '
        'photo asked about only', () async {
      answers = [];
      await start();
      final answer = Completer<bool>();
      final notSent = <int>[];
      askUntil(answer, notSent);
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      files['/shared/2/IMG_2.avif'] = Uint8List.fromList([2, 2]);
      source.controller.add(const SharedBatch(['/shared/1/IMG_1.jpg']));
      await pumpEventQueue(times: 100);
      expect(asked, 1, reason: 'the question is open');
      source.controller.add(const SharedBatch(['/shared/2/IMG_2.avif']));
      await pumpEventQueue(times: 100);
      expect(lines, isEmpty, reason: 'it waits behind the open question');
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(notSent, [1], reason: 'the photo asked about, not the AVIF');
      expect(asked, 1);
      expect(analyses, 0, reason: 'nothing sent');
      expect(lines, [
        "One shared file was skipped: Chopstats can't read AVIF photos yet."
      ]);
      expect(cleaned, contains('/shared/2/IMG_2.avif'));
    });

    test('Android: a share of a photo and an AVIF made while the question is '
        'open goes with its Not now, which counts the photos only', () async {
      answers = [];
      await start();
      final answer = Completer<bool>();
      final notSent = <int>[];
      askUntil(answer, notSent);
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      files['/shared/2/IMG_2.jpg'] = Uint8List.fromList([2, 2]);
      files['/shared/3/IMG_3.avif'] = Uint8List.fromList([3, 3]);
      source.controller.add(const SharedBatch(['/shared/1/IMG_1.jpg']));
      await pumpEventQueue(times: 100);
      source.controller.add(const SharedBatch(
          ['/shared/2/IMG_2.jpg', '/shared/3/IMG_3.avif']));
      await pumpEventQueue(times: 100);
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(notSent, [2], reason: 'IMG_1 and IMG_2');
      expect(asked, 1, reason: 'the second share was answered too');
      expect(analyses, 0);
      expect(lines, isEmpty);
      expect(cleaned,
          containsAll(['/shared/2/IMG_2.jpg', '/shared/3/IMG_3.avif']));
    });

    // Device QA (2026-11-22, PR81-QA-3): a CR3 among several reached the
    // line as a kind of file; shared alone as an image, it was named.
    test('Android: a share of a photo and a CR3 MainActivity refused for its '
        'type: the photo logged, then the CR3 named as a copy of it is',
        () async {
      answers = [true];
      await start();
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      source.controller.add(sharedBatchOf(
          [_copied('/shared/1/IMG_1.jpg'), _refusedItem('file_type/cr3')]));
      await pumpEventQueue(times: 100);
      expect(asked, 1);
      expect(analyses, 1);
      expect(lines, [
        'Meal logged: Beef noodles — ~620 kcal',
        "One shared file was skipped: Chopstats can't read CR3 photos yet.",
      ]);
      expect(read, ['/shared/1/IMG_1.jpg'], reason: 'nothing read for it');
      // A CR3 shared alone as an image is copied, and its copy's name
      // gives the same line.
      files['/shared/2/IMG_2.cr3'] = Uint8List.fromList([2]);
      source.controller.add(const SharedBatch(['/shared/2/IMG_2.cr3']));
      await pumpEventQueue(times: 100);
      expect(lines, hasLength(3));
      expect(lines.last,
          "One shared file was skipped: Chopstats can't read CR3 photos yet.");
      expect(read, ['/shared/1/IMG_1.jpg']);
      // With a text file too: the CR3 named, the text file a kind of file.
      files['/shared/3/IMG_3.jpg'] = Uint8List.fromList([3, 3]);
      source.controller.add(sharedBatchOf([
        _copied('/shared/3/IMG_3.jpg'),
        _refusedItem('file_type/x3f'),
        _refusedItem('file_type/txt'),
      ]));
      await pumpEventQueue(times: 100);
      expect(analyses, 2);
      expect(lines.sublist(3), [
        'Meal logged: Beef noodles — ~620 kcal',
        '2 shared files were skipped, one of them because Chopstats can\'t '
            'read X3F photos yet.',
      ]);
    });

    test('Android: a share of RAW files MainActivity refused while another '
        'share\'s question is open: not counted as photos, and its line, '
        'naming them, comes after that share\'s Not now', () async {
      answers = [];
      await start();
      final answer = Completer<bool>();
      final notSent = <int>[];
      askUntil(answer, notSent);
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      source.controller.add(const SharedBatch(['/shared/1/IMG_1.jpg']));
      await pumpEventQueue(times: 100);
      expect(asked, 1, reason: 'the question is open');
      source.controller.add(sharedBatchOf(
          [_refusedItem('file_type/cr3'), _refusedItem('file_type/rwl')]));
      await pumpEventQueue(times: 100);
      expect(lines, isEmpty, reason: 'it waits behind the open question');
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(notSent, [1], reason: 'the photo asked about, not the RAW files');
      expect(asked, 1);
      expect(analyses, 0, reason: 'nothing sent');
      expect(lines,
          ["2 shared files were skipped: Chopstats can't read CR3/RWL photos "
              'yet.']);
    });

    // A regression guard, not a test that fails on the code before (review
    // of PR81-QA-3, 2026-11-23): a refused item is never a copy, so it never
    // counted as a photo. The CR3 is now the photo type an AVIF copy is, and
    // like the AVIF above (PR81-QA-1) it must stay out of the Not now's
    // count.
    test('Android: a share of a photo and a CR3 made while the question is '
        'open goes with its Not now, which counts the photos only', () async {
      answers = [];
      await start();
      final answer = Completer<bool>();
      final notSent = <int>[];
      askUntil(answer, notSent);
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      files['/shared/2/IMG_2.jpg'] = Uint8List.fromList([2, 2]);
      source.controller.add(const SharedBatch(['/shared/1/IMG_1.jpg']));
      await pumpEventQueue(times: 100);
      source.controller.add(sharedBatchOf(
          [_copied('/shared/2/IMG_2.jpg'), _refusedItem('file_type/cr3')]));
      await pumpEventQueue(times: 100);
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(notSent, [2], reason: 'IMG_1 and IMG_2');
      expect(asked, 1, reason: 'the second share was answered too');
      expect(analyses, 0);
      expect(lines, isEmpty);
    });

    test('iOS: a share of one AVIF while another share\'s question is open '
        '(read at once, so nothing left to send) still gets its line', () async {
      answers = [];
      await start(android: false);
      final answer = Completer<bool>();
      final notSent = <int>[];
      askUntil(answer, notSent);
      files['/shared/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      source.controller.add(const SharedBatch(['/shared/IMG_1.jpg']));
      await pumpEventQueue(times: 100);
      expect(asked, 1, reason: 'the question is open');
      files['/shared/IMG_2.avif'] = Uint8List.fromList([2, 2]);
      source.controller.add(const SharedBatch(['/shared/IMG_2.avif']));
      await pumpEventQueue(times: 100);
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(notSent, [1]);
      expect(analyses, 0);
      expect(lines, [
        "One shared file was skipped: Chopstats can't read AVIF photos yet."
      ]);
    });

    test('a share with a photo made while the question is open is still '
        'covered by its Not now, refused files and all', () async {
      answers = [];
      await start();
      final answer = Completer<bool>();
      final notSent = <int>[];
      askUntil(answer, notSent);
      files['/shared/1/IMG_1.jpg'] = Uint8List.fromList([1, 1]);
      files['/shared/2/IMG_2.jpg'] = Uint8List.fromList([2, 2]);
      source.controller.add(const SharedBatch(['/shared/1/IMG_1.jpg']));
      await pumpEventQueue(times: 100);
      source.controller
          .add(const SharedBatch(['/shared/2/IMG_2.jpg'], refused: [_video]));
      await pumpEventQueue(times: 100);
      answer.complete(false);
      await pumpEventQueue(times: 100);
      expect(notSent, [2]);
      expect(asked, 1, reason: 'the second share was answered too');
      expect(analyses, 0);
      expect(lines, isEmpty);
    });
  });
}
