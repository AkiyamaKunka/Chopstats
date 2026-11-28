/// Today's status row for the automatic photo scan (Watch Camera Roll),
/// under the totals: what [PhotoScanStatus] holds, in words.
///
/// Today lists saved meals, and a photo becomes one only when its analysis
/// answers, one photo at a time. Without this row a day's backlog read
/// "0 kcal" until the first meal landed, and a photo that could not be
/// sent was dropped until the next scan without a word (2026-11-27).
///
///  * While a scan sends photos that had no verdict: a spinner,
///    "Checking photos: 3 of 12" and under it "Keep Chopstats open."
///  * For [PhotoScanRow.doneFor] after it finished: "12 photos checked."
///    Then the row goes.
///  * When photos were let go because the analysis could not be had (the
///    server unreachable or busy, a rate limit): "3 photos are not checked
///    yet (network or service issue)." and Retry, which starts the
///    catch-up again. The reason is one of the app's own short reason
///    lines (outcome_text.dart retryReason), never an exception's text. A
///    photo that was simply not food is a photo checked, and says nothing.
///
/// Screen readers: the sentence is a live region, said once when the row
/// appears and once when it changes to what the scan came to. The count
/// is not part of its label (it is the node's value, read when the row is
/// focused): both engines announce a live region when its label changes,
/// so a label that counted would be said again for every photo.
///
/// The row sits under the totals card, which therefore never moves, and
/// opens and closes over [AppMotion.standard] (at once with animations
/// off) so the meals under it slide instead of jumping.
library;

import 'dart:async' show Timer;

import 'package:flutter/material.dart';

import '../../services/photo/scan_status.dart';
import '../l10n.dart';
import '../outcome_text.dart' show retryReason;
import '../photo_pipeline.dart' show PhotoOutcome, PhotoOutcomeKind;
import '../theme/tokens.dart';
import 'grouped.dart' show GroupedCard, kGroupInset;
import 'small_spinner.dart';

class PhotoScanRow extends StatefulWidget {
  const PhotoScanRow({super.key, required this.status, this.onRetry});

  final PhotoScanStatus status;

  /// Starts the catch-up again and completes when it is over; null shows
  /// no Retry.
  final Future<void> Function()? onRetry;

  /// How long "N photos checked." stays after a scan has finished. A time
  /// to read it, not a motion: the same with animations off.
  static const Duration doneFor = Duration(seconds: 3);

  @override
  State<PhotoScanRow> createState() => _PhotoScanRowState();
}

enum _Shown { nothing, checking, done, waiting }

class _PhotoScanRowState extends State<PhotoScanRow> {
  _Shown _shown = _Shown.nothing;

