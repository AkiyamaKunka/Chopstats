/// What the app's own automatic photo scan is doing right now, for
/// Today's status row (ui/widgets/photo_scan_row.dart).
///
/// Today lists saved meals, and a photo meal exists only once its analysis
/// has answered. After a day without the app, Today therefore read "0 kcal"
/// while the catch-up worked through the backlog one photo at a time, and
/// nothing said so: on 2026-11-27 a noon meal was logged at 23:05, after a
/// 40-second visit that ended on that 0. A photo that could not be sent
/// (the server unreachable, or busy three times) was let go until the next
/// scan just as silently.
///
/// Two sides feed this, in the app engine only (the background run has no
/// screen and gets none):
///
///  * the watcher (watcher.dart) opens a [PhotoScan] around each of its
///    scans, with the photos it is about to read that look unchecked, and
///    says [PhotoScanStatus.passed] for each one it is done with;
///  * the photo pipeline (ui/photo_pipeline.dart, wired in ui/di.dart)
///    says [PhotoScanStatus.checking] when an automatic photo turned out
///    to have no verdict yet and is about to be sent, and
///    [PhotoScanStatus.finished] with how its turn ended.
///
/// The count is honest rather than exact. Which photos have no verdict is
/// only known for sure once each is read and looked up in the ledger, so
/// the watcher's list is an estimate (LibraryPhotoIntake.checkedThrough)
/// and the row waits for the pipeline to find the first one: a scan that
/// only walks photos already logged shows nothing, as before. A photo the
/// estimate missed joins the count when its analysis starts, and one it
/// counted for nothing leaves it when the scan has passed it.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../../core/outcome_kind.dart' show AnalysisErrorKind;

/// How one automatic photo's turn ended, as the row counts it.
enum ScanVerdict {
  /// It has a verdict now: a meal, not food, leftovers deducted, or a
  /// failure kept as failed (which the pipeline announces itself).
  checked,

  /// Let go without one because it could not be sent or was not answered
  /// this time, or because another run holds it: a later scan offers it
  /// again, and the row says it is not checked yet.
  waiting,

  /// Nothing to count: logged before, or held back for a reason that is
  /// not a failure of the send (the app in the background, an iCloud
  /// restore offer, a glasses preview waiting for its full-size copy, a
  /// pause every photo shares, which Settings explains).
  none,
}

/// What the row shows.
enum PhotoScanPhase {
  /// Nothing.
  idle,

  /// A scan is checking photos that had no verdict:
  /// [PhotoScanStatus.current] of [PhotoScanStatus.total].
  checking,

  /// No scan is checking, and [PhotoScanStatus.waitingCount] photos were
  /// let go unchecked.
  waiting,
}

/// An intake whose scans report to a [PhotoScanStatus]
/// (LibraryPhotoIntake). The app's catch-up reads it to hold one round
/// over its two parts (ui/background_glue.dart foregroundCatchUp).
abstract interface class ReportsPhotoScans {
  /// Null: nothing is reported (the background run, tests).
  PhotoScanStatus? get scanStatus;
}

/// One scan's hold on a [PhotoScanStatus]; [end] it when the scan is over.
class PhotoScan {
  PhotoScan._(this._status, {required this._untilEnd});

  final PhotoScanStatus _status;
  final bool _untilEnd;
  bool _ended = false;

  /// A second call does nothing.
  void end() {
    if (_ended) return;
    _ended = true;
    _status._end(heldRow: _untilEnd);
  }
}

class PhotoScanStatus extends ChangeNotifier {
  /// Scans running now. They nest: the catch-up holds one around the
  /// window scan and the late-import pass, and a scan the live watcher
  /// starts for a new photo runs beside it.
  int _scans = 0;

  /// Of them, those begun with untilEnd.
  int _holdingRow = 0;

  /// About to be read and, as far as the scan could tell, unchecked.
  final Set<String> _expected = <String>{};

  /// Being analyzed now.
  String? _checking;

  /// Finished since this round began: a verdict, or let go waiting. A
  /// round runs from the first scan's start to the last one's end.
  final Set<String> _done = <String>{};

  /// This round met a photo that had no verdict: the row may show.
  bool _found = false;

  /// Let go unchecked, each with why ([AnalysisErrorKind.none]: no reason
  /// to give), oldest first. Kept across rounds until a scan of the whole
  /// window takes them up again, or a verdict settles them.
  final Map<String, AnalysisErrorKind> _waiting =
      <String, AnalysisErrorKind>{};

  /// Since [reset], until the next scan begins: the photo still in flight
  /// then is not this row's to report any more. The watcher begins none
  /// for a scan the switch-off itself has ended (LibraryPhotoIntake.stop).
  bool _switchedOff = false;

  bool get _busy =>
      _checking != null ||
      (_scans > 0 &&
          (_expected.isNotEmpty || (_holdingRow > 0 && _done.isNotEmpty)));

  PhotoScanPhase get phase {
    if (_found && _busy) return PhotoScanPhase.checking;
    if (_waiting.isNotEmpty) return PhotoScanPhase.waiting;
    return PhotoScanPhase.idle;
  }

  /// While [PhotoScanPhase.checking]: how many photos this round checks,
  /// as far as is known, and which of them is being checked (from 1; the
  /// last one while a scan that holds the row has none left on its list).
  int get total =>
      _done.length + (_checking != null ? 1 : 0) + _expected.length;
  int get current => math.max(1, math.min(_done.length + 1, total));

