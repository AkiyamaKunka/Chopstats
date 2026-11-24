/// Explicit permission before meal data goes to a third-party AI (App Store
/// guideline 5.1.2(i): "clearly disclose where personal data will be shared
/// with third parties, including with third-party AI, and obtain explicit
/// permission before doing so").
///
/// Consent is per RECIPIENT (core/ai_consent.dart aiConsentRoute), asked:
/// - before a foreground send: a picked photo, Describe/Fix a meal,
///   Leftovers, Test This Provider, Photo Coverage ([ensureAiConsent]), a
///   note in Edit meal ([ensureMealNoteConsent]);
/// - for a photo shared into the app, held until answered
///   ([SharedPhotoConsentGate]);
/// - when Watch Camera Roll is turned on (settings_screen.dart), and when
///   the recipient changes while it is on ([confirmAiRecipientChange]).
///
/// And once more when the text changed what is sent since the current
/// recipient was allowed: by the app shell for a change to what goes on
/// its own ([askAiConsentUpdate], up to aiConsentShellAskVersion), and at
/// the first note sent in Edit meal for the note's text
/// ([ensureMealNoteConsent]). The newly described data waits for that
/// Allow.
///
/// A share of several photos is ONE question: Not now covers that share
/// (and any that arrived before the answer), dropped without being asked
/// about or sent, and one line says how many were not sent
/// ([askSharedPhotoConsent]). A share after the answer asks again.
///
/// These are the questions. Every automatic send already needs the
/// watcher, and the watcher only runs for a consented recipient; the photo
/// pipeline reads the answer once more at each send (photo_pipeline.dart
/// AiSendGate), because an admitted photo can still be waiting its turn
/// when the consent is withdrawn or the provider changes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/ai_consent.dart';
import '../core/contracts.dart' show IntakePhoto, ShareDeliveries;
import '../core/server_transport.dart'
    show isCleartextServerUrl, serverAddressRefused;
import 'l10n.dart';
import 'provider_names.dart' show providerDisplayLabel;
import 'services.dart' show SettingsStore;
import 'theme/app_dialog.dart';

/// The recipient the current provider choice sends to.
String currentAiConsentRoute(SettingsStore s) =>
    aiConsentRoute(s.provider, s.serverBackend);

/// Whether a send right now would need the user's permission first: a
/// recipient is configured (without a key nothing can leave the phone, and
/// the send fails with its own 'no key' message) and it is not allowed yet.
bool aiConsentNeeded(SettingsStore s) =>
    s.apiKey.trim().isNotEmpty && !s.hasAiConsent(currentAiConsentRoute(s));

/// The AI company itself, e.g. 'Google (Gemini)' or, for the user's own
/// server, the company behind its plan.
String aiConsentCompanyName(AppLocalizations l,
        {required String provider, required String serverBackend}) =>
    provider == 'server'
        ? l.aiConsentPlanCompany(serverBackend)
        : l.aiConsentCompany(provider);

/// The full consent text for a provider choice — the body naming the
/// recipient, plus where its company processes the data when that is
/// mainland China, plus, for the user's own server, how it travels when
/// the address is not https:// (core/server_transport.dart): with the
/// https switch on, that nothing is sent to it; with it off, that it goes
/// unencrypted. About transport, not about what is sent, so the wording
/// version (aiConsentWordingVersion) stays.
String aiConsentText(AppLocalizations l,
    {required String provider,
    required String serverBackend,
    required String serverBaseUrl}) {
  final company = aiConsentCompanyName(l,
      provider: provider, serverBackend: serverBackend);
  final String recipient;
  if (provider == 'server') {
    final host = _hostOf(serverBaseUrl);
    recipient = host.isEmpty
        ? l.aiConsentServerRecipientNoHost(company)
        : l.aiConsentServerRecipient(host, company);
  } else if (provider == 'openrouter') {
    recipient = l.aiConsentRelayRecipient;
  } else {
    recipient = company;
  }
  final body = l.aiConsentBody(recipient);
  final text = aiRoutesInMainlandChina
          .contains(aiConsentRoute(provider, serverBackend))
      ? '$body\n\n${l.aiConsentChinaNote(company)}'
      : body;
  final transport = provider != 'server'
      ? null
      : serverAddressRefused(serverBaseUrl)
          ? l.serverHttpsRequiredConsentNote
          : isCleartextServerUrl(serverBaseUrl)
              ? l.serverHttpConsentNote
              : null;
  return transport == null ? text : '$text\n\n$transport';
}

