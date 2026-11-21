/// Android 15 and later, 3-button navigation: an opaque band in the bar's
/// colour under the buttons, so no screen's content shows through the bar
/// (QA KAA-1, 2026-11-20).
///
/// From Android 15 the app draws edge to edge, under the navigation bar.
/// Behind the 3-button bar Android draws the colour the app gives it at
/// 80% only (the contrast scrim, app.dart _SystemNavBarStyle), so a pushed
/// screen's field that lay under the buttons at rest still showed through,
/// dimmed: Edit meal's last item at its first scroll, about 1.6:1 against
/// the bar in light and 1.9:1 in dark. The app now paints the bar's height
/// in that same colour itself, above its navigator and so above every
/// screen, under Android's scrim: the scrim over it changes nothing, and
/// whatever scrolls under the buttons is hidden, as under the tab bar,
/// whose own colour it is. Each scroll still ends past the bar
/// (grouped.dart scrollEndInset), so nothing is out of reach. The gesture
/// bar gets no band: Android draws no scrim there either, and the screens
/// stay edge to edge under it.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// The height of the 3-button navigation bar the app draws under, in
/// logical pixels, or 0: gesture navigation, no bar, or a bar the app does
/// not draw under (below Android 15, where the bottom view padding is 0).
///
/// Flutter does not say which navigation the phone uses, but the back
/// gesture does: gesture navigation keeps both side edges for it (system
/// gesture insets of about 30 dp each; its bar is 24 dp), and 3-button
/// navigation keeps neither (its bar is 48 dp). The view padding, not the
/// padding: the band stays put while the keyboard comes and goes, and the
/// keyboard covers it while it is up.
double threeButtonBarHeight(BuildContext context) {
  final gestures = MediaQuery.systemGestureInsetsOf(context);
  if (gestures.left > 0 || gestures.right > 0) return 0;
  return MediaQuery.viewPaddingOf(context).bottom;
}

/// The band: [threeButtonBarHeight] of [color], meant for the bottom of
/// the screen above the app's navigator (app.dart _SystemNavBarStyle).
/// Nothing at all with gesture navigation or without a bar. Touches pass
/// through it, to the system bar that takes them there anyway.
class NavBarBand extends StatelessWidget {
  const NavBarBand({super.key, required this.color});

  /// The colour Android's scrim is given now: the tab bar's, or that under
  /// a dialog's barrier while one or the analyzing overlay dims the app
  /// (NavBarDimming), since the band is out of their reach too. A change
  /// repaints the band without a rebuild: it can come while a frame is
  /// being built.
  final ValueListenable<Color?> color;

  @override
  Widget build(BuildContext context) {
    final height = threeButtonBarHeight(context);
    if (height <= 0) return const SizedBox.shrink();
    return IgnorePointer(
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: CustomPaint(painter: _BandPainter(color)),
      ),
    );
  }
}

class _BandPainter extends CustomPainter {
  _BandPainter(this.color) : super(repaint: color);

  final ValueListenable<Color?> color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = color.value;
    if (c == null) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = c);
  }

  @override
  bool shouldRepaint(_BandPainter oldDelegate) => oldDelegate.color != color;
}
