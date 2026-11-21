/// The ring a meal card gets when the user asked to see that meal (the
/// shared photo's View, a tap on a Logged meals card: ui/meal_reveal.dart),
/// and the scrolling that brings the card on screen first.
library;

import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show AccessibilityFocusBlockType;

import '../../core/contracts.dart' show Meal;
import '../../l10n/app_localizations.dart' show AppLocalizations;
import '../format.dart' show displayTotalCalories, mealDescription;
import '../theme/tokens.dart';
import 'grouped.dart' show kCellRadius;

/// Paints an accent ring and a light accent tint over [child] for
/// [duration] each time [trigger] changes to a new non-null value: held,
/// then faded out. With animations turned off it is held, then gone,
/// without a fade. Paints nothing otherwise, and takes no taps or focus:
/// the card under it works as before, its screen-reader node included.
///
/// [inset] is the card's own margin inside [child], so the ring follows
/// the card's rounded cell ([radius]) rather than the space around it.
class RevealHighlight extends StatefulWidget {
  const RevealHighlight({
    super.key,
    required this.child,
    this.trigger,
    this.announcement,
    this.inset = EdgeInsets.zero,
    this.radius = kCellRadius,
  });

  final Widget child;

  /// A new non-null value lights the ring again; null lights nothing.
  final Object? trigger;

  /// While set, a screen reader is told it: the ring is only seen, so a
  /// TalkBack user hears which meal the reveal brought on screen
  /// ([mealRevealLine]). A live region over the card's cell, the way
  /// Android has a screen reader say something (its announcement events
  /// are deprecated, and Flutter reports them unsupported there). It takes
  /// no accessibility focus and no taps, so the card keeps its own node.
  final String? announcement;

  final EdgeInsets inset;
  final double radius;

  /// How long the ring shows.
  static const Duration duration = Duration(milliseconds: 2000);

  @override
  State<RevealHighlight> createState() => RevealHighlightState();
}

class RevealHighlightState extends State<RevealHighlight>
    with SingleTickerProviderStateMixin {
  /// The ring's clock. AnimationBehavior.preserve: with Android's Remove
  /// animations on (disableAnimations, the platform flag the MediaQuery
  /// value below comes from), a normal controller runs at 0.05x its
  /// duration, and the ring was gone after about 0.1 s instead of 2 s. It
  /// is a time the ring shows, not a motion: it keeps its full length,
  /// without the fade.
  late final AnimationController _ring = AnimationController(
      vsync: this,
      duration: RevealHighlight.duration,
      animationBehavior: AnimationBehavior.preserve);

  /// Whether the ring is showing now.
  @visibleForTesting
  bool get lit => _ring.isAnimating;

  @override
  void initState() {
    super.initState();
    // A card first built while its reveal is on (it was off screen until
    // the list scrolled to it) lights as it comes.
    if (widget.trigger != null) _ring.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant RevealHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger != null && widget.trigger != oldWidget.trigger) {
      _ring.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final say = widget.announcement;
    final inset = widget.inset;
    // Always a Stack, so the card keeps its element (and its photo's
    // state) when the announcement comes and goes; passthrough, so the
    // card gets the list's constraints as before.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        CustomPaint(
          foregroundPainter: _RingPainter(
            _ring,
            color: AppColors.of(context).accent,
            inset: inset,
            radius: widget.radius,
            still: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
          ),
          child: widget.child,
        ),
        if (say != null)
          Positioned(
            left: inset.left,
            top: inset.top,
            right: inset.right,
            bottom: inset.bottom,
            child: Semantics(
              key: const Key('revealAnnouncement'),
              container: true,
              liveRegion: true,
              accessibilityFocusBlockType:
                  AccessibilityFocusBlockType.blockNode,
              label: say,
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}

/// What a screen reader says for a meal a reveal brought on screen
/// ([RevealHighlight.announcement]): its name and calories, worded as the
/// "Meal logged" line words them ("Ramen — ~600 kcal", "Ramen —— 约 600
/// 千卡"), as the meal is now.
String mealRevealLine(AppLocalizations l, Meal meal) => l.outcomeSavedSummary(
    mealDescription(meal.analysis, fallback: l.nlUnnamedMeal),
    displayTotalCalories(meal.analysis));

/// How strongly the ring shows at [t] of its time (0 to 1): fully while
/// held, for the first 60%, then fading out; with animations off ([still])
/// fully until the end, no fade. 0 when not [showing].
@visibleForTesting
double revealRingStrength(double t,
    {required bool showing, required bool still}) {
  if (!showing) return 0;
  if (still) return 1;
  const hold = 0.6;
  if (t <= hold) return 1;
  return 1 - Curves.easeOut.transform(((t - hold) / (1 - hold)).clamp(0, 1));
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress,
      {required this.color,
      required this.inset,
      required this.radius,
      required this.still})
      : super(repaint: progress);

  final AnimationController progress;
  final Color color;
  final EdgeInsets inset;
  final double radius;

  /// Animations off: no fade.
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final strength = revealRingStrength(progress.value,
        showing: progress.isAnimating, still: still);
    if (strength <= 0) return;
    final rect = inset.deflateRect(Offset.zero & size);
    if (rect.isEmpty) return;
    final cell = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(
        cell, Paint()..color = color.withValues(alpha: color.a * 0.12 * strength));
    canvas.drawRRect(
        cell.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: color.a * strength));
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      !identical(old.progress, progress) ||
      old.color != color ||
      old.inset != inset ||
      old.radius != radius ||
      old.still != still;
}

