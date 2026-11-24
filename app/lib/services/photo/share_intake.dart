/// Deliberate intake: share-sheet stream + in-app "recent photos" picker
/// source (spec §6, §2.3 caller policy).
///
/// Every photo emitted here carries `deliberate=true`: a human re-sending a
/// photo may reclaim failed/skipped/deleted ledger rows (the "deliberate
/// re-send" rule, spec §2.3). The share stream also carries, after a
/// share's photos, one note on its files that gave no photo
/// ([IntakePhoto.refusedNote]), which is no photo at all.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../core/contracts.dart';
import '../backup/file_pick_channel.dart' show filesChannelName;
import '../settings/app_settings.dart' show AppSettings;
import 'filename_dates.dart';
import 'glasses.dart' show captureMetaFor;
import 'photo_library.dart';

/// Spec §6.1: SUPPORTED_QUEUE_EXTENSIONS ∪ server-side .tiff, plus WebP
/// and GIF (2026-11): what Android browsers and chat apps share, and how
/// MainActivity names a nameless image stream (`IMG_<ts>.webp`, from its MIME
/// type); they were dropped without a word. Every decoder in the upload
/// chain reads both (the engine codec, iOS ImageIO, the `image` package),
/// and a GIF is sent as its first frame. Also the other names of a JPEG
/// (.jpe, .jfif) and a TIFF (.tif): the same content as .jpg and .tiff,
/// which the line for a refused file called types Chopstats can't read.
/// Not AVIF: its decoding is unverified. Content is ultimately validated
/// by decodability downstream (the analyzer's decode), not by extension —
/// this set only filters obvious non-photos out of the share sheet.
const Set<String> supportedPhotoExtensions = {
  '.jpg',
  '.jpeg',
  '.jpe',
  '.jfif',
  '.png',
  '.heic',
  '.heif',
  '.tiff',
  '.tif',
  '.webp',
  '.gif',
};

bool hasSupportedPhotoExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return supportedPhotoExtensions.contains(name.substring(dot).toLowerCase());
}

String fileBaseName(String path) {
  final sep = path.lastIndexOf(RegExp(r'[/\\]'));
  return sep < 0 ? path : path.substring(sep + 1);
}

/// The image formats share intake does not read that the line for a
/// refused file names by type ([sharedPhotoTypeOf]): AVIF and JPEG XL
/// (decoding unverified), JPEG 2000, DNG and the cameras' other RAW files
/// (Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax, Samsung,
/// Hasselblad, Epson, Sigma, Leica), BMP, SVG, icons and Photoshop files.
/// None is in [supportedPhotoExtensions].
const Set<String> refusedPhotoExtensions = {
  '.avif',
  '.jxl',
  '.jp2',
  '.dng',
  '.cr2',
  '.cr3',
  '.crw',
  '.nef',
  '.nrw',
  '.arw',
  '.srf',
  '.sr2',
  '.raf',
  '.orf',
  '.rw2',
  '.pef',
  '.srw',
  '.3fr',
  '.erf',
  '.x3f',
  '.rwl',
  '.bmp',
  '.svg',
  '.ico',
  '.psd',
};

/// The type a refused file's [name] gives, for the line that says it was
/// skipped: 'AVIF' for 'IMG_1.avif'. Only an extension in
/// [refusedPhotoExtensions], upper-cased; null for any other name (no
/// extension, or one that is no image format: 'notes.txt', 'clip.mp4',
/// 'Dinner with J.Smith'), which the line calls a kind of file Chopstats
/// can't read. So no part of a sender's name reaches the line as a type,
/// and no other file is called a photo.
String? sharedPhotoTypeOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = name.substring(dot).toLowerCase();
  return refusedPhotoExtensions.contains(ext)
      ? ext.substring(1).toUpperCase()
      : null;
}

/// One share as the platform hands it over: its image files' [paths], and
/// the files refused before any copy was made ([refused]: on Android,
/// MainActivity's, see [androidRefusedShareType]).
class SharedBatch {
  const SharedBatch(this.paths,
      {this.refused = const [], this.photoTypes = const []});

  final List<String> paths;
  final List<ShareRefusal> refused;

  /// The type of each [ShareRefusal.photoType] file of [refused] ('CR3'),
  /// in the same order (RefusedShareFiles.photoTypes).
  final List<String> photoTypes;
}

/// receive_sharing_intent seam so tests can fake the platform stream.
abstract class SharedMediaSource {
  /// The shares made while the app is alive, one batch each.
  Stream<SharedBatch> batches();

  /// The cold-start share that launched the app (consumed once).
  Future<SharedBatch> initialBatch();
}

