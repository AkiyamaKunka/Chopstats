/// Android: an analysis the user started keeps the app running after they
/// leave it, and online where its job is expedited (owner decision 9,
/// option 1, 2026-11-20).
///
/// Android caches an app once it is neither in front nor the "previous"
/// app and freezes it about 10 s later, and cuts a background app's network
/// about 8 s after Home (QA 2026-11-20, API 35 and 36: Home and then
/// another app froze Chopstats at about +17 s; Android 16 also freezes the
/// previous app after about 70 s). A photo shared or picked, a typed meal
/// or a Fix meals request still on its way waited in the frozen process
/// until the user came back, and a kill in between lost it. [guard] counts
/// one such request from its start to its end; while one is counted,
/// MainActivity keeps a WorkManager job running
/// (android/.../AnalysisKeepAlive.kt: expedited on Android 12 and later,
/// plain below, no notification), which keeps the process from being
/// cached and frozen and, expedited, its network usable. The job ends as
/// the last request does, and each request keeps it for 3 minutes at most
/// from its own begin (KeepAliveRules.CAP_MS): a photo waiting its turn
/// counts its wait as one request and its turn as another, so the turn
/// gets the full 3 minutes from its start (PhotoPipeline._chain).
///
/// Rules: ONE begin per request, always ended (in `finally`), whatever the
/// request comes to (a meal saved, a failure, a refusal, the user backing
/// out); each begin carries an id this Dart run never reuses, so a repeated
/// or stray end changes nothing native. The requests of an engine that dies
/// (Back finished the activity, a swipe from Recents) end with it:
/// MainActivity drops its session in cleanUpFlutterEngine. A Dart run that
/// starts over in the same engine (a hot restart: no cleanup, ids from 1
/// again) drops what the last run left with its first call, "reset".
/// Nothing is kept across processes. Built for the app's own engine on
/// Android only (di.dart): iOS asks for background time per photo instead
/// (background_time.dart), and the background engine has its job's own
/// time.
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/services.dart' show MethodChannel;

import '../core/contracts.dart';

/// MainActivity.KEEP_ALIVE_CHANNEL.
const String keepAliveChannelName = 'dev.calorietracker/keepalive';

class AnalysisKeepAlive {
  /// Built once per Dart run of the app's engine (di.dart). Its first call
  /// is "reset": MainActivity drops every request still open under this
  /// engine's session. A hot restart keeps the engine, and with it the
  /// session (configureFlutterEngine is not run again, cleanUpFlutterEngine
  /// is not called), while the ids here start over at 1: what the last run
  /// began would keep the job up for its full cap with nothing in flight,
  /// and this run's first begin would land on its stale entry. At a cold
  /// start nothing is open, and the reset changes nothing.
  AnalysisKeepAlive(
      [this._channel = const MethodChannel(keepAliveChannelName)]) {
    _send('reset');
  }

  final MethodChannel _channel;

  /// The requests begun and not ended yet, by id.
  final Set<int> _open = {};
  int _lastId = 0;

  /// True while a request is in flight in this engine: the app shell's
  /// Back at the root then moves the app to the back in every task instead
  /// of letting Android finish it, and the request with it
  /// (SharedPhotosBackGuard).
  ValueListenable<bool> get inFlight => _inFlight;
  final ValueNotifier<bool> _inFlight = ValueNotifier<bool>(false);

  /// Requests in flight now.
  int get openCount => _open.length;

  /// Runs [body], one request to the AI or the user's own server, kept
  /// alive from its start to its end however it ends: its value, or its
  /// error, comes through unchanged. A failed native call never touches
  /// the body.
  Future<T> guard<T>(Future<T> Function() body) async {
    final id = _begin();
    try {
      return await body();
    } finally {
      _end(id);
    }
  }

  int _begin() {
    final id = ++_lastId;
    _open.add(id);
    _inFlight.value = true;
    _send('begin', id);
    return id;
  }

  void _end(int id) {
    if (!_open.remove(id)) return;
    _inFlight.value = _open.isNotEmpty;
    _send('end', id);
  }

  /// Fire and forget: the channel keeps the calls in order, and a missing
  /// or failing native side (an old build, a test) only loses the job.
  void _send(String method, [int? id]) {
    try {
      unawaited(_channel
          .invokeMethod<Object?>(method, id == null ? null : {'id': id})
          .then<void>((_) {}, onError: (Object _) {}));
    } catch (_) {}
  }
}

/// The app engine's [NlExecutor] with each typed meal (Describe) and Fix
/// meals request kept alive while it runs ([AnalysisKeepAlive.guard]): the
/// model call and, for a fix, the writes it leads to. A delete's
/// confirmation sends nothing and is passed through.
class KeptAliveExecutor implements NlExecutor {
  KeptAliveExecutor(this._inner, this._keepAlive);

  final NlExecutor _inner;
  final AnalysisKeepAlive _keepAlive;

  @override
  Future<DescribeOutcome> describeMeal(String text) =>
      _keepAlive.guard(() => _inner.describeMeal(text));

  @override
  Future<List<NlReply>> handleText(String userText) =>
      _keepAlive.guard(() => _inner.handleText(userText));

  @override
  Future<String> confirmPendingDelete(List<int> mealIds) =>
      _inner.confirmPendingDelete(mealIds);
}
