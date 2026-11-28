// Production wiring gate (2026-10-19).
//
// The background-scan fixes are unit-tested through seams, but the lines
// that hand those seams to production are not: a mutation run on a scratch
// copy dropped `passOver:` in createPhotoIntake, `deferred:` in
// runHeadlessBackfill, the foreground catch-up in di.dart and app.dart, the
// iOS BackgroundTime and the deferred-asset clearing — and the whole suite
// stayed green each time. Dropping either of the first two silently turned
// "one undecodable photo cannot freeze the scan" off on the phone.
//
// AppServices.init and runHeadlessBackfill's pipeline open real plugins
// (sqflite, photo_manager), so where no behavioural test can reach, these
// pins read the source the way manifest_gate_test reads the Xcode project.
// Whitespace and trailing commas are free; the wiring is not.
import 'dart:io';

import 'package:calorie_tracker/services/photo/photo_changes.dart'
    show recordLateImportPass;
import 'package:calorie_tracker/services/photo/watcher.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

String _source(String path) =>
    File('${_appRoot().path}/$path').readAsStringSync();

/// The body of the top-level or member function [name] in [source]: from
/// its declaration to the next line that closes at column [indent].
String _body(String source, String declaration, {String indent = ''}) {
  final start = source.indexOf(declaration);
  expect(start, isNot(-1), reason: '"$declaration" not found');
  final end = source.indexOf('\n$indent}\n', start);
  expect(end, isNot(-1), reason: 'no end for "$declaration"');
  return source.substring(start, end);
}

/// [pattern] with every run of spaces in it allowed to be any whitespace,
/// and an optional trailing comma before each closing parenthesis.
Matcher _wired(String pattern) => matches(
  RegExp(pattern.replaceAll(' ', r'\s*').replaceAll(r'\)', r',?\s*\)')),
);

/// The one call in [source] that starts with [opening] ('Name('), through
/// its matching parenthesis.
String _call(String source, String opening) {
  expect(opening.allMatches(source), hasLength(1), reason: opening);
  final start = source.indexOf(opening);
  var depth = 0;
  for (var i = start + opening.length - 1; i < source.length; i++) {
    if (source[i] == '(') depth++;
    if (source[i] == ')' && --depth == 0) {
      return source.substring(start, i + 1);
    }
  }
  fail('no end for "$opening"');
}