  /// What the done line counts: the photos the finished round checked.
  int _doneCount = 0;
  Timer? _doneEnd;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    widget.status.addListener(_onStatus);
    _shown = _shownNow();
  }

  @override
  void didUpdateWidget(covariant PhotoScanRow old) {
    super.didUpdateWidget(old);
    if (identical(old.status, widget.status)) return;
    old.status.removeListener(_onStatus);
    widget.status.addListener(_onStatus);
    _doneEnd?.cancel();
    _shown = _shownNow();
  }

  @override
  void dispose() {
    widget.status.removeListener(_onStatus);
    _doneEnd?.cancel();
    super.dispose();
  }

  /// What the status shows as it stands, with no scan seen to finish.
  _Shown _shownNow() => switch (widget.status.phase) {
        PhotoScanPhase.checking => _Shown.checking,
        PhotoScanPhase.waiting => _Shown.waiting,
        PhotoScanPhase.idle => _Shown.nothing,
      };

  void _onStatus() {
    if (!mounted) return;
    final status = widget.status;
    final _Shown next;
    switch (status.phase) {
      case PhotoScanPhase.checking:
        next = _Shown.checking;
      case PhotoScanPhase.waiting:
        next = _Shown.waiting;
      case PhotoScanPhase.idle:
        if (_shown == _Shown.checking && status.checkedCount > 0) {
          // The scan this row counted is over: say what it came to, then
          // go.
          next = _Shown.done;
          _doneCount = status.checkedCount;
        } else if (_shown == _Shown.done) {
          next = _Shown.done; // until its time is up
        } else {
          next = _Shown.nothing;
        }
    }
    if (next != _Shown.done) {
      _doneEnd?.cancel();
      _doneEnd = null;
    } else if (_shown != _Shown.done) {
      _doneEnd?.cancel();
      _doneEnd = Timer(PhotoScanRow.doneFor, () {
        if (!mounted || _shown != _Shown.done) return;
        setState(() => _shown = _Shown.nothing);
      });
    }
    // Always: the counts move within one phase too.
    setState(() => _shown = next);
  }

  Future<void> _retry() async {
    final retry = widget.onRetry;
    if (retry == null || _retrying) return;
    setState(() => _retrying = true);
    try {
      await retry();
    } catch (_) {
      // The catch-up reports through the status; nothing to say here.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  /// The waiting line: how many, and why when the app has words for it.
  String _waitingLine(AppLocalizations l) {
    final status = widget.status;
    final count = status.waitingCount;
    final kind = status.waitingKind;
    final reason = kind == null
        ? null
        : retryReason(
            l,
            PhotoOutcome(PhotoOutcomeKind.failed, '',
                retryable: true, errorKind: kind));
    return reason == null
        ? l.todayScanWaiting(count)
        : l.todayScanWaitingReason(count, reason);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final colors = context.colors;
    final status = widget.status;
    final textStyle =
        theme.textTheme.bodyMedium?.copyWith(color: colors.label);

    final Widget? lead;
    final String line;
    String? caption;
    String? label;
    String? value;
    switch (_shown) {
      case _Shown.nothing:
        lead = null;
        line = '';
      case _Shown.checking:
        lead = const SmallSpinner(key: Key('photoScanSpinner'), size: 20);
        line = l.todayScanChecking(status.current, status.total);
        caption = l.todayScanKeepOpen;
        // The label a screen reader announces stays the same while the
        // count moves (see the library comment).
        label = l.todayScanCheckingLabel;
        value = l.todayScanCheckingValue(status.current, status.total);
      case _Shown.done:
        lead = Icon(Icons.check_circle_rounded,
            size: 22, color: colors.success);
        line = l.todayScanDone(_doneCount);
      case _Shown.waiting:
        lead = Icon(Icons.warning_amber_rounded,
            size: 22, color: colors.warning);
        line = _waitingLine(l);
    }

    final retry = widget.onRetry;
    final Widget child;
    if (lead == null) {
      child = const SizedBox(width: double.infinity);
    } else {
      child = GroupedCard(
        key: const Key('photoScanRow'),
        margin: const EdgeInsets.fromLTRB(kGroupInset, 8, kGroupInset, 0),
        padding: const EdgeInsets.all(AppSpace.cardPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: SizedBox(
                      width: 22, height: 22, child: Center(child: lead)),
                ),
                const SizedBox(width: AppSpace.s12),
                Expanded(
                  child: Semantics(
                    key: const Key('photoScanLine'),
                    container: true,
                    liveRegion: true,
                    label: label,
                    value: value,
                    excludeSemantics: label != null,
                    // Never cut, at any text size: the count and the
                    // reason are the row.
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(line,
                            key: const Key('photoScanText'),
                            style: textStyle),
                        if (caption != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(caption,
                                key: const Key('photoScanCaption'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.secondaryLabel)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_shown == _Shown.waiting && retry != null) ...[
              const SizedBox(height: AppSpace.s12),
              FilledButton.tonal(
                key: const Key('photoScanRetry'),
                onPressed: _retrying ? null : _retry,
                child: Text(l.retry),
              ),
            ],
          ],
        ),
      );
    }
    // With animations off the row is simply there or not. (An AnimatedSize
    // of zero duration is no way to say that: it asserts in its layout.)
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return AnimatedSize(
      duration: duration,
      curve: AppMotion.curve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}
