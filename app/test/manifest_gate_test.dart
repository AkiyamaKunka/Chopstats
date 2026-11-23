import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/services/analysis_keep_alive.dart'
    show keepAliveChannelName;
import 'package:calorie_tracker/services/analyzer/platform_decode.dart'
    show imageIOChannelName;
import 'package:calorie_tracker/services/local_store.dart'
    show localStoreDirName;
import 'package:calorie_tracker/services/photo/background_time.dart'
    show backgroundTimeChannelName;
import 'package:calorie_tracker/services/photo/photo_changes.dart'
    show photoChangesChannelName;
import 'package:calorie_tracker/services/photo/share_intake.dart'
    show androidRefusalTokens, androidRefusedSharePath, androidRefusedShareType;
import 'package:calorie_tracker/services/places/places.dart'
    show placesChannelName;
import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:calorie_tracker/ui/app.dart' show systemBarsChannelName;
import 'package:calorie_tracker/ui/background_glue.dart'
    show backgroundNativeLaunchPrefsKey;
import 'package:flutter_test/flutter_test.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

List<String> _plistStrings(String plist, String key) {
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<array>(.*?)</array>',
    dotAll: true,
  ).firstMatch(plist);
  expect(match, isNotNull, reason: '$key missing from Info.plist');
  return RegExp(r'<string>([^<]*)</string>')
      .allMatches(match!.group(1)!)
      .map((m) => m.group(1)!)
      .toList();
}

/// The body of the `project.pbxproj` object `ID /* comment */ = { isa = ...;
/// ... };` at object depth (two tabs); [id] narrows it when the comment is
/// shared, e.g. the two `Resources` build phases.
String _pbxObject(
  String pbxproj, {
  String id = '[0-9A-F]{24}',
  required String comment,
  required String isa,
}) {
  final match = RegExp(
    '\\n\\t\\t$id /\\* ${RegExp.escape(comment)} \\*/ = \\{\\s*isa = $isa;'
    '(.*?)\\n\\t\\t\\};',
    dotAll: true,
  ).firstMatch(pbxproj);
  expect(match, isNotNull, reason: 'project.pbxproj has no $isa "$comment"');
  return match!.group(1)!;
}

String _mainActivity() => File('${_appRoot().path}/android/app/src/main/'
        'kotlin/dev/calorietracker/calorie_tracker/MainActivity.kt')
    .readAsStringSync();

String _intakeRules() => File('${_appRoot().path}/android/app/src/main/'
        'kotlin/dev/calorietracker/calorie_tracker/IntakeRules.kt')
    .readAsStringSync();