/// Android: the type MainActivity gives each shared item it refused
/// before any copy (MainActivity.kt withSafeShares,
/// IntakeRules.REFUSED_SHARE_TYPE). Such an item reaches the plugin as a
/// file:// URI that names no file, [androidRefusedSharePath] and the
/// reason (and, for one refused for its type, its size or a failed copy,
/// its name's extension), which the plugin hands on as the item's path
/// without opening it; it is no image, so nothing reads it. It lets the
/// share's refusals travel in the share's own event, the launch share's
/// and a held one's included, and a share whose every item was refused
/// still arrives.
const String androidRefusedShareType = 'application/x-chopstats-refused';

/// The folder part of a refused item's path (IntakeRules.REFUSED_SHARE_PATH):
/// `/chopstats-refused/<reason>`, or `/chopstats-refused/too_big/cr3` for
/// an item refused for its type, its size or a failed copy whose name
/// gives an extension (IntakeRules.refusedSharePath); a path no file has.
const String androidRefusedSharePath = '/chopstats-refused';

/// The reasons MainActivity gives a refused item, the part of its path
/// after [androidRefusedSharePath] (IntakeRules.ShareRefusal's tokens).
const Map<String, ShareRefusal> androidRefusalTokens = {
  'video': ShareRefusal.video,
  'file_type': ShareRefusal.fileType,
  'too_big': ShareRefusal.tooBig,
  'unreadable': ShareRefusal.unreadable,
};

/// An extension as MainActivity sends it with a refused item
/// (IntakeRules.refusedExtension): letters a-z and digits only.
final RegExp _refusedItemExtension = RegExp(r'^[a-z0-9]+$');

/// The reasons whose refused item may carry its name's extension
/// (IntakeRules.refusedSharePath): all but a video's.
const Set<ShareRefusal> _reasonsWithExtension = {
  ShareRefusal.fileType,
  ShareRefusal.tooBig,
  ShareRefusal.unreadable,
};

/// What MainActivity's refused item at [path] says
/// (IntakeRules.refusedSharePath): its reason, the part after
/// [androidRefusedSharePath], and, for an item refused for its type, its
/// size or a failed copy (file_type, too_big, unreadable), the extension
/// of its name that may follow: `/chopstats-refused/too_big/cr3`. An image
/// format share intake does not read is then the refusal a copy of that
/// name gives (ShareIntake._fromPath, which looks at the name before the
/// size): a photo type, named.
/// - file_type: Android has no type for a CR3, 3FR, RWL, SR2, SRF or X3F,
///   so in a share of several with no listed types such an image is
///   refused before any copy, and the line called it a kind of file
///   Chopstats can't read (device QA 2026-11-22, PR81-QA-3).
/// - too_big, unreadable: MainActivity copies such a format, up to 25 MB,
///   when it is shared alone, or typed as an image among several (a DNG).
///   One over 25 MB, or whose copy failed, was said to be over 25 MB or
///   unreadable, although Chopstats reads no file of that format, of any
///   size (device QA 2026-11-23, PR81-QA-4). Its extension is the one its
///   name gives, else its copy's name's, which its image type gives
///   (IntakeRules.failedCopyName).
/// As there, only an extension in [refusedPhotoExtensions] is named
/// ([sharedPhotoTypeOf]), so no other part of a sender's name reaches the
/// line: with any other extension (a .jpg over 25 MB, a .txt) the item
/// keeps its reason, and a video's extension is not read. A path with no
/// extension reads as before; an unknown reason, or more parts than a
/// reason and an extension, as unreadable.
(ShareRefusal, String?) _androidRefusalOf(String path) {
  const folder = '$androidRefusedSharePath/';
  final parts = path.startsWith(folder)
      ? path.substring(folder.length).split('/')
      : [fileBaseName(path)];
  final why = parts.length <= 2 ? androidRefusalTokens[parts.first] : null;
  if (why == null) return (ShareRefusal.unreadable, null);
  final extension = parts.length == 2 ? parts.last : '';
  final type = _reasonsWithExtension.contains(why) &&
          _refusedItemExtension.hasMatch(extension)
      ? sharedPhotoTypeOf('.$extension')
      : null;
  return type == null ? (why, null) : (ShareRefusal.photoType, type);
}

/// The plugin's [files] for one share as a [SharedBatch]: the images'
/// paths, and a refusal for each item that is no image. MainActivity's
/// refused items say why ([androidRefusedShareType]; an unknown reason
/// reads as unreadable), and one whose extension gives a photo type is
/// that type, named ([_androidRefusalOf]); a video or another file the
/// plugin reports as it is counts by its kind. Text and links are no
/// file: left out.
SharedBatch sharedBatchOf(List<SharedMediaFile> files) {
  final paths = <String>[];
  final refused = <ShareRefusal>[];
  final photoTypes = <String>[];
  for (final f in files) {
    if (f.mimeType == androidRefusedShareType) {
      final (why, type) = _androidRefusalOf(f.path);
      refused.add(why);
      if (type != null) photoTypes.add(type);
      continue;
    }
    switch (f.type) {
      case SharedMediaType.image:
        paths.add(f.path);
      case SharedMediaType.video:
        refused.add(ShareRefusal.video);
      case SharedMediaType.file:
        refused.add(ShareRefusal.fileType);
      case SharedMediaType.text || SharedMediaType.url:
        break;
    }
  }
  return SharedBatch(paths, refused: refused, photoTypes: photoTypes);
}

