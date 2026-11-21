/// Android 15 and later, 3-button navigation: the system's navigation-bar
/// scrim dims with the app's own barriers (review NAV-2, 2026-11-20).
///
/// With the contrast scrim on (app.dart _SystemNavBarStyle), Android draws
/// the bar's colour at 80% as a view of its own ABOVE the app, so no
/// Flutter barrier can dim it: every dialog (its barrier is the theme's
/// scrim) and the overlay that dims a screen while a photo is analyzed
/// ([AnalyzingOverlay]) left a bright strip under the buttons, where the
/// transparent bar of before had let the barrier through. While one is up,
/// the shell hands MainActivity the bar colour under the barrier's instead
/// (Color.alphaBlend), and the bar's own colour again once it is gone.
/// Bottom sheets are left alone: a sheet covers the bar's area itself.
library;

import 'package:flutter/widgets.dart';

/// The barriers up now that dim the whole screen: each open dialog route
/// ([NavBarDimmingObserver]) and each analyzing overlay holds one.
class NavBarDimming extends ChangeNotifier {
  int _holds = 0;

  /// Whether any barrier dims the app now.
  bool get dimmed => _holds > 0;

  /// One barrier is up until the function returned is called (a second
  /// call changes nothing). Listeners hear the first hold and the last
  /// release only.
  VoidCallback hold() {
    _holds++;
    if (_holds == 1) notifyListeners();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holds--;
      if (_holds == 0) notifyListeners();
    };
  }

  /// The dimming the app shell provides above its navigator, or null (an
  /// iPhone, the startup-error screen, a test without the shell). No
  /// dependency is taken: a barrier holds once, for its whole life.
  static NavBarDimming? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NavBarDimmingScope>()?.dimming;
}

/// Hands [dimming] to the routes below it (app.dart _SystemNavBarStyle,
/// above the app's navigator).
class NavBarDimmingScope extends InheritedWidget {
  const NavBarDimmingScope(
      {super.key, required this.dimming, required super.child});

  final NavBarDimming dimming;

  @override
  bool updateShouldNotify(NavBarDimmingScope oldWidget) =>
      dimming != oldWidget.dimming;
}

/// Holds [dimming] while a dialog route with a visible barrier is open on
/// the navigator it observes (MaterialApp.navigatorObservers): showDialog's
/// alerts and confirmations, the date and time pickers, the consent
/// dialogs. Bottom sheets and menus are not dialog routes.
class NavBarDimmingObserver extends NavigatorObserver {
  NavBarDimmingObserver(this.dimming);

  final NavBarDimming dimming;
  final Map<Route<dynamic>, VoidCallback> _held = {};

  /// Whether [route] dims the screen as a dialog does.
  static bool dims(Route<dynamic> route) =>
      route is RawDialogRoute && (route.barrierColor?.a ?? 0) > 0;

  void _add(Route<dynamic>? route) {
    if (route == null || !dims(route) || _held.containsKey(route)) return;
    _held[route] = dimming.hold();
  }

  void _remove(Route<dynamic>? route) => _held.remove(route)?.call();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _remove(oldRoute);
    _add(newRoute);
  }
}
