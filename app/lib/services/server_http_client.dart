/// The one way a request reaches the user's own server.
///
/// ServerAnalyzer, ServerLookupClient and the Garmin fetch each send
/// through an [HttpsOnlyServerClient] wrapped around whatever client they
/// were given. It is the choke point for the https rule
/// (core/server_transport.dart): a request whose address the app sends
/// nothing to — not https:// while the switch is on; a debug build keeps
/// http:// to the phone itself — never reaches the network, so a server
/// method added later cannot send to such an address by forgetting a
/// check. The per-method checks in those three stay only where they word
/// what the user sees.
///
/// It is the choke point for the upload key too: a request carrying
/// X-API-Key goes only to the host the key is saved for, and only with
/// that key's text as it is saved at the moment of the request
/// (AppSettings.serverKeyFor). Each request reads the saved address and key
/// as it is built, so with the address changed before the key (the address
/// field saves as the key field is tapped, and the Restaurant nutrition
/// group asks the new address what it supports at once) the previous
/// server's key went to the new host (review of PR 74). Checking the host
/// alone still let a request built with the previous key, whose address was
/// read after a wait (a leftover estimate decoding, or waiting out a busy
/// server, as a setup link was confirmed), go to the new host once the new
/// key was bound there. The text of a key saved for one host now goes to no
/// other, whichever path sends and whenever it read the key.
///
/// It also turns redirects off. dart:io follows a 3xx by itself and
/// copies every header but Authorization and Cookie onto the next
/// request, so an https:// server (or something answering for it) that
/// redirected to an http:// address got the X-API-Key upload key sent
/// there in clear, and the reply read there taken as the server's
/// (review of the privacy lane, finding 3). With redirects off a 3xx is
/// an answer like any other: the callers already read it as a portal or
/// proxy page, never as the server.
library;

import 'package:http/http.dart' as http;

import '../core/server_transport.dart'
    show
        kServerKeyOtherHostMessage,
        kServerNeedsHttpsMessage,
        serverAddressRefused;

/// Raised instead of sending a request to an address the app sends
/// nothing to. A ClientException, so every caller's transport handling
/// treats it as a request that could not be made.
class ServerNeedsHttpsException extends http.ClientException {
  ServerNeedsHttpsException(Uri url) : super(kServerNeedsHttpsMessage, url);
}

/// Raised instead of sending the upload key to a host it was not saved
/// for. A ClientException, like [ServerNeedsHttpsException].
class ServerKeyOtherHostException extends http.ClientException {
  ServerKeyOtherHostException(Uri url)
      : super(kServerKeyOtherHostMessage, url);
}

class HttpsOnlyServerClient extends http.BaseClient {
  HttpsOnlyServerClient(this._inner, {required this.keyFor});

  /// [client] (a new http.Client when null) behind the https rule and the
  /// key's host; one that already is an [HttpsOnlyServerClient] as it is.
  static HttpsOnlyServerClient wrap(http.Client? client,
          {required String? Function(String host) keyFor}) =>
      client is HttpsOnlyServerClient
          ? client
          : HttpsOnlyServerClient(client ?? http.Client(), keyFor: keyFor);

  final http.Client _inner;

  /// Reads the text of the upload key that may go to a host (AppSettings
  /// .serverKeyFor: the saved key while it is bound to that host; null when
  /// none may: no key, another host's, or one not bound yet), at each
  /// request. Required, so no call site can leave the key unchecked.
  final String? Function(String host) keyFor;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (serverAddressRefused(request.url.toString())) {
      throw ServerNeedsHttpsException(request.url);
    }
    // Any spelling of the header (package:http's own map ignores case; a
    // request type with another map might not).
    final sent = [
      for (final MapEntry(:key, :value) in request.headers.entries)
        if (key.toLowerCase() == 'x-api-key') value,
    ];
    if (sent.isNotEmpty) {
      final allowed = keyFor(request.url.host.toLowerCase());
      if (allowed == null || sent.any((v) => v != allowed)) {
        throw ServerKeyOtherHostException(request.url);
      }
    }
    request.followRedirects = false;
    return _inner.send(request);
  }

  /// Not passed on: the client given may be shared with the other
  /// providers (MultiProviderAnalyzer hands one to all of them).
  @override
  void close() {}
}
