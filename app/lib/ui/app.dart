/// App shell: Material 3 light+dark, Today / History / Settings navigation,
/// FAB → add flow. Also the startup-failure screen used by main.dart.
library;

import 'dart:async' show StreamSubscription, scheduleMicrotask, unawaited;
import 'dart:io' show File, Platform;

import '../core/ai_consent.dart' show aiConsentRoute, aiRoutesInMainlandChina;
import '../core/app_channel.dart' show photoLibraryInBuild;
import '../core/contracts.dart' show Meal, noteCorrectorOf;
import '../core/setup_link.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, SystemUiOverlayStyle;

import '../services/backup/backup_coordinator.dart';
import '../services/backup/save_file_channel.dart' show SaveFileStatus;
import '../services/photo/background_time.dart' show appEngineInForeground;
import 'ai_consent.dart'
    show
        aiConsentCompanyName,
        aiConsentUpdateNeeded,
        askAiConsentUpdate,
        askSharedPhotoConsent,
        ensureAiConsent;
import 'background_glue.dart' show foregroundCatchUp;
import 'backup_sheets.dart';
import 'format.dart' show PhoneClockScope, isoDate;
import 'meal_reveal.dart';
import 'screens/add_flow.dart';
import 'screens/body_screen.dart';
import 'l10n.dart';
import 'theme/app_dialog.dart' show appAlertDialog;
import 'theme/app_theme.dart';
import 'screens/history_screen.dart';
import 'screens/settings/data_section.dart' show saveStatusLine;
import 'screens/settings/provider_page.dart';
import 'screens/settings_screen.dart';
import 'screens/today_screen.dart';
import 'refresh_signal.dart';
import 'services.dart';
import 'widgets/grouped.dart' show ContentWidthCap;
import 'widgets/nav_bar_band.dart';
import 'widgets/nav_bar_dimming.dart';
import 'widgets/restaurant_consent_sheet.dart';
import 'widgets/route_stack.dart';
import 'widgets/shared_photos_back_guard.dart';

class _AppleScrollBehavior extends MaterialScrollBehavior {
  const _AppleScrollBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}

/// How lists scroll on [platform]: iOS bounces with no overscroll
/// indicator, as it always did. Android scrolls as Android does (owner
/// decision 6, 2026-11-20): Material's own behaviour, which clamps at the
/// ends and stretches the content on an overscroll (Android 12 and later).
@visibleForTesting
ScrollBehavior appScrollBehavior(TargetPlatform platform) =>
    platform == TargetPlatform.android
        ? const MaterialScrollBehavior()
        : const _AppleScrollBehavior();

/// MainActivity.SYSTEM_BARS_CHANNEL.
const String systemBarsChannelName = 'dev.calorietracker/systembars';

/// Hands MainActivity the navigation bar's colour, which it sets on Android
/// 15 and later, where Flutter's engine no longer does
/// (MainActivity.colorNavigationBar); below that it changes nothing.
/// Never throws: without the channel (iPhone, tests) nothing happens.
@visibleForTesting
Future<void> sendNavigationBarColor(Color color,
    [MethodChannel channel = const MethodChannel(systemBarsChannelName)]) async {
  try {
    await channel.invokeMethod<Object?>(
        'navigationBarColor', {'color': color.toARGB32()});
  } catch (_) {}
}

/// Android's navigation bar styled for the theme the app SHOWS (Android
/// push, 2026-11-13). MainActivity handles uiMode changes itself
/// (AndroidManifest configChanges), so a light/dark switch while the app
/// runs kept the launch theme's bar: with 3-button navigation, a light bar
/// under the dark app and dark buttons on a dark bar after switching back
/// (UX run screenshots 57-59). Only the navigation-bar fields are set; the
/// status-bar ones stay null, so the app bars keep them. The bar takes the
/// tab bar's own colour (chrome), with the buttons in its contrast. Below
/// Android 15 that colour is the bar's own, opaque: the app does not draw
/// under the bar there, so a transparent one showed the window colour fixed
/// at launch under buttons that followed the new theme (review 2026-11-13),
/// and the contrast setting changes nothing on an opaque bar.
///
/// Android 15 and later draw the app edge to edge and Flutter leaves the
/// colour alone, so the colour also goes to MainActivity, which sets it on
/// the window (sendNavigationBarColor, MainActivity.colorNavigationBar):
/// - Until the app set one, Android took the light launch window for a
///   light bar and forced dark buttons, whatever the app asked for, and
///   never let go while the app ran (it handles uiMode itself): with
///   3-button navigation, a switch to dark left dark buttons on the dark
///   bar on Android 16 (A36-1). With the colour set the buttons follow
///   [SystemUiOverlayStyle.systemNavigationBarIconBrightness].
/// - With the contrast scrim on, Android draws that colour at 80% behind
///   the 3-button bar only (the gesture bar suppresses the scrim, so it
///   stays transparent, edge to edge), and the tab bar's own colour runs
///   on under the buttons.
/// - At 80%, a field that lay under the buttons at rest on a screen with
///   no tab bar (Edit meal at its first scroll) still showed through
///   (A36-2, QA KAA-1). So with 3-button navigation the app paints the
///   bar's height in the same colour itself, above its navigator and
///   under Android's scrim (NavBarBand): nothing shows under the buttons.
///   The gesture bar gets no band.
/// - That scrim is a view Android draws above the app, and the band is
///   above the app's routes, so no Flutter barrier dims either: while a
///   dialog or the analyzing overlay dims the app ([dimming],
///   NavBarDimming), the colour sent and painted is the tab bar's under
///   the barrier's scrim, and the tab bar's own again once it is gone, so
///   no bright strip stays under the buttons (NAV-2). Bottom sheets
///   change nothing: a sheet has only its bottom inset under the bar.
/// Sent after the frame, behind Flutter's own style, so the buttons'
/// light/dark is set before Android stops forcing it. iPhone has no such
/// bar: nothing is set there.
class _SystemNavBarStyle extends StatefulWidget {
  const _SystemNavBarStyle({required this.child, this.dimming});
  final Widget child;

