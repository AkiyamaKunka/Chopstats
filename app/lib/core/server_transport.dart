/// How the app talks to the user's OWN server: only over https://.
///
/// A plain http:// address carries the meal photos, the typed meal text
/// and the X-API-Key upload key across the network unencrypted (sweep
/// finding P0 read them off the socket). Google Play's User Data policy
/// asks for modern cryptography such as HTTPS for personal and sensitive
/// data in transit (answer/10144311), and the owner decided on 2026-11-13
/// to refuse plain http everywhere: iPhone, the GitHub APK and Play.
///
/// [kRequireHttpsServer] is that decision, in one place. Every path that
/// reaches the server reads it through [serverAddressRefused]:
/// - ServerAnalyzer (photos, meal text, leftovers, the key test, the
///   Claude sign-in, the server's login and feature checks),
/// - ServerLookupClient (restaurant lookups),
/// - the Garmin fetch,
/// - the setup link (parseSetupLink refuses an http:// server),
/// - Settings › Your own server (an http:// address is not saved, and a
///   saved one shows "needs https"),
/// - the Test AI Provider page (no reachability probe).
///
/// Turned off, the app still sends to an http:// address and says so
/// instead: a line in the consent text and a warning under the address.
///
/// The upload key is bound the same way to the host it was saved for
/// ([serverKeyHostOf]): a request carrying it to any other host never
/// reaches the network (services/server_http_client.dart).
library;

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;

/// The one switch: true = nothing is ever sent to an http:// server
/// address (owner decision, 2026-11-13). False brings back the earlier
/// behaviour with a warning: the consent text and the server page say
/// that what is sent travels unencrypted.
const bool kRequireHttpsServer = true;

/// Tests only: runs a test with the switch in the other position. Null
/// (always, outside tests) = [kRequireHttpsServer].
@visibleForTesting
bool? debugRequireHttpsServerOverride;

/// The switch as the app reads it.
bool get requireHttpsServer =>
    debugRequireHttpsServerOverride ?? kRequireHttpsServer;

/// Whether [url] is a plain http:// address (any letter case, spaces
/// around it ignored).
bool isCleartextServerUrl(String url) {
  final t = url.trim().toLowerCase();
  return t.startsWith('http://');
}

/// Whether [url]'s host is this device itself: localhost, 127.0.0.0/8 or
/// ::1. Traffic to it never leaves the device.
bool isLoopbackServerUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null) return false;
  final host = u.host.toLowerCase();
  if (host == 'localhost' || host == '::1') return true;
  final parts = host.split('.');
  return parts.length == 4 &&
      parts.first == '127' &&
      parts.every((p) => int.tryParse(p) != null);
}

/// Whether nothing may be sent to the saved server address [url]: the
/// switch is on, the address is set, and it does not start with
/// https://. An address with no scheme or another one ('10.0.0.5:5000',
/// 'ftp://…') is refused too: the only address the app sends to is an
/// https:// one.
///
/// The one exception: a DEBUG build may use http:// to this device
/// itself (localhost, 127.x.x.x, ::1) — a local test server, or one
/// reached through `adb reverse`. A release build never does: [debugBuild]
/// is false there.
bool serverAddressRefused(String url,
    {bool? require, bool debugBuild = kDebugMode}) {
  if (!(require ?? requireHttpsServer)) return false;
  final t = url.trim();
  if (t.isEmpty) return false; // "no address" is said on its own
  if (t.toLowerCase().startsWith('https://')) return false;
  if (debugBuild && isCleartextServerUrl(t) && isLoopbackServerUrl(t)) {
    return false;
  }
  return true;
}

/// What a send to a refused address reports, in English like the
/// analyzers' other lines. It names the 'server address', so
/// classifyAnalysisError reads it as user state (the photo is kept, not
/// burned), and outcome_text tells it apart by [isServerNeedsHttpsMessage].
const String kServerNeedsHttpsMessage =
    'Your server address does not start with https:// — Chopstats sends '
    'nothing to a plain http:// server. Change it to https:// in Settings.';

/// Whether [message] is [kServerNeedsHttpsMessage].
bool isServerNeedsHttpsMessage(String? message) =>
    message != null && message.contains('sends nothing to a plain http://');

/// The host an upload key saved for the server address [url] is bound to:
/// its host, lowercased, or null when [url] names none ('', an address
/// with no scheme). The key is only ever sent to that host
/// (services/server_http_client.dart): a key saved for one server never
/// goes to an address typed for another (review of PR 74).
String? serverKeyHostOf(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host.isEmpty ? null : host;
}

/// Whether the upload key, saved for [keyHost] (AppSettings.serverKeyHost),
/// is for another host than the server address [url]: nothing is sent
/// with it there. False when there is no address to send to.
bool serverKeyForOtherHost(String? keyHost, String url) {
  final host = serverKeyHostOf(url);
  return host != null && keyHost != host;
}

/// What a send whose upload key was saved for another server address
/// reports, in English like the analyzers' other lines. It names the
/// 'server upload key', so classifyAnalysisError reads it as user state
/// (the photo is kept, not burned), and outcome_text tells it apart by
/// [isServerKeyOtherHostMessage].
const String kServerKeyOtherHostMessage =
    'Your server upload key was saved for another server address, and '
    'Chopstats sends it only there. Paste this server\'s upload key in '
    'Settings, or use the saved one for it.';

/// Whether [message] is [kServerKeyOtherHostMessage].
bool isServerKeyOtherHostMessage(String? message) =>
    message != null && message.contains('saved for another server address');