void main() {
  group('lib/ui/di.dart (the app engine)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    // RC 1.6.0: the lookup's Undo was `() => unawaited(n.undo())`, silent
    // when the meal had changed since and nothing was undone.
    test("the lookup snackbar's Undo says when it undid nothing", () {
      expect(init(), isNot(contains('unawaited(n.undo())')));
      expect(
        init(),
        _wired(
          r'assistUndoAction\(n, '
          r'(//[^\n]*\n\s*)?'
          r'onNothingUndone: \(\) => notify\?\.call\( '
          r'localizationsFor\(settings\.appLanguage\) \.usualUndoStale\)',
        ),
      );
    });

    test('iOS gives each photo background time and holds automatic photos '
        'while the app is in the background', () {
      expect(
        init(),
        _wired(
          r'backgroundTime: Platform\.isIOS \? const BackgroundTime\(\) : null',
        ),
      );
      expect(
        init(),
        _wired(
          r'backgrounded: Platform\.isIOS \? appEngineBackgrounded : null',
        ),
      );
      expect(
        init(),
        _wired(
          r'if \(Platform\.isIOS\) \{[^}]*isEngineBackgrounded = '
          r'appEngineBackgrounded;',
        ),
      );
    });

    test(
      'a verdict here forgets a photo the background run kept deferring',
      () {
        expect(
          init(),
          _wired(
            r'onOutcome: \(photo, o\) \{\s*if \(!o\.retryable && '
            r'o\.kind != PhotoOutcomeKind\.alreadyTracked\) \{\s*'
            r'unawaited\(clearDeferredAsset\(photo\.assetId\)\);',
          ),
        );
      },
    );

    test('the launch catch-up is foregroundCatchUp (it moves the background '
        'watermark), stopping on iOS once the app is left', () {
      expect(
        init(),
        _wired(
          // iCloud Backup: held while a restore offer or a restore is open,
          // asked inside the catch-up and again before each photo.
          r'if \(await cloudBackup\?\.holdsCatchUp\(\) \?\? false\) return; '
          r'await foregroundCatchUp\(photoIntake, shouldContinue: '
          r'Platform\.isIOS \? \(\) => appEngineInForeground\(\) && '
          r'!\(cloudBackup\?\.holdsCatchUpNow \?\? false\) : null\)',
        ),
      );
      expect(
        init(),
        isNot(contains('.backfillScan(')),
        reason: 'a bare backfillScan leaves the watermark days behind',
      );
    });

    // Review r171: the restore offer's hold stopped only the catch-ups.
    // The live watcher's photos were still logged (and kept over the
    // backup's own meals by the restore), and a catch-up the hold had
    // skipped waited for the next return to the app.
    test('iCloud Backup holds the automatic intake, and the catch-up it held '
        'runs once it lets go', () {
      final pipeline = _call(init(), 'PhotoPipeline(');
      expect(
        pipeline,
        _wired(r'intakeHeld: \(\) => cloudBackup\?\.holdsPhotosNow \?\? false,'),
      );
      final coordinator = _call(init(), 'BackupCoordinator(');
      expect(
        coordinator,
        _wired(r'onCatchUpReleased: \(\) => unawaited\(catchUpAfterHold\(\)\),'),
      );
      final after = _body(
        init(),
        'Future<void> catchUpAfterHold() async {',
        indent: '    ',
      );
      expect(
        after,
        _wired(
          r'if \(!settings\.watcherEnabled \|\| !settings\.canAutoAnalyze \|\| '
          r'!appEngineInForeground\(\)\) \{ return; \}',
        ),
      );
      expect(
        after,
        _wired(
          r'await foregroundCatchUp\(photoIntake, shouldContinue: \(\) => '
          r'appEngineInForeground\(\) && '
          r'!\(cloudBackup\?\.holdsCatchUpNow \?\? false\)\)',
        ),
      );
    });

    test('the stuck probe reads the runs and the watermark together', () {
      expect(init(), _wired(r'backgroundScanStuck: backgroundScanStuckNow,'));
    });

    // 2026-11-28: the request for the next background scan used to be made
    // at a cold start only, and a submit iOS refused was only logged by
    // the plugin. iOS only: handed a hook or a probe, Android's shell and
    // Settings would start asking a channel that does not exist there
    // (background_schedule.dart answers nothing on Android even so, which
    // background_glue_test proves).
    test('iOS: the shell keeps the request for the next background scan '
        'alive and Settings reads what iOS said; Android gets neither', () {
      expect(
        init(),
        _wired(
          r'keepBackgroundScan: Platform\.isIOS \? \(\) => '
          r'keepBackgroundScanScheduled\(settings\) : null,',
        ),
      );
      expect(
        init(),
        _wired(
          r'backgroundSchedule: Platform\.isIOS \? lastBackgroundSchedule : '
          r'null,',
        ),
      );
      final shell = _source('lib/ui/app.dart');
      expect(shell, _wired(r'backgroundSchedule: s\.backgroundSchedule,'));
      expect(
        shell,
        _wired(
          r'if \(state == AppLifecycleState\.resumed \|\| '
          r'state == AppLifecycleState\.hidden \|\| '
          r'state == AppLifecycleState\.paused\) \{ '
          r'final keep = s\.keepBackgroundScan;',
        ),
      );
      // The launch and every Watch Camera Roll or look-back edit: what iOS
      // made of workmanager's submit is asked right behind it.
      final sync = _body(
        _source('lib/ui/background_glue.dart'),
        'Future<void> syncBackgroundScan(AppSettings settings) async {',
      );
      expect(
        sync,
        _wired(
          r'await enableBackgroundScan\([^;]*\); '
          r'await keepBackgroundScanScheduled\(settings\);',
        ),
      );
    });

    // G2b: without it every glasses preview copy is analyzed at once.
    test('a glasses preview copy waits once for its full-size one', () {
      expect(init(), _wired(r'previewHold: holdGlassesPreview,'));
    });

    // G3: without them a switched-off glasses photo is still logged, an
    // iPhone uploads every casual glasses frame, and the Glasses check
    // card stays empty.
    test('glasses photos: the live switch, the iOS food check, the record',
        () {
      expect(init(), _wired(r'includeGlasses: \(\) => settings\.watchGlasses,'));
      expect(
        init(),
        _wired(r'foodCheck: Platform\.isIOS \? foodScoreViaImageIO : null,'),
      );
      expect(init(), _wired(r'glassesCheckLog: recordGlassesCheckLocally\)'));
    });

    // Review of #72: without them, Photo Coverage called every glasses photo
    // the switch keeps out of automatic intake (Android's default) "never
    // scanned", and its Log all sent them all to the AI.
    test('Photo Coverage reads the glasses switch and the Meta albums as '
        'intake does', () {
      final auditor = _call(init(), 'CoverageAuditor(');
      expect(auditor,
          _wired(r'includeGlasses: \(\) => settings\.watchGlasses,'));
      expect(
        auditor,
        _wired(
          r'metaAlbumIds: albumChanges == null \? null : \(since\) => '
          r'metaAlbumAssetIds\(albumChanges, since: since\)\)',
        ),
      );
      expect(init(),
          _wired(r'final albumChanges = platformPhotoChangeSource\(\);'));
    });

    // G1b: without it every late import is read in full, logged or not.
    // Review r171: without liveHeld the live watcher read every photo an
    // iCloud Backup hold kept back again at each library change.
    test('late imports skip photos a meal already names, without a read, '
        'and the live watcher reads nothing while iCloud Backup holds it', () {
      expect(
        init(),
        _wired(
          r'createPhotoIntake\(settings, loggedAssetIds: dao\.loggedAssetIds, '
          r'liveHeld: \(\) => cloudBackup\?\.holdsPhotosNow \?\? false\)',
        ),
      );
    });

    // LINK-1 (2026-11-22): app_links answers every initial-link read with
    // the first link it was given, for as long as the plugin lives, and each
    // HomeShell reads it in initState: a second or rebuilt shell asked
    // about that link again (RCREL-V-1). The wrapper and the shells are
    // behaviour-tested on services the tests build themselves
    // (test/ui/launch_link_once_test.dart, setup_link_flow_test): without
    // this line every shell reads the plugin again, with all of them green.
    test('the setup link that started the app is read once, through '
        'launchLinkOnce; the warm links come from the plugin\'s stream', () {
      final services = _call(init(), 'UiServices(');
      expect(
        services,
        _wired(
          r'\n\s*initialSetupLink: launchLinkOnce\(appLinks\.getInitialLink\),',
        ),
      );
      expect(services, _wired(r'\n\s*setupLinks: appLinks\.uriLinkStream,'));
      expect(init(), _wired(r'\n\s*final appLinks = AppLinks\(\);'));
      // Nothing else reads the plugin's initial link: not the shell, and
      // not another line of di.dart.
      final lib = Directory('${_appRoot().path}/lib');
      final readers = <String>[];
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final code = file
            .readAsLinesSync()
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');
        final found = 'getInitialLink'.allMatches(code).length;
        for (var i = 0; i < found; i++) {
          readers.add(file.path.substring(lib.parent.path.length + 1));
        }
      }
      expect(readers, ['lib/ui/di.dart']);
    });

    // Android 13 and later's per-app language and the app's Language row
    // are one setting (app_language_sync_test covers what it decides):
    // agreed at every launch, on Android only, before the first frame. It
    // writes preferences, so after the notification ask's settling, which
    // must see those an earlier version left; and before the services that
    // start at launch. The background engine never runs it.
    test('Android agrees the app language with Android at launch', () {
      final body = init();
      const start =
          'if (Platform.isAndroid) await AppLanguageSync.startForApp(settings);';
      expect(start.allMatches(body), hasLength(1));
      expect('AppLanguageSync'.allMatches(body), hasLength(1));
      expect(body.indexOf(start),
          greaterThan(body.indexOf('await settleNotificationAskAtLaunch();')));
      expect(body.indexOf(start),
          greaterThan(body.indexOf('retireWatchCameraRoll(')));
      for (final later in [
        'if (Platform.isIOS) {',
        'final analyzer =',
        'await syncBackgroundScan(settings);',
      ]) {
        expect(body.indexOf(later), greaterThan(body.indexOf(start)),
            reason: later);
      }
      expect(_source('lib/ui/background_glue.dart'),
          isNot(contains('AppLanguageSync')));
    });
  });

  // R6b: the restaurant assist lives in the app engine, reads the real
  // pipeline, analyzer and registry, counts against the app's daily ledger,
  // and looks once the launch catch-up's photos are in.
  group('the restaurant assist (MealAssist)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('di.dart builds it from the real pipeline, analyzer and registry',
        () {
      expect(
        init(),
        _wired(
          r'final analyzer = MultiProviderAnalyzer\(settings, '
          r'lookupBudget: assistBudget\);',
        ),
      );
      expect(
        init(),
        _wired(
          r'final assistBudget = AssistDailyBudget\('
          r'await SharedPreferences\.getInstance\(\)\);',
        ),
      );
      final source = init();
      final from = source.indexOf('final mealAssist = MealAssist(');
      expect(from, isNot(-1));
      final build = source.substring(from, source.indexOf('\n    );\n', from));
      for (final wire in [
        r'dao: dao,',
        r'lookups: analyzer,',
        r'analyzerBusy: analyzer\.analyzerBusy,',
        r'pipelineIdle: \(\) => pipeline\.isIdle,',
        r'inUse: mealInUse\.isInUse,',
        r'budget: assistBudget,',
        r'state: AssistLocalState\.platform\(\),',
        r'mealsChanged: mealsChangedSignal,',
        r'onMealsChanged: signalMealsChanged,',
        r'inForeground: appEngineInForeground,',
        // The region: the locale name's, else the preferred languages'
        // (review 2026-10-25: a region-less 'zh_Hans' read as not the US);
        // on Android 13 and later from the phone's own languages, which a
        // language picked for the app never changes (review of PR 79:
        // 中文 (中国) picked in Android's settings read as CN).
        r'country: \(\) => phoneRegion\( phoneLocales: '
            r'PhoneSettings\.locales, localeName: Platform\.localeName, '
            r'countryCodes: PlatformDispatcher\.instance\.locales\.map\(\(l\) '
            r'=> l\.countryCode\) \),',
        r'repliesInChinese: \(\) => settings\.repliesInChinese,',
        // R6c: the location path is iOS only; Android is brand-only.
        r'location: Platform\.isIOS \? PhotoLocationReader\(photoLibrary\) '
            r': null,',
        r'places: Platform\.isIOS \? MapKitPlaces\(\) : null,',
        r'placesStore: AssistPlacesStore\.platform\(\),',
        // R7a: the mode, 'Use photo location' and the consent, read fresh
        // from the real settings on every decision (through the one view
        // usual foods reads too, pinned below).
        r'settings: assistSettingsView,',
      ]) {
        expect(build, _wired(wire), reason: wire);
      }
      expect(
        source,
        _wired(
          r'AssistSettingsView assistSettingsView\(\) => AssistSettingsView\( '
          r'mode: AssistMode\.fromWire\(settings\.restaurantAssist\), '
          r'useLocation: settings\.restaurantAssistLocation, '
          r'consentAt: settings\.restaurantAssistConsentAt, '
          r'consentRecipient: settings\.restaurantAssistConsentRecipient, '
          r'\);',
        ),
      );
      // The meal country's time zone is the phone's own (MealAssist's
      // default, DateTime.now().timeZoneOffset): di passes no other.
      expect(build, isNot(contains('utcOffset')));
      expect(build, isNot(contains('AssistSettingsView.off')),
          reason: 'R7a stores the settings: the assist reads them');
      // R7a: Settings' Restaurant nutrition group and the consent sheets
      // see the same analyzer, MealAssist and server; the location only on
      // iOS; and the shell gets them through UiServices.
      final controlsAt = source.indexOf(
          'final restaurantAssist = RestaurantAssistControls(');
      expect(controlsAt, isNot(-1));
      final controls = source.substring(
          controlsAt, source.indexOf('\n    );\n', controlsAt));
      for (final wire in [
        r'lookupSupport: analyzer\.lookupSupport,',
        r'clearLearnedPlaces: mealAssist\.clearLearnedPlaces,',
        r'consentNeeded: mealAssist\.consentNeeded,',
        r'serverState: \(\) async => '
            r'assistServerStateOf\(await serverAnalyzer\.serverFeatures\(\)\),',
        r'locationSupported: Platform\.isIOS,',
        // Review (run 6): Settings says why nothing would be looked up.
        r'whereNow: mealAssist\.whereNow,',
      ]) {
        expect(controls, _wired(wire), reason: wire);
      }
      expect(init(), _wired(r'restaurantAssist: restaurantAssist,'));
      expect(init(), _wired(r'mealAssist\.start\(\);'));
      expect(
        init(),
        _wired(
          r'unawaited\(launchCatchUp\(\) '
          r'\.whenComplete\(\(\) => unawaited\(mealAssist\.sweep\(\)\)\)',
        ),
      );
      expect(init(), _wired(r'if \(!catchingUp\) unawaited\(mealAssist\.sweep\(\)\);'));
    });

    test('background_glue.dart never references it, and its PhotoPipeline '
        'is built as before', () {
      final glue = _source('lib/ui/background_glue.dart');
      for (final banned in [
        'MealAssist',
        'meal_assist',
        'assist_local_state',
        'AssistDailyBudget',
        'lookupNow',
        'services/assist/',
        // R6c: no photo position or places query in the background engine.
        'PhotoLocationReader',
        'photo_location',
        'MapKitPlaces',
        'PlaceResolver',
        'services/places/',
        'AssistPlacesStore',
        // R7a: no consent sheet, Settings group or their seams either.
        'RestaurantAssistControls',
        'restaurant_assist_controls',
        'restaurant_consent_sheet',
      ]) {
        expect(glue, isNot(contains(banned)), reason: banned);
      }
      final after = _body(glue, 'Future<bool> _runAfterLaunch({');
      expect(
        after,
        _wired(r'pipeline: \(\) async => inFlight\.pipeline = PhotoPipeline\('),
      );
      // 2026-11-28: the same analyzer, now sending through the run's own
      // client (the pin on that argument is with the headless run's, below).
      expect(
        after,
        _wired(
          r'analyzer: createMultiProviderAnalyzer\(settings, '
          r'client: inFlight\.traffic\),',
        ),
      );
    });

    test('the pipeline constructor takes nothing from the assist', () {
      final pipeline = _source('lib/ui/photo_pipeline.dart');
      final from = pipeline.indexOf('\n  PhotoPipeline(\n');
      expect(from, isNot(-1));
      final ctor = pipeline.substring(
          from, pipeline.indexOf('_clock = clock ?? DateTime.now;', from));
      expect(ctor, isNot(contains('ssist')));
      expect(pipeline, isNot(contains('meal_assist')));
      expect(pipeline, contains('bool get isIdle =>'));
    });
  });

  // The owner's requirement before PR #19 ships (docs/RELEASING.md):
  // Settings › Stop Sharing with … says "nothing more is sent to …", so it
  // also stops the restaurant assist when its lookups go to that recipient.
  // The behaviour is tested through fakes and the real settings
  // (restaurant_assist_settings_test, stop_sharing_assist_test,
  // meal_assist_test). These pin the lines that make it true in the app:
  // another branch rewrites settings_screen.dart, and a merge that kept the
  // wrong side of these lines would leave lookups running after the stop.
  group('Stop Sharing also stops the restaurant assist', () {
    String stopSharing() => _body(
      _source('lib/ui/screens/settings_screen.dart'),
      'Future<void> _stopSharing() async {',
      indent: '  ',
    );

    test('the row stops the assist first, then withdraws the AI consent: '
        'nothing awaited before, nothing skipped in between', () {
      final body = stopSharing();
      final confirmed = body.indexOf('if (stop != true || !mounted) return;');
      expect(confirmed, isNot(-1));
      final after = body.substring(confirmed);
      final assist = RegExp(
        r'await\s+stopRestaurantAssistFor\(\s*s,\s*widget\.restaurantAssist,'
        r'\s*route,?\s*\);',
      ).firstMatch(after);
      final consent = RegExp(
        r'await\s+s\.setAiConsent\(\s*route,\s*granted:\s*false,?\s*\);',
      ).firstMatch(after);
      expect(assist, isNotNull, reason: 'the assist is stopped');
      expect(consent, isNotNull, reason: 'the AI consent is withdrawn');
      // No lookup reads the AI consent: only the assist's own mode and
      // consent stop one, so they go first.
      expect(assist!.start, lessThan(consent!.start));
      // The route is read after the dialog, and the assist's write starts
      // with nothing awaited before it: the settings say Off at once.
      final before = after.substring(0, assist.start);
      expect(before, _wired(r'final route = currentAiConsentRoute\(s\);'));
      expect(before, isNot(contains('await')));
      // A stop that began is finished: no way out between the two steps.
      final between = after.substring(assist.end, consent.start);
      expect(between, isNot(contains('return')));
      expect(between, isNot(contains('mounted')));
      expect(between, isNot(contains('await')));
      // The dialog says what will happen, from the same rule.
      expect(
        body.substring(0, confirmed),
        _wired(
          r'restaurantAssistStopFor\( s, widget\.restaurantAssist, '
          r'currentAiConsentRoute\(s\)\) \.turnOff;',
        ),
      );
    });

    test('nothing else withdraws an AI consent: the only call is the '
        "row's", () {
      final lib = Directory('${_appRoot().path}/lib');
      final withdrawals = <String>[];
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final found = RegExp(
          r'granted:\s*false',
        ).allMatches(file.readAsStringSync()).length;
        for (var i = 0; i < found; i++) {
          withdrawals.add(file.path.substring(lib.parent.path.length + 1));
        }
      }
      expect(withdrawals, ['lib/ui/screens/settings_screen.dart']);
      expect(stopSharing(), contains(RegExp(r'granted:\s*false')));
    });

    test('the engine sends through one poll and one submit, each behind '
        'the consent read again with nothing awaited in between', () {
      final source = _source('lib/services/assist/meal_assist.dart');
      expect('_lookups.poll('.allMatches(source), hasLength(1));
      expect('_lookups.submit('.allMatches(source), hasLength(1));
      const submit =
          'outcome = await _submit(request, settings, support, token);';
      expect(submit.allMatches(source), hasLength(2));
      expect('_submit('.allMatches(source), hasLength(3),
          reason: 'its declaration and the two calls in _run');
      // The check is the gate's own consent rule on freshly read settings.
      expect(
        source,
        _wired(
          r'bool _maySend\(int gen, LookupSupport support, '
          r'\{required bool manual\}\) => '
          r'_current\(gen, manual: manual\) && '
          r'_readSettings\(\)\.consentCovers\(support\);',
        ),
      );

      final run = _body(source, 'Future<_Run> _run(', indent: '  ');
      const check =
          r'if \(!_maySend\(gen, support, manual: manual\)\) '
          r'return _Run\.cancelled;';
      // Right before the send: the check, then the token, then the call.
      final send = RegExp(
        '$check\\s*final token = LookupCancelToken\\(\\);',
      ).firstMatch(run);
      expect(send, isNotNull, reason: 'the check at the send');
      const poll = 'outcome = await _lookups.poll(jobId);';
      expect(poll.allMatches(run), hasLength(1));
      expect(
        run.indexOf('await', send!.end),
        run.indexOf(poll) + 'outcome = '.length,
        reason: 'nothing is awaited between the check and the poll',
      );
      // A job the server lost is sent again only behind the same check,
      // and a refused resubmit ends the run as cancelled.
      expect(
        run,
        contains(
          RegExp(
            'if \\(outcome\\.needsResubmit\\) \\{(\\s*//[^\\n]*)*\\s*$check'
            '\\s*polled = false;\\s*${RegExp.escape(submit)}',
          ),
        ),
      );
      // The first submit follows the same check with nothing awaited: it
      // is the other branch of the poll.
      expect(
        run,
        contains(RegExp('\\} else \\{\\s*${RegExp.escape(submit)}\\s*\\}')),
      );
      // Every submit and the poll come after the check at the send.
      expect(run.indexOf(submit), greaterThan(send.end));
      expect(run.indexOf(poll), greaterThan(send.end));
    });

    // Without the controls the row cannot tell who a lookup reaches, and
    // fails closed (the assist goes Off whenever it is on).
    test('the app shell hands the assist to the Settings screen', () {
      final screen = _call(_source('lib/ui/app.dart'), 'SettingsScreen(');
      expect(screen, _wired(r'settings: s\.settings,'));
      expect(screen, _wired(r'restaurantAssist: s\.restaurantAssist,'));
    });
  });

  // Usual foods (spec T47, Lane C): worked out on the phone, app engine
  // only. The behaviour of usualLookupTakesIt is tested per branch in
  // usual_foods_test; these pin the lines that hand it the real settings
  // and lookup support, and keep the background engine and the photo
  // pipeline free of it.
  group('usual foods', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('di.dart builds one UsualFoods over one UsualChoices, with the '
        'lookup rule, and hands it to the screens', () {
      final di = _source('lib/ui/di.dart');
      expect('UsualFoods('.allMatches(di), hasLength(1));
      expect('UsualChoices('.allMatches(di), hasLength(1));
      final build = _call(init(), 'UsualFoods(');
      for (final wire in [
        r'dao: dao,',
        r'choices: UsualChoices\(await SharedPreferences\.getInstance\(\)\),',
        r'mealsChanged: mealsChangedSignal,',
        r'onMealsChanged: signalMealsChanged,',
        // Off decides first: the lookup client is not asked who a lookup
        // would reach (that builds it) while lookups are off.
        r'lookupTakesIt: \(analysis\) \{ '
            r'final view = assistSettingsView\(\); '
            r'if \(view\.mode == AssistMode\.off\) return false; '
            r'return usualLookupTakesIt\(analysis, '
            r'settings: view, support: analyzer\.lookupSupport\(\)\); '
            r'\},',
      ]) {
        expect(build, _wired(wire), reason: wire);
      }
      expect(build, isNot(contains('clock')),
          reason: 'the device clock, as every other service');
      expect(init(), _wired(r'usualFoods: usualFoods,'));
      final today = _call(_source('lib/ui/app.dart'), 'TodayScreen(');
      expect(today, _wired(r'usual: s\.usualFoods\)'));
    });

    test('background_glue.dart never references it, and the photo '
        'pipeline takes nothing from it', () {
      final glue = _source('lib/ui/background_glue.dart');
      for (final banned in [
        'services/usual',
        'usual_foods',
        'usual_choices',
        'UsualFoods',
        'UsualChoices',
        'usualLookupTakesIt',
      ]) {
        expect(glue, isNot(contains(banned)), reason: banned);
      }
      final pipeline = _source('lib/ui/photo_pipeline.dart');
      expect(pipeline, isNot(contains('sual')));
      final from = pipeline.indexOf('\n  PhotoPipeline(\n');
      expect(from, isNot(-1));
      final ctor = pipeline.substring(
          from, pipeline.indexOf('_clock = clock ?? DateTime.now;', from));
      expect(ctor, isNot(contains('sual')));
    });
  });

  // Edit meal's note (Correct with a note, owner 2026-11-24): the shell
  // hands the app engine's executor — the kept-alive one on Android
  // (di.dart) — to Today and to History, whose editors offer the note
  // only with it. usual: s.usualFoods stays Today's last argument.
  group('Edit meal note', () {
    test('Today and History get the executor as the note corrector', () {
      final app = _source('lib/ui/app.dart');
      final today = _call(app, 'TodayScreen(');
      expect(today, _wired(r'noteCorrector: noteCorrectorOf\(s\.executor\),'));
      expect(today, _wired(r'usual: s\.usualFoods\)'));
      final history = _call(app, 'HistoryScreen(');
      expect(history,
          _wired(r'noteCorrector: noteCorrectorOf\(s\.executor\)\)'));
    });

    test('History hands it to the day, and Today and the day to the editor',
        () {
      expect(_call(_source('lib/ui/screens/history_screen.dart'),
              'DayDetailScreen('),
          _wired(r'noteCorrector: widget\.noteCorrector,'));
      for (final screen in ['today_screen.dart', 'day_detail_screen.dart']) {
        expect(
            _call(_source('lib/ui/screens/$screen'), 'MealEditorScreen('),
            _wired(r'noteCorrector: widget\.noteCorrector,'),
            reason: screen);
      }
    });
  });

  group('lib/ui/app.dart (the resume catch-up)', () {
    test('is foregroundCatchUp, stopping on iOS once the app is left', () {
      final resume = _body(
        _source('lib/ui/app.dart'),
        'Future<void> _resumeCatchUp() async {',
        indent: '  ',
      );
      expect(
        resume,
        _wired(
          r'if \(await backup\?\.holdsCatchUp\(\) \?\? false\) return; '
          r'await foregroundCatchUp\(intake, shouldContinue: '
          r'Platform\.isIOS \? \(\) => appEngineInForeground\(\) && '
          r'!\(backup\?\.holdsCatchUpNow \?\? false\) : null\)',
        ),
      );
      expect(resume, isNot(contains('.backfillScan(')));
    });

    // Review of PR 79 (F1, F3): Android 13 and later take the FlutterView's
    // 12/24-hour clock from the app's own language once it has one. Every
    // time under the app's MaterialApp, Report Time's picker included,
    // reads the phone's own (format.dart PhoneClockScope).
    test("the app's MaterialApp tells time by the phone's own clock", () {
      final app = _source('lib/ui/app.dart');
      // Over every screen, with or without the View-after-share listener
      // (#80) around it.
      expect(
        app,
        _wired(
          r'builder: \(context, child\) \{ final styled = PhoneClockScope\( '
          r'child: _SystemNavBarStyle\( dimming: _dimming, child: child \?\? '
          r'const SizedBox\.shrink\(\)\)\); if \(!reveals\) return styled;',
        ),
      );
      expect(
        app,
        _wired(
          r'return NotificationListener<NavigationNotification>\( '
          r'onNotification: \(_\) \{ _routes\.popChanged\(\); return false; '
          r'\}, child: styled\); \},',
        ),
      );
      expect('PhoneClockScope('.allMatches(app), hasLength(1));
    });
  });

  // App Store 5.1.2(i), review run 7: a shared photo waits for the AI
  // consent through this gate. PR #19 rewrites the same line, and a merge
  // that keeps its side would send shared photos unasked with every
  // behavioural test still green (they drive the gate directly).
  group('lib/ui/di.dart (the AI consent for shared photos)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('a shared photo goes through the gate, built on the app\'s own '
        'store and handed to the app shell', () {
      // The gate is told the intake's deliveries, so one Not now covers a
      // whole share and its unread copies are deleted unread.
      expect(
        init(),
        _wired(
          r'pipeline\.bindStream\(\s*shareConsent\.gate\('
          r'shareIntake\.photos\(\),\s*deliveries:\s*shareIntake\)\);',
        ),
      );
      expect(
        init(),
        isNot(_wired(r'bindStream\(shareIntake\.photos\(\)\)')),
        reason: 'no second, ungated subscription to the share sheet',
      );
      expect(
        init(),
        _wired(r'final shareConsent = SharedPhotoConsentGate\(store\);'),
      );
      expect(init(), _wired(r'\n\s*settings: store,'));
      expect(init(), _wired(r'\n\s*sharedPhotoConsent: shareConsent,'));
    });

    // Review 2026-11-20 (Q9 under predictive back): the shell's guard keeps
    // Back at the root from letting Android finish the activity while a
    // shared photo is pending (test/ui/shared_photos_back_test.dart, which
    // builds its own services). Without this line the guard is off on the
    // phone with every behavioural test still green.
    test('the share intake\'s pending photos reach the shell, on Android',
        () {
      expect(
        init(),
        _wired(
          r'\n\s*sharedPhotosPending: Platform\.isAndroid \? '
          r'shareIntake\.photosPending : null,',
        ),
      );
    });

    // Owner decision 9 (2026-11-20): on Android an analysis the user
    // started keeps the process running and online until it settles
    // (test/services/analysis_keep_alive_test.dart and the leftover and
    // shell tests build their own). Without one of these lines, that
    // request freezes with the app again, with every behavioural test still
    // green: the pipeline's deliberate photos, typed meals and Fix meals
    // requests (the executor every screen gets), and the leftover estimate
    // and the shell's Back guard (UiServices). One instance: its id space
    // and the shell's in-flight flag are the engine's.
    test('analyses the user starts keep the app alive, on Android only', () {
      final source = init();
      expect(
        source,
        _wired(
          r'\n\s*final keepAlive = Platform\.isAndroid \? '
          r'AnalysisKeepAlive\(\) : null;',
        ),
      );
      expect(RegExp(r'AnalysisKeepAlive\(').allMatches(source), hasLength(1));
      expect(
        source,
        _wired(
          r'\n\s*final textExecutor = createExecutor\(dao, analyzer, settings\);'
          r'\s*final executor = keepAlive == null \? textExecutor : '
          r'KeptAliveExecutor\(textExecutor, keepAlive\);',
        ),
      );
      expect(_call(source, 'PhotoPipeline('),
          _wired(r'\n\s*keepAlive: keepAlive,'));
      final services = _call(source, 'UiServices(');
      expect(services, _wired(r'\n\s*executor: executor,'));
      expect(services, _wired(r'\n\s*analysisKeepAlive: keepAlive,'));
      // The background engine never keeps itself alive this way: its job
      // has its own time.
      final glue = _source('lib/ui/background_glue.dart');
      expect(glue, isNot(contains('AnalysisKeepAlive')));
      expect(glue, isNot(contains('keepAlive')));
    });
  });

  // Release-candidate review of 1.6.0: an admitted photo can still be
  // queued when Stop Sharing is confirmed or the provider changes, so both
  // engines' pipelines read the consent again at the send (AiSendGate;
  // behaviour in test/ui/ai_send_gate_test.dart, which builds its own
  // pipelines). Dropping either line below sends those photos again with
  // every behavioural test still green.
  group('the AI consent is read again at the send', () {
    test('the app engine: over its own settings, never re-read from disk',
        () {
      final init = _body(
        _source('lib/ui/di.dart'),
        'static Future<AppServices> init(',
        indent: '  ',
      );
      expect(init, _wired(r'\n\s*sendGate: aiSendGateFor\(settings\),'));
    });

    test('the background run: re-read from disk before each send', () {
      final after = _body(
        _source('lib/ui/background_glue.dart'),
        'Future<bool> _runAfterLaunch({',
      );
      expect(
        after,
        _wired(
          r'\n\s*sendGate: aiSendGateFor\(settings, rereadFromDisk: true\),',
        ),
      );
    });

    test('the adapter: the active recipient is allowed, or no key is set; '
        'a disk re-read only on request', () {
      // An expression-bodied function: from its name to its semicolon.
      final glue = _source('lib/ui/background_glue.dart');
      final from = glue.indexOf('AiSendGate aiSendGateFor(');
      expect(from, isNot(-1));
      final expr = glue.substring(from, glue.indexOf(';', from) + 1);
      expect(
        expr,
        _wired(
          r"allowed: \(\) => \(settings\.activeApiKey \?\? ''\)\.trim\(\)"
          r'\.isEmpty \|\| settings\.hasAiConsent\('
          r'settings\.activeAiConsentRoute\),',
        ),
      );
      expect(
        expr,
        _wired(r'refresh: rereadFromDisk \? settings\.reloadAiConsent : null,'),
      );
    });

    test('the pipeline: from the last check to the analyzer call nothing '
        'awaits, and a held verdict is exempt at both checks', () {
      final pipeline = _source('lib/ui/photo_pipeline.dart');
      final process = _body(
        pipeline,
        'Future<PhotoOutcome> _process(IntakePhoto photo,',
        indent: '  ',
      );
      // Early: before the photo is hashed or reserved.
      final early = process.indexOf(
        'if (held == null && !_sendAllowed()) return _notAllowed;',
      );
      expect(early, isNot(-1));
      expect(early, lessThan(process.indexOf('await _hash(photo.bytes)')));
      expect(early, lessThan(process.indexOf('dao.reservePhotoHash(')));
      // At the send: the disk re-read, then the check, then the call.
      final refresh = process.indexOf(
        'if (held == null) await _refreshSendGate();',
      );
      final late = process.indexOf(
        'if (held == null && !_sendAllowed()) {',
      );
      final send = process.indexOf('await analyzer.analyzePhoto(');
      expect(refresh, isNot(-1));
      expect(late, greaterThan(refresh));
      expect(send, greaterThan(late));
      expect(
        process.indexOf('analyzer.analyzePhoto('),
        process.lastIndexOf('analyzer.analyzePhoto('),
        reason: 'one send in the pipeline',
      );
      final blocked = process.indexOf('return _notAllowed;', late);
      final afterBranch = process.indexOf('}', blocked) + 1;
      expect(blocked, inInclusiveRange(late, send));
      expect(
        process.substring(afterBranch, send),
        isNot(contains('await')),
        reason: 'a consent withdrawn in between would not be seen',
      );
    });
  });

  // Play push, 2026-11-13: Android's summary is an OS card too (an
  // inexact alarm), armed and re-armed like the iPhone's; it used to come
  // from a Timer or the 30-minute photo job, late or never.
  group('the daily summary is an OS card on both phones', () {
    test('di.dart arms it on Android too, posting a card left past its '
        'slot first, and the shell and slot edits re-arm it', () {
      final init = _body(
        _source('lib/ui/di.dart'),
        'static Future<AppServices> init(',
        indent: '  ',
      );
      expect(
        init,
        _wired(
          r'final osSchedulesSummary = Platform\.isIOS \|\| Platform\.isAndroid;',
        ),
      );
      expect(
        init,
        _wired(
          r'Future<void> armOsSummary\(\) => armOsDailySummary\( dao: dao, '
          r'settings: settings, notifier: notifier, '
          r'android: Platform\.isAndroid\);',
        ),
      );
      expect(
        init,
        _wired(
          r'refreshDailyNotification: osSchedulesSummary \? armOsSummary : null,',
        ),
      );
      expect(
        init,
        _wired(
          r'onReportTimeChanged: osSchedulesSummary \? armOsSummary : null\);',
        ),
      );
    });

    // Android 13+ asks for the notification permission once, in context:
    // the first meal saved with the app in front is one of the moments
    // (notification_permission.dart). Never in a background run. On the
    // meals-changed signal, which every save path sends (review
    // 2026-11-19: Describe, manual entry and usual foods never reached the
    // pipeline's hook); notification_ask_on_save_test drives those paths.
    test('di.dart asks after a meal saved, by any path, while the summary '
        'or the watcher would notify', () {
      final init = _body(
        _source('lib/ui/di.dart'),
        'static Future<AppServices> init(',
        indent: '  ',
      );
      expect(init, _wired(r'onMealSaved: signalMealsChanged,'));
      expect(
        init,
        _wired(
          r'mealsChangedSignal\.addListener\(\(\) => unawaited\( '
          r'askNotificationPermissionAfterMealSaved\( '
          r'notifies: \(\) => '
          r'settings\.summaryEnabled \|\| settings\.watcherEnabled, '
          r'hasMeal: \(\) async => '
          r'\(await dao\.backupCounts\(\)\)\.meals > 0\)\)\);',
        ),
      );
      // An upgrader counts as asked: settled right after the settings
      // load, before anything this launch writes preferences
      // (notification_permission_test covers what it decides).
      expect(
        init,
        _wired(
          r'final settings = await AppSettings\.load\(\);\s*'
          r'(//[^\n]*\n\s*)*await settleNotificationAskAtLaunch\(\);\s*'
          r'final MealsDao dao = await createMealsDao\(\);',
        ),
      );
      final glue = _source('lib/ui/background_glue.dart');
      expect(glue, isNot(contains('askNotificationPermissionOnce')));
      expect(glue, isNot(contains('settleNotificationAskAtLaunch')));
      expect(glue, isNot(contains('requestNotificationsPermission')));
      expect(_source('lib/services/report/notifications.dart'),
          isNot(contains('requestNotificationsPermission')),
          reason: 'init runs at every start, in every engine');
    });

    // Review (finding 12b): Settings' notifications-off row asks about the
    // summary's own channel too (summaryNotificationsEnabled, behaviour-
    // tested in notifications_test).
    test('Settings reads whether the summary itself can be delivered', () {
      expect(
        _source('lib/ui/di.dart'),
        _wired(r'notificationsEnabled: notifier\.summaryNotificationsEnabled,'),
      );
    });

    // The Play push: meal cards have their own channel, named in the app
    // language like the summary's, in both engines. PR80-B2: so is the
    // summary over two or more Logged meals cards (Android).
    test('both engines name both channels in the app language', () {
      for (final path in ['lib/ui/di.dart', 'lib/ui/background_glue.dart']) {
        final source = _source(path);
        expect(
          source,
          _wired(
            r'channelStrings: \(\) => notificationChannelFor\(settings\.appLanguage\), '
            r'mealChannelStrings: \(\) => '
            r'mealNotificationChannelFor\(settings\.appLanguage\),',
          ),
          reason: path,
        );
        expect(
          source,
          _wired(
            r'mealGroupStrings: \(\) => '
            r'mealGroupSummaryFor\(settings\.appLanguage\),',
          ),
          reason: path,
        );
      }
    });

    test('the background run re-arms it on both platforms and posts '
        'nothing itself', () {
      final glue = _source('lib/ui/background_glue.dart');
      final after = _body(glue, 'Future<bool> _runAfterLaunch({');
      // The re-arm itself (fresh settings, both platforms) is behaviour-
      // tested through rearmSummaryAfterRun; here, that the run uses it,
      // after the scan, and hands it to Android's deadline.
      // On Android in the run's language while the app and Android agree
      // as they did when the run began (review of PR 79, below).
      expect(
        after,
        _wired(
          r'inFlight\.rearm = \(\) => rearmSummaryAfterRun\( prefs: prefs, '
          r'settings: settings, notifier: notifier, openDao: createMealsDao, '
          r'ios: ios, languageAgreedAtStart: languageAgreed\);',
        ),
      );
      expect(after, _wired(r'\n  await inFlight\.rearm!\(\);'));
      expect(glue, isNot(contains('postHeadlessSummary')));
      expect(glue, isNot(contains('maybePostDailySummary')));
      expect(glue, isNot(contains('showDailySummary')));
    });
  });

  group('lib/ui/background_glue.dart (the headless run)', () {
    String glue() => _source('lib/ui/background_glue.dart');
    String launch() => _body(glue(), 'Future<bool> runHeadlessBackfill({');
    String after() => _body(glue(), 'Future<bool> _runAfterLaunch({');

    // Review of PR 78, UXC-2: only the app engine moves keys (between
    // keychain classes, and an upload key an earlier version stored into
    // its item), and the ordering that lets the two engines load at once
    // holds with one mover alone. The tests pass these flags themselves,
    // so dropping them here kept the whole suite green.
    test('the run loads its settings with key stores that only read', () {
      expect(
        after(),
        _wired(
          r'AppSettings\.load\( keyStore: platformKeyStore\(migrate: false\), '
          r'readOnlyKeys: true\)',
        ),
      );
      expect(glue(), isNot(contains('platformKeyStore()')));
      expect(
        _body(glue(), 'Future<AppSettings> summarySettingsNow('),
        _wired(
          r'AppSettings\.load\( prefs: prefs, keyStore: const _NoKeys\(\), '
          r'readOnlyKeys: true\)',
        ),
      );
      expect('readOnlyKeys: false'.allMatches(glue()), isEmpty);
    });

    // Review of PR 79 (F2): a language picked for the app in Android 13+'s
    // settings reached only the app engine, at its next launch, and the
    // run's cards, channels and meal names stayed in the one turned off
    // there. The run takes it as soon as its settings are loaded, before
    // anything builds a card, a channel or an analyzer, and on Android
    // only; the summary it re-arms keeps it while nothing was agreed
    // since. Nothing here writes the language: the app engine's sync is
    // the only writer.
    test("the run takes a language picked in Android's settings, read only",
        () {
      final body = after();
      const take = 'final languageAgreed = '
          'takeAndroidLanguageForRun(settings, prefs, android: !ios);';
      final at = body.replaceAll(RegExp(r'\s+'), ' ').indexOf(take);
      expect(at, isNot(-1));
      final flat = body.replaceAll(RegExp(r'\s+'), ' ');
      expect(flat.indexOf('settings = await (loadSettings ??'),
          lessThan(at));
      for (final later in [
        'final notifier = ReportNotifier(',
        'ok = await headlessBackfillWith(',
        // Its second argument is the run's client (2026-11-28).
        'createMultiProviderAnalyzer(settings,',
      ]) {
        expect(flat.indexOf(later), greaterThan(at), reason: later);
      }
      expect(body, _wired(r'languageAgreedAtStart: languageAgreed\)'));
      expect(
        _body(glue(), 'Future<AppSettings> summarySettingsNow('),
        _wired(
          r'if \(agreedAtStart != null && '
          r'prefs\.getString\(appLanguageAndroidPrefsKey\) == agreedAtStart\) '
          r'\{ takeAndroidLanguageForRun\(now, prefs, android: true\); \}',
        ),
      );
      expect(glue(), isNot(contains('setAppLanguage(')));
      expect(glue(), isNot(contains('AppLanguageSync')));
      // The language for a run is the background engine's alone.
      for (final f in Directory('${_appRoot().path}/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final path = f.path.substring(_appRoot().path.length + 1);
        if (path == 'lib/ui/background_glue.dart' ||
            path == 'lib/services/settings/app_settings.dart') {
          continue;
        }
        expect(f.readAsStringSync(), isNot(contains('takeLanguageForRun(')),
            reason: path);
        expect(f.readAsStringSync(),
            isNot(contains('takeAndroidLanguageForRun(')),
            reason: path);
      }
    });

    // 2026-11-28: the call gained two arguments. On iOS the scan counts a
    // photo a meal already names covered without reading it (it used to be
    // only the late-import pass that did), and the record hears how many;
    // Android's run still reads them (scanSkipsLogged: ios, never true).
    test('the intake passes over what the run deferred too often, skips '
        'what a meal already names on iOS only, and the run notes what it '
        'defers', () {
      expect(
        after(),
        _wired(
          r'intake: createPhotoIntake\(settings, onBackfillListed: '
          r'recorder\.listed, passOver: deferred\.passOver, '
          r'loggedAssetIds: inFlight\.loggedAssetIds, '
          r'(//[^\n]*\n\s*)*'
          r'scanSkipsLogged: ios, '
          r'onScanSkippedLogged: recorder\.alreadyLogged\)',
        ),
      );
      // The app's own engine does not: its scans are as they were.
      expect(
        _body(
          _source('lib/ui/di.dart'),
          'static Future<AppServices> init(',
          indent: '  ',
        ),
        isNot(contains('scanSkipsLogged')),
      );
      expect(after(), _wired(r'\n\s*deferred: deferred,'));
      expect(
        after(),
        _wired(
          r'final deferred = inFlight\.deferred = await DeferredAssets\.load\(prefs\);',
        ),
      );
    });

    test('iOS: undecodable photos are deferred, the offer budget applies, '
        'and the deadline releases the photo in flight', () {
      expect(after(), _wired(r'deferUndecodable: ios\)'));
      // G2b: a glasses preview copy waits once there too.
      expect(after(), _wired(r'previewHold: holdGlassesPreview, '));
      // G3: the switch as the run loaded it, the food check on iOS (on the
      // CPU, or deferred to the app), and the Glasses check record.
      expect(
          after(), _wired(r'includeGlasses: \(\) => settings\.watchGlasses, '));
      expect(after(), _wired(r'foodCheck: ios \? foodScoreViaImageIO : null, '));
      expect(after(), _wired(r'glassesCheckLog: recordGlassesCheckLocally, '));
      // Android's offer budget too (review 171, Play push).
      expect(
        after(),
        _wired(r'budget: ios \? iosBackgroundBudget : androidBackgroundBudget,'),
      );
      expect(
        after(),
        _wired(r'pipeline: \(\) async => inFlight\.pipeline = PhotoPipeline\('),
      );
      // Both platforms go through the wrapper, each with its deadline.
      expect(
        launch(),
        _wired(
          r'final runDeadline = ios \? iosRunDeadline : androidRunDeadline;',
        ),
      );
      expect(
        launch(),
        _wired(
          r'return finishWithinGrant\(run, left: startedAt\.add\(runDeadline\)'
          r'\.difference\(clock\(\)\), recorder: recorder, '
          r'abandon: ios \? inFlight\.abandon : inFlight\.endAtDeadline, '
          r'abandonLimit: ios \? iosAbandonLimit : androidDeadlineWrapUp\);',
        ),
      );
      expect(launch(), isNot(contains('if (!ios) return run;')));
    });

    // G1b: photos other apps imported late, with the budget the scan left.
    test('the run takes late imports after its scan, under its budget', () {
      final headless = _body(glue(), 'Future<bool> headlessBackfillWith({');
      expect(
        headless,
        _wired(
          r'final drain = await drainBackfill\([^;]*\n\s*lateImports: true,',
        ),
      );
      final drain = _body(glue(), 'Future<BackfillDrain> drainBackfill(');
      expect(
        drain,
        _wired(
          r'scanCompleted = true;[^}]*if \(lateImports && roomLeft\(\)\) \{\s*'
          r'try \{\s*await intake\.lateImportScan\('
          r'shouldContinue: timed \? budgetLeft : null\);',
        ),
      );
      final catchUp = _body(glue(), 'Future<DateTime?> foregroundCatchUp(');
      expect(
        catchUp,
        _wired(
          r'\} finally \{[^}]*if \(shouldContinue\?\.call\(\) \?\? true\) \{\s*'
          r'try \{\s*await intake\.lateImportScan\('
          r'shouldContinue: shouldContinue\);',
        ),
      );
    });

    // Review, 2026-10-19: without these the run admits a photo that cannot
    // finish, and every deadline cut counts against the photo, so a slow
    // patch of the server passes photos over for good. Review 2026-11-19:
    // Android's window is its own (one full own-server attempt); iOS's
    // 15 s counted every Android cut.
    test('a photo that cannot finish by the deadline is not started, and a '
        'cut counts only for a photo that had the platform\'s full window',
        () {
      expect(
        launch(),
        _wired(
          r'final inFlight = RunInFlight\( deadline: '
          r'startedAt\.add\(runDeadline\), '
          r'window: ios \? slowPhotoWindow : androidSlowPhotoWindow, '
          r'clock: clock\);',
        ),
      );
      expect(after(), _wired(r'\n\s*finishBy: inFlight\.deadline,'));
      expect(after(), _wired(r'\n\s*photoOffered: inFlight\.offered,'));
    });

    // 2026-11-28: the run's own meals-changed signal has no listener (it
    // is another engine), so a meal it saved while the app was open stayed
    // invisible until the next return to the app. The run leaves a note
    // and the app looks for it (refresh_signal.dart; the note, the look
    // and the shell are behaviour-tested in other_engine_meals_test).
    // Without these lines nothing is ever written or looked for, and that
    // suite stays green.
    test('the run leaves word of a meal it saved, and the app looks for it '
        'after each photo of its scan and from the shell', () {
      expect(
        after(),
        _wired(r'final localStore = LocalNoBackupStore\.platform\(\);'),
      );
      expect(
        after(),
        _wired(
          r'onMealSaved: \(\) => '
          r'unawaited\(noteMealsChangedForOtherEngine\(localStore\)\),',
        ),
      );
      final init = _body(
        _source('lib/ui/di.dart'),
        'static Future<AppServices> init(',
        indent: '  ',
      );
      expect(
        init,
        _wired(
          r'final otherEngineMeals = '
          r'OtherEngineMeals\(store: LocalNoBackupStore\.platform\(\)\); '
          r'await otherEngineMeals\.prime\(\);',
        ),
      );
      // Primed before the pipeline, the scans and the screens exist.
      expect(
        init.indexOf('await otherEngineMeals.prime();'),
        lessThan(init.indexOf('final pipeline = PhotoPipeline(')),
      );
      expect(
        init,
        _wired(
          r'unawaited\(clearDeferredAsset\(photo\.assetId\)\); \} '
          r'(//[^\n]*\n\s*)*'
          r'unawaited\(otherEngineMeals\.check\(\)\); \},',
        ),
      );
      // The shell's looks: only while a background scan can exist.
      expect(
        init,
        _wired(
          r'mealsChangedElsewhere: photoLibraryInBuild \? \(\) => '
          r'settings\.watcherEnabled \? '
          r'otherEngineMeals\.check\(force: true\) : '
          r'Future<bool>\.value\(false\) : null,',
        ),
      );
    });

    // 2026-11-28: a cut with the full window counted whatever the run had
    // been waiting for, so three hung or busy runs passed a photo over.
    // The run's deadline now goes by what its analyzer sent for the photo
    // (RunInFlight.abandon, behaviour-tested in background_glue_test with
    // a real analyzer). That evidence exists only if the analyzer sends
    // through the run's client: without this argument nothing is ever
    // seen as sent, and every cut counts again, with the suite green.
    test('the run\'s analyzer sends through the run\'s own client, which the '
        'deadline reads', () {
      expect(
        after(),
        _wired(
          r'analyzer: createMultiProviderAnalyzer\(settings, '
          r'client: inFlight\.traffic\),',
        ),
      );
      final inFlight = _body(glue(), 'class RunInFlight {');
      expect(
        inFlight,
        _wired(r'void offered\(\) \{ _offeredAt = _clock\(\); '
            r'traffic\.next\(\); \}'),
      );
      expect(
        inFlight,
        _wired(r'final cutAt = traffic\.cutOffAt; '
            r'final assetId = await pipeline\?\.abandon\(\);'),
      );
      expect(
        inFlight,
        _wired(r'if \(cutAt != CutOffAt\.preparing\) return;'),
      );
    });
  });

  // The Google Play build (owner decision 1, 2026-11-13): one switch,
  // `--dart-define=CHOPSTATS_CHANNEL=play`. The behaviour is tested both
  // ways through debugAppChannelOverride (play_channel_test and the
  // screens' suites); these pins hold the lines that hand the switch to
  // production, which no widget test runs: AppServices.init and the
  // background run open real plugins.
  group('the Google Play build (core/app_channel.dart)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('production reads the compile-time define; only tests override it',
        () {
      final channel = _source('lib/core/app_channel.dart');
      expect(
        channel,
        contains(
          "const String kAppChannelDefine = "
          "String.fromEnvironment('CHOPSTATS_CHANNEL');",
        ),
      );
      expect(
        channel,
        _wired(
          r'AppChannel get appChannel => debugAppChannelOverride \?\? '
          r"\(kAppChannelDefine == 'play' && Platform\.isAndroid "
          r'\? AppChannel\.play : AppChannel\.github\);',
        ),
      );
      expect(
        channel,
        _wired(
          r'bool get photoLibraryInBuild => appChannel != AppChannel\.play;',
        ),
      );
      for (final file
          in Directory(
            '${_appRoot().path}/lib',
          ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        expect(
          file.readAsStringSync(),
          isNot(contains('debugAppChannelOverride =')),
          reason: '${file.path} sets the test override',
        );
      }
    });

    // After the notification ask's settling (which must see the launch's
    // preferences unwritten) and the launch sweep, before anything reads
    // the switch.
    test('di.dart turns a GitHub install\'s Watch Camera Roll off at '
        'launch, before anything starts it', () {
      final body = init();
      expect(
        body,
        _wired(
          r'await dao\.reclaimStaleProcessing\(\);\s*'
          r'(//[^\n]*\n\s*)*'
          r'final prefs = await SharedPreferences\.getInstance\(\);\s*'
          r'try \{ await retireWatchCameraRoll\(settings, prefs\); \}',
        ),
      );
      expect(
        body.indexOf('await settleNotificationAskAtLaunch();'),
        lessThan(body.indexOf('retireWatchCameraRoll(')),
      );
      expect('settings.watcherEnabled'.allMatches(
              body.substring(0, body.indexOf('retireWatchCameraRoll('))),
          isEmpty,
          reason: 'nothing reads the switch before it is settled');
      final retire = body.indexOf('retireWatchCameraRoll(');
      for (final later in [
        'await photoIntake.start();',
        'launchCatchUp()',
        'await syncBackgroundScan(settings);',
      ]) {
        expect(body.indexOf(later), greaterThan(retire), reason: later);
      }
      // And whatever the setting, the live watcher and the launch catch-up
      // never start in that build: both sit behind this one check.
      expect(
        body,
        _wired(
          r'if \(settings\.watcherEnabled && photoLibraryInBuild\) \{ '
          r'await photoIntake\.start\(\);',
        ),
      );
      expect(
        body.indexOf('if (settings.watcherEnabled && photoLibraryInBuild)'),
        lessThan(body.indexOf('launchCatchUp()')),
      );
      // Nor the resume catch-up.
      expect(
        _body(
          _source('lib/ui/app.dart'),
          '  void didChangeAppLifecycleState(AppLifecycleState state) {',
          indent: '  ',
        ),
        _wired(
          r'if \(!s\.settings\.watcherEnabled \|\| !photoLibraryInBuild\) '
          r'return; unawaited\(_resumeCatchUp\(\)\);',
        ),
      );
    });

    test('di.dart never asks for photo access in the Play build, and wires '
        'its one notice', () {
      final body = init();
      expect(
        body,
        _wired(
          r'Future<bool> requestPhotos\(\) async => photoLibraryInBuild && '
          r'await photoLibrary\.requestPermission\(\);',
        ),
      );
      expect(
        body,
        _wired(
          r'watchRetiredNotice: photoLibraryInBuild \? null : OwedNotice\( '
          r'pending: \(\) => watchRetiredNoticeOwed\(prefs\), '
          r'shown: \(\) => watchRetiredNoticeShown\(prefs\)\)',
        ),
      );
      expect(body, contains('requestPhotoPermission: requestPhotos,'));
      // No meal-card channel either (notifications_test covers what it does).
      expect(body, _wired(r'mealCards: photoLibraryInBuild,'));
      // No library for the screens either: no meal thumbnails looked up,
      // no coverage auditor, no library handed to Settings or Log.
      expect(
        body,
        _wired(
          r'MealThumbResolver\( dao: dao, '
          r'library: photoLibraryInBuild \? photoLibrary : null\)',
        ),
      );
      expect(
        body,
        _wired(r'coverage: photoLibraryInBuild \? CoverageAuditor\('),
      );
      expect(
        body,
        _wired(r'photoLibrary: photoLibraryInBuild \? photoLibrary : null,'),
      );
    });

    test('the job is never wanted there, and the launch sync cancels it', () {
      expect(
        _source('lib/services/photo/background.dart'),
        _wired(
          r'bool backgroundJobWanted\(\{required bool watcherEnabled\}\) => '
          r'\(debugIsIOSOverride \?\? Platform\.isIOS\) \|\| '
          r'\(watcherEnabled && photoLibraryInBuild\);',
        ),
      );
      expect(
        _source('lib/ui/background_glue.dart'),
        _wired(
          r'enableBackgroundScan\( '
          r'backgroundJobWanted\(watcherEnabled: settings\.watcherEnabled\),',
        ),
      );
    });

    test('the background run, should the old job run first: the move, no '
        'scan, and its own cancel', () {
      final run = _body(
        _source('lib/ui/background_glue.dart'),
        'Future<bool> _runAfterLaunch({',
      );
      expect(
        run,
        _wired(
          r'if \(!photoLibraryInBuild\) \{ '
          r'try \{ await retireWatchCameraRoll\(settings, prefs\); \} '
          r'catch \(_\) \{[^}]*\} '
          r'await recorder\.finish\(BackgroundStop\.watcherOff\); '
          r'try \{ await syncBackgroundScan\(settings\); \} catch \(_\) \{'
          r'[^}]*\} return true; \}',
        ),
      );
      expect(
        run.indexOf('if (!photoLibraryInBuild)'),
        lessThan(run.indexOf('createPhotoIntake(')),
        reason: 'before any intake (or library read) exists',
      );
    });

    test('the shell says it once: at launch, on a return to the app, and '
        'once the shell is back on top', () {
      final app = _source('lib/ui/app.dart');
      final shell = app.substring(app.indexOf('class _HomeShellState'));
      expect(
        _body(shell, '  void initState() {', indent: '  '),
        contains('_tellWatchRetiredWhenIdle();'),
      );
      expect(
        _body(
          app,
          '  void didChangeAppLifecycleState(AppLifecycleState state) {',
          indent: '  ',
        ),
        _wired(
          r'if \(_leftApp\) \{[^}]*_tellWatchRetiredWhenIdle\(\);[^}]*\}',
        ),
      );
      // Other calls may follow it (the meal a reveal waits to show).
      expect(
        app,
        _wired(
          r'_OnRouteReturn\( onReturn: \(\) \{ _onBackupPrompt\(\); '
          r'_tellWatchRetiredWhenIdle\(\); [^}]*\}',
        ),
      );
    });

    test('the screens leave the library alone: no Photos group in Settings, '
        'and the picker alone in Log and Leftovers', () {
      final settings = _source('lib/ui/screens/settings_screen.dart');
      expect(
        settings,
        _wired(r'if \(photoLibraryInBuild\) \.\.\._photoGroup\(theme\),'),
      );
      expect('_photoGroup(theme)'.allMatches(settings), hasLength(1));
      expect(
        settings,
        _wired(r'if \(lib == null \|\| !photoLibraryInBuild\) return;'),
      );
      for (final screen in [
        'lib/ui/screens/add_flow.dart',
        'lib/ui/screens/leftover_flow.dart',
      ]) {
        final source = _source(screen);
        expect(
          source,
          _wired(
            r'final full = photoLibraryInBuild && '
            r'await system\.hasBroadAccess\(\);',
          ),
          reason: screen,
        );
        expect(
          'hasBroadAccess()'.allMatches(source),
          hasLength(1),
          reason: '$screen reads broad access in one place',
        );
      }
      expect(
        _source('lib/ui/screens/settings/provider_page.dart'),
        _wired(r'channel: Platform\.isAndroid \? appChannel : null,'),
      );
    });
  });

  // Android, view-after-share lane: the View on a shared photo's snackbar
  // and a tap on a Logged meals card go to the meal (ui/meal_reveal.dart;
  // test/ui/view_after_share_test.dart and meal_reveal_test.dart build
  // their own). Without one of these lines View or the tap does nothing on
  // the phone, with every behavioural test still green; and iOS keeps both
  // as they were.
  group('the meal a View or a card tap asks for (Android)', () {
    String init() => _body(
      _source('lib/ui/di.dart'),
      'static Future<AppServices> init(',
      indent: '  ',
    );

    test('one MealReveals, on Android only, handed to the shell', () {
      final source = init();
      expect(
        source,
        _wired(
          r'\n\s*final mealReveals = Platform\.isAndroid \? '
          r'MealReveals\(\) : null;',
        ),
      );
      expect(RegExp(r'MealReveals\(').allMatches(source), hasLength(1));
      expect(source, _wired(r'\n\s*mealReveals: mealReveals,'));
    });

    test("a shared photo's snackbar is worded by outcomeAnnouncer, with "
        "main.dart's View sink", () {
      expect(
        init(),
        _wired(
          r'outcomeAnnouncer\( l10n: \(\) => '
          r'localizationsFor\(settings\.appLanguage\), notify: notify, '
          r'reveals: mealReveals, notifyView: notifyView\)',
        ),
      );
      expect(
        _source('lib/main.dart'),
        _wired(r'notifyView: showAppSnackbarWithView,'),
      );
    });

    test('a card tapped while the app runs, and one that started it, ask '
        'for its meal', () {
      final source = init();
      expect(
        source,
        _wired(
          r'\n\s*final cardTaps = mealReveals == null \? null : '
          r'MealCardTaps\(mealReveals\);',
        ),
      );
      expect(source, _wired(r'\n\s*onTap: cardTaps\?\.onTap,'));
      expect(
        source,
        _wired(
          r'await notifier\.init\(\); '
          r'await cardTaps\.launch\(notifier\.launchPayload\);',
        ),
      );
    });

    test("the background run's cards carry their meal to the plugin", () {
      final glue = _source('lib/ui/background_glue.dart');
      expect(
        glue,
        _wired(
          r'showMealCard: \(title, body, \{payload\}\) async \{[^}]*'
          r'await notifier\.showMealCard\(title, body, payload: payload\);',
        ),
      );
      expect(glue, _wired(r'payload: revealForMeal\(o\)\?\.payload\)'));
    });
  });

  // Review 171, C7: the fake schedulers see the policy enableBackgroundScan
  // asks for; only this line hands it to WorkManager. Without it the plugin
  // default applies (UPDATE in workmanager_android 0.9.0+2, but a default
  // can change under an upgrade).
  test('WorkmanagerScheduler hands the work policy to WorkManager', () {
    final source = _source('lib/services/photo/background.dart');
    expect(
      _body(source, 'class WorkmanagerScheduler implements'),
      _wired(
        r'Workmanager\(\)\.registerPeriodicTask\(uniqueName, taskName, '
        r'frequency: frequency, inputData: inputData, '
        r'existingWorkPolicy: existingWorkPolicy,',
      ),
    );
  });

  // Review 171, C4: on Android the photo library keeps a photo imported
  // late (taken before a scan's own cutoff, added after it) while it was
  // taken inside the lookback window. Without the window's start the live
  // watcher and the background run leave it to the next launch, and the
  // library's own field is private to the intake.
  test('createPhotoIntake gives the photo library the lookback window\'s '
      'start', () {
    expect(
      _body(
        _source('lib/services/photo/watcher.dart'),
        'PhotoIntake createPhotoIntake(',
      ),
      _wired(
        r'library: PhotoManagerLibrary\( windowStart: \(\) => '
        r'lookbackCutoff\(DateTime\.now\(\), settings\.lookbackDays\)\),',
      ),
    );
  });

  // Review 171, C5: on Android, share intake reads and deletes only the
  // copies MainActivity makes in the cache's share folder (share_intake
  // _test pins the folder). Without this argument a path of the sender's
  // making (a '..' name, a share's text) was read and deleted again: the
  // meal database, the settings.
  test('createShareIntake keeps Android\'s share intake to the share '
      'folder', () {
    expect(
      _call(
        _source('lib/services/photo/share_intake.dart'),
        'createShareIntake(AppSettings settings) => ShareIntake(',
      ),
      _wired(
        r'sharedFolder: Platform\.isAndroid \? androidSharedPhotoFolder '
        r': null\)$',
      ),
    );
  });

  // Behavioural where it can be: the factory's own fields are public.
  test(
    'createPhotoIntake hands passOver and onBackfillListed to the intake',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: _Keys(),
      );
      bool passOver(String id) => id == 'x';
      void listed(int n) {}
      final intake =
          createPhotoIntake(
                settings,
                onBackfillListed: listed,
                passOver: passOver,
              )
              as LibraryPhotoIntake;
      expect(intake.passOver, same(passOver));
      expect(intake.onBackfillListed, same(listed));
      // 2026-11-28: off unless asked for (the app's own engine, Android).
      expect(intake.scanSkipsLogged, isFalse);
      expect(intake.onScanSkippedLogged, isNull);
    },
  );

  test(
    'createPhotoIntake hands scanSkipsLogged and its count hook to the '
    'intake',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: _Keys(),
      );
      void skipped(int n) {}
      final intake =
          createPhotoIntake(
                settings,
                scanSkipsLogged: true,
                onScanSkippedLogged: skipped,
              )
              as LibraryPhotoIntake;
      expect(intake.scanSkipsLogged, isTrue);
      expect(intake.onScanSkippedLogged, same(skipped));
    },
  );

  test(
    'createPhotoIntake hands loggedAssetIds over, and reads the change '
    'history (with its diagnostics record) on iOS only',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: _Keys(),
      );
      Future<Set<String>> logged(List<String> ids) async => {};
      bool held() => false;
      final ios =
          createPhotoIntake(
                settings,
                loggedAssetIds: logged,
                liveHeld: held,
                isIOS: true,
              )
              as LibraryPhotoIntake;
      expect(ios.loggedAssetIds, same(logged));
      expect(ios.liveHeld, same(held));
      expect(ios.lateImports, isNotNull);
      expect(ios.lateImports!.store, isNotNull);
      expect(ios.onLateImportPass, equals(recordLateImportPass));
      // G2a/G2b: the album lookup and the added dates ride the same channel.
      expect(ios.metaAlbumIds, isNotNull);
      expect(ios.assetAddedDate, isNotNull);
      // RC 1.6.0: the live late-import pass reads a photo only while an
      // automatic analysis could succeed (canAutoAnalyze), like every
      // other automatic trigger.
      final gate = ios.liveLateShouldContinue!;
      expect(settings.canAutoAnalyze, isFalse, reason: 'no key yet');
      expect(gate(), isFalse);
      await settings.setGeminiApiKey('test-key');
      expect(settings.canAutoAnalyze, isTrue);
      expect(gate(), isTrue);
      final android =
          createPhotoIntake(settings, loggedAssetIds: logged, isIOS: false)
              as LibraryPhotoIntake;
      expect(android.lateImports, isNull);
      expect(android.onLateImportPass, isNull);
      expect(android.metaAlbumIds, isNull);
      expect(android.assetAddedDate, isNull);
      expect(android.liveLateShouldContinue, isNull);
    },
  );

  testWidgets(
    'the live late-import gate is closed while the app is in the '
    'background, even with a key',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: _Keys(),
      );
      await settings.setGeminiApiKey('test-key');
      final gate =
          (createPhotoIntake(settings, isIOS: true) as LibraryPhotoIntake)
              .liveLateShouldContinue!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(gate(), isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(gate(), isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(gate(), isTrue);
    },
  );
}
