// What a background run's analyzer has sent for the photo in flight, and
// what came back (run_traffic.dart, 2026-11-28): the evidence the run's
// deadline goes by when it decides whether a cut says anything about the
// photo.
import 'dart:async';

import 'package:calorie_tracker/services/photo/run_traffic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final url = Uri.parse('https://ai.example/v1/analyze');

  /// A client that answers each request with the next scripted status, an
  /// error to throw, or (a Completer) whenever the test says.
  RunTraffic traffic(List<Object> script) {
    var next = 0;
    return RunTraffic(
      MockClient((_) async {
        final step = script[next++];
        if (step is int) return http.Response('{}', step);
        if (step is Completer<http.Response>) return step.future;
        throw step;
      }),
    );
  }

  test('nothing sent yet: the phone is still preparing the photo', () {
    final t = traffic([]);
    expect(t.cutOffAt, CutOffAt.preparing);
    t.next();
    expect((t.sent, t.cutOffAt), (0, CutOffAt.preparing));
  });

  test('a request out and unanswered, or answered and being handled: '
      'waiting', () async {
    final answer = Completer<http.Response>();
    final t = traffic([answer]);
    final reply = t.post(url, body: 'photo');
    await pumpEventQueue();
    expect((t.sent, t.cutOffAt), (1, CutOffAt.waiting));
    answer.complete(http.Response('{"ok":true}', 200));
    expect((await reply).body, '{"ok":true}');
    expect(t.cutOffAt, CutOffAt.waiting);
  });

  test('"busy" answers: 503, 529 and 429', () async {
    for (final status in [503, 529, 429]) {
      final t = traffic([status]);
      expect((await t.post(url)).statusCode, status);
      expect(t.cutOffAt, CutOffAt.busy, reason: '$status');
    }
  });

  test('no answer at all, or another server error: unreachable', () async {
    final t = traffic([http.ClientException('Connection refused')]);
    await expectLater(t.post(url), throwsA(isA<http.ClientException>()));
    expect(t.cutOffAt, CutOffAt.unreachable);
    for (final status in [500, 502, 504]) {
      final t = traffic([status]);
      await t.post(url);
      expect(t.cutOffAt, CutOffAt.unreachable, reason: '$status');
    }
  });

  test(
    'any other answer is an answer: the verdict is the analyzer\'s',
    () async {
      for (final status in [200, 400, 401, 404]) {
        final t = traffic([status]);
        await t.post(url);
        expect(t.cutOffAt, CutOffAt.waiting, reason: '$status');
      }
    },
  );

  // The analyzer waits and tries again after a refusal: the try that is
  // out when the deadline comes is what the refusal caused.
  test('a refusal or a failure stands while the next try is out', () async {
    final retry = Completer<http.Response>();
    final busy = traffic([503, retry]);
    await busy.post(url);
    unawaited(busy.post(url));
    await pumpEventQueue();
    expect((busy.sent, busy.cutOffAt), (2, CutOffAt.busy));

    final down = traffic([http.ClientException('no route'), retry]);
    await expectLater(down.post(url), throwsA(anything));
    unawaited(down.post(url));
    await pumpEventQueue();
    expect((down.sent, down.cutOffAt), (2, CutOffAt.unreachable));
  });

  test('the latest answer is the one that counts', () async {
    final t = traffic([503, 200, http.ClientException('dropped'), 503]);
    await t.post(url);
    expect(t.cutOffAt, CutOffAt.busy);
    await t.post(url);
    expect(t.cutOffAt, CutOffAt.waiting);
    await expectLater(t.post(url), throwsA(anything));
    expect(t.cutOffAt, CutOffAt.unreachable);
    await t.post(url);
    expect(t.cutOffAt, CutOffAt.busy);
  });

  test('the next photo starts clean, and a late answer to the one before '
      'it says nothing about it', () async {
    final late = Completer<http.Response>();
    final t = traffic([late, 200]);
    final first = t.post(url); // the analyzer gave up on this one
    await pumpEventQueue();
    t.next();
    expect((t.sent, t.cutOffAt), (0, CutOffAt.preparing));
    late.complete(http.Response('busy', 503));
    expect((await first).statusCode, 503);
    expect(
      t.cutOffAt,
      CutOffAt.preparing,
      reason: 'that answer was the previous photo\'s',
    );
    await t.post(url);
    expect((t.sent, t.cutOffAt), (1, CutOffAt.waiting));
  });

  test('requests and answers pass through untouched', () async {
    http.BaseRequest? seen;
    final t = RunTraffic(
      MockClient((request) async {
        seen = request;
        return http.Response('body', 201, headers: {'x-test': 'yes'});
      }),
    );
    final reply = await t.post(
      url,
      headers: {'X-API-Key': 'k'},
      body: 'the photo',
    );
    expect(seen!.url, url);
    expect(seen!.headers['X-API-Key'], 'k');
    expect((seen! as http.Request).body, 'the photo');
    expect(
      (reply.statusCode, reply.body, reply.headers['x-test']),
      (201, 'body', 'yes'),
    );
  });

  test('close closes the client it was given, and one that never sent has '
      'nothing to close', () {
    final inner = _ClosingClient();
    RunTraffic(inner).close();
    expect(inner.closed, isTrue);
    RunTraffic().close(); // no client was ever made
  });
}

class _ClosingClient extends http.BaseClient {
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
  @override
  void close() => closed = true;
}