  /// The app shell's barriers (its navigator's dialogs, the analyzing
  /// overlay), handed to the routes below through NavBarDimmingScope.
  /// Null on the startup-error screen, which has neither.
  final NavBarDimming? dimming;

  @override
  State<_SystemNavBarStyle> createState() => _SystemNavBarStyleState();
}

class _SystemNavBarStyleState extends State<_SystemNavBarStyle> {
  /// The colour last handed to MainActivity: each change is sent once.
  Color? _sent;

  /// The last build's tab-bar and barrier colours (null until an Android
  /// build): a barrier that comes or goes changes neither, and is sent
  /// from them without a rebuild.
  Color? _chrome;
  Color? _scrim;

  /// The colour wanted now, which the band under a 3-button bar paints
  /// (NavBarBand): a change repaints it, and never rebuilds.
  final ValueNotifier<Color?> _band = ValueNotifier<Color?>(null);

  @override
  void initState() {
    super.initState();
    widget.dimming?.addListener(_sendWanted);
  }

  @override
  void didUpdateWidget(covariant _SystemNavBarStyle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dimming != widget.dimming) {
      oldWidget.dimming?.removeListener(_sendWanted);
      widget.dimming?.addListener(_sendWanted);
    }
  }

  @override
  void dispose() {
    widget.dimming?.removeListener(_sendWanted);
    _band.dispose();
    super.dispose();
  }

  /// Hands MainActivity the colour wanted now, once per change, and the
  /// band the same: the tab bar's, or under a barrier the tab bar's dimmed
  /// by the barrier's scrim. Never a rebuild: a barrier may come while a
  /// frame is being built.
  void _sendWanted() {
    final chrome = _chrome;
    final scrim = _scrim;
    if (chrome == null || scrim == null) return;
    final wanted = widget.dimming?.dimmed ?? false
        ? Color.alphaBlend(scrim, chrome)
        : chrome;
    _band.value = wanted;
    if (wanted == _sent) return;
    _sent = wanted;
    // Flutter sends the style below in a microtask queued while this
    // frame is composited; this one is queued after it.
    WidgetsBinding.instance.addPostFrameCallback((_) => scheduleMicrotask(
        () => unawaited(sendNavigationBarColor(wanted))));
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.platform != TargetPlatform.android) return widget.child;
    final dark = theme.brightness == Brightness.dark;
    final colors = context.colors;
    final chrome = colors.chrome;
    _chrome = chrome;
    _scrim = colors.scrim;
    _sendWanted();
    final dimming = widget.dimming;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: chrome,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
        systemNavigationBarContrastEnforced: true,
      ),
      // The band lies over every route, the navigator's dialogs and
      // sheets included, and paints nothing without a 3-button bar.
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.topLeft,
        children: [
          dimming == null
              ? widget.child
              : NavBarDimmingScope(dimming: dimming, child: widget.child),
          Positioned(
              left: 0, right: 0, bottom: 0, child: NavBarBand(color: _band)),
        ],
      ),
    );
  }
}

/// The app's name in [locale]: 筷拍 in Chinese, Chopstats otherwise, as
/// the launcher shows it (Android res/values-zh/strings.xml, iPhone
/// zh-Hans InfoPlist.strings). It is the task's title, which Android's
/// Recents and app switcher show beside the launcher label: fixed English,
/// a Chinese phone read "筷拍 Chopstats" there (RECENTS-1, 2026-11-24).
String appTitleFor(Locale locale) =>
    locale.languageCode == 'zh' ? '筷拍' : 'Chopstats';

class CalorieTrackerApp extends StatefulWidget {
  final UiServices services;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;
  const CalorieTrackerApp({super.key, required this.services, this.messengerKey});

  @override
  State<CalorieTrackerApp> createState() => _CalorieTrackerAppState();
}

class _CalorieTrackerAppState extends State<CalorieTrackerApp> {
  /// Android 15 and later: the dialogs open on the app's navigator and the
  /// analyzing overlays up, which dim the 3-button bar's scrim with them
  /// (_SystemNavBarStyle, NAV-2). One per app, kept across rebuilds: the
  /// navigator keeps its observer, and with it the dialogs it has seen.
  final NavBarDimming _dimming = NavBarDimming();
  late final NavBarDimmingObserver _dialogs = NavBarDimmingObserver(_dimming);

  /// Android: every route on the app's navigator, for the shell to go to
  /// a meal the user asked to see (meal_reveal.dart): it closes the
  /// screens over its tabs that Back would close without asking, and
  /// waits while one holds unsaved changes or a question is open. Kept
  /// across rebuilds with the navigator, like [_dialogs]. Not observed on
  /// iPhone, which has no View or card tap to go to a meal.
  final RouteStack _routes = RouteStack();