String _hostOf(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  return uri != null && uri.host.isNotEmpty ? uri.host : trimmed;
}

/// The consent dialog; true = Allow. Records nothing — callers do, so the
/// route they asked about is the one saved. [title], [appendix] and the
/// keys let the camera-roll switch reuse it with its own notice;
/// [leadWithAppendix] puts that notice above the general text, where the
/// one thing new to the user is read first (the text only moves: what is
/// asked, and when, is the caller's).
Future<bool> showAiConsentDialog(
  BuildContext context, {
  required String provider,
  required String serverBackend,
  required String serverBaseUrl,
  String? title,
  String? appendix,
  bool leadWithAppendix = false,
  String? allowLabel,
  String? cancelLabel,
  Key dialogKey = const Key('aiConsentDialog'),
  Key cancelKey = const Key('aiConsentNotNow'),
  Key allowKey = const Key('aiConsentAllow'),
}) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final l = ctx.l10n;
      final text = aiConsentText(l,
          provider: provider,
          serverBackend: serverBackend,
          serverBaseUrl: serverBaseUrl);
      // The app's scrolling dialog (A1): title and text scroll together,
      // so the disclosure is readable at every text size before Allow.
      return appAlertDialog(
        key: dialogKey,
        title: Text(title ?? l.aiConsentTitle),
        content: Text(appendix == null
            ? text
            : leadWithAppendix
                ? '$appendix\n\n$text'
                : '$text\n\n$appendix'),
        actions: [
          TextButton(
              key: cancelKey,
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelLabel ?? l.aiConsentNotNow)),
          FilledButton(
              key: allowKey,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(allowLabel ?? l.aiConsentAllow)),
        ],
      );
    },
  );
  return go == true;
}

/// Before a FOREGROUND send: true = go ahead (already allowed, nothing can
/// be sent yet, or the user just allowed it — which is saved). Not now
/// shows [declined] (default: "Nothing was sent.") and returns false;
/// [declinedAtAnswer], when given, words that line instead, read at the
/// moment of the answer.
Future<bool> ensureAiConsent(BuildContext context, SettingsStore settings,
    {String? declined, String Function()? declinedAtAnswer}) async {
  if (!aiConsentNeeded(settings)) return true;
  final route = currentAiConsentRoute(settings);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final declinedText = declined ?? context.l10n.aiConsentDeclined;
  final ok = await showAiConsentDialog(context,
      provider: settings.provider,
      serverBackend: settings.serverBackend,
      serverBaseUrl: settings.serverBaseUrl);
  if (ok) {
    await settings.setAiConsent(route, granted: true);
    return true;
  }
  messenger?.showSnackBar(SnackBar(
      content: Text(declinedAtAnswer?.call() ?? declinedText)));
  return false;
}

/// The app shell's question for a photo shared into the app
/// ([SharedPhotoConsentGate.attach]). Not now covers the rest of that
/// share: the gate drops, without asking or sending, every photo of the
/// shares that had arrived by the answer, and the one line says how many
/// were not sent ([SharedPhotoConsentGate.declineOpenQuestion]).
Future<bool> askSharedPhotoConsent(BuildContext context,
    SettingsStore settings, SharedPhotoConsentGate gate) {
  final l = context.l10n;
  return ensureAiConsent(context, settings, declinedAtAnswer: () {
    final notSent = gate.declineOpenQuestion();
    return notSent > 1
        ? l.shareConsentDeclinedMany(notSent)
        : l.shareConsentDeclined;
  });
}