/// A meal list that can bring one of its cards on screen and ring it
/// (Today, a History day). Each card is listed under [cardKey]: its
/// identity in the list, and how the card is found when it is built. A
/// lazily built list builds only the cards near the screen, so one that
/// is not built yet is brought near first, a screen at a time.
mixin RevealsCards<T extends StatefulWidget> on State<T> {
  final Map<int, GlobalKey> _cardKeys = {};
  int? _revealedId;
  int _reveals = 0;
  Timer? _revealEnd;

  /// A context inside the list's scroll view that is built whenever the
  /// list is (a sliver, or the list's first box), to find the scroll view
  /// when no card near the target is built. Null: only the cards are used.
  BuildContext? get revealAnchor => null;

  /// The key the card of meal [id] is listed under.
  GlobalKey cardKey(int id) =>
      _cardKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'mealCard$id'));

  /// Forgets the keys of meals no longer listed.
  void keepCardKeys(Iterable<int> ids) {
    final listed = ids.toSet();
    _cardKeys.removeWhere((id, _) => !listed.contains(id));
  }

  /// [RevealHighlight.trigger] for the card of meal [id].
  Object? revealTrigger(int id) => _revealedId == id ? _reveals : null;

  /// The meal whose card the reveal has brought on screen, while its ring
  /// shows: what a screen reader is told then ([revealAnnounces]).
  int? _announcedId;

  /// Whether the card of meal [id] gets its [RevealHighlight.announcement]
  /// now: the reveal has brought it on screen, and its ring still shows.
  bool revealAnnounces(int id) => _announcedId == id;

  /// Rings the card of meal [id] and brings it on screen, centred where the
  /// list allows. [order]: the ids of the cards as listed, top to bottom.
  /// Nothing when [id] is not listed.
  Future<void> revealCard(int id, List<int> order) async {
    if (!order.contains(id) || !mounted) return;
    _revealEnd?.cancel();
    setState(() {
      _revealedId = id;
      _announcedId = null;
      _reveals++;
    });
    final reveal = _reveals;
    _revealEnd = Timer(RevealHighlight.duration, () {
      if (!mounted || _reveals != reveal) return;
      setState(() {
        _revealedId = null;
        _announcedId = null;
      });
    });
    await _scrollIntoView(id, order, reveal);
  }

  /// The most frames [revealCard] steps the list toward a card not built.
  static const int _maxSteps = 12;

  Future<void> _scrollIntoView(int id, List<int> order, int reveal) async {
    final target = order.indexOf(id);
    for (var step = 0; step < _maxSteps; step++) {
      await WidgetsBinding.instance.endOfFrame;
      // A later reveal, or this screen went: that one scrolls instead.
      if (!mounted || _reveals != reveal) return;
      final card = _cardKeys[id]?.currentContext;
      if (card != null && card.mounted) {
        await Scrollable.ensureVisible(card,
            alignment: 0.5,
            duration: AppMotion.of(card, AppMotion.standard),
            curve: AppMotion.curve);
        // On screen now: a screen reader is told which meal it is. Not
        // before, while it may still lie off screen, where a live region
        // can go unsaid.
        if (mounted && _reveals == reveal && _revealedId == id) {
          setState(() => _announcedId = id);
        }
        return;
      }
      // Not built. Which way it lies: past the last card built, or before
      // the first.
      ScrollPosition? position;
      int? first, last;
      for (var i = 0; i < order.length; i++) {
        final built = _cardKeys[order[i]]?.currentContext;
        if (built == null || !built.mounted) continue;
        first ??= i;
        last = i;
        position ??= Scrollable.maybeOf(built)?.position;
      }
      final anchor = revealAnchor;
      if (position == null && anchor != null && anchor.mounted) {
        position = Scrollable.maybeOf(anchor)?.position;
      }
      if (position == null || !position.hasContentDimensions) return;
      final down = last == null || target > last;
      if (!down && first != null && target > first) return; // cannot be
      final by = position.viewportDimension * 0.8;
      final to = (position.pixels + (down ? by : -by))
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (to == position.pixels) return;
      position.jumpTo(to);
    }
  }

  @override
  void dispose() {
    _revealEnd?.cancel();
    super.dispose();
  }
}
