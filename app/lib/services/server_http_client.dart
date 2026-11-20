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
/// X-API-Key goes only to the host the key was saved for
/// (AppSettings.serverKeyHost, read at each request). Each request reads
/// the saved address and key as it is built, so with the address changed
/// before the key (the address field saves as the key field is tapped,
/// and the Restaurant nutrition group asks the new address what it
/// supports at once) the previous server's key went to the new host
/// (review of PR 74). Now it never does, whichever path sends.
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
  HttpsOnlyServerClient(this._inner, {required this.keyHost});

  /// [client] (a new http.Client when null) behind the https rule and the
  /// key's host; one that already is an [HttpsOnlyServerClient] as it is.
  static HttpsOnlyServerClient wrap(http.Client? client,
          {required String? Function() keyHost}) =>
      client is HttpsOnlyServerClient
          ? client
          : HttpsOnlyServerClient(client ?? http.Client(), keyHost: keyHost);

  final http.Client _inner;

  /// Reads the host the upload key was saved for (AppSettings
  /// .serverKeyHost; null: no key, or not bound yet), at each request.
  /// Required, so no call site can leave the key unbound.
  final String? Function() keyHost;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (serverAddressRefused(request.url.toString())) {
      throw ServerNeedsHttpsException(request.url);
    }
    // Any spelling of the header (package:http's own map ignores case; a
    // request type with another map might not).
    if (request.headers.keys.any((k) => k.toLowerCase() == 'x-api-key')) {
      final bound = keyHost();
      if (bound == null || bound != request.url.host.toLowerCase()) {
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
