// Android review 2026-11-19 (R13), on real sockets: the Test AI Provider
// page's reachability probe sent with a plain http.Client, which follows a
// 3xx by itself. A server, or a proxy or sign-in gateway in front of it,
// that redirected the probe to an http:// address or another host had a
// request sent there; the stage then passed on that address's answer, or
// said "Could not reach your server at all" when nothing listened there,
// though the server itself had answered. The probe now goes through the
// https-only client in front of the server, which follows no redirect
// (services/server_http_client.dart).
//
// Both listeners are plain http on this machine's loopback, the one http
// a debug build (this test run) may use, so no certificate is needed. No
// test binding here on purpose: it replaces HttpClient with one that
// answers 400.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/ui/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  /// The saved server: answers every request with a 302 to [location],
  /// and notes each request in [asked].
  Future<HttpServer> redirectingTo(String location, List<String> asked) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      asked.add('${req.method} ${req.uri}');
      await req.drain<void>();
      req.response
        ..statusCode = HttpStatus.found
        ..headers.set('location', location);
      await req.response.close();
    });
    return server;
  }

  /// The page's checks against the server on [port], built as
  /// provider_page.dart builds them: with no client of their own.
  Future<List<DiagResult>> checks(int port) => ProviderDiagnostics(
        settings: FakeSettings()
          ..provider = 'server'
          ..apiKey = 'k'
          ..serverBaseUrl = 'http://127.0.0.1:$port',
        analyzer: FakeAnalyzer()
          ..nextTextIntent = {'ok': true}
          ..nextPhotoOutcome = const AnalysisOutcome(
              analysis: {'is_food': false},
              isFood: false,
              wall: Duration.zero),
        l10n: AppLocalizationsEn(),
        testImage: () => Uint8List(1),
      ).run().toList();

  test('a 302 to another address is not followed: nothing reaches it, and '
      "the stage passes on the server's own answer", () async {
    final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final reached = <String>[];
    elsewhere.listen((req) async {
      reached.add('${req.method} ${req.uri}');
      await req.response.close();
    });
    final asked = <String>[];
    final server = await redirectingTo(
        'http://127.0.0.1:${elsewhere.port}/landed', asked);
    addTearDown(() async {
      await elsewhere.close(force: true);
      await server.close(force: true);
    });

    final results = await checks(server.port);
    expect(asked, ['GET /'], reason: 'the probe went to the server');
    expect(reached, isEmpty, reason: 'the redirect target got nothing');
    expect(results[1].stage, 'Endpoint reachability');
    expect(results[1].status, DiagStatus.pass);
    expect(results, hasLength(6));
  });

  test('a 302 to an address where nothing listens: the server answered, '
      'so it is reachable', () async {
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close(force: true);
    final asked = <String>[];
    final server =
        await redirectingTo('http://127.0.0.1:$port/landed', asked);
    addTearDown(() => server.close(force: true));

    final results = await checks(server.port);
    expect(asked, ['GET /']);
    expect(results[1].status, DiagStatus.pass,
        reason: 'not "Could not reach your server at all"');
    expect(results, hasLength(6));
  });
}