/// A provider or plan choice that would change the recipient. With Watch
/// Camera Roll ON the next automatic photo would go to the new recipient,
/// so it is asked now (the notice included) and Not now keeps the previous
/// choice: false = do not switch. With the watcher off the switch simply
/// happens and the next foreground send asks.
Future<bool> confirmAiRecipientChange(BuildContext context,
    SettingsStore settings,
    {required String provider, required String serverBackend}) async {
  if (!settings.watcherEnabled) return true;
  final route = aiConsentRoute(provider, serverBackend);
  if (settings.hasAiConsent(route)) return true;
  final l = context.l10n;
  final ok = await showAiConsentDialog(context,
      provider: provider,
      serverBackend: serverBackend,
      serverBaseUrl: settings.serverBaseUrl,
      // The camera-roll notice first: it is why this is asked now.
      appendix: l.watcherDisclosureBody(
          providerDisplayLabel(l, provider, serverBackend),
          settings.lookbackDays.clamp(1, 30)),
      leadWithAppendix: true);
  if (!ok) return false;
  await settings.setAiConsent(route, granted: true);
  return true;
}

/// Whether the app shell should ask once more for the CURRENT recipient:
/// it is allowed, but under a consent text older than the newest one the
/// shell asks about (core/ai_consent.dart aiConsentShellAskVersion: the
/// B14 text, a change to what an automatic photo carries), and the user
/// has not answered that yet. A grant under that text or newer is not
/// asked at launch: the Edit meal note, the one change since, asks at its
/// own send ([ensureMealNoteConsent]). Never without a key (nothing could
/// be sent) and never without a grant: the first send's own question
/// covers that.
bool aiConsentUpdateNeeded(SettingsStore s) {
  if (s.apiKey.trim().isEmpty) return false;
  final route = currentAiConsentRoute(s);
  final version = s.aiConsentVersion(route);
  return version > 0 &&
      version < aiConsentShellAskVersion &&
      !s.aiConsentUpdateDeclined(route);
}

/// What is new since consent text [version], oldest change first, for the
/// update question's lead: the B14 line below aiConsentPreviousDayVersion,
/// the Edit meal note's below aiConsentMealNoteVersion.
List<String> aiConsentUpdateLeads(AppLocalizations l, int version) => [
      if (version < aiConsentPreviousDayVersion) l.aiConsentUpdateLead,
      if (version < aiConsentMealNoteVersion) l.aiConsentUpdateLeadMealNote,
    ];

/// The update question's text before the full consent text: what is new
/// for a grant under [version] ([aiConsentUpdateLeads] — each change sits
/// in the full text, where nobody would find it), then the camera-roll
/// notice while Watch Camera Roll is on (the order it was turned on with).
String _updateAppendix(
        AppLocalizations l, SettingsStore settings, int version) =>
    [
      ...aiConsentUpdateLeads(l, version),
      if (settings.watcherEnabled)
        l.watcherDisclosureBody(
            providerDisplayLabel(l, settings.provider, settings.serverBackend),
            settings.lookbackDays.clamp(1, 30)),
    ].join('\n\n');

/// The one-time question for [aiConsentUpdateNeeded], under a title saying
/// what is sent has changed: first what is new ([aiConsentUpdateLeads]:
/// for a version-1 grant the B14 line, then the Edit meal note's), then
/// the camera-roll notice while Watch Camera Roll is on, then the full
/// consent text for the current recipient. Allow records the current text
/// for that recipient, which is what sends the newly described data;
/// anything else is remembered as Not now, and the older grant goes on
/// exactly as before. True = Allow.
Future<bool> askAiConsentUpdate(
    BuildContext context, SettingsStore settings) async {
  final route = currentAiConsentRoute(settings);
  final l = context.l10n;
  final ok = await showAiConsentDialog(context,
      provider: settings.provider,
      serverBackend: settings.serverBackend,
      serverBaseUrl: settings.serverBaseUrl,
      title: l.aiConsentUpdateTitle,
      appendix:
          _updateAppendix(l, settings, settings.aiConsentVersion(route)),
      leadWithAppendix: true,
      dialogKey: const Key('aiConsentUpdateDialog'),
      cancelKey: const Key('aiConsentUpdateNotNow'),
      allowKey: const Key('aiConsentUpdateAllow'));
  if (ok) {
    await settings.setAiConsent(route, granted: true);
  } else {
    await settings.declineAiConsentUpdate(route);
  }
  return ok;
}