  /// How many photos the round (the one running, or the last one) has
  /// given a verdict; those let go waiting are not among them.
  int get checkedCount =>
      _done.where((id) => !_waiting.containsKey(id)).length;

  /// The photos let go unchecked that no scan has taken up again.
  int get waitingCount => _waiting.length;

  /// Why the newest of them that has a reason was let go; null when none
  /// has one.
  AnalysisErrorKind? get waitingKind {
    AnalysisErrorKind? newest;
    for (final kind in _waiting.values) {
      if (kind != AnalysisErrorKind.none) newest = kind;
    }
    return newest;
  }

  /// What the row shows now: records and enum values compare by value.
  Object get _shown => switch (phase) {
        PhotoScanPhase.idle => PhotoScanPhase.idle,
        PhotoScanPhase.checking => (PhotoScanPhase.checking, current, total),
        PhotoScanPhase.waiting =>
          (PhotoScanPhase.waiting, waitingCount, waitingKind),
      };

  /// Runs [change], then tells the listeners if what the row shows moved.
  void _update(void Function() change) {
    final before = _shown;
    change();
    if (before != _shown) notifyListeners();
  }

  /// A scan starts. [expected]: the ids of the photos it is about to read
  /// that look unchecked (never one this session already gave a verdict,
  /// nor one a meal names).
  ///
  /// [wholeWindow]: the scan lists the whole lookback window, so every
  /// photo still waiting is either among [expected] or no longer there to
  /// check (deleted, logged since, out of the window). The listed ones are
  /// taken up again, and the row goes straight from "not checked yet" to
  /// "checking"; the others are forgotten.
  ///
  /// [untilEnd]: once this round has checked a photo, the row stays, on
  /// its last count, until this scan ends, even while nothing is left on
  /// any list. The app's catch-up holds one such scan around its two parts
  /// (ui/background_glue.dart foregroundCatchUp): after the last photo it
  /// expected, the window scan still walks the older photos, and the
  /// late-import pass first reads the library's change history before it
  /// can list anything. Without it the row went away after that last
  /// photo and came back for each photo found later.
  PhotoScan begin(
      {Iterable<String> expected = const <String>[],
      bool wholeWindow = false,
      bool untilEnd = false}) {
    _update(() {
      _switchedOff = false;
      if (_scans == 0) {
        _done.clear();
        _expected.clear();
        _found = false;
      }
      _scans++;
      final listed = <String>{
        for (final id in expected)
          if (id.isNotEmpty) id,
      };
      if (wholeWindow) {
        for (final id in _waiting.keys) {
          if (!listed.contains(id)) continue;
          _done.remove(id);
          _found = true;
        }
        _waiting.clear();
      }
      for (final id in listed) {
        if (id == _checking || _done.contains(id)) continue;
        _expected.add(id);
      }
      if (untilEnd) _holdingRow++;
    });
    return PhotoScan._(this, untilEnd: untilEnd);
  }

  void _end({required bool heldRow}) {
    _update(() {
      if (heldRow && _holdingRow > 0) _holdingRow--;
      if (_scans > 0) _scans--;
      // What no scan reached stays unchecked, and the next scan lists it
      // again: nothing is promised for it here.
      if (_scans == 0) _expected.clear();
    });
  }

  /// A scan is done with [id] without a verdict of its own: read before,
  /// left unread (the app went to the background), unreadable, too big.
  void passed(String id) {
    if (!_expected.contains(id)) return;
    _update(() => _expected.remove(id));
  }

  /// The pipeline is about to send [id]: it had no verdict.
  void checking(String id) {
    if (id.isEmpty || _switchedOff) return;
    _update(() {
      _found = true;
      _checking = id;
      _expected.remove(id);
      _waiting.remove(id);
      _done.remove(id);
    });
  }

  /// [id]'s turn ended with [verdict]. [kind]: why a
  /// [ScanVerdict.waiting] photo was let go ([AnalysisErrorKind.none] or
  /// null: no reason to give).
  void finished(String id, ScanVerdict verdict, {AnalysisErrorKind? kind}) {
    if (id.isEmpty || _switchedOff) return;
    _update(() {
      _expected.remove(id);
      if (_checking == id) _checking = null;
      _waiting.remove(id);
      switch (verdict) {
        case ScanVerdict.checked:
          _found = true;
          _done.add(id);
        case ScanVerdict.waiting:
          _found = true;
          _done.add(id);
          _waiting[id] = kind ?? AnalysisErrorKind.none;
        case ScanVerdict.none:
          break;
      }
    });
  }

  /// [id] got its verdict some other way (the user picked the photo in the
  /// add flow or logged it from Photo Coverage): no scan has it left to
  /// check, and it waits no longer.
  void settled(String id) {
    if (!_expected.contains(id) && !_waiting.containsKey(id)) return;
    _update(() {
      _expected.remove(id);
      _waiting.remove(id);
    });
  }

  /// Forgets everything shown (Watch Camera Roll was switched off). Scans
  /// still running end as they would have, and the photo in flight, if
  /// any, ends unreported.
  void reset() {
    _update(() {
      _switchedOff = true;
      _expected.clear();
      _done.clear();
      _waiting.clear();
      _checking = null;
      _found = false;
    });
  }
}