  @override
  void dispose() {
    _dimming.dispose();
    _routes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final messengerKey = widget.messengerKey;
    // Design (run 7, theme/app_theme.dart): Apple's system neutrals for
    // every surface, the terracotta accent (#A64B2A light / #F2A07B dark),
    // iOS type sizes on the system fonts, depth from the page/cell tone
    // inversion instead of elevation. The restraint is deliberate: the
    // researched redesign backlashes (MFP 3.2→1.5 stars, Yazio "app for
    // children") all came from decoration and added friction, never from
    // calm. Macro identity hues are unaffected (contract).

    // ListenableBuilder: the language row writes settings, and the whole
    // app re-locales in place — no restart.
    final reveals = services.mealReveals != null;
    final shell =
        HomeShell(services: services, routes: reveals ? _routes : null);
    Widget appFor(Locale? locale) {
      // Chinese text takes no Latin tracking (every letterSpacing 0).
      final cjk = (locale ?? WidgetsBinding.instance.platformDispatcher.locale)
              .languageCode ==
          'zh';
      return MaterialApp(
          // In the app's language, and again when it changes (appTitleFor).
          onGenerateTitle: (context) =>
              appTitleFor(Localizations.localeOf(context)),
          scaffoldMessengerKey: messengerKey,
          // iOS: bounce, no glow indicator. Android: stretch overscroll.
          scrollBehavior: appScrollBehavior(defaultTargetPlatform),
          theme: AppTheme.build(Brightness.light, cjk: cjk),
          darkTheme: AppTheme.build(Brightness.dark, cjk: cjk),
          // iOS Increase Contrast: darker accent, labels and separators.
          highContrastTheme:
              AppTheme.build(Brightness.light, cjk: cjk, highContrast: true),
          highContrastDarkTheme:
              AppTheme.build(Brightness.dark, cjk: cjk, highContrast: true),
          themeMode: ThemeMode.system,
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          navigatorObservers: [_dialogs, if (reveals) _routes],
          // Times follow the phone's own 12/24-hour clock, which Android 13
          // and later stop reporting once the app has a language of its
          // own (format.dart PhoneClockScope).
          builder: (context, child) {
            final styled = PhoneClockScope(
                child: _SystemNavBarStyle(
                    dimming: _dimming,
                    child: child ?? const SizedBox.shrink()));
            if (!reveals) return styled;
            // A route on top held or let go of its pop (a screen took or
            // dropped unsaved changes): the shell asks again whether it
            // can go to a meal at once (RouteStack). Passed on: WidgetsApp
            // tells Android from it whether Flutter handles Back.
            return NotificationListener<NavigationNotification>(
                onNotification: (_) {
                  _routes.popChanged();
                  return false;
                },
                child: styled);
          },
          home: shell,
        );
    }

    final changes = services.settingsChanges;
    if (changes == null) {
      return appFor(localeForSetting(services.settings.appLanguage));
    }
    return ListenableBuilder(
      listenable: changes,
      builder: (context, _) =>
          appFor(localeForSetting(services.settings.appLanguage)),
    );
  }
}

class HomeShell extends StatefulWidget {
  final UiServices services;

  /// Android: the app navigator's routes (CalorieTrackerApp), for going to
  /// a meal the user asked to see over the screens open on the tabs. Null
  /// on iPhone, and in tests that build the shell alone: then any screen
  /// open over the tabs holds the request until it is closed.
  final RouteStack? routes;

  const HomeShell({super.key, required this.services, this.routes});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  late int _index;
  final GlobalKey<TodayScreenState> _todayKey = GlobalKey<TodayScreenState>();
  // History sits in the IndexedStack, so its initState runs once at app
  // launch; reload it on tab selection or it shows launch-time data forever
  // (bug found by the e2e flow: meals logged after launch never appeared).
  final GlobalKey<HistoryScreenState> _historyKey =
      GlobalKey<HistoryScreenState>();
  final GlobalKey<BodyScreenState> _bodyKey = GlobalKey<BodyScreenState>();

  StreamSubscription<Uri>? _linkSub;