/// Before a note typed in Edit meal is sent (with that meal's description,
/// foods and numbers, and its earlier notes): true = go ahead.
/// - No key: true; nothing can be sent, and the send says why.
/// - Allowed under the text that lists the note
///   (core/ai_consent.dart aiConsentMealNoteVersion) or newer: true.
/// - Not allowed at all: the usual question ([ensureAiConsent]), whose
///   text lists the note.
/// - Allowed under an older text: asked once more now, at the note's own
///   send, under the update title with what is new for that grant leading
///   ([aiConsentUpdateLeads]), then the camera-roll notice while Watch
///   Camera Roll is on, then the full text. Allow records the current text
///   and the note goes; Not now sends nothing, says so, and is not
///   remembered: the next note asks again. The app shell never asks about
///   this text at launch (aiConsentShellAskVersion).
Future<bool> ensureMealNoteConsent(
    BuildContext context, SettingsStore settings) async {
  if (settings.apiKey.trim().isEmpty) return true;
  final route = currentAiConsentRoute(settings);
  final version = settings.aiConsentVersion(route);
  if (version >= aiConsentMealNoteVersion) return true;
  if (version <= 0) return ensureAiConsent(context, settings);
  final l = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ok = await showAiConsentDialog(context,
      provider: settings.provider,
      serverBackend: settings.serverBackend,
      serverBaseUrl: settings.serverBaseUrl,
      title: l.aiConsentUpdateTitle,
      appendix: _updateAppendix(l, settings, version),
      leadWithAppendix: true,
      dialogKey: const Key('mealNoteConsentDialog'),
      cancelKey: const Key('mealNoteConsentNotNow'),
      allowKey: const Key('mealNoteConsentAllow'));
  if (ok) {
    await settings.setAiConsent(route, granted: true);
    return true;
  }
  messenger?.showSnackBar(SnackBar(content: Text(l.aiConsentDeclined)));
  return false;
}

/// Holds each photo shared into the app until the current recipient is
/// allowed. A photo whose recipient is already allowed (or that nothing
/// could send — no key) passes straight through; otherwise the app shell's
/// dialog ([attach]) asks, and Not now drops the photo. A dropped photo is
/// settled (IntakePhoto.onSettled), so the share intake deletes its copy:
/// a photo answered Not now is never offered again at the next start.
/// Photos keep their order: the stream waits while a question is open.
///
/// Pause-transparent: a plain asyncMap, so while a question is open (and
/// while the pipeline holds a photo) the share intake reads no further
/// copy — one shared original in memory, at most one read ahead (review
/// 171, C2). It used to listen without ever pausing, to time each photo's
/// arrival, and that loaded every original of a 20-photo share at once.
///
/// One Not now per share: a 5-photo share answered Not now used to ask
/// five times. The intake numbers each share as its batch event arrives
/// (IntakePhoto.shareDelivery, [ShareDeliveries]); a Not now covers the
/// share asked about, however slowly its files are read, and every share
/// with a photo to send that arrived while the question was open. Their
/// photos are dropped without a question and never sent, even if the
/// recipient is allowed some other way before their turn (the user's
/// answer for them was no), and the intake deletes their copies not read
/// yet, unread. A share already waiting when the question opened, the
/// start-up batch of copies an earlier run left unread
/// (ShareDeliveries.asksAlone, whenever its sweep finishes) and one that
/// arrives after the answer get their own question.
///
/// The shell's question answers true (Allow), false (Not now) or null:
/// no dialog could be shown (the shell is going away). Null is no answer,
/// like a dialog that failed: nothing is declined, and the photo waits for
/// the next shell to ask: one that attaches, or, once the shell that asked
/// detaches, the latest one still attached.
///
/// Every shell attaches its own question, and the latest one attached
/// asks (GATE-1, 2026-11-22). The gate used to hold one question only: a
/// second shell that closed took it away while the first one still lived,
/// and a shared photo then waited for a question that never came until
/// another shell attached. The app opens one shell at a time since
/// Flutter's own deep linking is off (RCREL-V-1, IOS-DL-1), so this is
/// defence in depth.
///
/// A share's note on its files that gave no photo
/// (IntakePhoto.refusedNote) is no photo: it is never asked about, and a
/// share whose every file was refused asks nothing. It passes in its
/// place, after the share's photos, or goes with the share's Not now.
/// Another share's Not now never covers a share with no photo left to
/// send ([ShareDeliveries.photoCountOf] 0 at the answer), so its line
/// still comes.
class SharedPhotoConsentGate {
  SharedPhotoConsentGate(this._settings);