class ReceiveSharingIntentSource implements SharedMediaSource {
  @override
  Stream<SharedBatch> batches() =>
      ReceiveSharingIntent.instance.getMediaStream().map(sharedBatchOf);

  @override
  Future<SharedBatch> initialBatch() async {
    final files = await ReceiveSharingIntent.instance.getInitialMedia();
    // Consume the launch intent so a hot restart does not re-log the share.
    ReceiveSharingIntent.instance.reset();
    return sharedBatchOf(files);
  }
}

/// Android: the folder in the app's cache that MainActivity copies every
/// shared image into, one folder per image (MainActivity.kt SHARE_FOLDER;
/// review 171, C5). Share intake reads and deletes nothing outside it.
const String androidShareFolderName = 'shared_photos';

/// [androidShareFolderName] in the cache directory MainActivity copies into.
Future<String> androidSharedPhotoFolder() async =>
    '${(await getTemporaryDirectory()).path}/$androidShareFolderName';

/// The method MainActivity.kt answers on [filesChannelName] once share
/// intake listens to the plugin's live stream.
const String shareIntakeReadyMethod = 'shareIntakeReady';

/// Android: tells MainActivity that share intake listens to the plugin's
/// live stream now. receive_sharing_intent tells only a listener and keeps
/// nothing for later, and a share made after Android stopped the app's
/// process reaches MainActivity (onNewIntent, in the launch that recreates
/// it) before this engine's Dart has run: MainActivity holds such a share
/// until this word, then hands it to the plugin, whose event share intake
/// reads like any live share's (review 2026-11-19, R0). The word follows
/// the plugin's listen on the same main thread, so the plugin has its
/// listener by then. Never throws.
Future<void> androidShareIntakeReady(
    {MethodChannel channel = const MethodChannel(filesChannelName)}) async {
  try {
    await channel.invokeMethod<Object?>(shareIntakeReadyMethod);
  } on MissingPluginException {
    // No native side to tell (tests, an older build): nothing is held.
  } on PlatformException {
    // Its copies wait in the share folder for the sweep
    // (ShareIntake.strandedRecheck).
  }
}

/// Whether the absolute POSIX [path] lies inside [folder] once '.' and '..'
/// are resolved; a relative path never does.
bool isWithinFolder(String path, String folder) {
  List<String>? segments(String p) {
    if (!p.startsWith('/')) return null;
    final out = <String>[];
    for (final s in p.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (out.isEmpty) return null;
        out.removeLast();
      } else {
        out.add(s);
      }
    }
    return out;
  }

  final inner = segments(path);
  final outer = segments(folder);
  if (inner == null || outer == null || inner.length <= outer.length) {
    return false;
  }
  for (var i = 0; i < outer.length; i++) {
    if (inner[i] != outer[i]) return false;
  }
  return true;
}

/// [path] with '.' and '..' resolved, for comparing two spellings of one
/// file.
String _normalized(String path) {
  final out = <String>[];
  for (final s in path.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(s);
    }
  }
  return '/${out.join('/')}';
}

typedef FileBytesReader = Future<Uint8List?> Function(String path);
typedef SharedFileCleanup = FutureOr<void> Function(String path);

Future<Uint8List?> _readFileBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null; // unreadable share target: skip, never crash intake
  }
}

/// The plugin COPIES every share into the app's container (iOS app-group /
/// Android app dir) and its API contract says the consumer deletes the copy
/// after use — nothing else ever purges them, so skipping this leaks the
/// full-size original of every shared photo forever (storage + privacy).
/// "After use" is once the photo is settled on Android
/// (IntakePhoto.onSettled: its verdict written, or let go: released by
/// the pipeline or dropped unsent), at once on iOS.
/// Synchronous: a Not now's copies are gone before its answer returns
/// ([ShareIntake.declineDeliveries]), so an app stopped right after keeps
/// none for the next start's sweep.
void _deleteSharedFile(String path) {
  try {
    File(path).deleteSync();
  } catch (_) {
    // Best effort: a vanished/locked file must not break intake.
  }
}

/// Integration-contract factory: the integrator wires this next to
/// `createPhotoIntake` with the settings module's [AppSettings]. (Share
/// intake currently needs no settings knob — the parameter keeps the wiring
/// uniform and future-proof.)
ShareIntake createShareIntake(AppSettings settings) => ShareIntake(
    source: ReceiveSharingIntentSource(),
    library: PhotoManagerLibrary(),
    readBytes: _readFileBytes,
    listening: Platform.isAndroid ? androidShareIntakeReady : null,
    sharedFolder: Platform.isAndroid ? androidSharedPhotoFolder : null);

