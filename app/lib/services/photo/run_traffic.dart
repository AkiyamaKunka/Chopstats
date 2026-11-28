/// What a background run's analyzer has sent for the photo in flight, and
/// what came back (2026-11-28).
///
/// The run ends at a deadline (iOS: 22 s), and a photo still in flight then
/// is released for the next run. Whether that cut says anything about the
/// PHOTO depends on what the run was waiting for, and the only place that
/// shows it for every AI service alike is the HTTP client they all send
/// through. So the run hands its analyzer this client
/// (ui/background_glue.dart RunInFlight), and at the deadline asks it
/// [RunTraffic.cutOffAt].
///
/// Counts and status codes only: no address, header or body is kept, and
/// nothing is changed on the way through.
library;

import 'package:http/http.dart' as http;

/// What the photo in flight was waiting for when the run's deadline cut it
/// off.
enum CutOffAt {
  /// Nothing had been sent for it yet: the phone was still preparing it
  /// (its food check, its decode and resize). The one cut that can be the
  /// photo's own doing.
  preparing,

  /// The AI service's last answer for it was "busy": HTTP 503 or 529, or
  /// 429 (over a rate limit). The analyzer was waiting to try again, or
  /// had.
  busy,

  /// Its last request got no answer at all (no connection, a dropped one),
  /// or a server error (another 5xx).
  unreachable,

  /// A request was out and nothing had come back yet, with no refusal
  /// before it; or the answer had come and was still being handled. A slow
  /// answer, a busy server that holds the request, and a hung network all
  /// look like this from the phone.
  waiting,
}

/// The last thing heard for the photo in flight.
enum _Heard { nothing, answer, busy, error }

class RunTraffic extends http.BaseClient {
  /// [inner]: where the requests go. Null: a new [http.Client], made at
  /// the first request (a run that sends nothing makes none).
  RunTraffic([this._inner]);

  http.Client? _inner;

  /// Counts the photos: an answer to a request made for an earlier one
  /// says nothing about the one in flight now.
  int _photo = 0;
  int _sent = 0;
  _Heard _heard = _Heard.nothing;

  /// A photo was handed to the pipeline: what was sent before it is the
  /// previous photo's.
  void next() {
    _photo++;
    _sent = 0;
    _heard = _Heard.nothing;
  }

  /// Requests made for the photo in flight.
  int get sent => _sent;

  /// What the photo in flight is waiting for right now ([CutOffAt]). A
  /// refusal or a failure heard for it stands even while the analyzer's
  /// next try is out: that try is what the refusal caused.
  CutOffAt get cutOffAt {
    if (_sent == 0) return CutOffAt.preparing;
    return switch (_heard) {
      _Heard.busy => CutOffAt.busy,
      _Heard.error => CutOffAt.unreachable,
      _Heard.nothing || _Heard.answer => CutOffAt.waiting,
    };
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final photo = _photo;
    _sent++;
    try {
      final response = await (_inner ??= http.Client()).send(request);
      if (photo == _photo) _heard = _heardFor(response.statusCode);
      return response;
    } catch (_) {
      if (photo == _photo) _heard = _Heard.error;
      rethrow;
    }
  }

  static _Heard _heardFor(int status) {
    if (status == 503 || status == 529 || status == 429) return _Heard.busy;
    if (status >= 500 && status < 600) return _Heard.error;
    return _Heard.answer;
  }

  @override
  void close() => _inner?.close();
}
