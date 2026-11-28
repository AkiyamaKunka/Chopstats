/// iOS: the request for the next background scan, kept alive and made
/// visible (2026-11-28).
///
/// The background scan runs when iOS launches its BGAppRefreshTask, and iOS
/// launches one only while it holds a REQUEST for it. The request was made
/// at a cold start, after a Watch Camera Roll or look-back edit, and by
/// each run for the one after it (workmanager_apple). Nothing made it
/// again on a return to the app, and a submit iOS refused was only logged
/// by the plugin. So one refused submit — Background App Refresh off at
/// that moment, say — or one run that ended before it could ask, left an
/// app that stays in memory for days with no request at all: no background
/// scan until the next cold start, and the Settings row went on showing
/// the last run's time. On Nov 27 the owner's noon meal was logged at
/// 23:05, and the phone could not say whether a request had been waiting.
///
/// So the app now asks iOS how many requests it holds
/// (ios/Runner/BackgroundSchedulePlugin.swift) each time it comes to the
/// foreground and each time it leaves, submits one when there is none, and
/// records what iOS said for Settings and the diagnostics page.
///
/// Only when there is none: a submit REPLACES the request iOS holds for
/// the identifier. A request iOS already holds is left exactly as it is, so
/// its earliest time is never pushed later and iOS keeps whatever it had
/// planned for it.
///
/// iOS only. Android's WorkManager keeps its own chain across process
/// death and reports its own state; nothing here runs there.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:shared_preferences/shared_preferences.dart';

import 'background.dart' show backgroundRunIsIOS;

/// ios/Runner/BackgroundSchedulePlugin.swift.
const String backgroundScheduleChannelName = 'dev.calorietracker/bgschedule';

/// One JSON object: what iOS said at the last check ([BackgroundSchedule]).
/// Written by the app's own engine only.
const String backgroundSchedulePrefsKey = 'background.schedule_v1';

/// Why iOS did not take a request ([BackgroundSchedule.refusal]): the
/// BGTaskScheduler.Error.Code it threw, by name. Anything else is
/// `error <code>`.
abstract final class BackgroundRefusal {
  /// Code 1: the app cannot schedule background work right now. Background
  /// App Refresh is off for the app or the phone, or iOS has it switched
  /// off for the moment.
  static const unavailable = 'unavailable';

  /// Code 2: iOS already holds as many requests as it allows.
  static const tooManyPending = 'tooManyPendingTaskRequests';

  /// Code 3: the identifier is not one this build may schedule
  /// (Info.plist BGTaskSchedulerPermittedIdentifiers, UIBackgroundModes).
  static const notPermitted = 'notPermitted';

  /// The name for an error iOS threw from BGTaskScheduler.submit.
  static String of(Object? domain, Object? code) {
    if (domain == 'BGTaskSchedulerErrorDomain') {
      switch (code) {
        case 1:
          return unavailable;
        case 2:
          return tooManyPending;
        case 3:
          return notPermitted;
      }
    }
    return code is int ? 'error $code' : 'error';
  }
}

/// What iOS said the last time the app asked about the request for the
/// next background scan. A time, a yes or no and an error code's name;
/// nothing about any photo.
class BackgroundSchedule {
  const BackgroundSchedule({
    required this.at,
    required this.scheduled,
    this.refusal,
    this.submitted = false,
  });

  /// When the app asked (UTC).
  final DateTime at;

  /// iOS holds a request: it may launch the scan when it likes.
  final bool scheduled;

  /// Not [scheduled]: why iOS refused the submit ([BackgroundRefusal]).
  final String? refusal;

