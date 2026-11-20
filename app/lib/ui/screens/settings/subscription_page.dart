/// The "Your own server" connection type (user-designed IA, 2026-08-02 v2:
/// each connection type gets its OWN page; called Subscription until the
/// owner's R-F5 decision, 2026-10-29). Three flat-rate plans as a
/// checkmark list; picking one selects the server route AND that plan.
/// The server config (address, upload key, Claude connect) appears once
/// a plan is active.
///
/// The address must be https:// while the https switch is on
/// (core/server_transport.dart, owner decision 2026-11-13): an address
/// that is not is never saved ("Needs https://" under the field), and one
/// saved before (an older app, the switch off) shows the same line and a
/// footer saying nothing is sent to it. With the switch off, an http://
/// address is saved and the footer says it travels unencrypted.
///
/// The upload key is sent only to the host it was saved for
/// (services/server_http_client.dart). With the address changed to another
/// host and the key left as it was, the key field is empty and says which
/// host the key was saved for, and one tap makes it the new address's key
/// (the same server at a new IP, domain or port). What the user types or
/// pastes into the empty field is the new address's key, alone: the
/// previous server's key is never in the field to be edited in place.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../../core/server_transport.dart'
    show
        isCleartextServerUrl,
        requireHttpsServer,
        serverAddressRefused,
        serverKeyHostOf;
import '../../ai_consent.dart';
import '../../services.dart' show SettingsStore, serverKeyForOtherAddress;
import '../../l10n.dart';
import '../../provider_names.dart' show serverPlanName;
import '../../widgets/grouped.dart';
import '../../widgets/small_spinner.dart';
import '../../theme/app_dialog.dart';
import '../../theme/tokens.dart';
import 'settings_kit.dart';
import 'provider_page.dart' show kPlanChoices, noteLabel;

class SubscriptionProviderPage extends StatefulWidget {
  const SubscriptionProviderPage({
    super.key,
    required this.settings,
    this.startClaudeAuth,
    this.completeClaudeAuth,
    this.serverLoginState,
    this.openUrl,
  });

  final SettingsStore settings;
  final Future<({String? url, String? error})> Function()? startClaudeAuth;
  final Future<String?> Function(String code)? completeClaudeAuth;
  final Future<String?> Function()? serverLoginState;
  final Future<bool> Function(Uri url)? openUrl;

  @override
  State<SubscriptionProviderPage> createState() =>
      _SubscriptionProviderPageState();
}

