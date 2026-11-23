// LINK-1 (2026-11-22): app_links 7.2.1 answers every initial-link read with
// the first link it was given, for as long as the plugin lives, and each
// HomeShell reads it in initState: a second or rebuilt shell asked about
// that setup link again (RCREL-V-1). di.dart reads the plugin through
// launchLinkOnce (production_wiring_test pins the line), so only the
// engine's first call gets the link.
import 'dart:async';

import 'package:calorie_tracker/ui/services.dart' show launchLinkOnce;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final link = Uri.parse(
      'bitewise://setup?server=https%3A%2F%2F10.0.0.7&key=k1234&backend=claude');

  test('the first call gets the link, every later one null, and the plugin '
      'is read once', () async {
    var reads = 0;
    // As app_links: the same link, to every read.
    final initial = launchLinkOnce(() async {
      reads++;
      return link;
    });
    expect(await initial(), link);
    expect(await initial(), isNull);
    expect(await initial(), isNull);
    expect(reads, 1);
  });

  test('a call while the first read is still pending gets null at once',
      () async {
    final plugin = Completer<Uri?>();
    var reads = 0;
    final initial = launchLinkOnce(() {
      reads++;
      return plugin.future;
    });
    final first = initial();
    final second = initial();
    var answered = false;
    unawaited(second.whenComplete(() => answered = true));
    await pumpEventQueue();
    expect(answered, isTrue, reason: 'not held behind the first read');
    expect(await second, isNull);
    expect(reads, 1);

    plugin.complete(link);
    expect(await first, link, reason: 'the first call still gets the link');
    expect(await initial(), isNull);
    expect(reads, 1);
  });

  test('a first read that fails is not tried again', () async {
    var reads = 0;
    final initial = launchLinkOnce(() async {
      reads++;
      // What a channel call throws where no plugin answers it.
      throw MissingPluginException();
    });
    await expectLater(initial(), throwsA(isA<MissingPluginException>()));
    expect(await initial(), isNull);
    expect(await initial(), isNull);
    expect(reads, 1);
  });

  // AppLinksPlatform's own getInitialLink, which an implementation that
  // leaves it out falls back to, throws at once instead of failing its
  // future. HomeShell calls the read in initState and handles a failed
  // future; a throw out of the call would escape initState.
  test('a read that throws at once fails the first call\'s future, and is '
      'not tried again', () async {
    var reads = 0;
    Future<Uri?> unimplemented() {
      reads++;
      throw UnimplementedError('getInitialLink');
    }

    final initial = launchLinkOnce(unimplemented);
    Future<Uri?>? first;
    expect(() => first = initial(), returnsNormally);
    await expectLater(first, throwsA(isA<UnimplementedError>()));
    expect(await initial(), isNull);
    expect(reads, 1);
  });
}