  /// This check found no request and submitted one (taken or refused);
  /// false when iOS already held one and nothing was submitted.
  final bool submitted;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'ok': scheduled,
    if (refusal != null) 'why': refusal,
    if (submitted) 'asked': true,
  };

  /// Null for anything that is not a record.
  static BackgroundSchedule? decode(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    try {
      final json = jsonDecode(stored);
      if (json is! Map) return null;
      final at = DateTime.tryParse('${json['at']}');
      final ok = json['ok'];
      if (at == null || ok is! bool) return null;
      final why = json['why'];
      return BackgroundSchedule(
        at: at.toUtc(),
        scheduled: ok,
        refusal: !ok && why is String && why.isNotEmpty ? why : null,
        submitted: json['asked'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// How long one question to iOS may take. The scheduler answers in
/// milliseconds; this only bounds a channel that never replies, because
/// the app's launch and the Watch Camera Roll switch both wait for the
/// answer (ui/background_glue.dart syncBackgroundScan).
const Duration backgroundRequestTimeout = Duration(seconds: 3);

/// The native seam. Every method answers null when iOS cannot be asked: no
/// channel (tests, an older native build), a platform error, or no reply
/// within [backgroundRequestTimeout]. Never throws.
class BackgroundRequests {
  const BackgroundRequests([
    this._channel = const MethodChannel(backgroundScheduleChannelName),
  ]);

  final MethodChannel _channel;

  /// How many requests iOS holds for the background scan.
  Future<int?> pending() async {
    try {
      final count = await _channel
          .invokeMethod<int>('pending')
          .timeout(backgroundRequestTimeout);
      return count == null || count < 0 ? null : count;
    } catch (_) {
      return null;
    }
  }

  /// Submits one request, to begin as soon as iOS likes. `refusal` null:
  /// iOS took it.
  Future<({String? refusal})?> submit() async {
    try {
      final reply = await _channel
          .invokeMethod<Object?>('submit')
          .timeout(backgroundRequestTimeout);
      if (reply == null) return (refusal: null);
      if (reply is! Map) return null;
      return (refusal: BackgroundRefusal.of(reply['domain'], reply['code']));
    } catch (_) {
      return null;
    }
  }
}

@visibleForTesting
BackgroundRequests? debugBackgroundRequestsOverride;

/// The check in flight, shared by everyone who asks meanwhile: leaving the
/// app sends 'hidden' and then 'paused', and Settings reads the answer of
/// the same return to the app ([lastBackgroundSchedule]).
Future<BackgroundSchedule?>? _keeping;

/// iOS: asks how many requests iOS holds for the background scan, submits
/// one when [wanted] and there is none, and records the answer
/// ([backgroundSchedulePrefsKey]). Returns it; null when nothing was
/// learned — not iOS, not [wanted], or iOS could not be asked — and then
/// the record stays as it was (not wanted: it is removed).
///
/// A request iOS already holds is left alone: nothing is submitted, so its
/// earliest time is never pushed later. Never throws.
Future<BackgroundSchedule?> keepBackgroundRequest({
  required bool wanted,
  Future<SharedPreferences> Function()? loadPrefs,
  DateTime Function() clock = DateTime.now,
}) {
  if (!backgroundRunIsIOS()) {
    return Future<BackgroundSchedule?>.value();
  }
  final running = _keeping;
  if (running != null) return running;
  late final Future<BackgroundSchedule?> check;
  check = _keep(wanted: wanted, loadPrefs: loadPrefs, clock: clock)
      .whenComplete(() {
        if (identical(_keeping, check)) _keeping = null;
      });
  return _keeping = check;
}

Future<BackgroundSchedule?> _keep({
  required bool wanted,
  required Future<SharedPreferences> Function()? loadPrefs,
  required DateTime Function() clock,
}) async {
  try {
    if (!wanted) {
      final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
      await prefs.remove(backgroundSchedulePrefsKey);
      return null;
    }
    final requests =
        debugBackgroundRequestsOverride ?? const BackgroundRequests();
    final pending = await requests.pending();
    if (pending == null) return null;
    final BackgroundSchedule now;
    if (pending > 0) {
      now = BackgroundSchedule(at: clock().toUtc(), scheduled: true);
    } else {
      final answer = await requests.submit();
      if (answer == null) return null;
      now = BackgroundSchedule(
        at: clock().toUtc(),
        scheduled: answer.refusal == null,
        refusal: answer.refusal,
        submitted: true,
      );
    }
    final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
    await prefs.setString(backgroundSchedulePrefsKey, jsonEncode(now.toJson()));
    return now;
  } catch (_) {
    return null;
  }
}

/// What iOS said at the last check, once any check in flight has ended —
/// so a screen that asks as the app comes back reads this return's answer,
/// not the one before it. Null: never asked (Android, an iPhone build
/// without the channel), or the record cannot be read. Never throws.
Future<BackgroundSchedule?> lastBackgroundSchedule({
  Future<SharedPreferences> Function()? loadPrefs,
}) async {
  if (!backgroundRunIsIOS()) return null;
  try {
    await _keeping;
  } catch (_) {}
  try {
    final prefs = await (loadPrefs ?? SharedPreferences.getInstance)();
    return BackgroundSchedule.decode(
      prefs.getString(backgroundSchedulePrefsKey),
    );
  } catch (_) {
    return null;
  }
}