  /// Recipients whose consent sheet the user answered 'Not now' to in this
  /// session: the shell does not raise it again for them (Settings' paused
  /// row still does).
  final Set<String> _consentDeclined = {};
  bool _consentAsking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    mealsChangedSignal.addListener(_onMealsChanged);
    widget.services.restaurantAssist?.consentNeeded
        ?.addListener(_onConsentNeeded);
    // One-click setup: a bitewise://setup link (QR, adb, devicectl) lands
    // here whether the app was warm (stream) or cold (initial link).
    _linkSub = widget.services.setupLinks?.listen(_onSetupLink);
    // A photo shared into the app waits for the AI consent (5.1.2(i)); the
    // question needs this navigator, so the gate holds photos until now.
    widget.services.sharedPhotoConsent?.attach(_askShareConsent);
    // Android: "show me that meal" (a shared photo's View, a tap on a
    // Logged meals card): the shell goes to it when it can at once, and
    // tries again each time a route, a held pop or the focus changes
    // (meal_reveal.dart).
    final reveals = widget.services.mealReveals;
    if (reveals != null) {
      reveals.attach(_revealWhenOnTop, canShowNow: _canRevealNow);
      widget.routes?.addListener(_onRevealConditions);
      FocusManager.instance.addListener(_onRevealConditions);
    }
    // The initial link goes to the engine's first shell only: a second or
    // rebuilt one gets null (UiServices.initialSetupLink, LINK-1).
    final initial = widget.services.initialSetupLink;
    if (initial != null) {
      unawaited(initial().then((uri) {
        if (uri != null && mounted) _onSetupLink(uri);
      }, onError: (Object _) {}));
    }
    // Onboarding: with no API key yet, land on Settings first — unless this
    // install already logs meals by hand (no AI needed), where Settings on
    // every launch only cost a tap before + Log.
    final settings = widget.services.settings;
    _index =
        settings.apiKey.trim().isEmpty && !settings.mealLogged ? 3 : 0;
    // Debug-only: headless simulator screenshot runs force a tab by
    // dropping a one-byte file into the app's Documents dir (simctl has no
    // tap injection; env forwarding and HOME-derived paths both proved
    // unreliable). Async by necessity — a forced tab pops in a frame after
    // first build, which screenshot runs don't care about. Inert in release
    // builds and when the file is absent.
    if (kDebugMode) {
      unawaited(getApplicationDocumentsDirectory().then((dir) {
        final f = File('${dir.path}/ct_debug_tab');
        if (!f.existsSync() || !mounted) return;
        final raw = f.readAsStringSync().trim();
        // '3p' = Settings tab + push the provider page (screenshot runs).
        final push = raw.endsWith('p');
        final forced = int.tryParse(push ? raw.substring(0, raw.length - 1) : raw);
        if (forced != null && forced >= 0 && forced <= 3) {
          setState(() => _index = forced);
          if (push && forced == 3) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final s = widget.services;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProviderSettingsPage(
                  settings: s.settings,
                  analyzer: s.analyzer,
                  startClaudeAuth: s.startClaudeAuth,
                  completeClaudeAuth: s.completeClaudeAuth,
            serverLoginState: s.serverLoginState,
                ),
              ));
            });
          }
        }
      }, onError: (Object _) {}));
    }
    // The consent text changed what is sent since the current recipient
    // was allowed: asked once, over the first frame.
    _askConsentUpdateWhenIdle();
    // The Google Play build turned a GitHub install's Watch Camera Roll
    // off at launch (play_channel.dart): said once, after that question.
    _tellWatchRetiredWhenIdle();
    // Android: a Save to Device whose call died with the engine before
    // this one (the activity was recreated while the save screen was up)
    // still saved the file; said here, once (Android QA Q4).
    _tellLateSaveResult();
    // iCloud Backup (iPhone, 1.7.0): starts after the first frame (the
    // database is open by then: init opened it); its notice and restore
    // offer are asked here, one question at a time.
    final backup = widget.services.cloudBackup;
    if (backup != null) {
      backup.prompt.addListener(_onBackupPrompt);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(backup.start().then((_) {}, onError: (Object _) {}));
      });
    }
  }

  /// The backup question being asked, so it is asked once.
  BackupPrompt? _backupAsking;

  /// iCloud Backup asks (the notice, or a restore offer): like the
  /// consent update, only over the shell itself with nothing on top, and
  /// after the consent-update question. If it could not now, it asks again
  /// once the shell is back on top ([_OnRouteReturn]), at a later prompt
  /// change, or at a return to the app: an open restore offer holds every
  /// automatic photo until it is answered.
  void _onBackupPrompt() {
    final backup = widget.services.cloudBackup;
    final prompt = backup?.prompt.value;
    if (backup == null || prompt == null || !mounted) return;
    if (identical(_backupAsking, prompt)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || backup.prompt.value != prompt) return;
      if (_backupAsking != null) return;
      await _consentUpdateAnswered();
      if (!mounted || backup.prompt.value != prompt) return;
      if (Navigator.maybeOf(context)?.canPop() ?? false) return;
      _backupAsking = prompt;
      try {
        switch (prompt) {
          case NoticePrompt():
            await showBackupNotice(context, backup);
          case RestoreOfferPrompt(:final candidate, :final localMeals):
            await showRestoreOffer(context, backup, candidate, localMeals);
        }
      } finally {
        _backupAsking = null;
      }
      // Answering one may raise the next (the notice after a restore).
      if (mounted && backup.prompt.value != null &&
          !identical(backup.prompt.value, prompt)) {
        _onBackupPrompt();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// The share gate's question: true = allowed (and saved). Not now says
  /// that the shared photo was not analyzed.
  /// Null: no dialog could be shown (this shell is going away), which is
  /// no answer: the gate waits for the next shell, or asks again through
  /// one still attached once this one detaches (SharedPhotoConsentGate,
  /// GATE-1).
  Future<bool?> _askShareConsent() async {
    if (!mounted) return null;
    final gate = widget.services.sharedPhotoConsent;
    // One question per share: Not now covers the photos already in
    // (askSharedPhotoConsent).
    if (gate != null) {
      return askSharedPhotoConsent(context, widget.services.settings, gate);
    }
    return ensureAiConsent(context, widget.services.settings,
        declined: context.l10n.shareConsentDeclined);
  }

  /// The consent-update question while it is open: a setup link that
  /// lands meanwhile waits for its answer ([_consentUpdateAnswered]).
  Future<bool>? _consentUpdate;

  /// Set once the app really left the screen (hidden / paused), so the
  /// inactive → resumed around an iOS system alert is not a return.
  bool _leftApp = false;

  /// On a launch or a return to the app: asks once more for the current
  /// recipient when the consent text changed what is sent since it was
  /// allowed (aiConsentUpdateNeeded — never without a key or a grant).
  /// One question at a time, and only over the shell itself: never on top
  /// of the setup-link or shared-photo question, another dialog or a
  /// screen — a later return asks instead.
  void _askConsentUpdateWhenIdle() {
    if (_consentUpdate != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _consentUpdate != null) return;
      final settings = widget.services.settings;
      if (!aiConsentUpdateNeeded(settings)) return;
      // Nothing on top: asked through the navigator, not ModalRoute.of —
      // that makes the shell depend on its route, and every push and pop
      // over it then rebuilt the shell and its selected tab.
      if (Navigator.maybeOf(context)?.canPop() ?? false) return;
      final asked = _consentUpdate = askAiConsentUpdate(context, settings);
      asked.whenComplete(() => _consentUpdate = null).ignore();
    });
    // A post-frame callback alone waits for SOME frame; ask for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _consentUpdateAnswered() async {
    try {
      await _consentUpdate;
    } catch (_) {
      // A failed question is no answer; the link goes on.
    }
  }

  /// Set while the Watch Camera Roll notice is on screen: shown once.
  bool _watchNoticeShowing = false;

  /// The Google Play build's ONE notice (play_channel.dart): Watch Camera
  /// Roll, which the GitHub install it replaced had on, is not in this
  /// version and is off, and how to log photos instead. After the
  /// consent-update question, and only over the shell itself, like that
  /// one; with something on top it waits for the shell to be back on top
  /// ([_OnRouteReturn]) or for a return to the app. Dismissed in any way,
  /// it is never shown again.
  void _tellWatchRetiredWhenIdle() {
    final notice = widget.services.watchRetiredNotice;
    if (notice == null || _watchNoticeShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _watchNoticeShowing || !notice.pending()) return;
      _watchNoticeShowing = true;
      try {
        await _consentUpdateAnswered();
        if (!mounted || !notice.pending()) return;
        if (Navigator.maybeOf(context)?.canPop() ?? false) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => appAlertDialog(
            key: const Key('watchRetiredNotice'),
            title: Text(ctx.l10n.watchRetiredTitle),
            content: Text(ctx.l10n.watchRetiredBody),
            actions: [
              FilledButton(
                key: const Key('watchRetiredOk'),
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(ctx.l10n.okButton),
              ),
            ],
          ),
        );
        await notice.shown();
      } catch (_) {
        // Not shown or not forgotten: asked again at the next chance.
      } finally {
        _watchNoticeShowing = false;
      }
    });
    // A post-frame callback alone waits for SOME frame; ask for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Android: how a Save to Device ended whose call died with the engine
  /// before this one. Android recreated the activity while its save
  /// screen was up, the copy still ran (MainActivity), and the
  /// "Export saved." that Settings would have said never came (Android QA
  /// Q4). Asked once, after the first frame; a copy still running is
  /// waited for. The same line Settings says (saveStatusLine).
  void _tellLateSaveResult() {
    final take = widget.services.lateSaveResult;
    if (take == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      SaveFileStatus? status;
      try {
        status = await take();
      } catch (_) {
        return; // nothing said
      }
      if (status == null || !mounted) return;
      final line = saveStatusLine(context.l10n, status);
      if (line == null) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(line)));
    });
    // A post-frame callback alone waits for SOME frame; ask for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Whether the shell could go to a meal at once
  /// ([MealReveals.canShowNow]): every screen open over the tabs would
  /// close with Back without asking (it holds no unsaved changes: its
  /// discard guard lets the pop through), no dialog, sheet or menu is
  /// open (a question waits for its answer), and no text field has the
  /// focus (the user is typing). Without the app's [HomeShell.routes] (a
  /// test that builds the shell alone), anything open over the tabs holds
  /// it.
  bool _canRevealNow() {
    if (!mounted) return false;
    final routes = widget.routes?.routes;
    if (routes == null) {
      if (Navigator.maybeOf(context)?.canPop() ?? false) return false;
    } else {
      // The shell is the app's home: the navigator's first route.
      for (final route in routes.skip(1)) {
        if (route is! PageRoute) return false;
        if (route.popDisposition == RoutePopDisposition.doNotPop) {
          return false;
        }
      }
    }
    return !_typingNow();
  }

  /// Whether a text field has the focus: the user is typing.
  static bool _typingNow() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null || !focused.mounted) return false;
    return focused.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// A meal to show is waiting (meal_reveal.dart): shown after this frame
  /// if the shell can go there at once then ([_canRevealNow]).
  void _revealWhenOnTop() {
    if (!mounted || widget.services.mealReveals?.waiting == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryReveal());
    // A post-frame callback alone waits for SOME frame; ask for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Nothing is closed or covered for a waiting meal while a screen holds
  /// unsaved changes (its discard question is never asked on its behalf),
  /// a question is open or a text field has the focus: it waits for the
  /// next change of routes, held pops or focus ([_onRevealConditions], or
  /// the shell back on top: [_OnRouteReturn]), within
  /// [MealReveals.waitLimit].
  void _tryReveal() {
    final reveals = widget.services.mealReveals;
    if (!mounted || reveals == null || reveals.waiting == null) return;
    if (!_canRevealNow()) return;
    final reveal = reveals.take();
    if (reveal != null) unawaited(_reveal(reveal));
  }

  /// Set while [_onRevealConditions] waits for its frame.
  bool _revealConditionsDue = false;

  /// Whether the shell can go to a meal at once may have changed: a route
  /// came or went ([HomeShell.routes]), one held or let go of its pop, or
  /// the focus moved. After the frame, when the change has settled, the
  /// View on a message is asked again whether it is still offered
  /// ([MealReveals.availabilityChanged]), and a waiting meal is tried
  /// again.
  void _onRevealConditions() {
    if (_revealConditionsDue || !mounted) return;
    _revealConditionsDue = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealConditionsDue = false;
      final reveals = widget.services.mealReveals;
      if (!mounted || reveals == null) return;
      reveals.availabilityChanged();
      _tryReveal();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Goes to the meal [reveal] names: Today, scrolled to the meal and
  /// briefly ringed; History with the meal's day open on it, for a meal
  /// dated another day (a photo taken before midnight, say); Today alone
  /// when the meal is gone. For [MealReveal.dayOf] (a tap on the Logged
  /// meals cards' group summary) the same day opens with nothing ringed.
  /// Where it is dated now, not when it was logged: the editor may have
  /// moved it since. The screens open over the tabs close first, as Back
  /// would close each (none holds its pop).
  Future<void> _reveal(MealReveal reveal) async {
    final s = widget.services;
    Meal? meal;
    try {
      meal = (await s.dao.mealSnapshot(reveal.mealId))?.meal;
    } catch (_) {
      // Unreadable now: Today, as for a meal that is gone.
    }
    if (!mounted) return;
    // Something came up meanwhile that keeps the shell from going there:
    // the request waits again, unless a newer one already does.
    if (!_canRevealNow()) {
      final reveals = s.mealReveals;
      if (reveals != null && reveals.waiting == null) reveals.request(reveal);
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.popUntil((route) => route.isFirst);
    if (meal == null || meal.date == isoDate(DateTime.now())) {
      setState(() => _index = 0);
      final today = _todayKey.currentState;
      if (meal == null || !reveal.ring) {
        await today?.reload();
      } else {
        await today?.reveal(meal.id);
      }
      return;
    }
    setState(() => _index = 1);
    final history = _historyKey.currentState;
    if (history == null) return;
    unawaited(history.reload());
    await history.openDay(meal.date,
        revealMealId: reveal.ring ? meal.id : null);
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routes != widget.routes &&
        widget.services.mealReveals != null) {
      oldWidget.routes?.removeListener(_onRevealConditions);
      widget.routes?.addListener(_onRevealConditions);
    }
  }

  @override
  void dispose() {
    final reveals = widget.services.mealReveals;
    if (reveals != null) {
      FocusManager.instance.removeListener(_onRevealConditions);
      widget.routes?.removeListener(_onRevealConditions);
      reveals.detach(_revealWhenOnTop);
    }
    widget.services.cloudBackup?.prompt.removeListener(_onBackupPrompt);
    widget.services.sharedPhotoConsent?.detach(_askShareConsent);
    _linkSub?.cancel();
    mealsChangedSignal.removeListener(_onMealsChanged);
    widget.services.restaurantAssist?.consentNeeded
        ?.removeListener(_onConsentNeeded);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The last setup link handled, and when: app_links' stream also
  /// carries the link that cold-started the app, which the initial-link
  /// read already delivered — one link, one confirmation.
  ({String uri, DateTime at})? _lastSetupLink;

  /// A setup link arrived. Never applied silently: a crafted link could
  /// point every future photo upload at a stranger's server, so the user
  /// sees exactly what it names and confirms with one tap.
  Future<void> _onSetupLink(Uri uri) async {
    // Not ours at all — e.g. the share extension's ShareMedia-<bundle>:share
    // bounce on iOS, which app_links also forwards — is ignored silently.
    // Only a malformed bitewise:// link earns the "not valid" message.
    if (!isSetupLinkScheme(uri)) return;
    final now = DateTime.now();
    final text = uri.toString();
    final last = _lastSetupLink;
    if (last != null &&
        last.uri == text &&
        now.difference(last.at) < setupLinkRepeatWindow) {
      return;
    }
    _lastSetupLink = (uri: text, at: now);
    final l = context.l10n;
    final link = parseSetupLink(uri);
    if (link == null) {
      // A well-formed link to a plain http:// server is refused by the
      // https switch (core/server_transport.dart): said as such.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(setupLinkNeedsHttps(uri)
              ? l.setupLinkNeedsHttps
              : l.setupLinkInvalid)));
      return;
    }
    // One question at a time: the consent-update one answers first.
    await _consentUpdateAnswered();
    if (!mounted) return;
    final settings = widget.services.settings;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.l10n.setupLinkTitle),
        // The plan is named with the same words the Settings row shows
        // after confirming (Claude 订阅 / Claude Plan), not the raw id
        // 'claude' the link carries; the id itself is what gets saved.
        // Confirming is also the AI consent for this plan (5.1.2(i)), so the
        // dialog names the company the server passes the data to.
        content: SingleChildScrollView(
          child: Text([
            // Watch Camera Roll on: from the confirm on, every new library
            // photo (non-food too) goes to this server. Said first, as the
            // recipient-change dialog does (confirmAiRecipientChange).
            if (settings.watcherEnabled)
              ctx.l10n.watcherDisclosureBody(
                  providerDisplayLabel(ctx.l10n, 'server', link.backend),
                  settings.lookbackDays.clamp(1, 30)),
            ctx.l10n.setupLinkBody(
                link.server,
                providerDisplayLabel(ctx.l10n, 'server', link.backend),
                link.keyTail),
            ctx.l10n.setupLinkSharing(aiConsentCompanyName(ctx.l10n,
                provider: 'server', serverBackend: link.backend)),
            // The same mainland-China note the consent dialog adds: this
            // confirmation IS the consent for the plan (GLM, Doubao).
            if (aiRoutesInMainlandChina
                .contains(aiConsentRoute('server', link.backend)))
              ctx.l10n.aiConsentChinaNote(aiConsentCompanyName(ctx.l10n,
                  provider: 'server', serverBackend: link.backend)),
          ].join('\n\n')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('setupLinkConfirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.setupLinkConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final s = settings;
    // The confirmation named the plan's AI company: it is the consent for
    // that recipient, saved before anything can be sent to it.
    await s.setAiConsent(aiConsentRoute('server', link.backend),
        granted: true);
    // The address and its key together, bound to each other and notified
    // once: written one after the other, a frame between them saw the
    // link's address with the previous server's key (review of PR 74).
    await s.applyServerSetup(
        serverBackend: link.backend,
        serverBaseUrl: link.server,
        apiKey: link.key);
    if (!mounted) return;
    setState(() => _index = 3); // land on Settings, where the result shows
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l.setupLinkDone)));
  }

  /// The restaurant assist paused for a consent that does not name the
  /// recipient a lookup would reach now (another provider or server, design
  /// R7a): the consent sheet, once per recipient per session, and only over
  /// the shell itself — never on top of the editor or another screen (the
  /// assist asks again on its next sweep).
  void _onConsentNeeded() {
    final controls = widget.services.restaurantAssist;
    final support = controls?.consentNeeded?.value;
    if (controls == null || support == null || !mounted) return;
    final settings = widget.services.settings;
    if (settings.restaurantAssist == 'off') return;
    if (_consentAsking || _consentDeclined.contains(support.recipientStamp)) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _consentAsking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
        // Answered meanwhile (in Settings, say), or turned off: nothing to ask.
        if (settings.restaurantAssist == 'off' ||
            restaurantConsentCovers(settings, controls.lookupSupport())) {
          return;
        }
        final choice = await askRestaurantConsent(context,
            settings: settings,
            controls: controls,
            kind: RestaurantConsentKind.recipientChanged);
        if (choice == null) _consentDeclined.add(support.recipientStamp);
      } finally {
        _consentAsking = false;
      }
    });
    // A post-frame callback alone waits for SOME frame; ask for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// A meal was saved somewhere in the app (watcher, catch-up, coverage
  /// screen). Re-query the data tabs so what's on screen matches the DB.
  void _onMealsChanged() {
    if (!mounted) return;
    _todayKey.currentState?.reload();
    _historyKey.currentState?.reload();
    final settings = widget.services.settings;
    if (!settings.mealLogged) {
      unawaited(settings.markMealLogged().then((_) {}, onError: (Object _) {}));
    }
    // A change worth backing up (debounced by the coordinator).
    widget.services.cloudBackup?.noteChange();
    // iOS: a meal just landed (pipeline / share sheet) — the pending OS card
    // must carry it even if the user stays in the app through the slot.
    final rearm = widget.services.refreshDailyNotification;
    if (rearm != null) {
      unawaited(rearm().then((_) {}, onError: (Object _) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final s = widget.services;
    // iOS: whatever the user last saw is what the OS will deliver at the
    // slot — re-arm on EVERY transition (pause included: that is the last
    // moment content can still change before the app is suspended).
    final rearm = s.refreshDailyNotification;
    if (rearm != null) {
      unawaited(rearm().then((_) {}, onError: (Object _) {}));
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _leftApp = true;
      // iCloud Backup's background-entry run (inside a background task).
      s.cloudBackup?.onLifecycle(false);
    }
    if (state != AppLifecycleState.resumed) return;
    if (_leftApp) {
      _leftApp = false;
      _askConsentUpdateWhenIdle();
      _tellWatchRetiredWhenIdle();
      s.cloudBackup?.onLifecycle(true);
      _onBackupPrompt();
    }
    // The background job may have logged meals while we were away — the
    // IndexedStack keeps stale screens alive, so refresh them now.
    _todayKey.currentState?.reload();
    if (_index == 1) _historyKey.currentState?.reload();
    // Never in the Google Play build, whatever the setting
    // (core/app_channel.dart): it has no Watch Camera Roll.
    if (!s.settings.watcherEnabled || !photoLibraryInBuild) return;
    unawaited(_resumeCatchUp());
  }

  Future<void> _resumeCatchUp() async {
    final s = widget.services;
    // The background run (its own isolate and preferences cache) may have
    // latched the automatic scan on a rejected key / blocked region while
    // we were away — or an analysis there may have lifted it.
    try {
      await s.settings.reloadAutoScanBlock();
    } catch (_) {}
    // One predicate for "an automatic analysis could succeed" (key, no
    // quota latch, no rejected-key/region latch): don't read photo bytes
    // for nothing.
    if (!mounted || !s.settings.canAutoAnalyze) return;
    // Resume catch-up (full lookback window): the change-notify watcher is
    // frozen with the process on EMUI-class OSes, so photos taken while the
    // app was backgrounded surface here. The md5 ledger + in-session seen
    // set make repeat resumes near-free. Refresh again once the scan's
    // emissions have had a chance to process. What it covers moves the
    // background watermark too (foregroundCatchUp). iOS: it reads no more
    // photos once the user leaves again.
    final intake = s.photoIntake;
    if (intake == null) return;
    // iCloud Backup: a restore offer is open or a restore runs (answered
    // once a look for a backup to offer that is running has decided). A
    // catch-up held here is caught up as soon as the hold lets go
    // (BackupCoordinator.onCatchUpReleased → di.dart catchUpAfterHold,
    // when the app is in the foreground then), else at the next return to
    // the app. This engine also holds for an offer that is still open,
    // however long; the headless background run sees only the 30-minute
    // lease. One running stops before its next photo once an offer or a
    // restore holds it.
    final backup = s.cloudBackup;
    if (await backup?.holdsCatchUp() ?? false) return;
    await foregroundCatchUp(intake,
            shouldContinue: Platform.isIOS
                ? () =>
                    appEngineInForeground() &&
                    !(backup?.holdsCatchUpNow ?? false)
                : null)
        .then((_) {}, onError: (Object _) {})
        .then((_) => Future<void>.delayed(const Duration(seconds: 15)))
        .then((_) {
      if (!mounted) return;
      _todayKey.currentState?.reload();
      if (_index == 1) _historyKey.currentState?.reload();
    });
  }

  /// The tab widgets as last placed in the IndexedStack.
  List<Widget>? _tabs;

  /// Only the SELECTED tab gets this build's widget; the hidden ones keep
  /// their last one, which Flutter then skips. A tab tap used to rebuild
  /// all four screens, the hidden Body one re-deriving its whole history
  /// each time. The selected tab still rebuilds in the tap frame, so what
  /// it reads while building (the units preference, Settings' Today /
  /// Tomorrow labels) is current the moment it shows; hidden tabs still
  /// follow their own theme, locale and text-size dependencies.
  List<Widget> _onlySelectedRebuilds(List<Widget> fresh) {
    final kept = _tabs;
    return _tabs = [
      for (var i = 0; i < fresh.length; i++)
        i == _index || kept == null || kept.length != fresh.length
            ? fresh[i]
            : kept[i],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final shell = Scaffold(
      // No shared AppBar: each tab renders its own iOS-style large title
      // that collapses as it scrolls (SliverAppBar.large). A centred
      // column on tablets, foldables and Chromebooks (ContentWidthCap).
      body: ContentWidthCap(
        child: IndexedStack(
          index: _index,
          children: _onlySelectedRebuilds([
            TodayScreen(
                key: _todayKey,
                dao: s.dao,
                thumbs: s.thumbs,
                garminDaily: s.garminDaily,
                mealInUse: s.mealInUse,
                restaurantAssist: s.restaurantAssist,
                settings: s.settings,
                noteCorrector: noteCorrectorOf(s.executor),
                usual: s.usualFoods),
            HistoryScreen(
                key: _historyKey,
                dao: s.dao,
                thumbs: s.thumbs,
                mealInUse: s.mealInUse,
                restaurantAssist: s.restaurantAssist,
                settings: s.settings,
                noteCorrector: noteCorrectorOf(s.executor)),
            BodyScreen(key: _bodyKey, dao: s.dao, settings: s.settings),
            SettingsScreen(
              settings: s.settings,
              analyzer: s.analyzer,
              dao: s.dao,
              requestPhotoPermission: s.requestPhotoPermission,
              photoIntake: s.photoIntake,
              coverage: s.coverage,
              processPhoto: s.processPhoto,
              photoLibrary: s.photoLibrary,
              analysisKeepAlive: s.analysisKeepAlive,
              startClaudeAuth: s.startClaudeAuth,
              completeClaudeAuth: s.completeClaudeAuth,
              serverLoginState: s.serverLoginState,
              openSystemSettings: s.openSystemSettings,
              notificationsEnabled: s.notificationsEnabled,
              nextSummaryAt: s.nextSummaryAt,
              lastBackgroundScan: s.lastBackgroundScan,
              backgroundRefreshEnabled: s.backgroundRefreshEnabled,
              backgroundScanStuck: s.backgroundScanStuck,
              changes: s.settingsChanges,
              restaurantAssist: s.restaurantAssist,
              cloudBackup: s.cloudBackup,
              androidBackupNote: Platform.isAndroid,
              onImported: () {
                s.thumbs?.clear();
                signalMealsChanged();
              },
            ),
          ]),
        ),
      ),
      // The + 记录 button is a REAL Scaffold FAB (Today tab only — Body has
      // its own), so Material lifts it above this messenger's snackbars.
      // Until 2026-10-12 it was a Positioned inside TodayScreen, kept out
      // of the Scaffold so it would not cover the chat box's send button
      // (the chat box went 2026-07-31) — and every snackbar covered IT.
      floatingActionButton: _index == 0
          ? FloatingActionButton.extended(
              key: const Key('addMealFab'),
              // The SIGNAL, not a Today-only reload: the fix/delete,
              // describe, manual and leftover paths write meals directly,
              // and on iOS the pending OS card must be re-armed with them
              // (_onMealsChanged reloads Today + History and re-arms).
              onPressed: () => openAddFlow(context, s,
                  onChanged: () async => signalMealsChanged()),
              icon: const Icon(Icons.add),
              label: Text(context.l10n.fabLog),
            )
          : null,
      bottomNavigationBar: _TopHairline(child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          // BOTH data tabs reload on selection. They live in an IndexedStack,
          // so their state survives tab switches — and a meal logged while
          // the app was open (watcher, background job, or the launch/resume
          // catch-up) is invisible on a screen built before it existed. That
          // is exactly how a 07:40 latte, correctly analyzed and saved at
          // 18:06, stayed missing from Today until a manual pull-to-refresh
          // (real report, 2026-07-26).
          if (i == 0) _todayKey.currentState?.reload();
          if (i == 1) _historyKey.currentState?.reload();
          if (i == 2) _bodyKey.currentState?.reload();
          // The backup's upload state for the status line.
          final backup = s.cloudBackup;
          if (i == 3 && backup != null) unawaited(backup.refresh());
        },
        destinations: [
          NavigationDestination(
              icon: const Icon(Icons.today_outlined),
              selectedIcon: const Icon(Icons.today),
              label: context.l10n.tabToday),
          NavigationDestination(
              icon: const Icon(Icons.history),
              label: context.l10n.tabHistory),
          NavigationDestination(
              icon: const Icon(Icons.monitor_weight_outlined),
              selectedIcon: const Icon(Icons.monitor_weight),
              label: context.l10n.tabBody),
          NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: context.l10n.tabSettings),
        ],
      )),
    );
    // A backup question that waited for a screen over the shell (the add
    // flow, say) is asked once that screen is popped. It waited until the
    // prompt changed or the app came back, holding the photos meanwhile.
    // The Play build's Watch Camera Roll notice waits the same way.
    // A meal the user asked to see while something over the shell held it
    // is tried again once the shell is back on top (_revealWhenOnTop).
    final page = _OnRouteReturn(
        onReturn: () {
          _onBackupPrompt();
          _tellWatchRetiredWhenIdle();
          _revealWhenOnTop();
        },
        child: shell);
    // Android: while a shared photo is on its way to a meal, or any
    // analysis the user started is in flight (owner decision 9), Back at
    // the root moves the app to the back in every task. MainActivity keeps
    // that Back in Flutter wherever it knows Android 14 and later would
    // finish the activity, and its engine with it, mid-request (Q9); the
    // guard also covers a start it cannot see (a return from Recents on
    // Android 15 QPR1 and later, with a third-party home app).
    final sharing = s.sharedPhotosPending;
    final analyzing = s.analysisKeepAlive?.inFlight;
    return sharing == null && analyzing == null
        ? page
        : SharedPhotosBackGuard(
            pending: sharing, analyzing: analyzing, child: page);
  }
}