class ShareIntake implements ShareDeliveries {
  ShareIntake(
      {required this._source,
      required this._library,
      required this._readBytes,
      SharedFileCleanup? cleanup,
      DateTime Function()? clock,
      // §8 CAPTURED_AT_MAX_AGE_DAYS: default 45, not user-editable.
      this._capturedAtMaxAgeDays = 45,
      this._listening,
      this._sharedFolder,
      this._recheckAfter = strandedRecheck})
      : _cleanup = cleanup ?? _deleteSharedFile,
        _clock = clock ?? DateTime.now;

  /// [strandedRecheck]; shorter in tests.
  final Duration _recheckAfter;

  /// The folder a shared file must lie in to be read or deleted (Android:
  /// [androidSharedPhotoFolder]); null: any path (iOS, where the share
  /// extension writes the copies, and tests).
  final Future<String> Function()? _sharedFolder;

  /// Told once share intake listens to the live share stream (Android:
  /// [androidShareIntakeReady], so MainActivity hands over a share it held
  /// until then); null: nobody to tell (iOS, tests).
  final Future<void> Function()? _listening;

  /// Whether a copy may wait on disk for its turn: only where every copy
  /// has a path of its own (Android's share folder). See [photos].
  bool get _copiesWait => _sharedFolder != null;
  final SharedMediaSource _source;
  final PhotoLibrary _library;
  final FileBytesReader _readBytes;
  final SharedFileCleanup _cleanup;
  final DateTime Function() _clock;
  final int _capturedAtMaxAgeDays;

  /// Deliveries (IntakePhoto.shareDelivery): one per batch event, numbered
  /// as it arrives, before any of its copies is read. Its size counts only
  /// the copies whose names give a photo type ([_namedNoPhoto]), and
  /// unreadable those of them found to give no photo when read.
  int _deliveries = 0;
  final Map<int, int> _deliverySize = {};
  final Map<int, int> _deliveryUnreadable = {};

  /// Whether the copy at [path] gives no photo by its name alone (an AVIF,
  /// a DNG, a PDF: [_fromPath] refuses it before reading a byte), so it is
  /// never counted as one of its delivery's photos. On Android a copy
  /// waits to be read while the consent gate asks about another share, and
  /// counted until then it made that share's Not now cover a share of one
  /// AVIF and drop its line, and count it as a photo not sent (device QA
  /// of the skipped-files line, 2026-11-22, PR81-QA-1).
  static bool _namedNoPhoto(String path) =>
      !hasSupportedPhotoExtension(fileBaseName(path));

  /// Deliveries the consent gate declined: their copies not read yet are
  /// deleted unread.
  final Set<int> _declined = {};

  /// Android: each delivery's copies the reader has not taken yet, so a
  /// Not now deletes them at once, wherever the reader waits.
  final Map<int, List<String>> _untaken = {};

  /// Android: each delivery's copies read and handed on whose photo is
  /// not settled yet (IntakePhoto.onSettled): kept on disk until then, so
  /// an engine stopped mid-analysis leaves them for the next start.
  final Map<int, Set<String>> _inHand = {};

  /// Android: copies the reader has taken and is reading now, between
  /// [_untaken] and [_inHand].
  int _reading = 0;

  /// Android: whether a shared photo this engine took is not settled yet
  /// (IntakePhoto.onSettled) — its copy waiting unread ([_untaken]), being
  /// read, or in hand ([_inHand]) — so stopping the engine now would cut
  /// it off. The app shell keeps Back at the root from finishing the
  /// activity meanwhile, in every task (SharedPhotosBackGuard): with
  /// predictive back, Android 15 QPR1 and later can still finish the
  /// activity after a start MainActivity cannot see, its engine with it,
  /// mid-analysis (Q9). False once every photo is settled, and always on
  /// iOS.
  ValueListenable<bool> get photosPending => _pending;
  final ValueNotifier<bool> _pending = ValueNotifier<bool>(false);

  /// [photosPending] after a change to what this intake holds.
  void _notePending() => _pending.value = _copiesWait &&
      (_untaken.isNotEmpty || _inHand.isNotEmpty || _reading > 0);

  /// The share folder once it is known (the first copy checked against it
  /// asks for it): a Not now checks its copies against it synchronously.
  String? _knownFolder;

  /// Android: every copy path handed to a delivery so far (normalized).
  /// The start-up sweep (or its second look, [strandedRecheck]) and a live
  /// share can name the same copy (one whose event comes late): it goes
  /// to the first delivery only, so it is counted, and read, once.
  final Set<String> _delivered = {};

  /// Wakes the reader from its pause-wait (set by [photos]).
  void Function()? _wakeReader;

  /// The start-up batches of copies left unread ([asksAlone]).
  final Set<int> _startupBatches = {};

  @override
  bool asksAlone(int delivery) => _startupBatches.contains(delivery);

  @override
  int get arrivedDelivery => _deliveries;

  @override
  int photoCountOf(int delivery) =>
      (_deliverySize[delivery] ?? 0) - (_deliveryUnreadable[delivery] ?? 0);