/// The app's own Kotlin sources (android/app/src/main), by file name.
Map<String, String> _appKotlin() => {
      for (final f in Directory('${_appRoot().path}/android/app/src/main/'
              'kotlin/dev/calorietracker/calorie_tracker')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt')))
        f.uri.pathSegments.last: f.readAsStringSync(),
    };

/// [kotlin] with its comments removed (string literals kept) and every run
/// of whitespace collapsed to one space, so a pin matches code only: a
/// commented-out line no longer satisfies it, and a reflow breaks nothing.
String _kotlinCode(String kotlin) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < kotlin.length) {
    final c = kotlin[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < kotlin.length) {
        out.write(kotlin[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (kotlin.startsWith('//', i)) {
      final end = kotlin.indexOf('\n', i);
      i = end < 0 ? kotlin.length : end;
      continue;
    }
    if (kotlin.startsWith('/*', i)) {
      final end = kotlin.indexOf('*/', i + 2);
      i = end < 0 ? kotlin.length : end + 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The braced body of the function whose declaration starts with
/// [declaration] in [code] (from [_kotlinCode]), braces included; '' for
/// an expression body. Fails when the declaration is missing or repeated.
String _kotlinFunction(String code, String declaration) {
  expect(declaration.allMatches(code), hasLength(1), reason: declaration);
  final start = code.indexOf(declaration);
  // The parameter list, then a return type or not, then { or =.
  var depth = 0;
  var i = code.indexOf('(', start);
  for (; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')' && --depth == 0) break;
  }
  final open = code.indexOf('{', i);
  final equals = code.indexOf('=', i);
  if (equals >= 0 && equals < open) return '';
  String? quote;
  depth = 0;
  for (var j = open; j < code.length; j++) {
    final c = code[j];
    if (quote != null) {
      if (c == r'\') {
        j++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return code.substring(open, j + 1);
    }
  }
  fail('$declaration has no closing brace');
}

/// The JVM tests (android/app/src/test) exercise each of [rules], in
/// [suite] (IntakeRulesTest unless named).
void _expectJvmTests(List<String> rules, {String suite = 'IntakeRulesTest'}) {
  final test = File('${_appRoot().path}/android/app/src/test/kotlin/dev/'
      'calorietracker/calorie_tracker/$suite.kt');
  expect(test.existsSync(), isTrue, reason: test.path);
  final source = test.readAsStringSync();
  for (final rule in rules) {
    expect(source, contains(rule), reason: '$suite never runs $rule');
  }
}

/// Where pub resolved [package] (.dart_tool/package_config.json), so a
/// gate can read the plugin version the app actually builds with.
String _pluginRoot(String package) {
  final config = jsonDecode(
      File('${_appRoot().path}/.dart_tool/package_config.json')
          .readAsStringSync()) as Map<String, Object?>;
  final entry = (config['packages'] as List)
      .cast<Map<String, Object?>>()
      .firstWhere((p) => p['name'] == package);
  final root = Uri.parse(entry['rootUri'] as String);
  return root.isAbsolute
      ? root.toFilePath()
      : Directory('${_appRoot().path}/.dart_tool')
          .uri
          .resolveUri(root)
          .toFilePath();
}

String _manifest() =>
    File('${_appRoot().path}/android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

/// [xml] without its comments, so a comment that names a permission or a
/// component never satisfies (or trips) a gate.
String _uncommented(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// The two forms a manifest asks for a permission with:
/// `<uses-permission>`, and `<uses-permission-sdk-23>` (asked for on
/// Android 6 and later only). The manifest merger and aapt2 tell them
/// apart: a tools:node="remove" on one form leaves the other in.
const _permissionForms = ['uses-permission', 'uses-permission-sdk-23'];

/// Every permission entry in [xml] in either form: (form, name, whether it
/// is a `tools:node="remove"`).
Set<(String, String, bool)> _permissionEntries(String xml) => {
      for (final m in RegExp(r'<(uses-permission(?:-sdk-23)?)\s([^>]*)>')
          .allMatches(_uncommented(xml)))
        (
          m.group(1)!,
          RegExp(r'android:name="([^"]+)"').firstMatch(m.group(2)!)!.group(1)!,
          m.group(2)!.contains('tools:node="remove"'),
        ),
    };

/// Every permission in [manifest], in either form, by name: true when the
/// entry is a `tools:node="remove"` (it strips a library's permission from
/// the merged manifest rather than declaring one).
Map<String, bool> _permissions(String manifest) => {
      for (final (_, name, remove) in _permissionEntries(manifest))
        name: remove,
    };

/// The permissions [manifest] declares (removals left out).
Set<String> _declared(String manifest) => {
      for (final e in _permissions(manifest).entries)
        if (!e.value) e.key,
    };

/// What the Google Play build's manifest overlay removes
/// (android/app/src/playChannel/AndroidManifest.xml): the three photo
/// permissions. The GitHub APK keeps them.
const _playRemoved = {
  'android.permission.READ_MEDIA_IMAGES',
  'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
  'android.permission.READ_EXTERNAL_STORAGE',
};

/// Release-manifest drift gate.
///
/// Flutter auto-injects INTERNET into the DEBUG and PROFILE manifests (for
/// hot reload / VM service), so debug- and profile-mode testing can never
/// catch a missing network permission — the release APK shipped without
/// internet once and every Gemini call died with "Error contacting Gemini"
/// while all E2E stayed green. The MAIN manifest must declare what release
/// actually needs.
void main() {
  test('main AndroidManifest declares the permissions release needs', () {
    final declared = _declared(_manifest());
    for (final permission in [
      'android.permission.INTERNET',
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.POST_NOTIFICATIONS',
    ]) {
      expect(declared.contains(permission), isTrue,
          reason: '$permission missing from the MAIN manifest — debug/profile '
              'builds get it auto-injected, release does not.');
    }
  });

  // Every permission is a Play review question (and a Data safety answer),
  // so none arrives unnoticed. The system photo picker, Save to device
  // and the notification-settings link need none.
  test('the main manifest declares exactly these permissions', () {
    expect(_declared(_manifest()), {
      'android.permission.INTERNET',
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
      'android.permission.READ_EXTERNAL_STORAGE',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.RECEIVE_BOOT_COMPLETED',
    });
  });

  // The notification small icon is only ever named from Dart, which the
  // release resource shrinker cannot see. A drawable stripped from the
  // release APK makes initialize() fail with invalid_icon, the callers'
  // catch blocks swallow it, and Android notifications silently stop in
  // release only. Android also renders the small icon from its alpha
  // channel, so any colour other than white would just be lost.
  test('the notification small icon is white-only and kept in release', () {
    final res = '${_appRoot().path}/android/app/src/main/res';
    final icon = File('$res/drawable/${ReportNotifier.androidSmallIcon}.xml');
    expect(icon.existsSync(), isTrue, reason: '${icon.path} missing');
    final xml = icon.readAsStringSync();
    final colours = RegExp(r'android:(?:fill|stroke)Color="([^"]+)"')
        .allMatches(xml)
        .map((m) => m.group(1)!.toUpperCase())
        .toSet();
    expect(colours, isNotEmpty);
    expect(colours.difference({'#FFFFFFFF', '#FFFFFF', '#FFF'}), isEmpty,
        reason: 'small icons are alpha masks; found $colours');

    final keep = File('$res/raw/keep.xml');
    expect(keep.existsSync(), isTrue,
        reason: 'res/raw/keep.xml missing: release shrinking strips the icon');
    final kept = RegExp(r'tools:keep="([^"]*)"')
        .firstMatch(keep.readAsStringSync())
        ?.group(1)
        ?.split(',')
        .map((e) => e.trim());
    expect(
        kept,
        anyOf(contains('@drawable/${ReportNotifier.androidSmallIcon}'),
            contains('@drawable/*')));
  });

  // The tab screens are laid out portrait-first and do not apply side
  // safe-area insets: rotated, an iPhone drew the calorie ring and the first
  // History bar under the Dynamic Island, and the large title plus the tab bar
  // left only the top of one card visible. The iPhone list is portrait-only.
  // The app is iPhone-only (2026-10-12, owner's App Store decision): both
  // targets are TARGETED_DEVICE_FAMILY = 1 and there is no ~ipad list, so
  // App Review never sees a stretched phone layout on an iPad. Adding iPad
  // back is allowed later; removing it after an iPad build shipped is not.
  test('Info.plist locks iPhone to portrait and the app is iPhone-only', () {
    final plist = File('${_appRoot().path}/ios/Runner/Info.plist')
        .readAsStringSync();
    expect(_plistStrings(plist, 'UISupportedInterfaceOrientations'),
        ['UIInterfaceOrientationPortrait']);
    expect(plist.contains('UISupportedInterfaceOrientations~ipad'), isFalse);
    final pbxproj =
        File('${_appRoot().path}/ios/Runner.xcodeproj/project.pbxproj')
            .readAsStringSync();
    final families = RegExp(r'TARGETED_DEVICE_FAMILY = ([^;]+);')
        .allMatches(pbxproj)
        .map((m) => m.group(1))
        .toList();
    expect(families, isNotEmpty);
    expect(families, everyElement('1'));
  });

  // RCREL-V-1 on the iPhone (review of #83, 2026-11-21): the
  // bitewise://setup link reaches the app through app_links only (its
  // example Info.plist sets this key). With the key missing, Flutter's own
  // deep linking is on: a link that arrives while the app runs is offered
  // to the plugins, none claims it (app_links returns NO by default), and
  // the engine pushes it to the framework as a route. A bare link became
  // "/" and pushed a second HomeShell, as on Android. A cold start is
  // spared today only because receive_sharing_intent claims every scene
  // connection.
  test('Info.plist turns Flutter deep linking off, so only app_links sees '
      'the setup link', () {
    final plist = File('${_appRoot().path}/ios/Runner/Info.plist')
        .readAsStringSync();
    expect(plist, contains('<string>bitewise</string>'));
    expect(
        RegExp(r'<key>FlutterDeepLinkingEnabled</key>\s*<false/>')
            .allMatches(plist),
        hasLength(1));
    expect('FlutterDeepLinkingEnabled'.allMatches(plist), hasLength(1),
        reason: 'set once');
    final extension = File(
            '${_appRoot().path}/ios/ShareExtension/Info.plist')
        .readAsStringSync();
    expect(extension, isNot(contains('FlutterDeepLinkingEnabled')),
        reason: 'the share extension runs no Flutter engine');

    // Flutter 3.44, where the SDK carries its sources: the engine reads
    // this key, treats a missing key as on, and checks it before it sends
    // a link to the framework.
    final source = Directory('${_pluginRoot('flutter')}/../../engine/src/'
        'flutter/shell/platform/darwin/ios/framework/Source');
    if (!source.existsSync()) {
      markTestSkipped('this Flutter SDK carries no engine sources');
      return;
    }
    String objc(String name) => File('${source.path}/$name')
        .readAsStringSync()
        .replaceAll(RegExp(r'//[^\n]*'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(
        objc('FlutterSharedApplication.mm'),
        contains('NSNumber* isDeepLinkingEnabled = [[NSBundle mainBundle] '
            'objectForInfoDictionaryKey:@"FlutterDeepLinkingEnabled"]; '
            'return isDeepLinkingEnabled ? [isDeepLinkingEnabled boolValue] '
            ': YES;'));
    expect(
        objc('FlutterSceneLifeCycle.mm'),
        contains('if (!FlutterSharedApplication.isFlutterDeepLinkingEnabled) '
            '{ return NO; } [engine sendDeepLinkToFramework:url'));
  });
  // App Store Connect scans every executable in the IPA for "required
  // reason" APIs and emails ITMS-91053 for each bundle that uses one without
  // a PrivacyInfo.xcprivacy beside it. Both targets do: receive_sharing_intent
  // (which ships no manifest) is compiled into the share extension and the
  // app with its UserDefaults(suiteName:) call, and photo_manager's PHAsset
  // reads leave the creationDate/modificationDate selectors in the app binary
  // (the FileTimestamp category). A plugin's own manifest only covers its
  // resource bundle, so the app and the extension each carry one, and Xcode
  // only copies it when the target's Resources phase lists it.
  test('both iOS targets ship a privacy manifest for the APIs they use', () {
    final ios = '${_appRoot().path}/ios';
    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    const categories = {
      'Runner': {
        'NSPrivacyAccessedAPICategoryUserDefaults',
        'NSPrivacyAccessedAPICategoryFileTimestamp',
      },
      'ShareExtension': {'NSPrivacyAccessedAPICategoryUserDefaults'},
    };
    categories.forEach((target, expected) {
      final file = File('$ios/$target/PrivacyInfo.xcprivacy');
      expect(file.existsSync(), isTrue, reason: '${file.path} missing');
      final plist = file.readAsStringSync();
      for (final key in [
        'NSPrivacyTracking',
        'NSPrivacyTrackingDomains',
        'NSPrivacyCollectedDataTypes',
        'NSPrivacyAccessedAPITypes',
      ]) {
        expect(plist.contains('<key>$key</key>'), isTrue,
            reason: '$key missing from $target/PrivacyInfo.xcprivacy');
      }
      final declared = {
        for (final m in RegExp(
          r'<key>NSPrivacyAccessedAPIType</key>\s*<string>([^<]+)</string>\s*'
          r'<key>NSPrivacyAccessedAPITypeReasons</key>\s*<array>(.*?)</array>',
          dotAll: true,
        ).allMatches(plist))
          m.group(1)!: RegExp(r'<string>([^<]*)</string>')
              .allMatches(m.group(2)!)
              .map((r) => r.group(1)!)
              .toList(),
      };
      expect(declared.keys, unorderedEquals(expected), reason: target);
      for (final reasons in declared.values) {
        expect(reasons, isNotEmpty, reason: target);
        for (final reason in reasons) {
          expect(reason, matches(RegExp(r'^[0-9A-F]{4}\.\d$')),
              reason: '$target declares "$reason", not an approved reason '
                  'code such as CA92.1');
        }
      }

      // target → its Resources phase → the PBXBuildFile → a PBXFileReference
      // that sits in the target's own group, so `path = PrivacyInfo.xcprivacy`
      // resolves to ios/<target>/PrivacyInfo.xcprivacy.
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Resources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Resources phase');
      final buildFileId =
          RegExp(r'([0-9A-F]{24}) /\* PrivacyInfo.xcprivacy in Resources \*/')
              .firstMatch(_pbxObject(pbxproj,
                  id: phaseId!,
                  comment: 'Resources',
                  isa: 'PBXResourcesBuildPhase'))
              ?.group(1);
      expect(buildFileId, isNotNull,
          reason: 'PrivacyInfo.xcprivacy is not in the $target target\'s '
              'Resources build phase, so Xcode never copies it');
      final fileRefId = RegExp('$buildFileId /\\* PrivacyInfo.xcprivacy in '
              'Resources \\*/ = \\{isa = PBXBuildFile; fileRef = ([0-9A-F]{24})')
          .firstMatch(pbxproj)
          ?.group(1);
      expect(fileRefId, isNotNull, reason: '$buildFileId has no fileRef');
      final group = _pbxObject(pbxproj, comment: target, isa: 'PBXGroup');
      expect(group, contains('path = $target;'));
      expect(group, contains('$fileRefId /* PrivacyInfo.xcprivacy */'),
          reason: 'the $target manifest reference is not in the $target '
              'group, so its path would resolve elsewhere');
    });
  });

  // The background scan decodes HEIC through ImageIOPlugin.swift: the
  // headless engine's GPU is off for the whole run, and dart:ui decoding
  // never finishes there (2026-10-18). Nothing in Dart can see a Swift file
  // that is missing from the Runner target, or a channel registered only in
  // the app's engine — the call just answers MissingPluginException and the
  // photo is deferred on every run. So: compiled into Runner (and only
  // Runner — the share extension has no Flutter engine), and registered in
  // BOTH registrant paths.
  test('the ImageIO plugin is built into Runner and registered for both '
      'engines', () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/ImageIOPlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    // The Dart side's channel (platform_decode.dart) is the one Swift serves.
    expect(swift.readAsStringSync(), contains('"$imageIOChannelName"'));
    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* ImageIOPlugin.swift \*/ = '
            r'\{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* ImageIOPlugin.swift */'),
        reason: 'not in the Runner group, so its path resolves elsewhere');
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* ImageIOPlugin.swift in '
            'Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    String sourcesOf(String target) {
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Sources phase');
      return _pbxObject(pbxproj,
          id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase');
    }

    expect(sourcesOf('Runner'),
        contains('$buildFile /* ImageIOPlugin.swift in Sources */'));
    expect(sourcesOf('ShareExtension'), isNot(contains('ImageIOPlugin')));

    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final workmanager = RegExp(
            r'setPluginRegistrantCallback \{ registry in(.*?)\n    \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(1);
    expect(workmanager, isNotNull);
    expect(workmanager, contains('registerAppPlugins(with: registry)'),
        reason: 'the headless background engine would lack the channel');
    final implicit = RegExp(
            r'func didInitializeImplicitFlutterEngine\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(implicit, isNotNull);
    expect(implicit,
        contains('registerAppPlugins(with: engineBridge.pluginRegistry)'));
    expect(delegate, contains('ImageIOPlugin.register(with:'));
  });

  // The app's photo in flight asks iOS for time to finish when the user
  // leaves (BackgroundTimePlugin.swift, 2026-10-19). A Swift file missing
  // from Runner answers MissingPluginException, which the Dart side
  // swallows by design — so nothing but this gate would notice.
  test('the background-time plugin is built into Runner and registered',
      () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/BackgroundTimePlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    final source = swift.readAsStringSync();
    expect(source, contains('"$backgroundTimeChannelName"'));
    // The expiration handler must END the task, or iOS kills the app —
    // through the plugin, and without it too (its engine gone).
    expect(
        RegExp(r'beginBackgroundTask\(withName: name\) \{[^}]*end\(token\)'
                r'[^}]*task\.end\(\)')
            .hasMatch(source),
        isTrue);
    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* BackgroundTimePlugin.swift '
            r'\*/ = \{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* BackgroundTimePlugin.swift */'));
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* BackgroundTimePlugin.swift '
            'in Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
        .firstMatch(
            _pbxObject(pbxproj, comment: 'Runner', isa: 'PBXNativeTarget'))
        ?.group(1);
    expect(
        _pbxObject(pbxproj,
            id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase'),
        contains('$buildFile /* BackgroundTimePlugin.swift in Sources */'));
    // The app's engine registers app-local plugins through this one path.
    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final register = RegExp(
            r'static func registerAppPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(register, contains('BackgroundTimePlugin.register(with:'));
  });

  // The photo library's change history (PhotoChangesPlugin.swift, design
  // G1a, 2026-10-23) is how photos another app imports late — glasses
  // photos the Meta AI app copies in hours later, keeping their capture
  // time — are found at all. A Swift file missing from Runner, or a
  // registration only one engine gets, answers MissingPluginException,
  // which the Dart side turns into a quiet 'error' by design; so the wiring
  // is pinned here. The background run reads the history too, hence both
  // engines (registerAppPlugins; its two callers are pinned above). And it
  // stays read-only: it never writes to the library, and never asks for
  // access, which from a background run would be a prompt nobody sees.
  test('the photo-changes plugin is built into Runner, registered for both '
      'engines, and read-only', () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/PhotoChangesPlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    final source = swift.readAsStringSync();
    expect(source, contains('"$photoChangesChannelName"'));
    for (final write in [
      'performChanges',
      'ChangeRequest',
      'requestAuthorization',
      'presentLimitedLibraryPicker',
    ]) {
      expect(source, isNot(contains(write)),
          reason: 'PhotoChangesPlugin must stay read-only and never prompt');
    }
    expect(source, contains('PHPhotoLibrary.authorizationStatus(for: '
        '.readWrite)'));

    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* PhotoChangesPlugin.swift '
            r'\*/ = \{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* PhotoChangesPlugin.swift */'),
        reason: 'not in the Runner group, so its path resolves elsewhere');
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* PhotoChangesPlugin.swift '
            'in Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    String sourcesOf(String target) {
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Sources phase');
      return _pbxObject(pbxproj,
          id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase');
    }

    expect(sourcesOf('Runner'),
        contains('$buildFile /* PhotoChangesPlugin.swift in Sources */'));
    expect(sourcesOf('ShareExtension'), isNot(contains('PhotoChangesPlugin')));

    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final register = RegExp(
            r'static func registerAppPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(register, contains('registrar(forPlugin: "PhotoChangesPlugin")'));
    expect(register, contains('PhotoChangesPlugin.register(with:'));
  });

  // Restaurant assist's places (PlacesPlugin.swift, design R4,
  // 2026-10-24): Apple Maps on the phone lists the food places around a
  // photo's position. A Swift file missing from Runner answers
  // MissingPluginException, which the Dart side turns into a quiet 'error'
  // by design, so the wiring is pinned here. And it must never need a
  // location permission: no CLLocationManager (the prompt), no geocoder
  // (no city or street, ever), no NSLocation* key in either Info.plist —
  // and on Android no location permission at all, ACCESS_MEDIA_LOCATION
  // included (v1 reads no photo location there).
  test('the places plugin is built into Runner, registered, and needs no '
      'location permission on either platform', () {
    final ios = '${_appRoot().path}/ios';
    final swift = File('$ios/Runner/PlacesPlugin.swift');
    expect(swift.existsSync(), isTrue, reason: '${swift.path} missing');
    final source = swift.readAsStringSync();
    expect(source, contains('"$placesChannelName"'));
    expect(source, contains('MKLocalPointsOfInterestRequest'));
    // The code, without its comments (which name what it never does).
    final full = source
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
        .join('\n');
    // The one part of an address it reads (run 6, the meal country): each
    // place's ISO country — the region of addressRepresentations on iOS
    // 26+, the placemark's isoCountryCode before — exactly here, once.
    const countryReads = [
      'let address: MKAddressRepresentations? = item.addressRepresentations',
      'let region: Locale.Region? = address?.region',
      'country = region?.identifier',
      'country = item.placemark.isoCountryCode',
    ];
    var code = full;
    for (final read in countryReads) {
      expect(read.allMatches(full), hasLength(1), reason: read);
      code = code.replaceFirst(read, '');
    }
    // Of a placemark, only its position and that country.
    expect(
        RegExp(r'placemark\.(?!location\b|isoCountryCode\b)').hasMatch(code),
        isFalse,
        reason: 'PlacesPlugin.swift reads more of a placemark');
    for (final banned in [
      'isoCountryCode',
      'fullAddress',
      'cityName',
      'cityWithContext',
      'regionName',
      'regionCode',
      'locality',
      'postalCode',
      'administrativeArea',
      'CLLocationManager',
      'CLGeocoder',
      'requestWhenInUseAuthorization',
      'requestAlwaysAuthorization',
      'requestLocation',
      'startUpdatingLocation',
      'MKReverseGeocodingRequest',
      'MKGeocodingRequest',
      'reverseGeocode',
      // Nothing that identifies or addresses a place goes back to Dart.
      'phoneNumber',
      '.identifier',
      'thoroughfare',
      'postalAddress',
      'addressRepresentations',
      'UserDefaults',
      'FileManager',
    ]) {
      expect(code, isNot(contains(banned)),
          reason: 'PlacesPlugin.swift must not use $banned');
    }

    final pbxproj =
        File('$ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final fileRef = RegExp(r'([0-9A-F]{24}) /\* PlacesPlugin.swift \*/ = '
            r'\{isa = PBXFileReference;')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(fileRef, isNotNull, reason: 'no PBXFileReference');
    expect(_pbxObject(pbxproj, comment: 'Runner', isa: 'PBXGroup'),
        contains('$fileRef /* PlacesPlugin.swift */'),
        reason: 'not in the Runner group, so its path resolves elsewhere');
    final buildFile = RegExp(r'([0-9A-F]{24}) /\* PlacesPlugin.swift in '
            'Sources \\*/ = \\{isa = PBXBuildFile; fileRef = $fileRef')
        .firstMatch(pbxproj)
        ?.group(1);
    expect(buildFile, isNotNull, reason: 'no PBXBuildFile');
    String sourcesOf(String target) {
      final phaseId = RegExp(r'([0-9A-F]{24}) /\* Sources \*/')
          .firstMatch(_pbxObject(pbxproj,
              comment: target, isa: 'PBXNativeTarget'))
          ?.group(1);
      expect(phaseId, isNotNull, reason: '$target has no Sources phase');
      return _pbxObject(pbxproj,
          id: phaseId!, comment: 'Sources', isa: 'PBXSourcesBuildPhase');
    }

    expect(sourcesOf('Runner'),
        contains('$buildFile /* PlacesPlugin.swift in Sources */'));
    expect(sourcesOf('ShareExtension'), isNot(contains('PlacesPlugin')));

    final delegate =
        File('$ios/Runner/AppDelegate.swift').readAsStringSync();
    final register = RegExp(
            r'static func registerAppPlugins\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(register, contains('registrar(forPlugin: "PlacesPlugin")'));
    expect(register, contains('PlacesPlugin.register(with:'));

    for (final target in ['Runner', 'ShareExtension']) {
      final plist =
          File('$ios/$target/Info.plist').readAsStringSync();
      expect(RegExp(r'<key>NSLocation[A-Za-z]*</key>').hasMatch(plist),
          isFalse,
          reason: '$target/Info.plist declares a location key: places need '
              'no location permission, and none may be asked for');
    }

    final manifest = File('${_appRoot().path}/android/app/src/main/'
            'AndroidManifest.xml')
        .readAsStringSync();
    for (final permission in [
      'ACCESS_MEDIA_LOCATION',
      'ACCESS_FINE_LOCATION',
      'ACCESS_COARSE_LOCATION',
      'ACCESS_BACKGROUND_LOCATION',
    ]) {
      expect(manifest, isNot(contains(permission)),
          reason: 'v1 reads no location on Android');
    }
  });

  // The iOS background run counts its time budgets from the moment
  // workmanager started its engine (2026-10-19): the AppDelegate stamps it
  // in the registrant callback, which runs right after the engine is
  // created and started and before Dart's task, under the name
  // shared_preferences gives the Dart key. A renamed key, or a stamp written later in the callback,
  // silently falls back to the Dart entry and the boot is uncounted again.
  test('the background launch stamp is written first, under the Dart key',
      () {
    final delegate = File('${_appRoot().path}/ios/Runner/AppDelegate.swift')
        .readAsStringSync();
    expect(delegate,
        contains('"flutter.$backgroundNativeLaunchPrefsKey"'));
    final callback = RegExp(
            r'setPluginRegistrantCallback \{ registry in\s*\n(\s*)(\S[^\n]*)')
        .firstMatch(delegate);
    expect(callback?.group(2), 'AppDelegate.stampBackgroundLaunch()');
  });

  // The backup-excluded local store (lib/services/local_store.dart, design
  // F1, 2026-10-23) holds state that hints at location or only works on
  // this device. Nothing at runtime notices a backup rule that went
  // missing — the app works the same, and the documents just start riding
  // along to iCloud, a computer or a new phone — so the wiring is pinned
  // here. iOS: AppDelegate makes the directory and flags it before
  // anything else at launch (Dart never creates it there).
  test('iOS excludes the local store directory from backup at launch', () {
    final delegate = File('${_appRoot().path}/ios/Runner/AppDelegate.swift')
        .readAsStringSync();
    expect(delegate,
        contains('static let localStoreDirectoryName = "$localStoreDirName"'));
    final prepare = RegExp(r'static func prepareLocalStore\(.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(prepare, isNotNull, reason: 'AppDelegate.prepareLocalStore missing');
    expect(prepare, contains('.applicationSupportDirectory'));
    expect(prepare, contains('appendingPathComponent(\n      '
        'localStoreDirectoryName, isDirectory: true)'));
    expect(prepare, contains('createDirectory('));
    expect(prepare, contains('values.isExcludedFromBackup = true'));
    expect(prepare, contains('directory.setResourceValues(values)'));

    final launch = RegExp(
            r'didFinishLaunchingWithOptions launchOptions.*?\n  \}',
            dotAll: true)
        .firstMatch(delegate)
        ?.group(0);
    expect(launch, isNotNull);
    final call = launch!.indexOf('AppDelegate.prepareLocalStore()');
    expect(call, greaterThanOrEqualTo(0),
        reason: 'didFinishLaunching never prepares the local store');
    for (final later in [
      'WorkmanagerPlugin.setPluginRegistrantCallback',
      'WorkmanagerPlugin.registerPeriodicTask',
      'super.application(',
    ]) {
      expect(launch.indexOf(later), greaterThan(call),
          reason: 'the local store must be flagged before $later — before '
              'either engine can write into it');
    }
  });

  // Android: exclusion rules by path for both backup schemes, referenced
  // from <application>. Android 12+'s rules are exclude-only: an <include>
  // there would silently stop backing up everything else the app keeps.
  // The Android 11-and-lower rules include every domain, each under a
  // transfer flag (the end-to-end test below).
  test('Android excludes the local store from cloud backup and device '
      'transfer', () {
    final main = '${_appRoot().path}/android/app/src/main';
    final manifest = File('$main/AndroidManifest.xml').readAsStringSync();
    final application =
        RegExp(r'<application\b[^>]*>').firstMatch(manifest)?.group(0);
    expect(application, isNotNull);
    expect(application,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    expect(application,
        contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(application, isNot(contains('android:allowBackup="false"')),
        reason: 'F1 only excludes the local store; backup stays on');

    final exclude = RegExp('<exclude\\s+domain="file"\\s+'
        'path="${RegExp.escape(localStoreDirName)}/"\\s*/>');
    String section(String xml, String tag) {
      final body = RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true)
          .firstMatch(xml)
          ?.group(1);
      expect(body, isNotNull, reason: '<$tag> missing');
      return body!;
    }

    final extraction = File('$main/res/xml/data_extraction_rules.xml');
    expect(extraction.existsSync(), isTrue, reason: extraction.path);
    final rules = section(
        extraction.readAsStringSync(), 'data-extraction-rules');
    for (final scheme in ['cloud-backup', 'device-transfer']) {
      final body = section(rules, scheme);
      expect(exclude.hasMatch(body), isTrue,
          reason: '$scheme does not exclude $localStoreDirName/');
      expect(body, isNot(contains('<include')), reason: scheme);
    }

    // Android 9 to 11 read res/xml-v28. Android 8.1 and lower read
    // res/xml, which includes one file the app never writes and so
    // nothing else: the local store stays out with the rest (the Android
    // 8.1 test below).
    final legacy = File('$main/res/xml-v28/backup_rules.xml');
    expect(legacy.existsSync(), isTrue, reason: legacy.path);
    final full = section(legacy.readAsStringSync(), 'full-backup-content');
    expect(exclude.hasMatch(full), isTrue,
        reason: 'fullBackupContent does not exclude $localStoreDirName/');
    final oldest = section(
        _uncommented(File('$main/res/xml/backup_rules.xml').readAsStringSync()),
        'full-backup-content');
    expect(oldest.trim(),
        '<include domain="file" path="no_backup_before_android_9"/>');
  });

  // flutter_secure_storage's files hold the API keys encrypted with a key
  // in this phone's Android Keystore, which never leaves the phone: a copy
  // restored from a cloud backup or carried to a new phone can never be
  // read there (and the plugin's README asks apps to exclude them). Every
  // one of its shared_prefs files stays out of both backup schemes and the
  // Android 11-and-lower rules, so a restored phone starts with no keys
  // and asks for them (AndroidSecureKeyStore covers a copy that already
  // got through). Paths take no wildcards, hence each file by name.
  test("Android keeps flutter_secure_storage's files out of backup and "
      'device transfer', () {
    final main = '${_appRoot().path}/android/app/src/main';
    const files = [
      'FlutterSecureStorage.xml',
      'FlutterSecureKeyStorage.xml',
      'FlutterSecureStorageConfiguration.xml',
      'FlutterSecureStorageConfiguration:FlutterSecureStorage.xml',
    ];
    String section(String xml, String tag) {
      final body = RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true)
          .firstMatch(_uncommented(xml))
          ?.group(1);
      expect(body, isNotNull, reason: '<$tag> missing');
      return body!;
    }

    final extraction =
        File('$main/res/xml/data_extraction_rules.xml').readAsStringSync();
    String legacy(String dir) =>
        File('$main/res/$dir/backup_rules.xml').readAsStringSync();
    final sections = {
      'cloud-backup': section(extraction, 'cloud-backup'),
      'device-transfer': section(extraction, 'device-transfer'),
      'full-backup-content (Android 9 to 11)':
          section(legacy('xml-v28'), 'full-backup-content'),
    };
    // Android 8.1 and lower include one file the app never writes, so the
    // key files stay out there with everything else.
    expect(section(legacy('xml'), 'full-backup-content').trim(),
        '<include domain="file" path="no_backup_before_android_9"/>');
    sections.forEach((name, body) {
      for (final file in files) {
        expect(
            RegExp('<exclude\\s+domain="sharedpref"\\s+'
                    'path="${RegExp.escape(file)}"\\s*/>')
                .hasMatch(body),
            isTrue,
            reason: '$name does not exclude $file');
      }
    });

    // The names, in the plugin version pub resolved: the data and the
    // wrapped-key files (FlutterSecureStorageConfig.java), the saved
    // cipher settings (NamespacedConfigSource.java).
    final java = '${_pluginRoot('flutter_secure_storage')}/android/src/main/'
        'java/com/it_nomads/fluttersecurestorage';
    final config =
        File('$java/FlutterSecureStorageConfig.java').readAsStringSync();
    expect(config,
        contains('DEFAULT_PREF_NAME = "FlutterSecureStorage";'));
    expect(config, contains(': "FlutterSecureKeyStorage";'));
    final source =
        File('$java/NamespacedConfigSource.java').readAsStringSync();
    expect(source,
        contains('LEGACY_GLOBAL_CONFIG_NAME = "FlutterSecureStorageConfiguration";'));
    expect(source,
        contains('return "FlutterSecureStorageConfiguration:" + sharedPreferencesName;'));
  });

  // Owner decision 5 (2026-11-20): the log goes to the cloud only end-to-end
  // encrypted, which Android does from Android 9 with the phone's screen
  // lock; there a transfer to a new phone stays as it was
  // (developer.android.com/identity/data/autobackup, read 2026-11-20).
  // Android 12+: disableIfNoEncryptionCapabilities on <cloud-backup> alone.
  // Android 9 to 11 (res/xml-v28): every <include> takes a whole domain
  // under one transfer flag; one without requireFlags would back up
  // unencrypted, and a domain left out would silently stop being backed up
  // or transferred. Android 8.1 and lower: the next test.
  test('Android backs up to the cloud only end-to-end encrypted; from '
      'Android 9 a transfer to a new phone is unchanged', () {
    final main = '${_appRoot().path}/android/app/src/main';
    final extraction = _uncommented(
        File('$main/res/xml/data_extraction_rules.xml').readAsStringSync());
    Map<String, String> attributes(String tag) => {
          for (final m in RegExp(r'([\w:]+)="([^"]*)"').allMatches(tag))
            m.group(1)!: m.group(2)!,
        };
    String? openTag(String xml, String tag) =>
        RegExp('<$tag(?:\\s[^>]*)?>').firstMatch(xml)?.group(0);

    final cloud = openTag(extraction, 'cloud-backup');
    expect(cloud, isNotNull);
    expect(attributes(cloud!), {'disableIfNoEncryptionCapabilities': 'true'});
    final transfer = openTag(extraction, 'device-transfer');
    expect(transfer, '<device-transfer>',
        reason: 'a transfer goes phone to phone: no encryption condition');
    expect(extraction, isNot(contains('<include')),
        reason: 'Android 12+ stays exclude-only');

    const domains = {
      'root',
      'file',
      'database',
      'sharedpref',
      'external',
      'device_root',
      'device_file',
      'device_database',
      'device_sharedpref',
    };
    const flags = {'clientSideEncryption', 'deviceToDeviceTransfer'};
    final legacy = _uncommented(
        File('$main/res/xml-v28/backup_rules.xml').readAsStringSync());
    final rules = [
      for (final m in RegExp(r'<(include|exclude)\s([^>]*?)/?>')
          .allMatches(legacy))
        (m.group(1)!, attributes(m.group(2)!)),
    ];
    final includes = [
      for (final (kind, a) in rules)
        if (kind == 'include') a,
    ];
    for (final a in includes) {
      expect(a.keys.toSet(), {'domain', 'path', 'requireFlags'},
          reason: 'every include under a transfer flag: $a');
      expect(a['path'], '.', reason: 'a whole domain: $a');
      expect(flags, contains(a['requireFlags']), reason: '$a');
    }
    expect({for (final a in includes) (a['domain'], a['requireFlags'])}, {
      for (final d in domains)
        for (final f in flags) (d, f),
    });
    expect(includes, hasLength(domains.length * flags.length));
    for (final (kind, a) in rules) {
      if (kind == 'exclude') {
        expect(a.keys.toSet(), {'domain', 'path'}, reason: '$a');
      }
    }
  });

  // Android 8.1 and lower (minSdk is 24) cannot encrypt a backup end to end
  // and have no transfer flags: a cloud backup and a transfer read the same
  // rules. They refuse any rule with a third attribute (requireFlags), and
  // a parse that failed half way left the excludes alone in force for a
  // later backup in the same process, which then took everything else,
  // unencrypted (review of #72). Their rules (res/xml; Android 9 and later
  // read res/xml-v28) parse there and include one file the app never
  // writes: no backup or transfer carries the app's data, and a restore
  // takes none. Google's page asks for such alternate rules. No exclude:
  // one outside every included path fails lint's FullBackupContent check,
  // which is fatal, so it stops a release build (lintVital).
  test("Android 8.1 and lower: rules they can read, which carry none of the "
      "app's data", () {
    final res = '${_appRoot().path}/android/app/src/main/res';
    Map<String, String> attributes(String tag) => {
          for (final m in RegExp(r'([\w:]+)="([^"]*)"').allMatches(tag))
            m.group(1)!: m.group(2)!,
        };
    final variants = {
      for (final d in Directory(res).listSync().whereType<Directory>())
        if (File('${d.path}/backup_rules.xml').existsSync())
          d.uri.pathSegments.lastWhere((p) => p.isNotEmpty),
    };
    expect(variants, {'xml', 'xml-v28'},
        reason: 'res/xml for Android 8.1 and lower, res/xml-v28 from 9');

    final xml =
        _uncommented(File('$res/xml/backup_rules.xml').readAsStringSync());
    expect(xml, isNot(contains('requireFlags')));
    final tags = [
      for (final m in RegExp(r'<([\w-]+)\b([^>]*?)/?>').allMatches(xml))
        (m.group(1)!, attributes(m.group(2)!)),
    ];
    expect(tags.first.$1, 'full-backup-content');
    expect(tags.first.$2, isEmpty);
    for (final (name, a) in tags.skip(1)) {
      expect({'include', 'exclude'}, contains(name), reason: name);
      expect(a.keys.toSet(), {'domain', 'path'},
          reason: '$name $a: Android 8.1 and lower refuse a third attribute');
    }
    final includes = [
      for (final (name, a) in tags)
        if (name == 'include') a,
    ];
    expect(includes, hasLength(1),
        reason: 'one include, or Android backs up everything not excluded');
    final nothing = includes.single;
    expect(nothing['domain'], 'file');
    expect(nothing['path'], matches(RegExp(r'^[a-z0-9_]+$')),
        reason: 'one plain file name, no folder');
    // A file the app never writes: no Dart or Kotlin source names it.
    for (final source in [
      ...Directory('${_appRoot().path}/lib').listSync(recursive: true),
      ...Directory('${_appRoot().path}/android/app/src/main/kotlin')
          .listSync(recursive: true),
    ].whereType<File>()) {
      expect(source.readAsStringSync(), isNot(contains(nothing['path']!)),
          reason: source.path);
    }

    expect(tags.where((t) => t.$1 == 'exclude'), isEmpty,
        reason: 'an exclude outside every include fails lintVital');
  });

  // Lint's FullBackupContent check is fatal, so lintVital stops a release
  // build on it: once a file has an <include>, every <exclude> must lie
  // under an include of its domain (path "." or a folder above it).
  test("every backup rule file passes lint's include and exclude check", () {
    final res = '${_appRoot().path}/android/app/src/main/res';
    Map<String, String> attributes(String tag) => {
          for (final m in RegExp(r'(\w+)="([^"]*)"').allMatches(tag))
            m.group(1)!: m.group(2)!,
        };
    for (final dir in ['xml', 'xml-v28']) {
      final xml = _uncommented(
          File('$res/$dir/backup_rules.xml').readAsStringSync());
      final rules = [
        for (final m in RegExp(r'<(include|exclude)\b([^>]*?)/?>')
            .allMatches(xml))
          (m.group(1)!, attributes(m.group(2)!)),
      ];
      final included = <String, List<String>>{};
      for (final (kind, a) in rules) {
        if (kind == 'include') (included[a['domain']!] ??= []).add(a['path']!);
      }
      if (included.isEmpty) continue;
      for (final (kind, a) in rules) {
        if (kind != 'exclude') continue;
        final paths = included[a['domain']] ?? const <String>[];
        expect(paths.any((p) => p == '.' || a['path']!.startsWith(p)), isTrue,
            reason: "$dir: ${a['domain']} ${a['path']} is not in an included "
                'path');
      }
    }
  });

  // Owner decisions 6 and 7 (2026-11-20): back reaches the app through
  // Android's back callback (the predictive-back page transition follows
  // the gesture from Android 14), and phones stay upright as the iPhone
  // app does (Android 16 ignores the lock at 600 dp and wider, where the
  // width-capped layout applies). Nothing else sets either: not the
  // debug, profile or Play manifests, and not MainActivity's code.
  test('Android: back goes through the back callback, and MainActivity is '
      'portrait', () {
    final manifest = _uncommented(_manifest());
    final application =
        RegExp(r'<application\b[^>]*>').firstMatch(manifest)?.group(0);
    expect(application,
        contains('android:enableOnBackInvokedCallback="true"'));
    final activities = RegExp(r'<activity\b[^>]*>')
        .allMatches(manifest)
        .map((m) => m.group(0)!)
        .toList();
    expect(activities, hasLength(1));
    expect(activities.single, contains('android:name=".MainActivity"'));
    expect(activities.single,
        contains('android:screenOrientation="portrait"'));
    expect(
        RegExp('screenOrientation|enableOnBackInvokedCallback')
            .allMatches(manifest)
            .length,
        2,
        reason: 'set once each');

    final src = '${_appRoot().path}/android/app/src';
    for (final variant in ['debug', 'profile', 'playChannel']) {
      final xml =
          _uncommented(File('$src/$variant/AndroidManifest.xml').readAsStringSync());
      for (final word in [
        '<application',
        '<activity',
        'screenOrientation',
        'enableOnBackInvokedCallback',
      ]) {
        expect(xml, isNot(contains(word)), reason: '$variant: $word');
      }
    }
    expect(_kotlinCode(_mainActivity()),
        isNot(contains('requestedOrientation')));
  });

  // RCREL-V-1 (2026-11-21): the bitewise://setup link reaches the app
  // through app_links only. Flutter's own deep linking, on unless the
  // activity's meta-data turns it off, pushed each link that arrived while
  // the app was open as a named route: a bare link became "/", which opened
  // a second HomeShell that brought back the first setup link of the run
  // and, when it closed, detached the sharing-consent asker.
  test('Android: Flutter deep linking is off, so only app_links sees the '
      'setup link', () {
    final manifest = _uncommented(_manifest());
    // MainActivity by name, up to its </activity>; meta-data inside an
    // intent filter is not the activity's, so the filters are cut out.
    final activity = RegExp(
            r'<activity\b[^>]*android:name="\.MainActivity"[^>]*>.*?</activity>',
            dotAll: true)
        .firstMatch(manifest)
        ?.group(0);
    expect(activity, isNotNull, reason: 'MainActivity missing');
    expect(activity, contains('android:scheme="bitewise"'));
    final ownMetaData = activity!.replaceAll(
        RegExp(r'<intent-filter\b.*?</intent-filter>', dotAll: true), '');
    final flags = RegExp(r'<meta-data\b[^>]*>')
        .allMatches(ownMetaData)
        .map((m) => m.group(0)!.replaceAll(RegExp(r'\s+'), ' '))
        .where((m) => m.contains('flutter_deeplinking_enabled'))
        .toList();
    expect(flags, hasLength(1));
    expect(flags.single, contains('android:value="false"'));
    expect('flutter_deeplinking_enabled'.allMatches(manifest), hasLength(1),
        reason: 'set once, on MainActivity');

    // Nothing turns it back on: not the debug, profile or Play manifests,
    // and not the app's Kotlin (FlutterActivity.shouldHandleDeeplinking).
    final src = '${_appRoot().path}/android/app/src';
    for (final variant in ['debug', 'profile', 'playChannel']) {
      final xml = _uncommented(
          File('$src/$variant/AndroidManifest.xml').readAsStringSync());
      expect(xml, isNot(contains('flutter_deeplinking_enabled')),
          reason: variant);
    }
    for (final file in _appKotlin().entries) {
      expect(_kotlinCode(file.value),
          isNot(contains('shouldHandleDeeplinking')),
          reason: file.key);
    }

    // Flutter 3.44, where the SDK carries its sources: the meta-data key is
    // this one, deep linking is on when it is missing, and both ways a link
    // becomes a route (the cold-start route and the push on onNewIntent) go
    // through the activity's check of it.
    final engine = Directory('${_pluginRoot('flutter')}/../../engine/src/'
        'flutter/shell/platform/android/io/flutter/embedding/android');
    if (!engine.existsSync()) {
      markTestSkipped('this Flutter SDK carries no engine sources');
      return;
    }
    String java(String name) => File('${engine.path}/$name')
        .readAsStringSync()
        .replaceAll(RegExp(r'//[^\n]*'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    final configs = java('FlutterActivityLaunchConfigs.java');
    expect(
        configs,
        contains('HANDLE_DEEPLINKING_META_DATA_KEY = '
            '"flutter_deeplinking_enabled";'));
    expect(
        configs,
        contains('if (metaData != null && metaData.containsKey('
            'HANDLE_DEEPLINKING_META_DATA_KEY)) { return '
            'metaData.getBoolean(HANDLE_DEEPLINKING_META_DATA_KEY); } else '
            '{ return true; }'));
    expect(
        java('FlutterActivity.java'),
        contains('public boolean shouldHandleDeeplinking() { try { Bundle '
            'metaData = getMetaData(); return deepLinkEnabled(metaData);'));
    final delegate = java('FlutterActivityAndFragmentDelegate.java');
    expect(
        delegate,
        contains('private String maybeGetInitialRouteFromIntent(Intent '
            'intent) { if (host.shouldHandleDeeplinking()) {'));
    expect(
        delegate,
        contains('String initialRoute = maybeGetInitialRouteFromIntent(intent); '
            'if (initialRoute != null && !initialRoute.isEmpty()) { '
            'flutterEngine.getNavigationChannel().pushRouteInformation('
            'initialRoute);'));
  });

  // With enableOnBackInvokedCallback, Flutter unregisters its back
  // callback at an idle root route and leaves Back there to Android.
  // Android 14 and later move the task to the back only after starts from
  // the home screen (ActivityClientController.shouldMoveTaskToBack: the
  // root's creating intent is the launcher's, ActivityRecord.isMainIntent,
  // and its launch source is the home app's process) and finish any other
  // root: a task a share created was finished on Back, with the engine
  // that was still analyzing its photo (review of #72). Android 14 and the
  // first release of Android 15 keep the launch source of the start that
  // created the activity; Android 15 QPR1 and later, and Android 16, give
  // the task's top activity each start's own (RC171A-1: one `am start` of
  // the launcher intent, or one photo shared into a task the home screen
  // started, and the next idle Back finished it). So unless the home
  // screen made both the first start and the latest (HomeStarts),
  // MainActivity keeps Flutter's callback, and Back at its root goes
  // through Flutter's SystemNavigator.pop to popSystemNavigator, which
  // moves the task to the back (the test of decision 6.1 below), as on
  // Android 12 and lower.
  // A home start is the launcher's intent from the caller Android recorded
  // for it (getReferrer), when that is the default home app, which the
  // manifest's <queries> lets the app see. The first is decided once per
  // activity: at its first create, from its creating start, before the
  // replay rewrite empties the intent, then from the saved state, since a
  // relaunch in the same process (theme colours, Bold text, grammatical
  // gender) hands the new instance whatever intent the last one set (the
  // replay rewrite's, a notification tap's; review of #72). The latest
  // moves with each start onNewIntent delivers, read there before anything
  // calls setIntent, and with the starts that deliver no intent but that
  // the activity can tell: an activity the app opens in its task (a
  // picker, a permission dialog), and the window shell's in multi-window
  // mode. The callback follows at once.
  test('Back at the root stays with Flutter on Android 14 and later unless '
      'the home screen made the first and the latest start', () {
    final code = _kotlinCode(_mainActivity());
    final create = _kotlinFunction(code, 'override fun onCreate(');
    const decide = 'homeStarts = HomeStarts.restore( first = '
        'savedInstanceState?.savedBoolean(STATE_FIRST_HOME_START), latest = '
        'savedInstanceState?.savedBoolean(STATE_LATEST_HOME_START), ) { '
        'intent?.let { isHomeStart(it) } ?: false } coveredInTask = '
        'savedInstanceState?.getBoolean(STATE_COVERED_IN_TASK) ?: false '
        'backCallbackAtRoot = IntakeRules.keepsBackCallbackAtRoot('
        'Build.VERSION.SDK_INT, homeStarts.systemMovesTaskBack)';
    expect(create, contains(decide));
    expect(create.indexOf(decide), lessThan(create.indexOf('val replay =')),
        reason: 'read before the replay rewrite empties the intent');
    expect(create,
        contains('super.onCreate(savedInstanceState) applyBackCallback()'),
        reason: 'registered at once: the root route never asks for it');
    expect(
        code,
        contains('private var homeStarts = HomeStarts(first = false, latest = '
            'false) private var backCallbackAtRoot = false private var '
            'flutterHandlesBack = false private var coveredInTask = false'));
    for (final (field, sets) in [
      ('homeStarts', 3),
      ('backCallbackAtRoot', 3),
      ('flutterHandlesBack', 2),
      ('coveredInTask', 4),
    ]) {
      expect(RegExp('\\b$field = (?!=)').allMatches(code), hasLength(sets),
          reason: '$field: declared, then set only where this test pins it');
    }
    // Each start into the running activity, first thing in onNewIntent
    // (pinned whole with the share hold below): getReferrer() names its
    // caller only during that call, and reads a referrer extra on the
    // activity's intent first, which a plugin's setIntent there can change.
    expect(_kotlinFunction(code, 'private fun noteStart('),
        '{ noteStarts(homeStarts.after(isHomeStart(start), coveredInTask)) }');
    expect(_kotlinFunction(code, 'override fun onNewIntent('),
        startsWith('{ noteStart(intent) '));
    // Every move of the answers goes through noteStarts, and the callback
    // follows it at once.
    expect(
        _kotlinFunction(code, 'private fun noteStarts('),
        '{ homeStarts = starts val keep = IntakeRules.keepsBackCallbackAtRoot('
        'Build.VERSION.SDK_INT, starts.systemMovesTaskBack) if (keep == '
        'backCallbackAtRoot) return backCallbackAtRoot = keep '
        'applyBackCallback() }');
    expect(RegExp(r'\bnoteStarts\(').allMatches(code), hasLength(5),
        reason: 'declared, then called from noteStart, onPause, onResume '
            'and onMultiWindowModeChanged only');
    expect(
        code,
        contains('private fun isHomeStart(start: Intent): Boolean = try { val '
            'claimed = start.namesReferrer() || intent?.namesReferrer() == '
            'true val from = referrer IntakeRules.homeStart( launcherIntent = '
            'IntakeRules.isLauncherIntent(start.action, start.categories, '
            'start.data != null, start.type), referrerPackage = '
            'IntakeRules.callerPackage(from?.scheme, from?.host, claimed, '
            'start.flags), homePackage = defaultHomePackage(), ) } catch (e: '
            'Exception) { false }'));
    expect(
        code,
        contains('private fun Intent.namesReferrer(): Boolean = '
            'hasExtra(Intent.EXTRA_REFERRER) || '
            'hasExtra(Intent.EXTRA_REFERRER_NAME)'));
    expect(
        _kotlinFunction(code, 'private fun defaultHomePackage('),
        '{ val home = Intent(Intent.ACTION_MAIN).addCategory('
        'Intent.CATEGORY_HOME) val found = if (Build.VERSION.SDK_INT >= 33) { '
        'packageManager.resolveActivity( home, '
        'PackageManager.ResolveInfoFlags.of('
        'PackageManager.MATCH_DEFAULT_ONLY.toLong()), ) } else { '
        'packageManager.resolveActivity(home, '
        'PackageManager.MATCH_DEFAULT_ONLY) } return '
        'found?.activityInfo?.packageName }');
    // Android 15 QPR1 and later give a start to the task's top activity.
    // The app's own start of a picker, a permission dialog or the share
    // sheet finds MainActivity there, so it is a latest start that was not
    // the home screen's, seen as MainActivity pauses below the new activity
    // (HomeStarts.afterOtherStart; review of #82, F1). A start that
    // comes while that activity is still open goes to it, which the start
    // then closes, and is not counted (HomeStarts.after); whether one is
    // open is read as MainActivity pauses and kept until it resumes. In
    // multi-window mode the window shell starts the task from Recents with
    // no intent (SystemUI's launch source, F2): no start counts as a home
    // start there, nor after it until the next home start.
    expect(_kotlinFunction(code, 'override fun onPause('),
        '{ super.onPause() coveredInTask = !isTopOfItsTask() if '
        '(coveredInTask) noteStarts(homeStarts.afterOtherStart()) }');
    expect(_kotlinFunction(code, 'override fun onResume('),
        '{ super.onResume() coveredInTask = false if (isInMultiWindowMode) '
        'noteStarts(homeStarts.afterOtherStart()) }');
    expect(
        code,
        contains('@RequiresApi(Build.VERSION_CODES.O) override fun '
            'onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: '
            'Configuration) { super.onMultiWindowModeChanged('
            'isInMultiWindowMode, newConfig) if (isInMultiWindowMode) '
            'noteStarts(homeStarts.afterOtherStart()) }'));
    expect(
        _kotlinFunction(code, 'private fun isTopOfItsTask('),
        endsWith('am.appTasks.asSequence().mapNotNull { it.taskInfo } '
            '.firstOrNull { it.taskId == task }?.topActivity == componentName '
            '} catch (e: Exception) { false } }'));
    // The answers outlive a relaunch: the activity's saved state keeps
    // them, under keys of their own.
    expect(
        _kotlinFunction(code, 'override fun onSaveInstanceState('),
        contains(' outState.putBoolean(STATE_FIRST_HOME_START, '
            'homeStarts.first) outState.putBoolean(STATE_LATEST_HOME_START, '
            'homeStarts.latest) outState.putBoolean(STATE_COVERED_IN_TASK, '
            'coveredInTask) '));
    for (final (name, key) in [
      ('STATE_FIRST_HOME_START', 'firstHomeStart'),
      ('STATE_LATEST_HOME_START', 'latestHomeStart'),
      ('STATE_COVERED_IN_TASK', 'coveredInTask'),
    ]) {
      expect(code, contains('const val $name = "chopstats.back.$key"'));
    }
    expect(
        code,
        contains('private fun Bundle.savedBoolean(key: String): Boolean? = '
            'if (containsKey(key)) getBoolean(key) else null'));
    // What Flutter asks for is kept, so a start can register or drop the
    // callback while the activity runs.
    expect(_kotlinFunction(code, 'override fun setFrameworkHandlesBack('),
        '{ flutterHandlesBack = frameworkHandlesBack applyBackCallback() }');
    expect(_kotlinFunction(code, 'private fun applyBackCallback('),
        '{ super.setFrameworkHandlesBack(flutterHandlesBack || '
        'backCallbackAtRoot) }');
    expect('super.setFrameworkHandlesBack('.allMatches(code), hasLength(1),
        reason: 'registered and dropped in applyBackCallback only');
    expect(code, isNot(contains('registerOnBackInvokedCallback')),
        reason: "Flutter's own callback, not a second one in front of it");
    final rules = _kotlinCode(_intakeRules());
    expect(
        rules,
        contains('fun isLauncherIntent(action: String?, categories: '
            'Set<String>?, hasData: Boolean, type: String?): Boolean = '
            'action == Intent.ACTION_MAIN && categories != null && '
            'categories.size == 1 && Intent.CATEGORY_LAUNCHER in categories '
            '&& !hasData && type == null'));
    expect(rules, contains('const val REFERRER_SCHEME = "android-app"'));
    expect(
        rules,
        contains('fun callerPackage(scheme: String?, host: String?, claimed: '
            'Boolean, flags: Int): String? = if (claimed || (flags and '
            'Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0 || scheme != '
            'REFERRER_SCHEME ) null else host?.takeIf { it.isNotEmpty() }'));
    expect(
        rules,
        contains('fun homeStart(launcherIntent: Boolean, referrerPackage: '
            'String?, homePackage: String?): Boolean = launcherIntent && '
            'referrerPackage != null && homePackage != null && homePackage != '
            '"android" && referrerPackage == homePackage'));
    expect(
        rules,
        contains('fun keepsBackCallbackAtRoot(sdk: Int, systemMovesTaskBack: '
            'Boolean): Boolean = sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE '
            '&& !systemMovesTaskBack'));
    expect(
        rules,
        contains('internal data class HomeStarts(val first: Boolean, val '
            'latest: Boolean) { fun after(home: Boolean, covered: Boolean): '
            'HomeStarts = copy(latest = home && !covered) fun '
            'afterOtherStart(): HomeStarts = copy(latest = false) val '
            'systemMovesTaskBack: Boolean get() = first && latest companion '
            'object { fun restore(first: Boolean?, latest: Boolean?, created: '
            '() -> Boolean): HomeStarts = if (first != null && latest != null) '
            'HomeStarts(first, latest) else created().let { HomeStarts(it, it) '
            '} } }'));
    _expectJvmTests([
      'isLauncherIntent',
      'IntakeRules.callerPackage(',
      'IntakeRules.homeStart(',
      'HomeStarts.restore(',
      '.after(',
      '.afterOtherStart(',
      'keepsBackCallbackAtRoot',
      'androidMovesTaskBack',
    ]);
    // The home apps are visible to the app (package visibility, Android 11
    // and later): otherwise the home intent resolves to none of them and
    // the referrer drops the home app, so no start would count as one from
    // the home screen. No permission comes with it.
    final queries = RegExp(r'<queries>(.*?)</queries>', dotAll: true)
        .firstMatch(_uncommented(_manifest()))
        ?.group(1)
        ?.replaceAll(RegExp(r'\s+'), ' ');
    expect(
        queries,
        contains('<intent> <action android:name="android.intent.action.MAIN"/> '
            '<category android:name="android.intent.category.HOME"/> '
            '</intent>'));
    expect(_uncommented(_manifest()), isNot(contains('QUERY_ALL_PACKAGES')));
    expect(_uncommented(_manifest()),
        contains('android:enableOnBackInvokedCallback="true"'));

    // Flutter 3.44, where the SDK carries its sources: FlutterActivity
    // registers its callback through the hook and restores the saved state
    // through it in onCreate, and a committed back gesture no route took
    // becomes handlePopRoute, which ends in SystemNavigator.pop.
    final flutter = _pluginRoot('flutter');
    final activity = File('$flutter/../../engine/src/flutter/shell/platform/'
        'android/io/flutter/embedding/android/FlutterActivity.java');
    if (activity.existsSync()) {
      final java = activity.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(
          java,
          contains('public void setFrameworkHandlesBack(boolean '
              'frameworkHandlesBack) { if (frameworkHandlesBack && '
              '!hasRegisteredBackCallback) { registerOnBackInvokedCallback();'));
      expect(
          java,
          contains('setFrameworkHandlesBack(frameworkHandlesBack); } '
              'delegate = new FlutterActivityAndFragmentDelegate(this);'));
    }
    final binding = File('$flutter/lib/src/widgets/binding.dart');
    expect(binding.existsSync(), isTrue, reason: binding.path);
    final dart = binding
        .readAsStringSync()
        .replaceAll(RegExp(r'//[^\n]*'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(
        dart,
        contains('Future<void> _handleCommitBackGesture() async { if '
            '(_backGestureObservers.isEmpty) { await handlePopRoute(); '
            'return; }'));
  });

  // Design R7a: while restaurant lookup uses the photo location, the app
  // reads where a meal photo was taken. iOS shows NSPhotoLibraryUsageDescription
  // in the permission prompt, from Info.plist and from each InfoPlist.strings
  // (which wins for its language) — so all three must say it, in step: the
  // English pair identical, the Chinese one saying the same. Neither may
  // suggest the location leaves for anyone but Apple Maps.
  test('the photo-library usage string says when the photo location is read, '
      'in Info.plist and both InfoPlist.strings', () {
    final ios = '${_appRoot().path}/ios/Runner';
    final plist = File('$ios/Info.plist').readAsStringSync();
    final fromPlist = RegExp(
            r'<key>NSPhotoLibraryUsageDescription</key>\s*<string>([^<]*)</string>')
        .firstMatch(plist)
        ?.group(1);
    String fromStrings(String lproj) {
      final file = File('$ios/$lproj/InfoPlist.strings');
      expect(file.existsSync(), isTrue, reason: file.path);
      final value = RegExp(r'"NSPhotoLibraryUsageDescription" = "([^"]*)";')
          .firstMatch(file.readAsStringSync())
          ?.group(1);
      expect(value, isNotNull, reason: '$lproj has no usage string');
      return value!;
    }

    expect(fromPlist, isNotNull);
    final en = fromStrings('en.lproj');
    final zh = fromStrings('zh-Hans.lproj');
    expect(en, fromPlist, reason: 'en.lproj mirrors Info.plist');
    // The photo prompt's first purpose is unchanged.
    expect(en, contains('AI service you choose in Settings'));
    expect(zh, contains('AI 服务'));
    // R7a: the photo's location, read only for restaurant lookup, and only
    // to ask Apple Maps — and (run 6) to check on the phone whether a
    // restaurant or takeout photo was taken in the US.
    expect(en, contains('restaurant lookup with photo location'));
    expect(en, contains('where a restaurant or takeout meal photo was taken'));
    expect(en, contains('only to check on this phone whether it was taken in '
        'the US, to ask Apple Maps'));
    expect(zh, contains('使用照片位置的餐厅查询'));
    expect(zh, contains('餐厅餐或外卖照片的拍摄位置'));
    expect(zh, contains('仅用于在本机判断照片是否在美国拍摄、向 Apple 地图查询'));
    // The editor's answers keep a ~100 m cell on the phone (review
    // 2026-10-25): the prompt says so too.
    expect(en, contains('to remember, on this phone, the restaurants you '
        'confirm or rule out'));
    expect(zh, contains('在本机记住你在那里确认或排除的餐厅'));
  });

  // App Store Connect's App Privacy answer is B (docs/RELEASING.md § 4.3,
  // owner decision R-F8): the Runner manifest declares what leaves the
  // phone (photos, health, other user content; release_decisions_test.dart
  // pins the three entries). The restaurant lookup adds no data type: its
  // chain and food names go to the same user-chosen recipient as the
  // photos, and the photo location goes only to Apple's MapKit — so no
  // location type, in either manifest. The share extension sends nothing
  // itself and keeps an empty array.
  test('the restaurant lookup adds no collected data type to either manifest',
      () {
    final ios = '${_appRoot().path}/ios';
    for (final target in const ['Runner', 'ShareExtension']) {
      final plist =
          File('$ios/$target/PrivacyInfo.xcprivacy').readAsStringSync();
      expect(plist, isNot(contains('NSPrivacyCollectedDataTypePreciseLocation')),
          reason: target);
      expect(plist, isNot(contains('NSPrivacyCollectedDataTypeCoarseLocation')),
          reason: target);
      expect(
          RegExp(r'<key>NSPrivacyTracking</key>\s*<false\s*/>').hasMatch(plist),
          isTrue,
          reason: target);
    }
    final share = File('$ios/ShareExtension/PrivacyInfo.xcprivacy')
        .readAsStringSync();
    expect(
        RegExp(r'<key>NSPrivacyCollectedDataTypes</key>\s*<array\s*/>')
            .hasMatch(share),
        isTrue,
        reason: 'ShareExtension/PrivacyInfo.xcprivacy must keep '
            'NSPrivacyCollectedDataTypes an empty array (RELEASING.md § 4.3)');
    final releasing = File('${_appRoot().parent.path}/docs/RELEASING.md')
        .readAsStringSync();
    expect(releasing, contains('NSPrivacyCollectedDataTypes'));
    expect(releasing, contains('the lookup adds no data type'));
  });

  // MainActivity's decisions live in IntakeRules.kt, where the JVM unit
  // tests (android/app/src/test, run by mobile-build.yml) exercise them for
  // real; the pins below hold MainActivity's wiring of them, on its code
  // with the comments stripped and whitespace collapsed (so neither a
  // commented-out line nor a reflow satisfies them).

  // A share is delivered once. After Android stops the process, reopening
  // the app from Recents or the icon recreates MainActivity with the
  // intent that first started its task (and the sender's grant), and
  // receive_sharing_intent reads activity.intent as a new share while
  // super.onCreate attaches it: a deleted meal came back, a not-food photo
  // went to the AI again. A recreated activity (saved state) or a launch
  // from Recents therefore hands the plugins an empty intent — no copy —
  // which also keeps a bitewise://setup link from reopening its dialog.
  // New shares still arrive through onNewIntent, but one that comes before
  // share intake listens waits for it (review 2026-11-19, R0): the launch
  // that recreates a stopped app delivers the share it was started for
  // before Dart has run, and the plugin tells only a listener. It is held
  // (ShareHold) until Dart says it listens, then handed to the plugin once.
  test('a recreated MainActivity never re-delivers its launch share', () {
    final code = _kotlinCode(_mainActivity());
    final create = _kotlinFunction(code, 'override fun onCreate(');
    expect(
        create,
        contains('val replay = IntakeRules.isRedelivery(savedInstanceState '
            '!= null, intent?.flags ?: 0) if (replay) { intent?.let { '
            'setIntent(emptyShare(it)) } } else { intent?.let { '
            'setIntent(withSafeShares(it)) } } super.onCreate('
            'savedInstanceState)'),
        reason: 'replay → the empty intent, else the safe copies, both '
            'before the plugins read it in super.onCreate');
    expect(
        _kotlinFunction(code, 'override fun onNewIntent('),
        '{ noteStart(intent) val safe = withSafeShares(intent) val copied = '
        'safe !== intent && safe.action != null if (copied && '
        '!heldShares.pass(safe)) return super.onNewIntent(safe) }');
    expect(code, contains('private val heldShares = ShareHold<Intent>()'));
    expect(
        _kotlinFunction(code, 'private fun releaseHeldShares('),
        '{ val held = heldShares.ready() for (share in held) '
        'super.onNewIntent(share) return held.size }');
    expect(code,
        contains('"shareIntakeReady" -> result.success(releaseHeldShares())'));
    final rules = _kotlinCode(_intakeRules());
    expect(
        rules,
        contains('fun isRedelivery(hasSavedState: Boolean, flags: Int): '
            'Boolean = hasSavedState || (flags and '
            'Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0'));
    _expectJvmTests(['isRedelivery', 'ShareHold']);
  });

  // Decision 6.1 (Q9): SystemNavigator.pop moves the task to the back, so
  // the engine lives on: FlutterActivity's default finished the activity,
  // destroying its engine, and a shared photo still being analyzed was
  // never saved. Flutter's PlatformPlugin runs its default (finish(), or
  // the OnBackPressedDispatcher) only when popSystemNavigator returns
  // false. Only a Back Flutter handles reaches it: every Back on Android
  // 12 and lower; with enableOnBackInvokedCallback, a Back at the root
  // while MainActivity keeps Flutter's callback there (on Android 14 and
  // later, unless the home screen made its first start and its latest:
  // the test above). At an idle root Android answers Back itself: Android
  // 13 moves a task whose root is a launcher activity (MainActivity is
  // one) to the back, and Android 14 and later move back an activity the
  // home screen started, and finish it after a start the app cannot see
  // (a return from Recents on Android 15 QPR1 and later, with a
  // third-party home app as the default). While a shared photo is pending
  // the shell's guard keeps that Back in Flutter in every task
  // (test/ui/shared_photos_back_test.dart).
  // The launch mode stays singleTask (decision 6.4), and nothing else
  // finishes the activity by hand.
  test('SystemNavigator.pop moves the task to the back, never finishes it',
      () {
    final code = _kotlinCode(_mainActivity());
    expect(_kotlinFunction(code, 'override fun popSystemNavigator('),
        '{ moveTaskToBack(true) return true }');
    expect(code, contains('override fun popSystemNavigator(): Boolean {'));
    expect(code, isNot(contains('finish()')));
    // Flutter 3.44's embedding, where the SDK carries its sources: the
    // hook, and that the default runs only when the hook says no.
    final embedding = '${_pluginRoot('flutter')}/../../engine/src/flutter/'
        'shell/platform/android/io/flutter';
    final activity =
        File('$embedding/embedding/android/FlutterActivity.java');
    final plugin = File('$embedding/plugin/platform/PlatformPlugin.java');
    if (activity.existsSync() && plugin.existsSync()) {
      expect(activity.readAsStringSync(),
          contains('public boolean popSystemNavigator() {'));
      expect(
          plugin.readAsStringSync().replaceAll(RegExp(r'\s+'), ' '),
          contains('if (platformPluginDelegate != null && '
              'platformPluginDelegate.popSystemNavigator()) { '));
    }
    final manifest = File('${_appRoot().path}/android/app/src/main/'
            'AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('android:launchMode="singleTask"'));
  });

  // Chopstats is a target in its own sharesheet: Today's day image and the
  // Export file go out through share_plus's FileProvider. Picked there,
  // the report image would come back in as a meal photo and go to the AI.
  // Share intake leaves out every stream from that provider, without a
  // word (it is no refused file: the next test); with nothing left, the
  // share reaches no plugin.
  test("share intake leaves out the app's own share-out files", () {
    final code = _kotlinCode(_mainActivity());
    final safe = _kotlinFunction(code, 'private fun withSafeShares(');
    expect(
        safe,
        contains('return@forEachIndexed } if '
            '(IntakeRules.isOwnShareOut(uri.scheme, uri.authority, '
            'packageName)) return@forEachIndexed val name = shareName(uri) '),
        reason: 'skipped before anything is read or copied, and not '
            'counted as refused');
    expect(safe,
        contains('if (copies.isEmpty() && refused.isEmpty()) return '
            'emptyShare(intent)'));
    final rules = _kotlinCode(_intakeRules());
    expect(rules,
        contains('const val SHARE_OUT_AUTHORITY_SUFFIX = ".flutter.share_provider"'));
    _expectJvmTests(['isOwnShareOut']);
    // share_plus's provider: the applicationId, which is the package.
    final sharePlus = _pluginRoot('share_plus');
    final pluginManifest =
        File('$sharePlus/android/src/main/AndroidManifest.xml')
            .readAsStringSync();
    expect(pluginManifest,
        contains(r'android:authorities="${applicationId}.flutter.share_provider"'));
  });

  // A shared item that gives no copy (a video or a PDF in a mixed share, a
  // file over 25 MB, a stream that cannot be read) was dropped without a
  // word, and a share of nothing else never reached Dart at all. Each now
  // goes on after the copies as a refused item: a file:// URI that names
  // no file (/chopstats-refused/<reason>), of a type that is no image.
  // The plugin hands a file:// URI's path to Dart as it is, without
  // opening it, and share intake reads it as the reason, never as a
  // file: it says how many were skipped and why, after the share's
  // photos, and asks nothing for a share of refused items alone.
  test('a shared item that gives no copy goes on as a refused item, which '
      'the plugin hands Dart unread', () {
    final code = _kotlinCode(_mainActivity());
    final safe = _kotlinFunction(code, 'private fun withSafeShares(');
    for (final refused in [
      'if (uri == null) { refused.add(IntakeRules.ShareRefusal.UNREADABLE) '
          'return@forEachIndexed }',
      'val name = shareName(uri) if (name == null) { refused.add('
          'IntakeRules.ShareRefusal.UNREADABLE) return@forEachIndexed }',
      'if (itemType?.startsWith("image") != true) { refused.add('
          'IntakeRules.typeRefusal(itemType)) return@forEachIndexed }',
      'val (copy, copied) = copyShare(uri, copyName(uri, name, itemType)) '
          'if (copy == null) { refused.add( if (copied == Copied.TOO_BIG) '
          'IntakeRules.ShareRefusal.TOO_BIG else '
          'IntakeRules.ShareRefusal.UNREADABLE, ) return@forEachIndexed }',
      '} catch (e: Exception) { refused.add('
          'IntakeRules.ShareRefusal.UNREADABLE) } }',
    ]) {
      expect(safe, contains(refused));
    }
    expect(
        safe,
        contains('if (kind == Intent.ACTION_SEND_MULTIPLE || '
            'refused.isNotEmpty()) { action = Intent.ACTION_SEND_MULTIPLE '
            'setDataAndType(null, shareType) val items = ArrayList<Uri>('
            'copies) val types = ArrayList<String>(copyTypes) for (refusal '
            'in refused) { items.add(Uri.fromFile(File('
            'IntakeRules.refusedSharePath(refusal)))) types.add('
            'IntakeRules.REFUSED_SHARE_TYPE) } putParcelableArrayListExtra('
            'Intent.EXTRA_STREAM, items) putExtra(Intent.EXTRA_MIME_TYPES, '
            'types.toTypedArray()) }'),
        reason: 'the copies first, then each refused item with its type');
    expect(
        _kotlinFunction(code, 'private fun copyShare('),
        contains('val copied = copyAtMost(uri, out, MAX_SHARE_BYTES) if '
            '(copied == Copied.OK) return out to copied out.delete() '
            'dir.delete() return null to copied }'),
        reason: 'over 25 MB (TOO_BIG) is told from a failed copy');
    // The same reasons, type and path as share_intake.dart reads.
    final rules = _kotlinCode(_intakeRules());
    expect(rules,
        contains('const val REFUSED_SHARE_TYPE = "$androidRefusedShareType"'));
    expect(rules,
        contains('const val REFUSED_SHARE_PATH = "$androidRefusedSharePath"'));
    expect(
        rules,
        contains('fun refusedSharePath(refusal: ShareRefusal): String = '
            '"\$REFUSED_SHARE_PATH/\${refusal.token}"'));
    final tokens = RegExp(r'enum class ShareRefusal\(val token: String\) '
            r'\{([^}]*)\}')
        .firstMatch(rules)
        ?.group(1);
    expect(tokens, isNotNull);
    expect(
        RegExp(r'[A-Z_]+\("([a-z_]+)"\)')
            .allMatches(tokens!)
            .map((m) => m.group(1))
            .toSet(),
        androidRefusalTokens.keys.toSet());
    _expectJvmTests(['typeRefusal', 'refusedSharePath', 'REFUSED_SHARE_TYPE']);
    // receive_sharing_intent, as the app builds it: a several-item share
    // gives each item its listed type, a type that is no image, video or
    // text is a file (no thumbnail: that is for a video only), and a
    // file:// URI's path is handed on as it is, nothing opened or copied.
    final plugin = '${_pluginRoot('receive_sharing_intent')}/android/src/'
        'main/kotlin/com/kasem/receive_sharing_intent';
    final share = _kotlinCode(
        File('$plugin/ReceiveSharingIntentPlugin.kt').readAsStringSync());
    expect(
        share,
        contains('uris?.mapIndexedNotNull { index, uri -> toJsonObject(uri, '
            'null, mimeTypes?.getOrNull(index)) }'));
    expect(
        share,
        contains('mimeType?.startsWith("image") == true -> IMAGE '
            'mimeType?.startsWith("video") == true -> VIDEO '
            'mimeType?.startsWith("text") == true -> TEXT else -> FILE'));
    expect(share,
        contains('if (type != MediaType.VIDEO) return Pair(null, null)'));
    final paths = _kotlinCode(
        File('$plugin/FileDirectory.kt').readAsStringSync());
    final absolute =
        _kotlinFunction(paths, 'fun getAbsolutePath(context: Context, uri: Uri)');
    expect(absolute,
        startsWith('{ if (DocumentsContract.isDocumentUri(context, uri)) {'));
    expect(
        absolute,
        endsWith('} else if ("content".equals(uri.scheme, ignoreCase = '
            'true)) { return getDataColumn(context, uri, null, null) } '
            'return uri.path }'));
  });

  // Share intake (Dart) takes a copy by its name's type. A provider can
  // show an image's name without an extension (IMG_1731500000000, "Lunch
  // with.Sarah"), and MainActivity copied it under that name, so a JPEG
  // shared as image/jpeg was refused as a kind of file Chopstats can't
  // read. Such a name gets the extension its image type gives (the
  // share's own type for it, else its provider's), from Android's MIME
  // table, as the plugin's own name for a nameless stream did.
  test('a shared image whose name has no extension Android knows is copied '
      'under the one its type gives', () {
    final code = _kotlinCode(_mainActivity());
    final copyName = _kotlinFunction(
        code, 'private fun copyName(uri: Uri, name: String, itemType: String)');
    expect(
        copyName,
        contains('val types = MimeTypeMap.getSingleton() fun extensionOf('
            'type: String?): String? = type?.lowercase(Locale.ROOT)?.takeIf '
            '{ it.startsWith("image/") } ?.let { '
            'types.getExtensionFromMimeType(it) } return '
            'IntakeRules.copyName(name, { types.hasExtension(it) }) { '
            'extensionOf(itemType) ?: extensionOf(providerType(uri)) }'));
    // Only an image's copy: after the type check, before the copy.
    final safe = _kotlinFunction(code, 'private fun withSafeShares(');
    expect(
        safe.indexOf('if (itemType?.startsWith("image") != true)'),
        lessThan(safe.indexOf('copyShare(uri, copyName(uri, name, itemType))')));
    expect('copyName('.allMatches(safe), hasLength(1));
    final rules = _kotlinCode(_intakeRules());
    expect(rules, contains('const val MAX_NAME_BYTES = 255'));
    _expectJvmTests([
      'aNameWithNoExtensionGetsTheOneItsTypeGives',
      'aNameWithAKnownExtensionIsKeptAndItsTypeNotAskedFor',
      'aTypeThatGivesNoPlainExtensionLeavesTheNameAsItIs',
      'aNameThatWouldGrowPastTheLongestFileNameIsKept',
      'IntakeRules.copyName(',
    ]);
  });

  // A file:// URI into the app's own data is never copied, shared or
  // picked (review 171, C5; review 2026-11-13 for picks).
  test("neither a share nor a pick copies the app's own files", () {
    final code = _kotlinCode(_mainActivity());
    expect(
        code,
        contains('private fun isOwnFile(uri: Uri): Boolean = "file".equals('
            'uri.scheme, ignoreCase = true) && IntakeRules.liesIn('
            'File(applicationInfo.dataDir), uri.path)'));
    expect(_kotlinFunction(code, 'private fun copyShare('),
        startsWith('{ if (isOwnFile(uri)) return null '));
    final picked = _kotlinFunction(code, 'private fun onPhotosPicked(');
    final own = picked.indexOf('if (isOwnFile(uri)) { failed++ return@forEach }');
    expect(own, greaterThan(0));
    expect(picked.indexOf('copyAtMost(uri, out, MAX_SHARE_BYTES)'),
        greaterThan(own));
    _expectJvmTests(['liesIn']);
  });

  // Log and Leftovers pick photos through the system Photo Picker, which
  // needs no permission (Play's Photo and Video FAQ asks apps to serve
  // users who grant no broad access). FlutterActivity is a plain Activity
  // with no registerForActivityResult, so MainActivity runs AndroidX's
  // contracts by hand: createIntent, startActivityForResult, parseResult.
  // Copies go to cacheDir/picked_photos/<uuid>/<name>, under the share cap.
  // A pick's call dies with its engine, so what earlier picks left there
  // when the activity starts has no reader: cleared before any pick of its
  // own can open (review 2026-11-19, R6).
  // One call at a time, answered exactly once (SingleCall): a reply sent
  // twice crashes, and a call never answered leaves every later pick busy.
  // The ModuleDependencies entry asks Play services for the backported
  // picker on Android 7-10 (minSdk 24); elsewhere the contract falls back
  // to ACTION_OPEN_DOCUMENT by itself.
  test('MainActivity serves pickImages through the system photo picker', () {
    final code = _kotlinCode(_mainActivity());
    expect(
        code,
        contains('"pickImages" -> pickImages( (call.argument<Any?>("max") as? '
            'Number)?.toInt() ?: 1, result, )'));
    expect(code, contains('const val PICKED_PHOTO_FOLDER = "picked_photos"'));
    expect(code, contains('const val PHOTO_PICK_REQUEST = 4208'));
    expect(code, contains('PHOTO_PICK_REQUEST -> onPhotosPicked(resultCode, data)'));

    final pick = _kotlinFunction(code, 'private fun pickImages(');
    expect(
        pick,
        startsWith('{ if (photoPicks.isOpen) { result.success('
            'photoPickAnswer("busy")) return } val max = '
            'IntakeRules.pickMax(requested, systemPickLimit()) '));
    expect(
        pick,
        contains('if (max == 1) ActivityResultContracts.PickVisualMedia()'
            '.createIntent(this, request) else ActivityResultContracts'
            '.PickMultipleVisualMedia(max).createIntent(this, request)'));
    expect(
        pick,
        contains('PickVisualMediaRequest(ActivityResultContracts'
            '.PickVisualMedia.ImageOnly)'));
    expect(
        pick,
        contains('} catch (e: Exception) { result.success('
            'photoPickAnswer("unavailable")) return } val call = '
            'photoPicks.open { result.success(it) } ?: return '
            'result.success(photoPickAnswer("busy")) photoPickCall = call '
            'photoPickMax = max try { startActivityForResult(intent, '
            'PHOTO_PICK_REQUEST) } catch (e: Exception) { '
            'photoPicks.answer(call, photoPickAnswer("unavailable")) } }'));
    expect(
        _kotlinFunction(code, 'private fun systemPickLimit('),
        isEmpty,
        reason: 'an expression body, pinned below');
    expect(
        code,
        contains('private fun systemPickLimit(): Int? = if '
            '(Build.VERSION.SDK_INT >= 33 || (Build.VERSION.SDK_INT >= 30 && '
            'SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2) ) '
            'MediaStore.getPickImagesMaxLimit() else null'));

    final picked = _kotlinFunction(code, 'private fun onPhotosPicked(');
    expect(
        picked,
        startsWith('{ if (!photoPicks.isOpen) return val call = '
            'photoPickCall val max = photoPickMax '));
    expect(picked,
        contains('ActivityResultContracts.PickVisualMedia().parseResult('
            'resultCode, data)'));
    expect(picked,
        contains('ActivityResultContracts.PickMultipleVisualMedia(max)'
            '.parseResult(resultCode, data)'));
    expect(
        picked,
        contains('val uris = IntakeRules.firstPicks(picked, max) if '
            '(resultCode != Activity.RESULT_OK || uris.isEmpty()) { '
            'photoPicks.answer(call, photoPickAnswer("cancelled")) return }'));
    expect(
        picked,
        contains('val root = File(cacheDir, PICKED_PHOTO_FOLDER) '
            'IntakeRules.tidyPickFolders(root, System.currentTimeMillis())'));
    expect(picked, isNot(contains('deleteRecursively')),
        reason: 'only tidyPickFolders clears earlier picks');
    expect(
        _kotlinFunction(code, 'override fun onCreate('),
        startsWith('{ IntakeRules.clearPickFolders(File(cacheDir, '
            'PICKED_PHOTO_FOLDER)) '),
        reason: 'what picks of an earlier activity left goes at its start');
    expect(picked, contains('copyAtMost(uri, out, MAX_SHARE_BYTES)'));
    expect(picked, contains('val dir = File(root, UUID.randomUUID().toString())'));
    expect(picked, contains('dateTaken(uri)?.let { item["dateTakenMs"] = it }'));
    expect(
        picked,
        contains('runOnUiThread { photoPicks.answer(call, photoPickAnswer('
            '"ok", items, tooBig, failed)) } }.start() }'));
    expect('.success('.allMatches(picked), isEmpty,
        reason: 'answers only through SingleCall, which answers once');
    expect('photoPicks.answer('.allMatches(picked), hasLength(2));
    expect(code, contains('MediaStore.MediaColumns.DATE_TAKEN'));
    _expectJvmTests(['pickMax', 'firstPicks', 'tidyPickFolders',
        'clearPickFolders', 'SingleCall']);

    final gradle = File('${_appRoot().path}/android/app/build.gradle.kts')
        .readAsStringSync();
    final activity = RegExp(r'implementation\("androidx\.activity:activity-ktx:'
            r'(\d+)\.(\d+)\.(\d+)"\)')
        .firstMatch(gradle);
    expect(activity, isNotNull, reason: 'androidx.activity is not declared');
    final major = int.parse(activity!.group(1)!);
    final minor = int.parse(activity.group(2)!);
    expect(major > 1 || (major == 1 && minor >= 7), isTrue,
        reason: 'the picker contracts need androidx.activity 1.7.0 or later');

    final manifest = _manifest();
    expect(RegExp(r'<manifest\b[^>]*>').firstMatch(manifest)?.group(0),
        contains('xmlns:tools="http://schemas.android.com/tools"'));
    final service = RegExp(
            r'<service\s+android:name="com\.google\.android\.gms\.metadata\.'
            r'ModuleDependencies"(.*?)</service>',
            dotAll: true)
        .firstMatch(_uncommented(manifest))
        ?.group(1);
    expect(service, isNotNull, reason: 'the picker backport entry is missing');
    expect(service, contains('android:enabled="false"'));
    expect(service, contains('android:exported="false"'));
    expect(service, contains('tools:ignore="MissingClass"'));
    expect(service, contains('<action android:name='
        '"com.google.android.gms.metadata.MODULE_DEPENDENCIES"'));
    expect(service, contains('<meta-data android:name='
        '"photopicker_activity:0:required" android:value=""'));
  });

  // Export › Save to device: a stock Pixel's sharesheet has no "save to
  // Files", so the export is written where the user picks with the
  // Storage Access Framework (no permission). The method only ever copies
  // a regular file whose real path lies in the app's cache, where the
  // export is written: never the database or anything else the app keeps.
  // The new document is opened only in a truncating mode, and a failed
  // copy removes it. If Android recreates the activity while the screen is
  // up, the source survives in the saved state, so the user's pick still
  // gets the file (or, with no source, the empty document is removed).
  // The copy takes its source out of the cache as soon as it has it open
  // (the open file still reads in full): no export is left behind
  // whatever happens to the call, and one written later under the same
  // name is never deleted by an earlier copy. A cancel with no caller
  // left to delete the source deletes it there (review 2026-11-19, R14).
  test('MainActivity serves saveFile, from the cache only', () {
    final code = _kotlinCode(_mainActivity());
    expect(
        code,
        contains('"saveFile" -> saveFile( call.argument<Any?>("path") as? '
            'String, call.argument<Any?>("name") as? String, '
            'call.argument<Any?>("mime") as? String, result, )'));
    expect(code, contains('const val SAVE_REQUEST = 4209'));
    expect(code, contains('SAVE_REQUEST -> onSaveTargetPicked(resultCode, data)'));
    expect(
        code,
        contains('private fun cachedFile(path: String?): File? = '
            'IntakeRules.regularFileIn(cacheDir, path)'));
    final save = _kotlinFunction(code, 'private fun saveFile(');
    expect(
        save,
        startsWith('{ if (saves.isOpen) { result.success(saveAnswer("busy")) '
            'return } val source = cachedFile(path) if (source == null) { '
            'result.success(saveAnswer("failed")) return } val intent = '
            'Intent(Intent.ACTION_CREATE_DOCUMENT).apply { addCategory('
            'Intent.CATEGORY_OPENABLE) '));
    expect(save, contains('putExtra(Intent.EXTRA_TITLE, baseName(name) ?: source.name)'));
    expect(
        save,
        contains('val call = saves.open { result.success(it) } ?: return '
            'result.success(saveAnswer("busy")) saveCall = call '
            'pendingSaveSource = source try { startActivityForResult(intent, '
            'SAVE_REQUEST) } catch (e: Exception) { pendingSaveSource = null '
            'saves.answer(call, saveAnswer("unavailable")) } }'));

    final saved = _kotlinFunction(code, 'private fun onSaveTargetPicked(');
    expect(
        saved,
        startsWith('{ val call = if (saves.isOpen) saveCall else null val uri '
            '= data?.data val source = pendingSaveSource pendingSaveSource = '
            'null val step = IntakeRules.saveStep(resultCode == '
            'Activity.RESULT_OK, uri != null, source != null) if (step == '
            'IntakeRules.SaveStep.CANCEL || uri == null) { '
            'IntakeRules.dropSaveSource(cacheDir, source?.path, call != null) '
            'call?.let { saves.answer(it, saveAnswer("cancelled")) } return } '
            'if (step == IntakeRules.SaveStep.DISCARD || source == null) { '
            'discardDocument(uri) answerSave(call, "failed") return } if '
            '(call == null) lateSave.started() Thread { val ok = try { val '
            'input = IntakeRules.openSaveSource(cacheDir, source.path) ?: '
            'throw IllegalStateException() input.use { inp -> val out = '
            'IntakeRules.firstStream(IntakeRules.SAVE_MODES) { '
            'contentResolver.openOutputStream(uri, it) } out?.use { o -> '
            'inp.copyTo(o, 64 * 1024) } != null } } catch (e: Exception) { '
            'false } if (!ok) discardDocument(uri) runOnUiThread { '
            'answerSave(call, if (ok) "ok" else "failed") } }.start() }'));
    expect('dropSaveSource('.allMatches(saved).length, 1,
        reason: 'only the cancel deletes by name: a copy has deleted its '
            'source on opening it');
    expect('.success('.allMatches(saved), isEmpty,
        reason: 'answers only through SingleCall, which answers once');
    expect(code, isNot(contains('openOutputStream(uri, "w")')),
        reason: 'plain "w" may leave stale bytes; SAVE_MODES only');
    expect(_kotlinFunction(code, 'private fun discardDocument('),
        contains('DocumentsContract.deleteDocument(contentResolver, uri)'));
    // The pending source outlives a recreated activity (with the home-start
    // answers, pinned with Back at the root).
    expect(_kotlinFunction(code, 'override fun onSaveInstanceState('),
        '{ super.onSaveInstanceState(outState) pendingSaveSource?.let { '
        'outState.putString(STATE_SAVE_SOURCE, it.path) } '
        'outState.putBoolean(STATE_FIRST_HOME_START, homeStarts.first) '
        'outState.putBoolean(STATE_LATEST_HOME_START, homeStarts.latest) '
        'outState.putBoolean(STATE_COVERED_IN_TASK, coveredInTask) }');
    final create = _kotlinFunction(code, 'override fun onCreate(');
    expect(
        create,
        endsWith(' pendingSaveSource = '
            'cachedFile(savedInstanceState?.getString(STATE_SAVE_SOURCE)) }'),
        reason: 'restored through the same cache check');
    expect(create.indexOf('super.onCreate(savedInstanceState)'),
        lessThan(create.indexOf('pendingSaveSource =')),
        reason: 'once the activity is created');
    // The open call is answered; with none (it died with its engine:
    // Android recreated the activity while the save screen was up), the
    // result waits for the restarted app, which asks once and says
    // "Export saved." (Android QA Q4).
    expect(_kotlinFunction(code, 'private fun answerSave('),
        '{ if (call != null) saves.answer(call, saveAnswer(status)) else '
        'lateSave.finished(status) }');
    expect(code,
        contains('private val lateSave = LateSaveResult<String>()'));
    expect(
        code,
        contains('"takeSaveResult" -> lateSave.take { status -> '
            'result.success(status?.let { saveAnswer(it) }) }'));
    _expectJvmTests(['regularFileIn', 'saveStep', 'dropSaveSource',
        'openSaveSource', 'SAVE_MODES', 'firstStream', 'SingleCall',
        'LateSaveResult']);
  });

  // Settings' notifications-off remedy lands on the app's own
  // notification page (API 26+), not App info two taps away; App info
  // stays the fallback. True only when a page actually opened. The
  // background lane calls it and falls back to openAppSettings when it is
  // not implemented.
  test('MainActivity serves openNotificationSettings', () {
    final code = _kotlinCode(_mainActivity());
    final channel = RegExp(
            r'MethodChannel\(flutterEngine\.dartExecutor\.binaryMessenger, '
            r'CHANNEL\)(.*?)\}\s*\}',
            dotAll: true)
        .firstMatch(code)
        ?.group(1);
    expect(channel, contains('"openNotificationSettings" -> '
        'result.success(openNotificationSettings())'));
    expect(code, contains('const val CHANNEL = "dev.calorietracker/background"'));
    expect(
        _kotlinFunction(code, 'private fun openNotificationSettings('),
        '{ val pages = mutableListOf<Intent>() if (Build.VERSION.SDK_INT >= '
        'Build.VERSION_CODES.O) { pages.add( Intent('
        'Settings.ACTION_APP_NOTIFICATION_SETTINGS) .putExtra('
        'Settings.EXTRA_APP_PACKAGE, packageName), ) } pages.add( Intent('
        'Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts('
        '"package", packageName, null)), ) return IntakeRules.openFirst(pages) '
        '{ startActivity(it) } }');
    _expectJvmTests(['openFirst']);
  });

  // Android QA Q6: preferences restored from another install (Auto Backup
  // after a reinstall, a device transfer) carried its notification-ask
  // flags, so Settings offered "Open system settings" and Android's own
  // dialog never came. Dart tells such preferences from this install's
  // own by this install's PackageInfo times (notification_permission.dart).
  test('MainActivity serves installTimes', () {
    final code = _kotlinCode(_mainActivity());
    final channel = RegExp(
            r'MethodChannel\(flutterEngine\.dartExecutor\.binaryMessenger, '
            r'CHANNEL\)(.*?)\}\s*\}',
            dotAll: true)
        .firstMatch(code)
        ?.group(1);
    expect(channel,
        contains('"installTimes" -> result.success(installTimes())'));
    expect(
        code,
        contains('private fun installTimes(): Map<String, Long>? = try { '
            '@Suppress("DEPRECATION") val info = '
            'packageManager.getPackageInfo(packageName, 0) '
            'mapOf("firstInstall" to info.firstInstallTime, "lastUpdate" to '
            'info.lastUpdateTime) } catch (e: Exception) { null }'));
  });

  // Android QA Q7: the phone's 12/24-hour switch reached the app only at a
  // restart or a configuration change: the embedding sends it then, and
  // turning the switch is neither. MainActivity watches the setting and
  // hands the FlutterView (its public id) the configuration again, which
  // re-sends the user settings as a configuration change does.
  test('MainActivity re-sends the 12/24-hour switch when it changes', () {
    final code = _kotlinCode(_mainActivity());
    expect(
        code,
        contains('private val clockFormatObserver = object : '
            'ContentObserver(Handler(Looper.getMainLooper())) { override fun '
            'onChange(selfChange: Boolean) { findViewById<View>('
            'FlutterActivity.FLUTTER_VIEW_ID) '
            '?.dispatchConfigurationChanged(resources.configuration) } }'));
    expect(
        _kotlinFunction(code, 'override fun configureFlutterEngine('),
        startsWith('{ super.configureFlutterEngine(flutterEngine) '
            'contentResolver.registerContentObserver( '
            'Settings.System.getUriFor(Settings.System.TIME_12_24), false, '
            'clockFormatObserver, ) '));
    // The same hook drops the engine's analysis keep-alive requests (the
    // keep-alive test below).
    expect(_kotlinFunction(code, 'override fun cleanUpFlutterEngine('),
        '{ contentResolver.unregisterContentObserver(clockFormatObserver) '
        'AnalysisKeepAlive.drop(applicationContext, keepAliveSession) '
        'super.cleanUpFlutterEngine(flutterEngine) }');
  });

  // The JVM unit tests run on CI (mobile-build.yml), and the built APKs'
  // permissions are checked there against an allowlist: the merged
  // manifest, which this file cannot see, is what Play reviews. Every
  // permission the main manifest declares must be on that list, so a new
  // one needs a deliberate edit in both places. The Play build's APK is
  // checked against the same list without the three its overlay removes.
  test('CI runs the JVM unit tests and checks the APK permissions', () {
    final root = _appRoot().parent.path;
    final workflow =
        File('$root/.github/workflows/mobile-build.yml').readAsStringSync();
    expect(workflow, contains('./gradlew :app:testDebugUnitTest'));
    expect(workflow, contains('flutter build apk --release'));
    // aapt2 reads each APK through the one script (release.yml uses it too).
    final script = File('$root/scripts/android_permissions.sh');
    expect(script.existsSync(), isTrue, reason: script.path);
    expect(script.readAsStringSync(), contains('dump permissions'));
    expect(workflow, contains('got=\$(scripts/android_permissions.sh "\$2")'));
    expect(
        workflow,
        contains('flutter build apk --release --target-platform android-arm64 '
            '--dart-define=CHOPSTATS_CHANNEL=play'));
    expect(
        workflow,
        contains('check app-release.apk "\$RUNNER_TEMP/app-github.apk" '
            '"\$allowed"'));
    expect(
        workflow,
        contains('check "the Play build\'s APK" "\$RUNNER_TEMP/app-play.apk" '
            '"\$play_allowed"'));
    final lists = {
      for (final m in RegExp(
              r"(\w+)=\$\(sed .*?<<'LIST'.*?\n(.*?)\n\s*LIST\n",
              dotAll: true)
          .allMatches(workflow))
        m.group(1)!: {
          for (final line in m.group(2)!.split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        },
    };
    expect(lists.keys, {'allowed', 'play_removed'});
    expect(lists['play_removed'], _playRemoved,
        reason: 'the Play build is checked without exactly what its overlay '
            'removes');
    final allowed = RegExp(r'^\s+(android\.permission\.[A-Z_]+|'
            r'dev\.calorietracker\.calorie_tracker\.[A-Z_]+)\s*$',
            multiLine: true)
        .allMatches(workflow)
        .map((m) => m.group(1)!)
        .toSet();
    expect(lists['allowed'], allowed);
    expect(allowed, containsAll(_declared(_manifest())));
    for (final banned in [
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.SCHEDULE_EXACT_ALARM',
      'android.permission.USE_EXACT_ALARM',
    ]) {
      expect(allowed, isNot(contains(banned)));
    }
    final gradle = File('${_appRoot().path}/android/app/build.gradle.kts')
        .readAsStringSync();
    expect(gradle, contains('testImplementation("junit:junit:'));
  });

  // Every permission check (mobile-build's allowlists, release.yml's Play
  // bundle check, the hand check in docs/RELEASING.md § 6) reads aapt2's
  // listing through scripts/android_permissions.sh. aapt2 prints a
  // permission asked for through <uses-permission-sdk-23> as its own line
  // form, which a parse of `uses-permission:` lines alone let past every
  // gate (review, 2026-11-19). The script's own parse, run on a listing
  // with both forms, as aapt2 36 prints them.
  test('the permission script lists the permissions aapt2 prints in both '
      'forms, and nothing else', () async {
    final script =
        File('${_appRoot().parent.path}/scripts/android_permissions.sh');
    final dir = Directory.systemTemp.createTempSync('aapt2-listing');
    addTearDown(() => dir.deleteSync(recursive: true));
    final listing = File('${dir.path}/permissions.txt')
      ..writeAsStringSync([
        'package: dev.calorietracker.calorie_tracker',
        "uses-permission: name='android.permission.INTERNET'",
        "uses-permission-sdk-23: name='android.permission.READ_MEDIA_IMAGES'",
        "uses-permission: name='android.permission.READ_EXTERNAL_STORAGE' "
            "maxSdkVersion='32'",
        'uses-permission-sdk-23: '
            "name='android.permission.READ_MEDIA_VISUAL_USER_SELECTED' "
            "maxSdkVersion='34'",
        'permission: dev.calorietracker.calorie_tracker.'
            'DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
        'uses-permission: name=\'dev.calorietracker.calorie_tracker.'
            'DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION\'',
        "uses-permission: name='android.permission.INTERNET'",
        '',
      ].join('\n'));
    // $0 stays 'bash': the script runs its main only when it is $0.
    final result = await Process.run('bash', [
      '-c',
      r'source "$1" && permission_names < "$2"',
      'bash',
      script.path,
      listing.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
        const LineSplitter().convert(result.stdout as String),
        [
          'android.permission.INTERNET',
          'android.permission.READ_EXTERNAL_STORAGE',
          'android.permission.READ_MEDIA_IMAGES',
          'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
          'dev.calorietracker.calorie_tracker.'
              'DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
        ],
        reason: 'sorted, unique, both forms; a declared <permission> is no '
            'request');
    // Sourced, it only defines: nothing ran aapt2 or wanted a file.
    expect(result.stderr, isEmpty);
    // What the script prints for an APK or bundle is that parse.
    expect(script.readAsStringSync(), contains('permission_names <<<"\$dump"'));
  });

  // The Google Play build ships WITHOUT broad photo access (owner decision
  // 1, 2026-11-13); the GitHub APK keeps everything. ONE switch makes it,
  // `--dart-define=CHOPSTATS_CHANNEL=play`: the Dart side reads it
  // (lib/core/app_channel.dart), and Gradle merges this overlay into every
  // variant from the same define. Each entry is a tools:node="remove": it
  // strips the main manifest's permission and any library's (photo_manager
  // declares READ_EXTERNAL_STORAGE itself), in both forms: a library that
  // asks through <uses-permission-sdk-23> would keep it past a
  // <uses-permission> removal (review, 2026-11-19).
  test("the Play build's overlay removes exactly the three photo permissions",
      () {
    final overlay = File(
        '${_appRoot().path}/android/app/src/playChannel/AndroidManifest.xml');
    expect(overlay.existsSync(), isTrue, reason: overlay.path);
    final xml = overlay.readAsStringSync();
    expect(
        _permissionEntries(xml),
        {
          for (final p in _playRemoved)
            for (final form in _permissionForms) (form, p, true),
        },
        reason: 'each a tools:node="remove" in both forms, and nothing else '
            'removed');
    // Nothing but those entries: no component, no other element. A
    // permission or component added here would ship in the Play build only.
    final elements = RegExp(r'<([a-zA-Z0-9-]+)')
        .allMatches(_uncommented(xml))
        .map((m) => m.group(1))
        .toSet();
    expect(elements, {'manifest', ..._permissionForms});
    expect(xml, contains('xmlns:tools="http://schemas.android.com/tools"'));
    // The GitHub APK keeps all three: the main manifest still declares them.
    expect(_declared(_manifest()), containsAll(_playRemoved));
  });

  test('Gradle merges the overlay into every variant of the Play build, '
      'from the define Flutter hands it', () {
    final gradle = _kotlinCode(
        File('${_appRoot().path}/android/app/build.gradle.kts')
            .readAsStringSync());
    // Flutter's dart-defines, decoded: the `dart-defines` property, each
    // entry base64(utf8("KEY=VALUE")), comma-separated.
    expect(gradle, contains('project.findProperty("dart-defines")'));
    expect(gradle, contains(".split(',')"));
    expect(gradle,
        contains('String(Base64.getDecoder().decode(entry.trim()), '
            'Charsets.UTF_8)'));
    expect(gradle,
        contains('val playChannel = dartDefines["CHOPSTATS_CHANNEL"] == "play"'));
    // Every variant (no selector), through the variant API: the debug and
    // profile source-set manifests (INTERNET) are not replaced.
    expect(
        RegExp(r'androidComponents \{ onVariants \{ variant -> '
                r'if \(playChannel\) \{ variant\.sources\.manifests\.'
                r'addStaticManifestFile\( "src/playChannel/AndroidManifest\.xml",? \) '
                r'\} \} \}')
            .hasMatch(gradle),
        isTrue,
        reason: 'the overlay must be added to every variant when playChannel');
    expect(gradle, isNot(contains('manifest.srcFile')));
    expect(gradle, isNot(contains('selector()')));
    for (final variant in ['debug', 'profile']) {
      expect(
          _declared(File('${_appRoot().path}/android/app/src/$variant/'
                  'AndroidManifest.xml')
              .readAsStringSync()),
          {'android.permission.INTERNET'},
          reason: variant);
    }
    // The Dart side reads the same define, at compile time.
    expect(File('${_appRoot().path}/lib/core/app_channel.dart')
            .readAsStringSync(),
        contains("String.fromEnvironment('CHOPSTATS_CHANNEL')"));
  });

  // The decoding above is Flutter's contract, not ours: should a Flutter
  // upgrade change how dart-defines reach Gradle, the Play build would
  // silently keep the photo permissions (release.yml's check would stop the
  // release, late). Read from the SDK pub resolved.
  test("Flutter still hands dart-defines to Gradle as base64 entries", () {
    final tools = '${_pluginRoot('flutter')}/../flutter_tools';
    final buildInfo =
        File('$tools/lib/src/build_info.dart').readAsStringSync();
    expect(buildInfo,
        contains('_defineEncoder = utf8.encoder.fuse(base64.encoder)'));
    expect(buildInfo,
        contains("return defines.map(_defineEncoder.convert).join(',');"));
    expect(buildInfo,
        contains(r"'-Pdart-defines=${encodeDartDefines(dartDefines)}'"));
    final plugin = File('$tools/gradle/src/main/kotlin/FlutterPlugin.kt')
        .readAsStringSync();
    expect(plugin, contains('project.findProperty("dart-defines")'));
  });

  // The daily summary is armed with the OS on Android too (background
  // lane): flutter_local_notifications' zonedSchedule posts it from
  // ScheduledNotificationReceiver, and alarms die at shutdown, so the boot
  // receiver re-arms them after a reboot or an app update. Inexact only
  // (AndroidScheduleMode.inexactAllowWhileIdle): no exact-alarm permission,
  // which Play reviews.
  test("flutter_local_notifications' scheduled-notification receivers are "
      'declared, and no exact-alarm permission', () {
    final manifest = _uncommented(_manifest());
    final application = RegExp(r'<application\b.*?</application>',
            dotAll: true)
        .firstMatch(manifest)
        ?.group(0);
    expect(application, isNotNull);
    const package = 'com.dexterous.flutterlocalnotifications';
    expect(
        RegExp('<receiver\\s+android:exported="false"\\s+'
                'android:name="$package\\.ScheduledNotificationReceiver"\\s*/>')
            .hasMatch(application!),
        isTrue,
        reason: 'ScheduledNotificationReceiver missing');
    final boot = RegExp(
            '<receiver\\s+android:exported="false"\\s+'
            'android:name="$package\\.ScheduledNotificationBootReceiver"\\s*>'
            '(.*?)</receiver>',
            dotAll: true)
        .firstMatch(application)
        ?.group(1);
    expect(boot, isNotNull, reason: 'ScheduledNotificationBootReceiver missing');
    expect(
        RegExp(r'<action android:name="([^"]+)"\s*/>')
            .allMatches(boot!)
            .map((m) => m.group(1))
            .toSet(),
        {
          'android.intent.action.BOOT_COMPLETED',
          'android.intent.action.MY_PACKAGE_REPLACED',
          'android.intent.action.QUICKBOOT_POWERON',
          'com.htc.intent.action.QUICKBOOT_POWERON',
        });
    expect(_declared(manifest), contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    for (final exact in ['SCHEDULE_EXACT_ALARM', 'USE_EXACT_ALARM']) {
      expect(manifest, isNot(contains(exact)), reason: exact);
    }
    // The classes exist in the plugin version pub resolved.
    final sources = '${_pluginRoot('flutter_local_notifications')}/android/'
        'src/main/java/com/dexterous/flutterlocalnotifications';
    for (final receiver in [
      'ScheduledNotificationReceiver',
      'ScheduledNotificationBootReceiver',
    ]) {
      expect(File('$sources/$receiver.java').existsSync(), isTrue,
          reason: receiver);
    }
  });

  // WorkManager's library manifest brings FOREGROUND_SERVICE and its
  // SystemForegroundService (no type), which it only uses for expedited
  // work on Android 11 and lower or for setForeground. The app registers
  // one periodic task from Dart, and the analysis keep-alive's one-time
  // job from Kotlin, expedited only on Android 12 and later (the test of
  // the keep-alive below), so both are stripped from the merged manifest.
  // Expedited work below Android 12, or setForeground, would need them back.
  // hasFragileUserData: on Android 10+ the uninstall dialog offers to keep
  // the app's data, and the meal log lives only on the phone. Should the
  // kept key store lose its Keystore key, AndroidSecureKeyStore turns it
  // into "no key" (android_key_store_test).
  test('the manifest strips WorkManager\'s foreground service and keeps '
      'data on uninstall when asked', () {
    final manifest = _manifest();
    final permissions = _permissions(manifest);
    expect(permissions['android.permission.FOREGROUND_SERVICE'], isTrue,
        reason: 'FOREGROUND_SERVICE must be a tools:node="remove" entry');
    expect(_declared(manifest),
        isNot(contains('android.permission.FOREGROUND_SERVICE')));
    expect(
        RegExp(r'<service\s+android:name="androidx\.work\.impl\.foreground\.'
                r'SystemForegroundService"\s+tools:node="remove"\s*/>')
            .hasMatch(_uncommented(manifest)),
        isTrue,
        reason: 'SystemForegroundService is not removed');
    final application = RegExp(r'<application\b[^>]*>')
        .firstMatch(_uncommented(manifest))
        ?.group(0);
    expect(application, contains('android:hasFragileUserData="true"'));

    // Nothing in Dart asks WorkManager for expedited or one-off work,
    // which on Android 11 and lower runs as that foreground service (the
    // workmanager plugin's worker gives no foreground info). The one
    // one-time job is the keep-alive's, in Kotlin.
    final dart = Directory('${_appRoot().path}/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in dart) {
      final source = file.readAsStringSync();
      for (final call in [
        'registerOneOffTask',
        'outOfQuotaPolicy',
        'OutOfQuotaPolicy',
      ]) {
        expect(source, isNot(contains(call)),
            reason: '${file.path} uses $call: put WorkManager\'s '
                'foreground service back first');
      }
    }
  });

  // Android 7-11 (API 24-30) draw the launch window from LaunchTheme's
  // colorBackground (launch_background in drawable-v21), which Theme.Light
  // made white: a white flash before the grey first frame. Both launch
  // themes take the app's page colours (lib/ui/theme/tokens.dart), as the
  // Android 12+ splash themes do.
  test('the API 24-30 launch window takes the app page colours', () {
    final res = '${_appRoot().path}/android/app/src/main/res';
    String launch(String folder) {
      final xml = File('$res/$folder/styles.xml').readAsStringSync();
      final style = RegExp(r'<style name="LaunchTheme"[^>]*>(.*?)</style>',
              dotAll: true)
          .firstMatch(_uncommented(xml))
          ?.group(1);
      expect(style, isNotNull, reason: folder);
      expect(style,
          contains('<item name="android:windowBackground">@drawable/'
              'launch_background</item>'),
          reason: folder);
      return style!;
    }

    expect(launch('values'),
        contains('<item name="android:colorBackground">#FFF2F2F7</item>'));
    expect(launch('values-night'),
        contains('<item name="android:colorBackground">#FF000000</item>'));
    expect(File('$res/drawable-v21/launch_background.xml').readAsStringSync(),
        contains('android:drawable="?android:colorBackground"'));
    final tokens = File('${_appRoot().path}/lib/ui/theme/tokens.dart')
        .readAsStringSync();
    expect(tokens, contains('page: Color(0xFFF2F2F7)'));
    expect(tokens, contains('page: Color(0xFF000000)'));
  });

  // Owner decision 2026-11-13: the package stays, and the upload key the
  // GitHub APKs are signed with becomes Play's app-signing key. Both are
  // permanent once the first bundle is uploaded: a new package is a new
  // app on Play, and a phone can only update between builds of one
  // package and one signer (the log lives only on the phone, so an
  // uninstall loses it).
  test('the Android package is permanent', () {
    final gradle =
        File('${_appRoot().path}/android/app/build.gradle.kts')
            .readAsStringSync();
    const package = 'dev.calorietracker.calorie_tracker';
    expect(gradle, contains('applicationId = "$package"'));
    expect(gradle, contains('namespace = "$package"'));
    expect(gradle, isNot(contains('applicationIdSuffix')));
    for (final invite in [
      'TODO: Specify your own unique Application ID',
      'You can update the following values to match your application needs',
    ]) {
      expect(gradle, isNot(contains(invite)),
          reason: 'the template line invites a change that would orphan '
              'every installed copy');
    }
    final note = RegExp(r'\n(\s*//[^\n]*\n)+\s*applicationId = ')
        .firstMatch(gradle)
        ?.group(0);
    expect(note, contains('never change applicationId'),
        reason: 'the note above applicationId says it is permanent');
    expect(_mainActivity(), startsWith('package $package\n'));
  });

  // Owner decision 9 (2026-11-20): Android froze an app the user left for
  // another one about 10 s later, so an analysis still on its way waited
  // in the frozen process (QA on API 35 and 36). While one the user started
  // is in flight, a WorkManager job keeps the process running and online
  // (AnalysisKeepAlive.kt). Dart drives it over this engine's own channel;
  // an engine that dies takes its requests with it, or the job would keep
  // the process up for the full cap after they were gone.
  // A Dart run that starts over in the same engine (a hot restart: no
  // configure, no cleanup, ids from 1 again) sends "reset" first, and the
  // session drops what the last run left open (review DL-3).
  test('the analysis keep-alive: each engine drives it over its own channel, '
      'and its requests end with the engine', () {
    final code = _kotlinCode(_mainActivity());
    expect(code,
        contains('const val KEEP_ALIVE_CHANNEL = "$keepAliveChannelName"'));
    expect(
        _kotlinFunction(code, 'override fun configureFlutterEngine('),
        contains('val session = AnalysisKeepAlive.newSession() '
            'keepAliveSession = session MethodChannel('
            'flutterEngine.dartExecutor.binaryMessenger, KEEP_ALIVE_CHANNEL) '
            '.setMethodCallHandler { call, result -> val id = '
            '(call.argument<Any?>("id") as? Number)?.toLong() when { '
            'call.method == "reset" -> { AnalysisKeepAlive.drop('
            'applicationContext, session) result.success(true) } '
            'id == null -> result.success(false) call.method == "begin" -> '
            'result.success(AnalysisKeepAlive.begin(applicationContext, '
            'session, id)) call.method == "end" -> result.success('
            'AnalysisKeepAlive.end(applicationContext, session, id)) '
            'else -> result.notImplemented() } }'));
    // Dart's side: the reset is the first call each instance makes.
    final dart =
        File('${_appRoot().path}/lib/services/analysis_keep_alive.dart')
            .readAsStringSync()
            .replaceAll(RegExp(r'\s+'), ' ');
    expect(
        dart,
        contains('AnalysisKeepAlive( [this._channel = const '
            "MethodChannel(keepAliveChannelName)]) { _send('reset'); }"));
    // The same hook also stops the 12/24-hour observer (Q7, above).
    expect(_kotlinFunction(code, 'override fun cleanUpFlutterEngine('),
        '{ contentResolver.unregisterContentObserver(clockFormatObserver) '
        'AnalysisKeepAlive.drop(applicationContext, keepAliveSession) '
        'super.cleanUpFlutterEngine(flutterEngine) }');
    expect(code, contains('private var keepAliveSession = 0L'));
    expect(RegExp(r'\bkeepAliveSession = (?!=)').allMatches(code),
        hasLength(2),
        reason: 'declared 0, then set once per engine, in '
            'configureFlutterEngine');
    // Flutter 3.44's embedding, where the SDK carries its sources: the hook
    // runs as the activity lets go of its engine, before it is destroyed.
    final delegate = File('${_pluginRoot('flutter')}/../../engine/src/'
        'flutter/shell/platform/android/io/flutter/embedding/android/'
        'FlutterActivityAndFragmentDelegate.java');
    if (delegate.existsSync()) {
      final java =
          delegate.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      final detach = java.substring(java.indexOf('void onDetach() {'));
      expect(detach.indexOf('host.cleanUpFlutterEngine(flutterEngine);'),
          lessThan(detach.indexOf('flutterEngine.destroy();')));
    }
  });

  // The job itself: one time, expedited from Android 12 only, where
  // JobScheduler runs it with no foreground service and no notification,
  // and out of quota as a plain job. Below Android 12 WorkManager would run
  // expedited work as its stripped foreground service and ask the worker
  // for foreground info it does not give: a plain job there. From Android 9
  // it needs a network, any that reaches the internet, validated or not
  // (review BG-1): JobInfo's NETWORK_TYPE_ANY without
  // NET_CAPABILITY_VALIDATED, so a network that fails Android's probe (a
  // phone in mainland China with no VPN) still starts it, and an expedited
  // job keeps its network bypass, which needs a network constraint. Below
  // Android 9 none (a plain job, no bypass to keep). The first request of
  // a burst replaces any job WorkManager still has, a backed-off re-run
  // that would never be expedited (review BG-2); a system stop mid-run is
  // renewed with a fresh job while a request is live. It is cancelled as
  // soon as nothing is live, and its worker only waits and succeeds, for
  // 2 minutes 45 seconds at most: never retried, never a foreground
  // service.
  test('the keep-alive job: one time, any network from Android 9, expedited '
      'only on Android 12 and later, fresh for each burst; its worker only '
      'waits', () {
    final kotlin = _appKotlin();
    final glue = _kotlinCode(kotlin['AnalysisKeepAlive.kt']!);
    expect(
        _kotlinFunction(glue, 'private fun request('),
        '{ val constraints = if (KeepAliveRules.usesNetworkRequest('
        'Build.VERSION.SDK_INT)) { Constraints.Builder()'
        '.setRequiredNetworkRequest( NetworkRequest.Builder() '
        '.addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) '
        '.removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) '
        '.removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) '
        '.build(), NetworkType.CONNECTED, ).build() } else { '
        'Constraints.NONE } val builder = OneTimeWorkRequest.Builder('
        'AnalysisKeepAliveWorker::class.java) .setConstraints(constraints) '
        'if (KeepAliveRules.expedited(Build.VERSION.SDK_INT)) { '
        'builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST) '
        '} return builder.build() }');
    expect(glue, isNot(contains('NET_CAPABILITY_VALIDATED')));
    expect(glue, isNot(contains('setRequiredNetworkType(')),
        reason: 'CONNECTED alone asks for a validated network');
    expect(
        _kotlinFunction(glue, 'fun begin('),
        '{ val now = SystemClock.elapsedRealtime() val replace = '
        'KeepAliveRules.replacesJob(liveBefore = ledger.live(now)) '
        'val added = ledger.begin(session, id, now) enqueue(context, '
        'if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP) '
        'return added }');
    expect(
        _kotlinFunction(glue, 'private fun enqueue('),
        '{ try { WorkManager.getInstance(context) .enqueueUniqueWork('
        'KeepAliveRules.WORK_NAME, policy, request()) } catch (e: Exception) '
        '{ } }');
    expect(
        _kotlinFunction(glue, 'fun renewAfterStop('),
        '{ if (!KeepAliveRules.renewsAfterStop(stopReason)) return if '
        '(!ledger.live(SystemClock.elapsedRealtime())) return '
        'enqueue(context, ExistingWorkPolicy.REPLACE) }');
    expect(_kotlinFunction(glue, 'fun end('),
        '{ val removed = ledger.end(session, id) if (removed) '
        'settle(context) return removed }');
    expect(_kotlinFunction(glue, 'fun drop('),
        '{ if (ledger.drop(session) > 0) settle(context) }');
    expect(
        _kotlinFunction(glue, 'private fun settle('),
        '{ if (ledger.live(SystemClock.elapsedRealtime())) return try { '
        'WorkManager.getInstance(context).cancelUniqueWork('
        'KeepAliveRules.WORK_NAME) } catch (e: Exception) { } }');
    expect(
        glue,
        contains('class AnalysisKeepAliveWorker(context: Context, params: '
            'WorkerParameters) : CoroutineWorker(context, params) { override '
            'suspend fun doWork(): Result { try { '
            'AnalysisKeepAlive.runJob(applicationContext) } catch (e: '
            'CancellationException) { if (Build.VERSION.SDK_INT >= '
            'Build.VERSION_CODES.S) { AnalysisKeepAlive.renewAfterStop('
            'applicationContext, stopReason) } throw e } '
            'return Result.success() } }'));
    // Android counts an expedited job of 3 minutes or more as timed out
    // however it ends, and more than 10 timeouts a day restrict the app
    // (JobSchedulerService.maybeProcessBuggyJob): each job stops at its
    // cap, and a request still live gets a follow-up job after it.
    expect(
        _kotlinFunction(glue, 'suspend fun runJob('),
        '{ val stillLive = ledger.awaitIdleOrCap(KeepAliveRules.JOB_CAP_MS) '
        '{ SystemClock.elapsedRealtime() } if (!stillLive) return '
        'enqueue(context, ExistingWorkPolicy.APPEND_OR_REPLACE) }');

    final rules = _kotlinCode(kotlin['KeepAliveRules.kt']!);
    expect(rules, contains('const val CAP_MS = 3L * 60 * 1000'));
    expect(rules, contains('const val JOB_CAP_MS = 165L * 1000'));
    expect(rules,
        contains('fun expedited(sdk: Int): Boolean = sdk >= Build.VERSION_CODES.S'));
    expect(
        rules,
        contains('fun usesNetworkRequest(sdk: Int): Boolean = '
            'sdk >= Build.VERSION_CODES.P'));
    expect(rules,
        contains('fun replacesJob(liveBefore: Boolean): Boolean = !liveBefore'));
    expect(
        rules,
        contains('fun renewsAfterStop(stopReason: Int): Boolean = when '
            '(stopReason) { WorkInfo.STOP_REASON_PREEMPT, '
            'WorkInfo.STOP_REASON_DEVICE_STATE, '
            'WorkInfo.STOP_REASON_CONSTRAINT_CONNECTIVITY, '
            'WorkInfo.STOP_REASON_QUOTA, WorkInfo.STOP_REASON_APP_STANDBY, '
            'WorkInfo.STOP_REASON_SYSTEM_PROCESSING -> true else -> false }'));
    expect(rules, isNot(contains('import android.content')),
        reason: 'the rules stay free of Android objects, for the JVM tests');
    _expectJvmTests([
      'KeepAliveRules.expedited(',
      'KeepAliveRules.usesNetworkRequest(',
      'KeepAliveRules.replacesJob(',
      'KeepAliveRules.renewsAfterStop(',
      'KeepAliveRules.CAP_MS',
      'KeepAliveRules.JOB_CAP_MS',
      'ledger.drop(',
      'ledger.awaitIdle(',
      'awaitIdleOrCap(',
      'aStrayEndChangesNothing',
      'aDartThatStartsOverDropsWhatItsLastRunLeft',
    ], suite: 'KeepAliveRulesTest');

    // One expedited request in the app, the one above; no foreground
    // service, foreground info or retry anywhere in its Kotlin.
    final all = kotlin.values.map(_kotlinCode).join('\n');
    expect('setExpedited('.allMatches(all), hasLength(1));
    for (final banned in [
      'setForeground',
      'ForegroundInfo',
      'startForeground',
      'Result.retry',
      'FOREGROUND_SERVICE',
    ]) {
      expect(all, isNot(contains(banned)), reason: banned);
    }
    // WorkManager builds the worker by its class name: R8 keeps it.
    final keep = File('${_appRoot().path}/android/app/proguard-rules.pro')
        .readAsStringSync();
    expect(keep,
        contains('-keep class * extends androidx.work.ListenableWorker { <init>(...); }'));
  });

  // The job needs no permission of its own, so the merged manifest Play
  // reviews (the GitHub APK and the Play build alike) asks for nothing
  // new: the app compiles against the WorkManager the workmanager plugin
  // already brings, at the version the plugin builds with, so the library
  // manifest merged is the one it always was (WAKE_LOCK,
  // ACCESS_NETWORK_STATE and RECEIVE_BOOT_COMPLETED, already on CI's
  // allowlist; FOREGROUND_SERVICE stripped). The main manifest declares
  // the same set as before (the test of exactly these permissions above)
  // and no service of its own.
  test('the keep-alive adds no permission: the WorkManager the plugin '
      'already brings, no service, no foreground service type', () {
    final gradle = File('${_appRoot().path}/android/app/build.gradle.kts')
        .readAsStringSync();
    final work = RegExp(r'implementation\("androidx\.work:([a-z-]+):([0-9.]+)"\)')
        .allMatches(gradle)
        .map((m) => (m.group(1)!, m.group(2)!))
        .toList();
    expect(work, hasLength(1));
    expect(work.single.$1, 'work-runtime');
    expect(RegExp(r'androidx\.work:').allMatches(gradle), hasLength(1));
    final plugin = File('${_pluginRoot('workmanager_android')}/android/'
            'build.gradle')
        .readAsStringSync();
    expect(plugin, contains('def work_version = "${work.single.$2}"'),
        reason: 'the app and the plugin resolve one WorkManager');
    expect(plugin,
        contains(r'implementation "androidx.work:work-runtime:$work_version"'));

    final manifest = _uncommented(_manifest());
    expect(manifest, isNot(contains('foregroundServiceType')));
    expect(manifest, isNot(contains('AnalysisKeepAlive')));
    expect(_declared(manifest),
        isNot(contains('android.permission.FOREGROUND_SERVICE')));
    for (final variant in ['debug', 'profile', 'playChannel']) {
      final xml = _uncommented(File('${_appRoot().path}/android/app/src/'
              '$variant/AndroidManifest.xml')
          .readAsStringSync());
      expect(xml, isNot(contains('<service')), reason: variant);
      expect(xml, isNot(contains('FOREGROUND_SERVICE')), reason: variant);
    }
  });

  // A36-1 (QA 2026-11-20, Android 16): from Android 15 the app draws edge
  // to edge and Flutter's engine no longer sets the navigation bar's
  // colour, so Android took the light launch window for a light bar and
  // forced dark buttons (APPEARANCE_FORCE_LIGHT_NAVIGATION_BARS), which a
  // switch to dark while the app ran never undid: dark buttons on the dark
  // 3-button bar. MainActivity sets the colour the shell hands it
  // (lib/ui/app.dart _SystemNavBarStyle), which ends the forced buttons
  // and tints the 3-button contrast scrim (A36-2); below Android 15 Flutter
  // sets it as before.
  test('MainActivity sets the navigation bar colour from Android 15 only',
      () {
    final code = _kotlinCode(_mainActivity());
    expect(code,
        contains('const val SYSTEM_BARS_CHANNEL = "$systemBarsChannelName"'));
    expect(
        _kotlinFunction(code, 'override fun configureFlutterEngine('),
        contains('MethodChannel(flutterEngine.dartExecutor.binaryMessenger, '
            'SYSTEM_BARS_CHANNEL) .setMethodCallHandler { call, result -> '
            'when (call.method) { "navigationBarColor" -> result.success('
            'colorNavigationBar((call.argument<Any?>("color") as? Number)'
            '?.toLong())) else -> result.notImplemented() } }'));
    expect(
        _kotlinFunction(code, 'private fun colorNavigationBar('),
        '{ if (argb == null || !IntakeRules.colorsNavigationBar('
        'Build.VERSION.SDK_INT)) return false window.navigationBarColor = '
        'argb.toInt() return true }');
    expect('navigationBarColor ='.allMatches(code), hasLength(1));
    expect(code, isNot(contains('setSystemBarsAppearance')),
        reason: 'the buttons stay Flutter\'s to set');
    expect(
        _kotlinCode(_intakeRules()),
        contains('fun colorsNavigationBar(sdk: Int): Boolean = '
            'sdk >= Build.VERSION_CODES.VANILLA_ICE_CREAM'));
    _expectJvmTests(['IntakeRules.colorsNavigationBar(']);
  });
}
