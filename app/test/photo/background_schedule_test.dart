// iOS: the request for the next background scan is kept alive, and what
// iOS said about it is recorded (2026-11-28).
//
// On Nov 27 the owner's iPhone logged a noon meal at 23:05. No background
// scan had reached the server all day, and the phone could not say whether
// iOS even held a request for one: the request was made at a cold start
// only, and a submit iOS refused was only logged by workmanager.
import 'dart:async';
import 'dart:convert';

import 'package:calorie_tracker/services/photo/background.dart';
import 'package:calorie_tracker/services/photo/background_schedule.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// iOS's side of the seam, scripted.
class FakeRequests implements BackgroundRequests {
  /// What `pending` answers; null: cannot be asked.
  int? held = 0;

  /// What `submit` answers: null takes the request (iOS then holds one), a
  /// refusal's name refuses it.
  String? refuse;

  /// `submit` cannot be asked at all.
  bool submitUnanswered = false;

  /// Holds each `pending` answer back until completed.
  Completer<void>? gate;

  final List<String> calls = [];

  @override
  Future<int?> pending() async {
    calls.add('pending');
    await gate?.future;
    return held;
  }

  @override
  Future<({String? refusal})?> submit() async {
    calls.add('submit');
    if (submitUnanswered) return null;
    if (refuse == null) held = (held ?? 0) + 1;
    return (refusal: refuse);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FakeRequests ios;
  final t0 = DateTime.utc(2026, 11, 27, 14, 24);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    ios = FakeRequests();
    debugBackgroundRequestsOverride = ios;
    debugIsIOSOverride = true;
    debugIsAndroidOverride = false;
  });

  tearDown(() {
    debugBackgroundRequestsOverride = null;
    debugIsIOSOverride = null;
    debugIsAndroidOverride = null;
  });

  BackgroundSchedule? stored() =>
      BackgroundSchedule.decode(prefs.getString(backgroundSchedulePrefsKey));

  Future<BackgroundSchedule?> keep({bool wanted = true}) =>
      keepBackgroundRequest(wanted: wanted, clock: () => t0);

  group('keepBackgroundRequest (iOS)', () {
    test(
      'iOS holds none: one is submitted, and "scheduled" is recorded',
      () async {
        final now = await keep();
        expect(ios.calls, ['pending', 'submit']);
        expect(now?.scheduled, isTrue);
        expect(now?.submitted, isTrue);
        expect(now?.at, t0);
        final kept = stored()!;
        expect(
          (kept.scheduled, kept.refusal, kept.submitted, kept.at),
          (true, null, true, t0),
        );
      },
    );

    // A submit REPLACES the request iOS holds. The one a run leaves behind
    // may begin 30 minutes after that run; nothing here may touch it.
    test('iOS already holds one: nothing is submitted, so its earliest '
        'time is never moved', () async {
      ios.held = 1;
      final now = await keep();
      expect(ios.calls, ['pending'], reason: 'asked, never submitted over');
      expect((now?.scheduled, now?.submitted), (true, false));
      expect(stored()?.scheduled, isTrue);
      // And again at the next return to the app.
      await keep();
      await keep();
      expect(ios.calls.where((c) => c == 'submit'), isEmpty);
    });

    test('iOS refuses the submit: "not scheduled" with its reason, and the '
        'next check tries again', () async {
      ios.refuse = BackgroundRefusal.unavailable;
      final refused = await keep();
      expect(refused?.scheduled, isFalse);
      expect(refused?.refusal, BackgroundRefusal.unavailable);
      expect(stored()?.scheduled, isFalse);
      expect(stored()?.refusal, BackgroundRefusal.unavailable);
      // Background App Refresh is back on by the next return to the app.
      ios.refuse = null;
      final taken = await keep();
      expect(ios.calls, ['pending', 'submit', 'pending', 'submit']);
      expect((taken?.scheduled, taken?.refusal), (true, null));
      expect((stored()?.scheduled, stored()?.refusal), (true, null));
    });

    test(
      'iOS cannot be asked: nothing is learned and the record stays',
      () async {
        await keep(); // scheduled
        final before = prefs.getString(backgroundSchedulePrefsKey);
        ios.held = null; // no channel, or it threw
        expect(await keep(), isNull);
        expect(prefs.getString(backgroundSchedulePrefsKey), before);
        // The count answers, the submit cannot.
        ios
          ..held = 0
          ..submitUnanswered = true;
        expect(await keep(), isNull);
        expect(prefs.getString(backgroundSchedulePrefsKey), before);
      },
    );

    test('not wanted: nothing is asked of iOS and no record is kept', () async {
      await keep();
      ios.calls.clear();
      expect(await keep(wanted: false), isNull);
      expect(ios.calls, isEmpty);
      expect(prefs.getString(backgroundSchedulePrefsKey), isNull);
    });

    // Leaving the app sends 'hidden' and then 'paused'.
    test('two checks at once are one: iOS is asked once, both get the '
        'answer', () async {
      ios.gate = Completer<void>();
      final first = keep();
      final second = keep();
      expect(identical(first, second), isTrue);
      ios.gate!.complete();
      expect((await first)?.scheduled, isTrue);
      expect(ios.calls, ['pending', 'submit']);
      // Once it has ended, the next one asks again.
      ios.gate = null;
      await keep();
      expect(ios.calls, ['pending', 'submit', 'pending']);
    });

    test('Settings reads the answer of the check in flight, not the one '
        'before it', () async {
      ios.refuse = BackgroundRefusal.unavailable;
      await keep();
      expect((await lastBackgroundSchedule())?.scheduled, isFalse);
      // The app comes back; the switch is on again.
      ios
        ..refuse = null
        ..gate = Completer<void>();
      final check = keep();
      final read = lastBackgroundSchedule();
      ios.gate!.complete();
      await check;
      expect((await read)?.scheduled, isTrue);
    });

    test('a store that cannot be written never throws', () async {
      expect(
        await keepBackgroundRequest(
          wanted: true,
          loadPrefs: () async => throw StateError('store'),
        ),
        isNull,
      );
      expect(
        await lastBackgroundSchedule(
          loadPrefs: () async => throw StateError('store'),
        ),
        isNull,
      );
    });
  });

  // The whole of Android's path is WorkManager's own chain (background.dart
  // enableBackgroundScan). Nothing here may ask, submit or write there.
  group('Android', () {
    setUp(() {
      debugIsIOSOverride = false;
      debugIsAndroidOverride = true;
    });

    test(
      'nothing is asked, nothing is submitted, nothing is written',
      () async {
        expect(await keep(), isNull);
        expect(await keep(wanted: false), isNull);
        expect(ios.calls, isEmpty);
        expect(prefs.getKeys(), isEmpty);
      },
    );

    test('there is nothing to read either, even over a stray record', () async {
      await prefs.setString(
        backgroundSchedulePrefsKey,
        jsonEncode(BackgroundSchedule(at: t0, scheduled: false).toJson()),
      );
      expect(await lastBackgroundSchedule(), isNull);
    });
  });

  group('the native seam (BackgroundRequests)', () {
    const channel = MethodChannel(backgroundScheduleChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final sent = <MethodCall>[];

    void answer(Future<Object?> Function(MethodCall call) reply) {
      sent.clear();
      messenger.setMockMethodCallHandler(channel, (call) {
        sent.add(call);
        return reply(call);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    test('pending is the count iOS gives', () async {
      answer((_) async => 1);
      expect(await const BackgroundRequests().pending(), 1);
      expect(sent.single.method, 'pending');
      expect(
        sent.single.arguments,
        isNull,
        reason: 'never an identifier from Dart: the native side has one',
      );
    });

    test('submit: nil is taken; an error is named by its code', () async {
      answer((_) async => null);
      expect(await const BackgroundRequests().submit(), (refusal: null));
      expect(sent.single.method, 'submit');
      for (final (code, name) in const [
        (1, BackgroundRefusal.unavailable),
        (2, BackgroundRefusal.tooManyPending),
        (3, BackgroundRefusal.notPermitted),
        (7, 'error 7'),
      ]) {
        answer(
          (_) async => {'domain': 'BGTaskSchedulerErrorDomain', 'code': code},
        );
        expect(await const BackgroundRequests().submit(), (refusal: name));
      }
      // Another domain's code 1 is not 'unavailable'.
      answer((_) async => {'domain': 'NSCocoaErrorDomain', 'code': 1});
      expect(await const BackgroundRequests().submit(), (refusal: 'error 1'));
    });

    test(
      'no channel, a platform error or a junk reply: null, never a throw',
      () async {
        // No handler at all: MissingPluginException.
        expect(await const BackgroundRequests().pending(), isNull);
        expect(await const BackgroundRequests().submit(), isNull);
        answer((_) async => throw PlatformException(code: 'boom'));
        expect(await const BackgroundRequests().pending(), isNull);
        expect(await const BackgroundRequests().submit(), isNull);
        answer((call) async => call.method == 'pending' ? -1 : 'junk');
        expect(await const BackgroundRequests().pending(), isNull);
        expect(await const BackgroundRequests().submit(), isNull);
      },
    );

    // Review, 2026-11-28: in a simulator the native side answers "not
    // implemented" to every call (BackgroundSchedulePlugin.register; a
    // simulator refuses every submit, and Settings read a red "Not
    // scheduled" in every simulator session). That has to read as "iOS
    // cannot be asked", end to end: nothing is submitted and nothing is
    // recorded, so Settings and the diagnostics page show what they showed
    // before (background_schedule_ui_test: no record, no line).
    test('a native side that answers "not implemented" (a simulator): '
        'nothing is learned and nothing is recorded', () async {
      debugBackgroundRequestsOverride = null; // the real seam
      final asked = <String?>[];
      messenger.setMockMessageHandler(backgroundScheduleChannelName, (
        message,
      ) async {
        asked.add(const StandardMethodCodec().decodeMethodCall(message).method);
        return null; // what FlutterMethodNotImplemented puts on the wire
      });
      addTearDown(
        () => messenger.setMockMessageHandler(
          backgroundScheduleChannelName,
          null,
        ),
      );
      expect(await keep(), isNull);
      expect(asked, ['pending'], reason: 'no count, so no submit either');
      expect(prefs.getString(backgroundSchedulePrefsKey), isNull);
      expect(await lastBackgroundSchedule(), isNull);
      // A record from an earlier check is left exactly as it was.
      final before = jsonEncode(
        BackgroundSchedule(at: t0, scheduled: true).toJson(),
      );
      await prefs.setString(backgroundSchedulePrefsKey, before);
      expect(await keep(), isNull);
      expect(prefs.getString(backgroundSchedulePrefsKey), before);
    });

    // The app's launch and the Watch Camera Roll switch wait for the
    // answer (syncBackgroundScan): a channel that never replies must not
    // hold either.
    testWidgets('a channel that never replies is given up on', (tester) async {
      answer((_) => Completer<Object?>().future);
      Object? count = 'waiting', taken = 'waiting';
      unawaited(const BackgroundRequests().pending().then((c) => count = c));
      unawaited(const BackgroundRequests().submit().then((r) => taken = r));
      await tester.pump(
        backgroundRequestTimeout - const Duration(milliseconds: 1),
      );
      expect((count, taken), ('waiting', 'waiting'));
      await tester.pump(const Duration(milliseconds: 2));
      expect((count, taken), (null, null));
    });
  });

  group('the record', () {
    test('round-trips; a refusal is kept only while not scheduled', () {
      final refused = BackgroundSchedule(
        at: t0,
        scheduled: false,
        refusal: BackgroundRefusal.unavailable,
        submitted: true,
      );
      final back = BackgroundSchedule.decode(jsonEncode(refused.toJson()))!;
      expect(
        (back.at, back.scheduled, back.refusal, back.submitted),
        (t0, false, BackgroundRefusal.unavailable, true),
      );
      final held = BackgroundSchedule.decode(
        jsonEncode({'at': t0.toIso8601String(), 'ok': true, 'why': 'x'}),
      )!;
      expect(
        (held.scheduled, held.refusal, held.submitted),
        (true, null, false),
      );
    });

    test('anything else reads as no record', () {
      for (final junk in [
        null,
        '',
        'not json',
        '[]',
        '{}',
        '{"at":"2026-11-27T14:24:00Z"}',
        '{"at":"never","ok":true}',
        '{"at":"2026-11-27T14:24:00Z","ok":"yes"}',
      ]) {
        expect(BackgroundSchedule.decode(junk), isNull, reason: '$junk');
      }
    });

    test('holds a time, a yes or no and a code: nothing else', () {
      expect(
        BackgroundSchedule(
          at: t0,
          scheduled: false,
          refusal: BackgroundRefusal.notPermitted,
          submitted: true,
        ).toJson().keys,
        unorderedEquals(['at', 'ok', 'why', 'asked']),
      );
    });
  });
}