  final SettingsStore _settings;

  /// Each attached shell's question, the latest attached last ([attach],
  /// [detach]).
  final List<Future<bool?> Function()> _askers = [];

  /// The question a photo is asked through: the latest attached shell's;
  /// null while no shell is attached.
  Future<bool?> Function()? get _ask => _askers.isEmpty ? null : _askers.last;

  /// Completed while a shell is attached: what a photo waits for while
  /// none is.
  Completer<void> _attached = Completer<void>();

  /// Completed by the next [attach], and by a [detach] of the asking shell
  /// that leaves the question to one still attached: what a photo whose
  /// question could not be shown waits for.
  Completer<void> _reattached = Completer<void>();

  /// The share intake's deliveries; null when [gate] was given none (then
  /// a Not now covers the asked photo's delivery as far as photos say).
  ShareDeliveries? _deliveries;

  /// The deliveries a Not now covers.
  final Set<int> _declined = {};

  /// The latest delivery that had arrived when the open question opened.
  int _openedAt = 0;

  /// The latest delivery a photo has come from (without [_deliveries]).
  int _latestSeen = 0;

  /// Photos of each delivery passed on.
  final Map<int, int> _admitted = {};

  /// The photo the open question is about; null when none is open.
  IntakePhoto? _asking;

  /// Whether [declineOpenQuestion] already marked the open question's
  /// answer.
  bool _declineMarked = false;

  /// The app shell's dialog, once it has a navigator; true = allowed (and
  /// recorded). A cold-start share arrives before the first frame and
  /// waits here until then.
  ///
  /// Each shell attaches its own, and the latest one attached asks; a
  /// shell that attaches again is the latest once more, and one [detach]
  /// still takes it away (GATE-1, 2026-11-22).
  void attach(Future<bool?> Function() ask) {
    // ==, not identical: two tear-offs of one method are equal only.
    _askers
      ..remove(ask)
      ..add(ask);
    if (!_attached.isCompleted) _attached.complete();
    _reattach();
  }

  /// The shell going away takes its question back, however often it
  /// attached it; a question that is not attached changes nothing. The
  /// latest shell still attached asks from then on (GATE-1, 2026-11-22).
  /// When the one going away was the latest, the shell now asking counts
  /// as attached just now: a photo whose question the one going away could
  /// not show (null, answered before this or when its open question ends)
  /// is asked again through it, without waiting for an [attach].
  void detach(Future<bool?> Function() ask) {
    // ==, not identical: two tear-offs of one method are equal only.
    final wasAsking = _ask == ask;
    if (!_askers.remove(ask)) return;
    if (_askers.isEmpty) {
      _attached = Completer<void>();
    } else if (wasAsking) {
      _reattach();
    }
  }

  /// A photo whose question could not be shown is asked again, through the
  /// latest shell attached ([_reattached]).
  void _reattach() {
    final waiting = _reattached;
    _reattached = Completer<void>();
    waiting.complete();
  }