/// Calls [onReturn] each time the route it sits in is back on top: a
/// screen, sheet or dialog over it was popped or removed. Only this widget
/// depends on the route, and it hands [child] through untouched: the
/// shell itself must not depend on it, or every push and pop over it
/// rebuilds the shell and its selected tab (see _askConsentUpdateWhenIdle).
class _OnRouteReturn extends StatefulWidget {
  const _OnRouteReturn({required this.onReturn, required this.child});
  final VoidCallback onReturn;
  final Widget child;

  @override
  State<_OnRouteReturn> createState() => _OnRouteReturnState();
}

class _OnRouteReturnState extends State<_OnRouteReturn> {
  /// Whether the route was on top when last told; null before the first.
  bool? _current;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    final returned = _current == false && current;
    _current = current;
    if (returned) widget.onReturn();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The tab bar's top edge: one physical-pixel separator line, painted
/// OVER the bar (the bar's own Material would cover a background line).
class _TopHairline extends StatelessWidget {
  const _TopHairline({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
                color: context.colors.separator,
                width: 1 / MediaQuery.devicePixelRatioOf(context)),
          ),
        ),
        child: child,
      );
}

/// Shown when async startup (settings → dao → services) throws.
class StartupErrorApp extends StatefulWidget {
  final String error;

