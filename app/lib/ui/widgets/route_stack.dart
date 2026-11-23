/// The app navigator's routes, as its observer sees them come and go
/// (Android, view-after-share lane: ui/meal_reveal.dart).
///
/// The navigator lists its routes to no one, and the app shell needs all
/// of them to go to a meal the user asked to see: every screen over the
/// tabs that Back would close without asking is closed for it, and none
/// is closed while one of them holds its pop (unsaved changes:
/// DiscardChangesGuard) or a dialog, sheet or menu is open. A screen
/// closed above an editor that keeps its changes would leave the user
/// half way, so the shell decides on the whole stack first.
library;

import 'package:flutter/widgets.dart';

/// The routes of the navigator it observes (MaterialApp.navigatorObservers),
/// bottom to top, and a signal each time they change or one of them holds
/// or lets go of its pop ([popChanged]).
class RouteStack extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _routes = [];

  /// The routes, bottom (the app's home) to top.
  List<Route<dynamic>> get routes => List.unmodifiable(_routes);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (at >= 0) _routes.removeAt(at);
    if (newRoute != null) {
      _routes.insert(at >= 0 ? at : _routes.length, newRoute);
    }
    notifyListeners();
  }

  /// A route held or let go of its pop: a PopScope's canPop changed on the
  /// route on top, which the navigator reports with a
  /// NavigationNotification above it (app.dart's MaterialApp builder).
  void popChanged() => notifyListeners();
}