  @override
  void declineDeliveries(Set<int> deliveries) {
    _declined.addAll(deliveries);
    // Their copies the reader has not taken go now, before this returns,
    // not when the reader reaches them: one queued behind a delivery that
    // is not declined (the start-up batch) waited for all of it to be
    // read, and an app stopped meanwhile left them for the next start's
    // sweep, which sent them unasked once the recipient was allowed
    // (review 2026-11-19, R1).
    for (final delivery in deliveries) {
      for (final path in _untaken.remove(delivery) ?? const <String>[]) {
        _discardNow(path);
      }
      // So do those already read and handed on, which the gate drops
      // unsent as they reach it: the photo the question was about, the
      // one read ahead. (While a question is open no photo of a share is
      // in the pipeline: each waits for the one before it.)
      for (final path in _inHand.remove(delivery) ?? const <String>{}) {
        _discardNow(path);
      }
    }
    _notePending();
    // And the reader stops waiting on any of them.
    _wakeReader?.call();
  }

  /// Cold-start share first, then live shares for the app's lifetime.
  /// (Explicit controller, not async*: an async* generator parked on the
  /// live-share stream would defer subscription cancellation forever.)
  ///
  /// BACKPRESSURE (review 171, C2), Android: a copy is read only while the
  /// listener is not paused. The pipeline pauses the stream until each
  /// photo's turn ends (PhotoPipeline.bindStream), and the consent gate
  /// while it asks, so a 40-photo share holds one original in memory, plus
  /// at most one read ahead — not all 40 (about 160 MB) in the stream's
  /// buffer. The copies wait in the share folder meanwhile, each in a
  /// folder of its own (MainActivity). Batches are read one after another,
  /// in order.
  ///
  /// DELIVERIES: each batch event is numbered as it arrives
  /// ([ShareDeliveries], IntakePhoto.shareDelivery), so the consent gate's
  /// Not now covers the whole share it was asked about — and any that
  /// arrived before the answer — and their copies not read yet are deleted
  /// here unread, at once ([declineDeliveries]).
  ///
  /// KEPT UNTIL SETTLED (Android, 2026-11-20, Q1/Q9): a photo's copy stays
  /// on disk after it is read, until the photo is settled
  /// (IntakePhoto.onSettled: its verdict written, or let go: released by
  /// the pipeline or dropped unsent). It used to go as its bytes were
  /// read, so an engine stopped mid-analysis (Back finished the activity,
  /// Android stopped the process) lost the photo in flight and the one
  /// read ahead: the meal was never saved, and nothing could offer it
  /// again. Now the next start's sweep ([_leftOver]) offers them again
  /// with the copies never read. A copy that gives no photo (another
  /// type, empty, over 25 MB, unreadable) still goes at once, and on a
  /// cancel the copies read but not handed on go with those not read.
  ///
  /// REFUSED FILES (2026-11-21): a share's files that give no photo were
  /// dropped without a word: an AVIF or DNG, a file over 25 MB, an empty
  /// or unreadable one here, and on Android a video, a PDF, a file over
  /// 25 MB or a stream MainActivity could not read before any copy
  /// ([SharedBatch.refused]). Once every file of a share has been looked
  /// at, one note ([IntakePhoto.refusedNote]) follows its photos: how many
  /// gave none, and why. None for a share answered Not now, or once the
  /// stream is cancelled. A share whose every file was refused is still a
  /// delivery, with no photo to ask about: its [photoCountOf] is 0 at once
  /// when MainActivity refused it whole or its copies' names give no photo
  /// type (an AVIF, a DNG), and once each is read for an empty or
  /// unreadable copy. Another share's Not now does not cover it then, and
  /// its note still comes.
  ///
  /// iOS reads each copy the moment it arrives, as before: the share
  /// extension writes `<appGroup>/<file name>` and replaces a file of the
  /// same name (FullSizeRender.jpg for every edited photo, TempImage.png
  /// for every in-memory image), so a copy left waiting was overwritten by
  /// the next share of that name — two shares, one meal (review
  /// 2026-11-13). iOS shares one image at a time: one original per share.
  Stream<IntakePhoto> photos() {
    late final StreamController<IntakePhoto> controller;
    StreamSubscription<SharedBatch>? liveSub;
    Timer? recheck;
    var cancelled = false;
    Completer<void>? resumed;
    var reading = Future<void>.value();

    void wake() {
      final r = resumed;
      resumed = null;
      r?.complete();
    }

    Future<void> emitPaths(List<String> paths, int delivery,
        {List<ShareRefusal> refusedBefore = const [],
        List<String> typesBefore = const []}) async {
      // The share's files that gave no photo: those refused before any
      // copy (MainActivity), then the copies refused here; the types of
      // those refused for a photo type, in the same order.
      final refused = [...refusedBefore];
      final photoTypes = [...typesBefore];
      // [counted]: the copy was one of the delivery's photos as far as was
      // known ([_namedNoPhoto] never was).
      void gaveNoPhoto(ShareRefusal why, {String? type, bool counted = true}) {
        if (counted) {
          _deliveryUnreadable[delivery] =
              (_deliveryUnreadable[delivery] ?? 0) + 1;
        }
        refused.add(why);
        if (type != null) photoTypes.add(type);
      }

      bool declined() => _declined.contains(delivery);
      for (final path in paths) {
        // A declined delivery is never waited on.
        while (_copiesWait &&
            controller.isPaused &&
            !cancelled &&
            !declined()) {
          await (resumed ??= Completer<void>()).future;
        }
        // Taken from here on (Android); one a Not now deleted already is
        // not this reader's any more.
        if (_copiesWait && !_take(delivery, path)) continue;
        // Cancelled, or declined by the consent gate's Not now: not read,
        // but not left in the cache either.
        if (cancelled || controller.isClosed || declined()) {
          _notePending();
          await _discard(path);
          continue;
        }
        final _Read read;
        final counted = !_namedNoPhoto(path);
        // Pending while it is read, too: in hand once it gives a photo.
        _reading++;
        try {
          read = await _fromPath(path, delivery);
        } catch (_) {
          gaveNoPhoto(ShareRefusal.unreadable, counted: counted);
          continue; // one bad copy (already deleted) never stops the rest
        } finally {
          _reading--;
          _notePending();
        }
        final photo = read.photo;
        if (photo == null) {
          gaveNoPhoto(read.refusal ?? ShareRefusal.unreadable,
              type: read.type, counted: counted);
        } else if (!cancelled && !controller.isClosed && !declined()) {
          controller.add(photo);
        } else {
          // Read as the stream went, or as a Not now covered its share:
          // handed to nobody, so not kept.
          photo.onSettled?.call();
        }
      }
      // Every file of the share is looked at: those that gave no photo
      // are said in one line, after its photos (the consent gate and the
      // pipeline keep the order). Not for a share answered Not now, whose
      // own line says nothing was sent, nor once the stream is gone.
      if (refused.isNotEmpty &&
          !cancelled &&
          !controller.isClosed &&
          !declined()) {
        controller.add(IntakePhoto.refusedNote(
            RefusedShareFiles(refused, photoTypes: photoTypes),
            shareDelivery: delivery));
      }
    }

    // One reader, batch after batch: a failure cannot break the chain, or
    // every later share would wait behind it for good. The delivery is
    // numbered here, as its batch event arrives (an empty one is none).
    void enqueue(SharedBatch batch, {bool leftOver = false}) {
      // Android's copies each have a path of their own: one already given
      // to a delivery (the start-up sweep and a late live event) is not
      // given again. iOS reuses names for new copies: never deduplicated.
      final paths = _copiesWait
          ? [
              for (final p in batch.paths)
                if (_delivered.add(_normalized(p))) p
            ]
          : batch.paths;
      // A share whose every file was refused before any copy is still a
      // delivery: its line says so, with no question asked.
      if (paths.isEmpty && batch.refused.isEmpty) return;
      final delivery = ++_deliveries;
      if (leftOver) _startupBatches.add(delivery);
      _deliverySize[delivery] = paths.where((p) => !_namedNoPhoto(p)).length;
      if (_copiesWait && paths.isNotEmpty) _untaken[delivery] = [...paths];
      _notePending();
      reading = reading
          .then((_) => emitPaths(paths, delivery,
              refusedBefore: batch.refused, typesBefore: batch.photoTypes))
          .catchError((Object _) {});
    }

    _wakeReader = wake;
    controller = StreamController<IntakePhoto>(
      onListen: () async {
        final initial = await _source.initialBatch();
        if (cancelled) return;
        enqueue(initial);
        // Listened for at once, not after the launch share is read: the
        // plugin drops a share that arrives while nobody listens, and the
        // launch share may now wait on the pipeline for minutes.
        liveSub = _source.batches().listen(enqueue,
            onError: controller.addError,
            onDone: () => reading = reading.then((_) => controller.close()));
        // Only now has the plugin a listener to tell: MainActivity hands
        // over the shares it held until then (Android; R0), whose events
        // come like any live share's.
        try {
          unawaited(_listening?.call().catchError((Object _) {}));
        } catch (_) {
          // Nobody to tell: their copies wait for the sweep (below).
        }
        if (_copiesWait) {
          final (left, young) = await _leftOver(initial.paths);
          if (!cancelled && left.isNotEmpty) {
            enqueue(SharedBatch(left), leftOver: true);
          }
          // The copies too young for it: once each is old enough that its
          // share's event has come if it ever will, those still on disk
          // and given to no delivery are taken ([strandedRecheck]).
          if (!cancelled && young.isNotEmpty) {
            recheck = Timer(_recheckAfter, () async {
              final waiting = <String>[];
              for (final path in young) {
                try {
                  if (await File(path).exists()) waiting.add(path);
                } catch (_) {
                  // Cannot tell: left for the next start's sweep.
                }
              }
              if (cancelled || controller.isClosed) return;
              enqueue(SharedBatch(waiting), leftOver: true);
            });
          }
        }
      },
      onResume: wake,
      onCancel: () async {
        _wakeReader = null;
        cancelled = true;
        recheck?.cancel();
        wake();
        await liveSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// How long a copy a killed app left behind is still logged at the next
  /// start (Android); older ones are deleted unread.
  static const strandedMaxAge = Duration(hours: 24);

  /// A copy younger than this may still be being written for a share
  /// whose own event delivers it: the start-up sweep leaves it alone. The
  /// event comes even for a share Android delivered before this engine's
  /// Dart ran (MainActivity holds it until share intake listens,
  /// [androidShareIntakeReady]), but not for one held by an activity that
  /// went before then (Back or a swipe during the cold start, a crash):
  /// that copy is taken at [strandedRecheck].
  static const strandedMinAge = Duration(seconds: 10);

  /// How long after the start-up sweep the copies it left for being
  /// younger than [strandedMinAge] are looked at again (Android). Each is
  /// older than that by then, so its share's event has come if it ever
  /// will; one still on disk and given to no delivery is taken then, as a
  /// start-up batch ([asksAlone]), through the same consent gate. Without
  /// this, a share whose activity went before this engine's Dart listened
  /// waited, when the app was opened again within seconds, for a later
  /// start: possibly a day late, or deleted unread (review 2026-11-19).
  static const strandedRecheck = Duration(seconds: 15);

  /// The share folder's copies an earlier run never read (Android, review
  /// 2026-11-13): with the C2 backpressure they wait there for minutes,
  /// and an app killed mid-batch left them for good — full-size originals
  /// in the cache, never logged, nothing said (MainActivity removes only
  /// empty folders, and a recreated activity hands no share over again).
  /// Those shared within [strandedMaxAge] come back, oldest first, to go
  /// through the same consent gate and pipeline as any share: the user
  /// shared them to be logged, and a copy still on disk has no verdict
  /// written (a copy goes once its photo is settled, [photos]). Most were
  /// never read; the one an engine stopped mid-analysis was maybe sent
  /// once already, and goes again (the launch sweep,
  /// MealsDao.reclaimStaleProcessing, released its 'processing' row, or
  /// failed it once 20 minutes old, and its deliberate add takes the
  /// photo either way). The photo ledger keeps a photo whose meal
  /// was written as its engine stopped from becoming a second meal: the
  /// pipeline answers "already logged" before anything is sent. Older
  /// ones are deleted here, unread: logged days late they would surprise,
  /// and could land on the wrong day. The launch share's own copies are
  /// left out, and those younger than [strandedMinAge] come back second,
  /// for [strandedRecheck].
  Future<(List<String>, List<String>)> _leftOver(List<String> launch) async {
    final String root;
    try {
      root = _knownFolder ??= await _sharedFolder!();
    } catch (_) {
      return (const <String>[], const <String>[]);
    }
    final skip = {for (final p in launch) _normalized(p)};
    final now = _clock();
    final keep = <(DateTime, String)>[];
    final young = <(DateTime, String)>[];
    try {
      await for (final entry
          in Directory(root).list(recursive: true, followLinks: false)) {
        if (entry is! File || !isWithinFolder(entry.path, root)) continue;
        if (skip.contains(_normalized(entry.path))) continue;
        final DateTime modified;
        try {
          modified = await entry.lastModified();
        } catch (_) {
          continue;
        }
        final age = now.difference(modified);
        if (age < strandedMinAge) {
          young.add((modified, entry.path));
          continue;
        }
        if (age > strandedMaxAge) {
          await _cleanup(entry.path);
          continue;
        }
        keep.add((modified, entry.path));
      }
    } catch (_) {
      // No folder yet, or it cannot be listed: nothing left over.
    }
    List<String> oldestFirst(List<(DateTime, String)> copies) =>
        [for (final c in copies..sort((a, b) => a.$1.compareTo(b.$1))) c.$2];
    return (oldestFirst(keep), oldestFirst(young));
  }

  /// The reader takes [path] of [delivery]: false when it is no longer
  /// waiting (a Not now deleted it).
  bool _take(int delivery, String path) {
    final untaken = _untaken[delivery];
    if (untaken == null || !untaken.remove(path)) return false;
    if (untaken.isEmpty) _untaken.remove(delivery);
    return true;
  }

  /// Deletes [path] unread when it is a copy this intake may delete.
  Future<void> _discard(String path) async {
    if (await _isShareCopy(path)) await _cleanup(path);
  }

  /// [_discard] at once (the production cleanup is synchronous) once the
  /// share folder is known, as it is by the time any question is open:
  /// the photo asked about was checked against it.
  void _discardNow(String path) {
    final folder = _knownFolder;
    if (folder == null) {
      unawaited(_discard(path));
    } else if (isWithinFolder(path, folder)) {
      unawaited(Future.sync(() => _cleanup(path)).catchError((Object _) {}));
    }
  }

  /// Whether [path] is a copy this intake may read and delete.
  Future<bool> _isShareCopy(String path) async {
    final folder = _sharedFolder;
    if (folder == null) return true;
    try {
      return isWithinFolder(path, _knownFolder ??= await folder());
    } catch (_) {
      return false; // cannot tell: leave it alone
    }
  }

  /// The photo the copy at [path] gives, or why it gives none.
  Future<_Read> _fromPath(String path, int delivery) async {
    // Android (review 171, C5): the plugin used to hand over a path of the
    // sender's making (its file name, climbing out of the cache with
    // '..'; or a share's text when it had no stream), which was read when
    // it looked like a photo and deleted either way: the meal database,
    // the settings. Only MainActivity's copies are touched now.
    if (!await _isShareCopy(path)) {
      return const _Read.refused(ShareRefusal.unreadable);
    }
    var kept = false;
    try {
      final name = fileBaseName(path);
      if (!hasSupportedPhotoExtension(name)) {
        // §6.1. Said by the type its name gives, when it gives one.
        final type = sharedPhotoTypeOf(name);
        return type == null
            ? const _Read.refused(ShareRefusal.fileType)
            : _Read.refused(ShareRefusal.photoType, type: type);
      }
      final bytes = await _readBytes(path);
      if (bytes == null || bytes.isEmpty) {
        return const _Read.refused(ShareRefusal.unreadable);
      }
      if (bytes.length > maxPhotoBytes) {
        return const _Read.refused(ShareRefusal.tooBig); // §8: 25 MB cap
      }
      // A shared file has no library asset date; filename timestamp or bust
      // (§6.3 fallback = intake-time dating, expressed as capturedAt null).
      final capturedAt = deriveCapturedAt(
          fileName: name, now: _clock(), maxAgeDays: _capturedAtMaxAgeDays);
      // How it was taken, from its own bytes (design G2a): no asset, so no
      // creation date and no album.
      final photo = IntakePhoto(bytes, '', name,
          capturedAt: capturedAt,
          deliberate: true,
          capture: captureMetaFor(bytes, name),
          shareDelivery: delivery,
          onSettled: _copiesWait ? _settler(delivery, path) : null);
      kept = _copiesWait;
      return _Read.photo(photo);
    } finally {
      // The plugin's container copy goes once it has served its purpose:
      // at once when it gives no photo (rejected or unreadable) and on
      // iOS, whose share extension reuses file names (a copy left there
      // would be overwritten by the next share of that name); on Android
      // a photo's copy waits until the photo is settled ([photos]).
      if (!kept) await _cleanup(path);
    }
  }

  /// [IntakePhoto.onSettled] for [delivery]'s copy at [path], which is in
  /// hand from now on: deletes it, once, unless a Not now did already.
  void Function() _settler(int delivery, String path) {
    (_inHand[delivery] ??= {}).add(path);
    return () {
      final inHand = _inHand[delivery];
      if (inHand == null || !inHand.remove(path)) return;
      if (inHand.isEmpty) _inHand.remove(delivery);
      _discardNow(path);
      _notePending();
    };
  }

  /// Recent library assets for the UI's own picker grid (the UI renders the
  /// grid; this module only supplies the data). deliberate=true — a picked
  /// photo is a user decision, reclaiming failed/skipped/deleted (§2.3).
  Future<List<IntakePhoto>> pickFromRecent(int limit) async {
    if (limit <= 0) return const [];
    if (!await _library.requestPermission()) return const [];
    final assets = await _library.recentImages(limit);
    final out = <IntakePhoto>[];
    for (final asset in assets.take(limit)) {
      final bytes = await asset.originBytes(); // ORIGINAL bytes (§6.2)
      if (bytes == null || bytes.isEmpty) continue;
      if (bytes.length > maxPhotoBytes) continue;
      final name = await asset.fileName();
      final capturedAt = deriveCapturedAt(
          fileName: name,
          assetCreateDate: asset.createDateTime,
          now: _clock(),
          maxAgeDays: _capturedAtMaxAgeDays);
      out.add(IntakePhoto(bytes, asset.id, name,
          capturedAt: capturedAt,
          deliberate: true,
          capture: captureMetaFor(bytes, name,
              createDate: asset.createDateTime)));
    }
    return out;
  }
}

/// What one shared copy gave ([ShareIntake]): its photo, or why none.
class _Read {
  const _Read.photo(IntakePhoto this.photo)
      : refusal = null,
        type = null;
  const _Read.refused(ShareRefusal this.refusal, {this.type}) : photo = null;

  final IntakePhoto? photo;
  final ShareRefusal? refusal;

  /// [ShareRefusal.photoType]: the type the copy's name gives.
  final String? type;
}