  /// Another startup attempt; run on resume and from the Retry button.
  final Future<void> Function()? onRetry;
  const StartupErrorApp({super.key, required this.error, this.onRetry});

  @override
  State<StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends State<StartupErrorApp>
    with WidgetsBindingObserver {
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _retry();
  }

  Future<void> _retry() async {
    final retry = widget.onRetry;
    if (retry == null || _retrying) return;
    _retrying = true;
    try {
      await retry(); // success replaces this whole app via runApp
    } finally {
      if (mounted) _retrying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // No AppLocalizations exists yet when startup fails, so the two lines
    // follow the phone's language directly.
    final zh =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    return MaterialApp(
      title: appTitleFor(WidgetsBinding.instance.platformDispatcher.locale),
      theme: AppTheme.build(Brightness.light, cjk: zh),
      darkTheme: AppTheme.build(Brightness.dark, cjk: zh),
      themeMode: ThemeMode.system,
      builder: (context, child) =>
          _SystemNavBarStyle(child: child ?? const SizedBox.shrink()),
      home: Builder(builder: (context) {
        final text = Theme.of(context).textTheme;
        final colors = context.colors;
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.error_outline_rounded,
                        size: 44, color: colors.secondaryLabel),
                  ),
                  const SizedBox(height: 12),
                  Text(zh ? '筷拍无法启动。' : 'Chopstats could not start.',
                      textAlign: TextAlign.center, style: text.titleMedium),
                  const SizedBox(height: 8),
                  Text(widget.error,
                      textAlign: TextAlign.center,
                      style: text.bodySmall
                          ?.copyWith(color: colors.secondaryLabel)),
                  if (widget.onRetry != null) ...[
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('startupRetry'),
                      onPressed: _retry,
                      child: Text(zh ? '重试' : 'Retry'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