class _SubscriptionProviderPageState
    extends State<SubscriptionProviderPage> {
  late final TextEditingController _keyController;
  late final TextEditingController _serverUrlController;
  final FocusNode _serverUrlFocus = FocusNode();

  /// The address field holds an edit that is not saved yet.
  bool _serverUrlEdited = false;

  /// The last attempt to save the field's edit was refused: it does not
  /// start with https:// (core/server_transport.dart). Cleared by the next
  /// keystroke.
  bool _refusedEdit = false;

  /// The key field holds an edit of the user's (typed, pasted, deleted)
  /// since the page last filled it ([_fillKeyField]). Done and a tap
  /// outside save the field only then: the field left empty because the
  /// saved key is another host's ([_keyFieldText]), saved as it is, would
  /// delete that key, its host and the row that makes it this address's.
  bool _keyEdited = false;
  bool _authBusy = false;

  /// 'token' | 'none' | null (unknown / not applicable). Fetched on open
  /// and after a Connect round-trip, so the row never lies about state it
  /// just changed.
  String? _loginState;
  bool _loginChecking = false;

  bool get _planActive => widget.settings.provider == 'server';

  /// What the key field shows: the saved upload key while it is this
  /// address's, and nothing while it was saved for another host. In the
  /// field, the obscured key was edited in place: a paste at the cursor
  /// (iOS's Paste in the focused field, a keyboard's clipboard chip,
  /// Android's long-press past the dots) or one backspace made a new key
  /// out of the previous server's, bound to the address above and sent
  /// there (review of PR 74). The line under the field names the host it
  /// was saved for; the row under that makes it this address's.
  String get _keyFieldText =>
      _planActive && !serverKeyForOtherAddress(widget.settings)
          ? widget.settings.apiKey
          : '';

  /// Fills the key field from the store ([_keyFieldText]), the caret at
  /// the end; no edit of the user's until the next keystroke.
  void _fillKeyField() {
    final text = _keyFieldText;
    _keyController.value = TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: text.length));
    _keyEdited = false;
  }

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: _keyFieldText);
    _serverUrlController =
        TextEditingController(text: widget.settings.serverBaseUrl);
    _serverUrlFocus.addListener(() {
      if (!_serverUrlFocus.hasFocus && _serverUrlEdited) _saveServerUrl();
    });
    _refreshLoginState();
  }

  /// Saves what the address field holds as the server's address — only
  /// when the edit is over: Done, focus leaving the field (for the upload
  /// key under it, or a sheet or dialog on top), leaving the page, or an
  /// action about to use the address ([_saveServerUrlEdit]). Never per
  /// keystroke, nor when a pointer goes down outside while the field keeps
  /// its focus (a scroll, a tap beside it): the analyzer, the Garmin fetch
  /// and the lookups read the saved address at each request, so an
  /// automatic photo and the upload key went to whatever host a half-typed
  /// address named (http://10.0.0.5 on the way to .55, review 171).
  ///
  /// An address the app would send nothing to is not saved: the edit
  /// stays in the field under "Needs https://", and the saved address is
  /// left as it was. False = refused.
  ///
  /// An address on another host than the one the upload key was saved for
  /// empties the key field, and the key's own host puts the key back
  /// ([_keyFieldText]): this save runs as the key field is tapped, so the
  /// field is emptied before anything can be typed or pasted into it.
  bool _saveServerUrl() {
    final url = _serverUrlController.text.trim();
    if (serverAddressRefused(url)) {
      if (mounted) setState(() => _refusedEdit = true);
      return false;
    }
    _serverUrlEdited = false;
    final settings = widget.settings;
    final keyWasForOther = serverKeyForOtherAddress(settings);
    settings.update(serverBaseUrl: url);
    // Read straight after the call, not after it completes: the store
    // takes the address (and binds a key saved before any address to it)
    // before its first await (AppSettings.setServerBaseUrl).
    if (mounted && serverKeyForOtherAddress(settings) != keyWasForOther) {
      _fillKeyField();
    }
    if (mounted) setState(() => _refusedEdit = false);
    return true;
  }

  /// An action about to use the address ([_connectClaude], [_selectPlan])
  /// saves an edit still being typed first. Activating its row leaves the
  /// field its focus, whether by a finger (a pointer going down outside
  /// saves nothing) or by a screen reader (no pointer at all), so nothing
  /// else has saved it: with a screen reader, Connect Claude asked for the
  /// address the field showed (the U3 bug run 7 fixed) or went to the old
  /// server, and a plan's question named the old host (review 171).
  ///
  /// False when the edit was refused ([_saveServerUrl]): the action stops
  /// rather than go on with the old address while the field shows another.
  bool _saveServerUrlEdit() {
    if (!_serverUrlEdited || _saveServerUrl()) return true;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.errServerNeedsHttps)));
    }
    return false;
  }

  Future<void> _refreshLoginState() async {
    final probe = widget.serverLoginState;
    if (probe == null ||
        !_planActive ||
        widget.settings.serverBackend != 'claude') {
      return;
    }
    setState(() => _loginChecking = true);
    String? state;
    try {
      state = await probe();
    } catch (_) {
      state = null;
    }
    if (!mounted) return;
    setState(() {
      _loginState = state;
      _loginChecking = false;
    });
  }

  @override
  void dispose() {
    // Leaving the page with an edit not saved yet saves it, once this
    // frame is done: a store notifying from here would rebuild its
    // listeners while the tree is locked.
    if (_serverUrlEdited) {
      final settings = widget.settings;
      final url = _serverUrlController.text.trim();
      // Never an address the app would send nothing to.
      if (!serverAddressRefused(url)) {
        scheduleMicrotask(() => settings.update(serverBaseUrl: url));
      }
    }
    _serverUrlFocus.dispose();
    _keyController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  /// Picking a PLAN means: provider = the server, backend = that plan.
  Future<void> _selectPlan(String backend) async {
    final already = _planActive &&
        widget.settings.serverBackend == backend;
    if (already) return;
    HapticFeedback.selectionClick();
    // The question names the host the photos would go to.
    if (!_saveServerUrlEdit()) return;
    // The plan is the AI company behind the server: a new recipient while
    // Watch Camera Roll is on asks now (App Store 5.1.2(i)); Not now keeps
    // the previous plan or provider.
    if (!await confirmAiRecipientChange(context, widget.settings,
            provider: 'server', serverBackend: backend) ||
        !mounted) {
      return;
    }
    await widget.settings.update(serverBackend: backend);
    if (widget.settings.provider != 'server') {
      await widget.settings.update(provider: 'server');
    }
    if (!mounted) return;
    setState(_fillKeyField);
  }

  /// The phone half of the server's Claude OAuth re-connect: fetch the
  /// OFFICIAL Anthropic authorize URL from our server, open it in the
  /// system browser (RFC 8252: never an in-app login form), then collect
  /// the pasted code and hand it back. No credential touches this device.
  ///
  /// It sends the server the upload key, then the authorization code the
  /// user pastes (the server hands it to `claude setup-token`), so it asks
  /// first, as every send does: before the first Allow, and after Stop
  /// Sharing, nothing goes to the server (ensureAiConsent; Not now says
  /// "Nothing was sent.").
  Future<void> _connectClaude() async {
    final start = widget.startClaudeAuth;
    final complete = widget.completeClaudeAuth;
    if (start == null || complete == null) return;
    if (!_saveServerUrlEdit()) return;
    // Nothing to sign in yet: the request needs the server's address and
    // upload key, and without them it only came back with an English
    // 'Set the server address and key first.' (U3). Said here instead,
    // without calling anything.
    if (widget.settings.serverBaseUrl.trim().isEmpty ||
        widget.settings.apiKey.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.connectNeedsServer)));
      return;
    }
    // A saved address nothing is sent to: said here, nothing called.
    if (serverAddressRefused(widget.settings.serverBaseUrl)) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.errServerNeedsHttps)));
      return;
    }
    // A key saved for another server is sent nowhere else: said here.
    if (serverKeyForOtherAddress(widget.settings)) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.errServerKeyOtherHost)));
      return;
    }
    // Busy from the question on, so a second tap stacks no second dialog.
    setState(() => _authBusy = true);
    try {
      // After the address checks: the question names the host Connect
      // would reach, and a missing or refused address asks nothing.
      if (!await ensureAiConsent(context, widget.settings) || !mounted) {
        return;
      }
      final started = await start();
      if (!mounted) return;
      if (started.error != null || started.url == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(started.error ?? context.l10n.connectStartFailed)));
        return;
      }
      final open = widget.openUrl ??
          (uri) => launcher.launchUrl(uri,
              mode: launcher.LaunchMode.externalApplication);
      final opened = await open(Uri.parse(started.url!));
      if (!mounted) return;
      if (!opened) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context.l10n.connectBrowserFailed)));
        return;
      }
      final code = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final ctrl = TextEditingController();
          return appAlertDialog(
            title: Text(ctx.l10n.connectDialogTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(ctx.l10n.connectDialogBody),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('claudeAuthCodeField'),
                  controller: ctrl,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: ctx.l10n.connectCodeLabel,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: Text(ctx.l10n.cancel)),
              FilledButton(
                key: const Key('claudeAuthSubmit'),
                onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
                child: Text(ctx.l10n.connect),
              ),
            ],
          );
        },
      );
      if (!mounted) return;
      if (code == null || code.isEmpty) return; // user cancelled
      final error = await complete(code);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              error ?? context.l10n.connectDone)));
      unawaited(_refreshLoginState());
    } finally {
      if (mounted) setState(() => _authBusy = false);
    }
  }

  String _modelLabel(BuildContext context, String v) => switch (v) {
        'fable' => 'Fable',
        'opus' => 'Opus',
        'sonnet' => 'Sonnet',
        'haiku' => 'Haiku',
        _ => context.l10n.planChoiceDefault,
      };

  /// The ROW shows the bare level, like [_modelLabel] shows 'Opus'; the
  /// picker sheet keeps the explanatory 'High — most thorough' labels.
  /// The long label as the row value ellipsised in English beside a
  /// badge and chevron — 'Thinking e…  High — most thoro…' (loop find
  /// 2026-10-07, round 3).
  String _effortLabel(BuildContext context, String v) => switch (v) {
        'low' => context.l10n.planEffortLowShort,
        'medium' => context.l10n.planEffortMedium,
        'high' => context.l10n.planEffortHighShort,
        _ => context.l10n.planChoiceDefault,
      };

  /// One picker for both rows: the sheet lists (value, label) options
  /// with a checkmark on the current one; '' = server default.
  Future<void> _pickPlanValue({
    required String key,
    required String title,
    required String current,
    required List<(String, String)> options,
    required Future<void> Function(String) apply,
  }) async {
    final picked = await showChoiceSheet(
      context,
      title: title,
      keyPrefix: 'plan-$key',
      keyOf: (value) => value.isEmpty ? 'default' : value,
      current: current,
      options: options,
    );
    if (picked == null || !mounted) return;
    await apply(picked);
    if (mounted) setState(() {});
  }

  /// The server section's footer: what the server is, then how the saved
  /// address travels when it is not https://.
  String _serverFooter(AppLocalizations l) {
    final saved = widget.settings.serverBaseUrl;
    final note = serverAddressRefused(saved)
        ? l.serverNeedsHttpsFooter
        : !requireHttpsServer && isCleartextServerUrl(saved)
            ? l.serverHttpFooter
            : null;
    return note == null ? l.serverFooter : '${l.serverFooter}\n\n$note';
  }

  /// Saves the user's edit of the key field (per keystroke, as before; on
  /// Done and a tap outside only after an edit, [_keyEdited]). A new key
  /// is bound to the address above (AppSettings.setServerApiKey); the
  /// page rebuilds so the line under the field follows. An unchanged one
  /// keeps the host it was saved for, except here: the saved key itself,
  /// pasted into the field left empty because it was saved for another
  /// host, is the user saying it is this address's key (the same server at
  /// a new address), as the row under the field does.
  Future<void> _saveKey(String value) async {
    final settings = widget.settings;
    final key = value.trim();
    final address = settings.serverBaseUrl;
    await settings.update(apiKey: key);
    if (key.isNotEmpty &&
        key == settings.apiKey.trim() &&
        settings.serverBaseUrl == address &&
        serverKeyForOtherAddress(settings)) {
      await settings.bindServerKeyToAddress();
    }
    if (mounted) setState(() {});
  }

  void _keyChanged(String value) {
    _keyEdited = true;
    unawaited(_saveKey(value));
  }

  /// Done and a tap outside: the field again, if the user edited it.
  void _keyEditEnded(String value) {
    if (_keyEdited) unawaited(_saveKey(value));
  }

  /// The host the saved upload key was saved for, when that is not the
  /// saved address's: shown under the key field, with the row that makes
  /// the key this address's. Null otherwise.
  String? get _keySavedForOtherHost {
    final s = widget.settings;
    return serverKeyForOtherAddress(s) ? s.serverKeyHost : null;
  }

  /// "Needs https://" under the field: a refused save, or the saved
  /// address (shown while the field holds it unedited).
  bool get _showNeedsHttps =>
      _refusedEdit ||
      (!_serverUrlEdited &&
          serverAddressRefused(widget.settings.serverBaseUrl));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = widget.settings;
    final keySavedFor = _keySavedForOtherHost;
    final addressHost = serverKeyHostOf(settings.serverBaseUrl);
    return GroupedPage(
      title: context.l10n.subPageTitle,
      children: [
        GroupedSection(
          header: context.l10n.planHeader,
          footer: context.l10n.planFooter,
          separatorInset: AppSpace.separatorInset,
          children: [
            for (final (backend, _, note) in kPlanChoices)
              GroupedRow(
                key: Key('planChoice-$backend'),
                title: serverPlanName(context.l10n, backend),
                value: noteLabel(context.l10n, note),
                selected: _planActive && settings.serverBackend == backend,
                showChevron: false,
                trailing: _planActive && settings.serverBackend == backend
                    ? Icon(Icons.check_rounded,
                        size: 20, color: context.colors.accent)
                    : const SizedBox(width: 20),
                onTap: () => _selectPlan(backend),
              ),
          ],
        ),
        if (_planActive) ...[
          GroupedSection(
            header: context.l10n.serverHeader,
            footer: _serverFooter(context.l10n),
            separatorInset: AppSpace.separatorInset,
            children: [
              cellField(TextField(
                key: const Key('serverUrlField'),
                controller: _serverUrlController,
                focusNode: _serverUrlFocus,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: cellFieldDecoration(
                  context,
                  labelText: context.l10n.serverAddressLabel,
                  hintText: 'https://your.server',
                ).copyWith(
                    errorText: _showNeedsHttps
                        ? context.l10n.serverNeedsHttpsField
                        : null,
                    // The cell is the frame: the error line only, never
                    // the theme's outline (see cellFieldDecoration).
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none),
                // Saved when the edit is over ([_saveServerUrl]), not as
                // typed.
                onChanged: (_) {
                  final wasShown = _showNeedsHttps;
                  _serverUrlEdited = true;
                  _refusedEdit = false;
                  if (wasShown) setState(() {});
                },
                onSubmitted: (_) => _saveServerUrl(),
                // A pointer going down outside leaves the edit going, as
                // before (the field keeps its focus, the keyboard stays
                // up), and saves nothing: a scroll or a tap beside the
                // field is not the end of the edit (review 171).
                onTapOutside: (_) {},
              )),
              cellField(TextField(
                key: const Key('serverUploadKeyField'),
                controller: _keyController,
                obscureText: true,
                autocorrect: false,
                onChanged: _keyChanged,
                onSubmitted: _keyEditEnded,
                onTapOutside: (_) => _keyEditEnded(_keyController.text),
                decoration: cellFieldDecoration(
                  context,
                  labelText: context.l10n.serverUploadKeyLabel,
                ).copyWith(
                    // Saved for another server: nothing is sent with it to
                    // the address above until it is that server's.
                    errorText: keySavedFor == null
                        ? null
                        : context.l10n.serverKeyOtherHostField(keySavedFor),
                    errorMaxLines: 3,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none),
              )),
              if (keySavedFor != null && addressHost != null)
                GroupedRow(
                  key: const Key('serverKeyUseHereRow'),
                  icon: Icons.key_outlined,
                  iconColor: scheme.primary,
                  title: context.l10n.serverKeyUseHere(addressHost),
                  showChevron: false,
                  onTap: () async {
                    await settings.bindServerKeyToAddress();
                    // The key is this address's now: back in the field.
                    if (mounted) setState(_fillKeyField);
                  },
                ),
            ],
          ),
          if (settings.serverBackend == 'claude')
            GroupedSection(
              header: context.l10n.planTuningHeader,
              footer: context.l10n.planTuningFooter,
              children: [
                GroupedRow(
                  key: const Key('planModelRow'),
                  icon: Icons.auto_awesome_outlined,
                  iconColor: scheme.primary,
                  title: context.l10n.planModelRow,
                  value: _modelLabel(context, settings.serverModel),
                  onTap: () => _pickPlanValue(
                    key: 'model',
                    title: context.l10n.planModelRow,
                    current: settings.serverModel,
                    options: [
                      ('', context.l10n.planChoiceDefault),
                      ('fable', context.l10n.planModelFable),
                      ('opus', context.l10n.planModelOpus),
                      ('sonnet', context.l10n.planModelSonnet),
                      ('haiku', context.l10n.planModelHaiku),
                    ],
                    apply: (v) => settings.update(serverModel: v),
                  ),
                ),
                GroupedRow(
                  key: const Key('planEffortRow'),
                  icon: Icons.psychology_outlined,
                  iconColor: scheme.secondary,
                  title: context.l10n.planEffortRow,
                  value: _effortLabel(context, settings.serverEffort),
                  onTap: () => _pickPlanValue(
                    key: 'effort',
                    title: context.l10n.planEffortRow,
                    current: settings.serverEffort,
                    options: [
                      ('', context.l10n.planChoiceDefault),
                      ('low', context.l10n.planEffortLow),
                      ('medium', context.l10n.planEffortMedium),
                      ('high', context.l10n.planEffortHigh),
                    ],
                    apply: (v) => settings.update(serverEffort: v),
                  ),
                ),
              ],
            ),
          if (settings.serverBackend == 'claude' &&
              (_loginChecking || _loginState != null))
            GroupedSection(
              footer: context.l10n.serverLoginFooter,
              children: [
                GroupedRow(
                  key: const Key('serverLoginRow'),
                  icon: _loginState == 'token'
                      ? Icons.verified_user_outlined
                      : Icons.person_off_outlined,
                  iconColor: _loginState == 'token'
                      ? scheme.primary
                      : scheme.error,
                  title: context.l10n.serverLoginRow,
                  value: _loginChecking
                      ? context.l10n.serverLoginChecking
                      : switch (_loginState) {
                          'token' => context.l10n.serverLoginOk,
                          'none' => context.l10n.serverLoginMissing,
                          _ => context.l10n.serverLoginUnknown,
                        },
                ),
              ],
            ),
          if (settings.serverBackend == 'claude' &&
              widget.startClaudeAuth != null)
            GroupedSection(
              footer: context.l10n.connectClaudeFooter,
              children: [
                GroupedRow(
                  key: const Key('connectClaudeButton'),
                  icon: Icons.link,
                  iconColor: scheme.tertiary,
                  title: context.l10n.connectClaude,
                  trailing: _authBusy
                      ? const SmallSpinner()
                      : null,
                  onTap: _authBusy ? null : _connectClaude,
                ),
              ],
            ),
        ] else
          GroupedSection(
            footer: context.l10n.subInactiveFooter,
            children: const [],
          ),
      ],
    );
  }
}