  /// The open question was answered Not now: covers the asked photo's
  /// delivery and every one that arrived while the question was open (not
  /// one already waiting when it opened, nor one with no photo left to
  /// send), tells the intake to delete their unread copies, and returns
  /// how many shared photos the answer leaves unsent — those deliveries'
  /// photos not passed on, the asked one included. 1 for a photo with no
  /// delivery, or when no question is open.
  ///
  /// The count can be a little high, never low: a copy not read yet that
  /// turns out unusable (empty, over 25 MB, a failing read) is counted too;
  /// one whose name gives no photo type (an AVIF) is not
  /// (ShareDeliveries.photoCountOf).
  int declineOpenQuestion() {
    final asking = _asking;
    if (asking == null) return 1;
    _declineMarked = true;
    final delivery = asking.shareDelivery;
    if (delivery == null) return 1;
    final deliveries = _deliveries;
    final now = deliveries?.arrivedDelivery ?? _latestSeen;
    final covered = {
      delivery,
      for (var d = math.max(_openedAt, delivery) + 1; d <= now; d++)
        // The start-up batch of copies left unread is no share being made
        // now: it gets its own question, whenever its sweep finished. Nor
        // is a share with no photo left to send (its files all refused:
        // on Android before any copy or by their names, on iOS as each was
        // read): nothing of it is ever asked about, and the line on its
        // refused files is all it gets, which this answer would drop.
        if (!(deliveries?.asksAlone(d) ?? false) &&
            (deliveries?.photoCountOf(d) ?? 1) > 0)
          d,
    }..removeAll(_declined);
    _declined.addAll(covered);
    if (covered.isNotEmpty) deliveries?.declineDeliveries(covered);
    if (deliveries == null) return 1;
    var notSent = 0;
    for (final d in covered) {
      notSent += math.max(0, deliveries.photoCountOf(d) - (_admitted[d] ?? 0));
    }
    return math.max(1, notSent);
  }

  /// [photos] through the consent question, pausing them while it is open;
  /// [deliveries] is the share intake that numbered them.
  Stream<IntakePhoto> gate(Stream<IntakePhoto> photos,
      {ShareDeliveries? deliveries}) {
    _deliveries = deliveries;
    return photos
        .asyncMap(_admit)
        .where((p) => p != null)
        .cast<IntakePhoto>();
  }

  Future<IntakePhoto?> _admit(IntakePhoto photo) async {
    final delivery = photo.shareDelivery;
    if (delivery != null && delivery > _latestSeen) _latestSeen = delivery;
    // A share's files that gave no photo (IntakePhoto.refusedNote): nothing
    // to ask about or send, so no question, even when none of the share's
    // files gave a photo. Passed on to be said, after the share's photos,
    // unless the share was answered Not now: that line says nothing was
    // sent.
    if (photo.refused != null) {
      return delivery != null && _declined.contains(delivery) ? null : photo;
    }
    IntakePhoto passed() {
      if (delivery != null) _admitted[delivery] = (_admitted[delivery] ?? 0) + 1;
      return photo;
    }

    // Dropped unsent: settled, so its share copy goes.
    IntakePhoto? dropped() {
      photo.onSettled?.call();
      return null;
    }

    while (true) {
      // Its share was answered Not now: dropped unasked, never sent.
      if (delivery != null && _declined.contains(delivery)) return dropped();
      // Re-read after every wait: the user may have allowed it meanwhile.
      if (!aiConsentNeeded(_settings)) return passed();
      final ask = _ask;
      if (ask == null) {
        await _attached.future;
        continue;
      }
      final nextShell = _reattached.future;
      _asking = photo;
      _openedAt = _deliveries?.arrivedDelivery ?? _latestSeen;
      _declineMarked = false;
      final bool? answer;
      try {
        answer = await ask();
      } catch (_) {
        _asking = null;
        return dropped(); // a failed dialog is not consent
      }
      if (answer == true) {
        _asking = null;
        return passed();
      }
      if (answer == false) {
        // Not now: the rest of the share is covered too. Marked here when
        // the dialog's own line did not.
        if (!_declineMarked) declineOpenQuestion();
        _asking = null;
        return dropped();
      }
      // No dialog could be shown: no answer. Nothing is declined; the
      // photo waits for the next shell's question: until a shell attaches,
      // or the shell that asked detaches while another is still attached
      // (GATE-1). Either one while the question was open counts too, and
      // then it is asked again at once.
      _asking = null;
      await nextShell;
    }
  }
}
