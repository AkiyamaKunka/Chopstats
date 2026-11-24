/// The owner's first-submission decisions (2026-10-29, docs/RELEASING.md
/// "First submission — owner steps in order"), pinned where they live in
/// files rather than in widgets:
///
/// - R-F8: App Privacy answer B — Photos or Videos, Health and Other User
///   Content, App Functionality only, not linked, no tracking — mirrored in
///   the app's privacy manifest; the share extension declares nothing.
/// - R-F14: docs/SUPPORT.md is the support URL: iPhone-only, and its one
///   email address is the one the owner chose (2026-10-29).
/// - R-F11: the English strings carry no Chinese text and no
///   mainland-China / VPN advice.
/// - R-F9: the English name is Chopstats everywhere (renamed from BiteWise
///   2026-10-29); 筷拍 in Chinese.
/// - R-F7: the privacy policy's third-party and consent section.
/// - Google Play (2026-11-13, docs/RELEASING.md § 6): the listing pack in
///   app/android/store/ within Play's limits and with Google's health
///   disclaimer, the graphics Play accepts, the What's new texts, the
///   themed icon and the Android 12+ splash, release.yml's play_track and
///   its v*-only tag trigger (decision 4: android-v* tags start no run),
///   CI builds that never use the Aliyun mirrors (C44), § 6's corrected
///   answers, and the policy's "Who we are".
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart'
    show kApiKeyChoices, kKnownModels, modelChoiceLabel, noteLabel;
import 'package:calorie_tracker/ui/theme/tokens.dart' show AppColors;
import 'package:flutter_test/flutter_test.dart';

import 'support/store_listing_files.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

String _read(String pathFromApp) =>
    File('${_appRoot().path}/$pathFromApp').readAsStringSync();

String _readRepo(String pathFromRepo) =>
    File('${_appRoot().parent.path}/$pathFromRepo').readAsStringSync();

/// A small XML property-list reader (dict, array, key, string, integer,
/// real, true, false; comments skipped) — enough for the manifests, and
/// runs where `plutil` does not (the Linux CI).
Object? parsePlist(String xml) => _PlistReader(xml).document();

class _PlistReader {
  _PlistReader(String xml) {
    final body = xml
        .replaceAll(RegExp(r'<\?xml[^>]*\?>'), '')
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>'), '')
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    for (final m in RegExp(
      r'<(/?)([A-Za-z]+)[^>]*?(/?)>|([^<]+)',
    ).allMatches(body)) {
      if (m.group(4) != null) {
        _tokens.add(('text', m.group(4)!));
      } else if (m.group(1) == '/') {
        _tokens.add(('close', m.group(2)!));
      } else if (m.group(3) == '/') {
        _tokens.add(('empty', m.group(2)!));
      } else {
        _tokens.add(('open', m.group(2)!));
      }
    }
  }

  final List<(String, String)> _tokens = [];
  int _i = 0;

  void _skipSpace() {
    while (_i < _tokens.length &&
        _tokens[_i].$1 == 'text' &&
        _tokens[_i].$2.trim().isEmpty) {
      _i++;
    }
  }

  (String, String) _peek() {
    _skipSpace();
    return _tokens[_i];
  }

  (String, String) _next() {
    _skipSpace();
    return _tokens[_i++];
  }

  String _textUntil(String tag) {
    final buf = StringBuffer();
    while (_tokens[_i].$1 == 'text') {
      buf.write(_tokens[_i++].$2);
    }
    final close = _tokens[_i++];
    if (close != ('close', tag)) throw FormatException('want </$tag>: $close');
    return buf
        .toString()
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  Object? document() {
    final open = _next();
    if (open != ('open', 'plist')) throw FormatException('no <plist>: $open');
    final value = _value();
    if (_next() != ('close', 'plist')) throw const FormatException('</plist>');
    _skipSpace();
    if (_i != _tokens.length) throw const FormatException('trailing content');
    return value;
  }

  Object? _value() {
    final (kind, tag) = _next();
    if (kind == 'empty') {
      return switch (tag) {
        'true' => true,
        'false' => false,
        'array' => <Object?>[],
        'dict' => <String, Object?>{},
        'string' => '',
        _ => throw FormatException('<$tag/>'),
      };
    }
    if (kind != 'open') throw FormatException('unexpected $kind $tag');
    switch (tag) {
      case 'dict':
        final map = <String, Object?>{};
        while (_peek() != ('close', 'dict')) {
          if (_next() != ('open', 'key')) throw const FormatException('<key>');
          final key = _textUntil('key');
          if (map.containsKey(key)) throw FormatException('duplicate $key');
          map[key] = _value();
        }
        _next();
        return map;
      case 'array':
        final list = <Object?>[];
        while (_peek() != ('close', 'array')) {
          list.add(_value());
        }
        _next();
        return list;
      case 'string':
        return _textUntil('string');
      case 'integer':
        return int.parse(_textUntil('integer').trim());
      case 'real':
        return double.parse(_textUntil('real').trim());
      default:
        throw FormatException('<$tag>');
    }
  }
}

const _collectedTypes = [
  'NSPrivacyCollectedDataTypePhotosorVideos',
  'NSPrivacyCollectedDataTypeHealth',
  'NSPrivacyCollectedDataTypeOtherUserContent',
];

/// Chinese, Japanese and full-width characters.
final _cjk = RegExp(r'[⺀-鿿豈-﫿＀-￯　-〿]');

/// Characters as Play counts them: one per Unicode code point, full-width
/// and half-width alike (answer/9866151). A file's final newline is not
/// part of the pasted text.
int _playLength(String fileText) =>
    fileText.replaceFirst(RegExp(r'\n$'), '').runes.length;

/// (width, height, bit depth, colour type) from a PNG's IHDR chunk; colour
/// type 6 is RGBA (with 8-bit depth: "32-bit"), 2 is RGB ("24-bit").
(int, int, int, int) _pngHeader(File file) {
  final b = file.readAsBytesSync();
  expect(b.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      reason: '${file.path} is not a PNG');
  expect(String.fromCharCodes(b.sublist(12, 16)), 'IHDR', reason: file.path);
  int u32(int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
  return (u32(16), u32(20), b[24], b[25]);
}

/// GitHub Actions' filter pattern for a tag (`*` matches anything but `/`,
/// `**` anything), enough for the patterns release.yml uses.
bool _githubTagMatches(String pattern, String tag) {
  final re = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        re.write('.*');
        i++;
      } else {
        re.write('[^/]*');
      }
    } else {
      re.write(RegExp.escape(c));
    }
  }
  re.write(r'$');
  return RegExp(re.toString()).hasMatch(tag);
}

/// The privacy policy's effective date, in one place: docs/PRIVACY.md's
/// "Effective date:" line must say the same. Whoever merges a branch that
/// changes the policy sets both to the merge date (docs/RELEASING.md § 6.8);
/// this pin can only check that they agree, not that the date is new.
const kPolicyEffectiveDate = '2026-11-24';

/// x.y.z against x.y.z, number by number (1.10.0 is above 1.9.0).
int _compareVersions(String a, String b) {
  final x = [for (final p in a.split('.')) int.parse(p)];
  final y = [for (final p in b.split('.')) int.parse(p)];
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return 0;
}

/// The versions docs/PRIVACY.md dates a change from, in English ("From
/// version X.Y.Z", what release.yml's plan step reads) and in 中文 ("从
/// X.Y.Z 版本起"), whitespace squeezed first as the plan step does.
({List<String> en, List<String> zh}) _policyVersions(String policy) {
  final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
  return (
    en: [
      for (final m in RegExp(r'From version (\d+\.\d+\.\d+)').allMatches(flat))
        m.group(1)!,
    ],
    zh: [
      for (final m in RegExp(r'从 (\d+\.\d+\.\d+) 版本起').allMatches(flat))
        m.group(1)!,
    ],
  );
}

/// pubspec.yaml's x.y.z.
String _pubspecVersion(String pubspec) =>
    RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+', multiLine: true)
        .firstMatch(pubspec)!
        .group(1)!;

/// The Android-only versions out on GitHub (decision 4, docs/RELEASING.md
/// § 6.6), oldest first: each one's version, build number, the day it went
/// out (in the repo's local time), the hand-build `+N` pubspec had at its
/// commit (§ 5) and that commit, where its tag is. None reached the App
/// Store, so the iPhone skips each one's version below main's, even once
/// one of their bundles is the first Play upload (§ 6.3; PREP-R6,
/// 2026-11-23). main builds a version above each of them, with a `+N`
/// above each one's (PREP-R3, 2026-11-23), except the newest, whose
/// version and `+N` main keeps until the next bump: android-v1.7.2 went
/// out from main at 1.7.2+11 on 2026-11-24, so the next Android-only
/// version is bumped first (§ 6.6), and until then main's next iPhone tag
/// is v1.7.2, a version the iPhone does not skip.
const _kAndroidReleases = [
  (version: '1.7.0', build: 207, day: '2026-11-19', plus: 9, sha: '610df6c6'),
  (version: '1.7.1', build: 209, day: '2026-11-22', plus: 10, sha: '189f34c6'),
  (version: '1.7.2', build: 210, day: '2026-11-24', plus: 11, sha: 'c7a0e8a5'),
];

/// "a", "a and b", "a, b and c".
String _andList(List<String> items) => items.length == 1
    ? items.single
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

/// The Android-only versions the iPhone skips: those below main's next
/// iPhone version, pubspec's [version]. One that holds pubspec's own
/// version is not skipped: main's next iPhone tag is that version until
/// the next bump.
List<String> _iphoneSkipped(String version) => [
      for (final r in _kAndroidReleases)
        if (_compareVersions(r.version, version) < 0) r.version,
    ];

/// The versions the iPhone skips, as RELEASING and the maintainer notes
/// list them: "1.7.0 and 1.7.1" while pubspec is 1.7.2.
String _iphoneSkips(String version) => _andList(_iphoneSkipped(version));

/// docs/RELEASING.md § 6.8's step before the lane play run (RD-1).
const _kVersionStep = '`version:` in `app/pubspec.yaml` must not be below '
    'the newest *From version X.Y.Z* in `docs/PRIVACY.md`';

/// The docs/PRIVACY.md the release.yml plan harness (R15 below) writes
/// unless a test gives its own: its newest version is the harness's
/// pubspec version, 1.7.0.
const _kStubPolicy = 'Effective date: 2026-11-20\n\n'
    'From version 1.6.0 the app does A. From version 1.7.0, on Android,\n'
    'it does B.\n';

/// What docs/RELEASING.md lacks while pubspec is below the newest version
/// the policy names: § 6.6 naming the version to bump to, and § 6.8's
/// version step before its lane play run. Empty when pubspec is not behind.
List<String> _versionGateGaps(
    {required String policy,
    required String pubspec,
    required String releasing}) {
  final v = _policyVersions(policy);
  final named = [...v.en, ...v.zh];
  if (named.isEmpty) return const [];
  final newest =
      named.reduce((a, b) => _compareVersions(a, b) >= 0 ? a : b);
  final current = _pubspecVersion(pubspec);
  if (_compareVersions(current, newest) >= 0) return const [];
  final flat = releasing.replaceAll(RegExp(r'\s+'), ' ');
  final gaps = <String>[];
  if (!flat.contains('set `version:` in `app/pubspec.yaml` and '
      '`kAppVersion` (`lib/services/backup/backup_files.dart`) to '
      '`$newest` or later')) {
    gaps.add('pubspec says $current and the policy names $newest: '
        'RELEASING.md § 6.6 must say to bump ("… to `$newest` or later")');
  }
  final at = flat.indexOf('### 6.8 Owner checklist, in order');
  final end = at < 0 ? -1 : flat.indexOf('### 6.9 ', at);
  final s68 = at < 0 ? '' : flat.substring(at, end < 0 ? flat.length : end);
  final step = s68.indexOf(_kVersionStep);
  final run = s68.indexOf('Run workflow › `main` › lane `play`');
  if (step < 0 || run < 0 || step > run) {
    gaps.add('pubspec says $current and the policy names $newest: '
        'RELEASING.md § 6.8 must keep its version step before the lane '
        'play run');
  }
  return gaps;
}

void main() {
  group('R-F8: App Privacy answer B in the manifests', () {
    test('the plist reader reads what it should', () {
      expect(
        parsePlist(
          '<?xml version="1.0"?><plist version="1.0"><dict>'
          '<key>a</key><array><string>x &amp; y</string><true/></array>'
          '<!-- note --><key>b</key><dict/><key>c</key><integer>3'
          '</integer></dict></plist>',
        ),
        {
          'a': ['x & y', true],
          'b': <String, Object?>{},
          'c': 3,
        },
      );
      expect(
        () => parsePlist('<plist><dict><key>a</key></dict></plist>'),
        throwsFormatException,
      );
    });

    test('Runner declares exactly Photos or Videos, Health and Other User '
        'Content — App Functionality, not linked, no tracking', () {
      final manifest =
          parsePlist(_read('ios/Runner/PrivacyInfo.xcprivacy'))
              as Map<String, Object?>;
      expect(manifest['NSPrivacyTracking'], isFalse);
      expect(manifest['NSPrivacyTrackingDomains'], isEmpty);
      final types = (manifest['NSPrivacyCollectedDataTypes'] as List)
          .cast<Map<String, Object?>>();
      expect(
        types.map((t) => t['NSPrivacyCollectedDataType']),
        unorderedEquals(_collectedTypes),
      );
      for (final t in types) {
        expect(
          t.keys,
          unorderedEquals([
            'NSPrivacyCollectedDataType',
            'NSPrivacyCollectedDataTypeLinked',
            'NSPrivacyCollectedDataTypeTracking',
            'NSPrivacyCollectedDataTypePurposes',
          ]),
        );
        expect(
          t['NSPrivacyCollectedDataTypeLinked'],
          isFalse,
          reason: '${t['NSPrivacyCollectedDataType']}: not linked',
        );
        expect(
          t['NSPrivacyCollectedDataTypeTracking'],
          isFalse,
          reason: '${t['NSPrivacyCollectedDataType']}: no tracking',
        );
        expect(t['NSPrivacyCollectedDataTypePurposes'], [
          'NSPrivacyCollectedDataTypePurposeAppFunctionality',
        ]);
      }
    });

    // The share extension sends nothing itself: it copies the shared photo
    // into the App Group container and opens the app, which asks for
    // consent and does the sending. So its own manifest declares no
    // collected data; the app's covers the data.
    test('the share extension declares none: the app does the sending', () {
      final manifest =
          parsePlist(_read('ios/ShareExtension/PrivacyInfo.xcprivacy'))
              as Map<String, Object?>;
      expect(manifest['NSPrivacyTracking'], isFalse);
      expect(manifest['NSPrivacyCollectedDataTypes'], isEmpty);
      final swift = _read('ios/ShareExtension/ShareViewController.swift');
      for (final network in ['URLSession', 'URLRequest', 'NWConnection']) {
        expect(
          swift,
          isNot(contains(network)),
          reason: 'the extension must not send anything itself',
        );
      }
    });

    test('RELEASING § 4.3 gives the same answers, click by click', () {
      final releasing = _readRepo('docs/RELEASING.md');
      // Line breaks in the Markdown are not part of the wording.
      final section = releasing
          .substring(
            releasing.indexOf('### 4.3 App Privacy'),
            releasing.indexOf('### 4.4 Review submission checklist'),
          )
          .replaceAll(RegExp(r'\s+'), ' ');
      for (final key in _collectedTypes) {
        expect(section, contains(key));
      }
      for (final label in [
        'Photos or Videos',
        'Health',
        'Other User Content',
        'App Functionality',
        'Yes, we collect data from this app',
        'Publish',
      ]) {
        expect(section, contains(label));
      }
    });

    // One rule for every row: what the app attaches by itself is declared
    // as what it is; what the user types is Other User Content, whatever it
    // is about. Fix's prompt turns a typed weight or workout into an entry
    // (log_weight / log_activity), so the rows must not say "nothing sends
    // workouts" or lean on a typed weight for Health (review 2026-10-29).
    test('§ 4.3 counts typed weights and workouts as Other User Content', () {
      final releasing = _readRepo('docs/RELEASING.md');
      final section = releasing.substring(
        releasing.indexOf('### 4.3 App Privacy'),
        releasing.indexOf('### 4.4 Review submission checklist'),
      );
      String row(String start) {
        final rows = section
            .split('\n')
            .where((l) => l.startsWith('| $start'))
            .toList();
        expect(rows, hasLength(1), reason: 'one § 4.3 row for $start');
        return rows.single;
      }

      final prompt = _readRepo('shared/prompts/text_handler_prompt.txt');
      expect(prompt, contains('"log_weight"'));
      expect(prompt, contains('"log_activity"'));

      final health = row('Health & Fitness → **Health**');
      expect(health, isNot(contains('typed')));
      final fitness = row('Health & Fitness → Fitness');
      expect(fitness, contains('**No**'));
      expect(fitness, isNot(contains('nothing sends')));
      expect(fitness, contains('Other User Content'));
      final other = row('User Content → **Other User Content**');
      expect(other, contains('weight'));
      expect(other, contains('workout'));
      // The manifest follows the table: Fitness stays undeclared.
      expect(
        _read('ios/Runner/PrivacyInfo.xcprivacy'),
        isNot(contains('NSPrivacyCollectedDataTypeFitness')),
      );
    });
  });

  group('R-F14: the support page', () {
    final support = _readRepo('docs/SUPPORT.md');

    test('is iPhone-only: no Android, APK, Telegram or VPN', () {
      for (final word in [
        'android',
        'apk',
        'telegram',
        'vpn',
        'google play',
        'play store',
        'sideload',
        'termux',
      ]) {
        expect(support.toLowerCase(), isNot(contains(word)), reason: word);
      }
    });

    test('names exactly the support address the owner chose', () {
      final emails = RegExp(
        r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+',
      ).allMatches(support).map((m) => m.group(0)).toSet();
      expect(emails, {'junjia.wang.me@gmail.com'});
      expect(support, isNot(contains('owner to choose')));
      expect(
        support,
        contains('https://github.com/AkiyamaKunka/Chopstats/issues'),
      );
    });

    test('is the support URL of both store listings', () {
      for (final locale in ['en-US', 'zh-Hans']) {
        expect(
          _read('ios/store/metadata/$locale/support_url.txt').trim(),
          'https://github.com/AkiyamaKunka/Chopstats/blob/main/docs/'
          'SUPPORT.md',
          reason: locale,
        );
      }
    });
  });

  // Owner decision 1 (2026-11-13): the Google Play build ships WITHOUT
  // broad photo access, and the GitHub APK keeps everything
  // (docs/RELEASING.md § 6). One switch, --dart-define=CHOPSTATS_CHANNEL=play
  // (lib/core/app_channel.dart and the manifest overlay it turns on): the
  // release lane builds the bundle Play gets with it and the sideload APK
  // without, and checks both before anything is uploaded or released.
  group('the Play channel in the release lane', () {
    final workflow = _readRepo('.github/workflows/release.yml');

    /// The step named [name], through to the next step.
    String step(String name) {
      final start = workflow.indexOf('      - name: $name\n');
      expect(start, isNonNegative, reason: name);
      final next = RegExp(r'\n      - (name|uses):')
          .firstMatch(workflow.substring(start + 1));
      return workflow.substring(
          start, next == null ? workflow.length : start + 1 + next.start);
    }

    /// Each `flutter build <kind>` command in [text], continuation lines
    /// included.
    List<String> builds(String text, String kind) => [
          for (final m in RegExp('flutter build $kind\\b'
                  r'(?:[^\\\n]|\\\n)*')
              .allMatches(text))
            m.group(0)!,
        ];

    test('the bundle is built with the define, the GitHub APK without it',
        () {
      final build = step('Build the signed app bundle and the arm64 APK');
      final bundle = builds(build, 'appbundle');
      final apk = builds(build, 'apk');
      expect(bundle, hasLength(1));
      expect(apk, hasLength(1));
      expect(bundle.single, contains('--dart-define=CHOPSTATS_CHANNEL=play'));
      expect(apk.single, isNot(contains('CHOPSTATS_CHANNEL')));
      expect(apk.single, contains('--target-platform android-arm64'));
      // Different Dart code: each build keeps its own Dart symbols.
      expect(bundle.single,
          contains('--split-debug-info=build/android/symbols/play'));
      expect(apk.single,
          contains('--split-debug-info=build/android/symbols/github'));
      // No other build in the lane carries the define.
      expect('CHOPSTATS_CHANNEL=play'.allMatches(workflow).length,
          'CHOPSTATS_CHANNEL=play'.allMatches(build).length + 1,
          reason: 'once in the bundle build, once in the check\'s message');
    });

    test('the run stops if the bundle asks for a photo permission or the '
        'APK lost READ_MEDIA_IMAGES, before any upload', () {
      final check = step('Check the Play bundle asks for no photo permission '
          'and the APK keeps them');
      expect(check, contains("if: steps.secrets.outputs.ready == 'true'"));
      for (final kind in ['aab', 'apk']) {
        expect(check,
            contains('in_$kind=\$(scripts/android_permissions.sh "\$$kind")'));
      }
      expect(check,
          contains('aab=app/build/app/outputs/bundle/release/app-release.aab'));
      expect(check,
          contains('apk=app/build/app/outputs/flutter-apk/app-release.apk'));
      expect(
          check,
          contains('for p in READ_MEDIA_IMAGES READ_MEDIA_VISUAL_USER_SELECTED '
              'READ_EXTERNAL_STORAGE; do'));
      expect(check,
          contains(r'grep -qx "android.permission.$p" <<<"$in_aab"'));
      expect(
          check,
          contains(r'grep -qx android.permission.READ_MEDIA_IMAGES '
              r'<<<"$in_apk"'));
      // A listing with nothing in it never passes the deny-list by default:
      // the bundle must list INTERNET first (review, 2026-11-19).
      const readable = r'grep -qx android.permission.INTERNET <<<"$in_aab"';
      expect(check, contains(readable));
      expect(check.indexOf(readable),
          lessThan(check.indexOf('for p in READ_MEDIA_IMAGES')));
      expect('exit 1'.allMatches(check), hasLength(3));
      final at = workflow.indexOf(check);
      expect(at,
          lessThan(workflow.indexOf('uses: r0adkll/upload-google-play')));
      expect(
          at,
          lessThan(workflow.indexOf(
              'uses: actions/upload-artifact', workflow.indexOf('  android:'))),
          reason: 'the GitHub Release takes the APK from that artifact');
      expect(
          workflow,
          contains('releaseFiles: '
              'app/build/app/outputs/bundle/release/app-release.aab'));
      // The script it reads them with: aapt2, and a bundle's own manifest.
      final script = _readRepo('scripts/android_permissions.sh');
      expect(script, contains('dump permissions'));
      expect(script,
          contains('base/manifest/AndroidManifest.xml base/resources.pb'));
    });
  });

  group('R-F11: neutral English', () {
    // Provider brand names may carry their Chinese name; nothing else may.
    const brandNames = ['深度求索', '通义千问', '豆包', '智谱'];
    // Where a provider PROCESSES the data is a privacy disclosure, not
    // reachability advice: the consent dialog keeps it.
    const disclosures = {'aiConsentChinaNote'};
    final mainlandOrVpn = RegExp(
      r'\bvpn\b|mainland|\bchina\b|chinese|hong kong|firewall',
      caseSensitive: false,
    );

    final en = (jsonDecode(_read('lib/l10n/app_en.arb')) as Map)
        .cast<String, Object?>();

    test('no English string carries Chinese text', () {
      for (final MapEntry(:key, :value) in en.entries) {
        if (key.startsWith('@')) continue;
        var text = value as String;
        for (final brand in brandNames) {
          text = text.replaceAll(brand, '');
        }
        expect(_cjk.hasMatch(text), isFalse, reason: '$key: $value');
      }
    });

    test('no English string gives mainland-China or VPN advice', () {
      for (final MapEntry(:key, :value) in en.entries) {
        if (key.startsWith('@') || disclosures.contains(key)) continue;
        expect(
          mainlandOrVpn.hasMatch(value as String),
          isFalse,
          reason: '$key: $value',
        );
      }
      expect(
        AppLocalizationsEn().aiConsentChinaNote('DeepSeek'),
        contains('mainland China'),
        reason: 'the processing-location disclosure stays',
      );
    });

    test('the API key page: no reachability notes, no 免费 in English; '
        'Chinese unchanged', () {
      final en = AppLocalizationsEn();
      final zh = AppLocalizationsZh();
      for (final (id, _, tag) in kApiKeyChoices) {
        final note = noteLabel(en, tag) ?? '';
        expect(_cjk.hasMatch(note), isFalse, reason: id);
        expect(mainlandOrVpn.hasMatch(note), isFalse, reason: id);
      }
      expect(noteLabel(en, 'vpn'), isNull);
      expect(noteLabel(en, 'direct'), isNull);
      expect(noteLabel(zh, 'vpn'), '需要 VPN');
      expect(noteLabel(zh, 'freeDirect'), '免费 · 中国直连');
      for (final MapEntry(key: provider, value: models)
          in kKnownModels.entries) {
        for (final (id, label) in models) {
          final shown = modelChoiceLabel(en, label);
          expect(_cjk.hasMatch(shown), isFalse, reason: '$provider $id');
          expect(shown, isNot(contains('{')), reason: '$provider $id');
        }
      }
      final glm = kKnownModels['glm']!.first.$2;
      expect(modelChoiceLabel(en, glm), 'glm-4.6v-flash — FREE, default');
      expect(modelChoiceLabel(zh, glm), 'glm-4.6v-flash — FREE 免费, default');
    });
  });

  group('R-F9: Chopstats', () {
    // 2026-10-29: "BiteWise" is shared by a dozen live US App Store apps,
    // so the English name became Chopstats (no same-name US app, no live
    // USPTO mark); 筷拍 stays. The repository kept its old name until
    // 2026-11-09, when it became AkiyamaKunka/Chopstats too (GitHub
    // redirects the old links, which the 1.5.0 build still opens).
    const repoUrl = 'github.com/AkiyamaKunka/Chopstats';
    void expectNoOldName(String text, {String? reason}) {
      final rest = text.replaceAll(repoUrl, '');
      expect(rest, isNot(contains('BiteWise')), reason: reason);
      expect(rest, isNot(contains('Bitewise')), reason: reason);
    }

    String? plistString(String plist, String key) => RegExp(
      '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(plist)?.group(1);
    String? stringsValue(String strings, String key) => RegExp(
      '"${RegExp.escape(key)}"\\s*=\\s*"([^"]*)";',
    ).firstMatch(strings)?.group(1);

    for (final target in ['Runner', 'ShareExtension']) {
      test('$target: Chopstats in English, 筷拍 in Chinese', () {
        final plist = _read('ios/$target/Info.plist');
        final en = _read('ios/$target/en.lproj/InfoPlist.strings');
        final zh = _read('ios/$target/zh-Hans.lproj/InfoPlist.strings');
        expect(plistString(plist, 'CFBundleDisplayName'), 'Chopstats');
        expect(stringsValue(en, 'CFBundleDisplayName'), 'Chopstats');
        expect(stringsValue(zh, 'CFBundleDisplayName'), '筷拍');
        for (final text in [plist, en]) {
          expectNoOldName(text);
        }
        expect(
          plistString(plist, 'NSPhotoLibraryUsageDescription'),
          startsWith('Chopstats reads your photo library'),
        );
        expect(
          stringsValue(en, 'NSPhotoLibraryUsageDescription'),
          startsWith('Chopstats reads your photo library'),
        );
      });
    }

    test('the English strings, the policy and the listing', () {
      final arb = _read('lib/l10n/app_en.arb');
      expectNoOldName(arb);
      expect(arb, contains('Chopstats'));
      expectNoOldName(_readRepo('docs/PRIVACY.md'));
      expectNoOldName(_readRepo('docs/SUPPORT.md'));
      expectNoOldName(_read('lib/ui/app.dart'));
      // The listing's own files, not a checkout's .DS_Store (binary) or
      // git mergetool's .orig (see store_listing_files.dart).
      final listing = storeListingFiles(
        Directory('${_appRoot().path}/ios/store/metadata'),
        recursive: true,
      );
      expect(listing, isNotEmpty);
      for (final file in listing) {
        expectNoOldName(file.readAsStringSync(), reason: file.path);
      }
      for (final locale in ['en-US', 'zh-Hans']) {
        expect(
          _read('ios/store/metadata/$locale/name.txt').trim(),
          'Chopstats · 筷拍',
        );
      }
    });
  });

  group('R-F7: the privacy policy names the third parties', () {
    final policy = _readRepo('docs/PRIVACY.md');

    test('in English and 中文, with the new effective date', () {
      // The merge of PR #19 (restaurant lookup) changed the policy again,
      // and so did its "Which meals" bullet, rewritten on 2026-11-05 for
      // the auto_branding trigger, and the usual-foods PR on 2026-11-07
      // (saved lookup answers kept up to a year; My usual foods). The date
      // and this pin are set by hand, and again to the merge date when PR
      // #19 merges, when the usual-foods PR merges and when PR #22 merges
      // (docs/RELEASING.md): a 3-way merge keeps the older date without a
      // conflict. PR #19 and the usual-foods PR both merged on 2026-11-09;
      // the 1.6.0 review fixes, which also name the maker of the OpenRouter
      // model a lookup goes to, merged on 2026-11-10; run 7 (PR #22: the
      // day before's meals with a photo taken before 4 a.m., under the
      // consent text that says so) merged on 2026-11-11, and so did the
      // 1.7.0 iCloud Backup (PR #36: the iCloud Backup section). Review
      // r171 changed it on 2026-11-13: activities in what an export holds,
      // and that iOS can keep API keys in the Keychain after uninstalling.
      // The Google Play release (android/release, 2026-11-13) changed it
      // again: Who we are, adults only, https only, and Android's backup
      // leaving the keys out. If that branch merges on a later day, set the
      // date and kPolicyEffectiveDate to the merge date. The Android
      // look-and-defaults branch (android/feel-and-defaults, #72) changed it
      // again and merged on 2026-11-20: Android's cloud backup only
      // end-to-end encrypted (a screen lock), and Meta glasses photos off
      // by default on Android. The Android lows lane
      // (android/lows-and-release, #74, 2026-11-20) changed it again:
      // Connect Claude sends your own server the sign-in code you paste; if
      // it merges on a later day, set both to that day too. The legacy
      // upload key lane (android/legacy-key-host, #78, 2026-11-21) changed
      // it again: a Server upload key saved without its server address is
      // removed with Remove this key, its field being empty; if it merges
      // on a later day, set both to that day too. The Edit meal note
      // (feat/meal-note-correction, 2026-11-24) changed it again: what a
      // note sends and that the notes are kept with the meal; it merges
      // after the 1.8.0 prep, so set both to its merge day then.
      expect(
          RegExp(r'^Effective date: (\S+)$', multiLine: true)
              .allMatches(policy)
              .map((m) => m.group(1))
              .toList(),
          [kPolicyEffectiveDate]);
      expect(policy, contains('### Third parties and your consent'));
      expect(policy, contains('### 第三方与你的同意'));
      expect(policy, contains('Stop Sharing with …'));
      expect(policy, contains('停止发送给 …'));
      // Own-server wording, not the plan's old name.
      expect(policy, contains('**Your own server**'));
      expect(policy, isNot(contains('**Claude Plan**')));
      // No promise that every provider protects data the same way.
      for (final claim in ['equal protection', 'same protection', '同等保护']) {
        expect(policy, isNot(contains(claim)));
      }
    });

    // 1.7.0 iCloud Backup: the policy says where the copy lives, what is
    // never in it, that the developer cannot see it, and how to delete it,
    // in both languages.
    test('iCloud Backup: own iCloud, never the keys, deletable', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      expect(policy, contains('### iCloud Backup (iPhone)'));
      expect(policy, contains('### iCloud 备份（iPhone）'));
      expect(flat, contains('**What is never copied:** API keys'));
      expect(flat, contains('**绝不会复制的内容**：API Key'));
      expect(flat, contains('the developer cannot see them and runs no server'));
      expect(flat, contains('开发者看不到它们'));
      expect(flat, contains('nothing is uploaded until you answer it'));
      expect(flat, contains('在你回答之前不会上传任何内容'));
      expect(flat, contains('uninstalling the app does not delete it'));
      expect(flat, contains('卸载应用不会删除它'));
      expect(flat, contains('Apart from the copy **iCloud Backup** keeps'));
    });

    // The section names the recipient, so it must not open by saying the
    // data is shared with no one (review 2026-10-29).
    test('says who it shares with, never "with anyone"', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      for (final claim in [
        'share it with anyone',
        'shared with anyone',
        'with no one',
        '不会与任何人分享',
        '不与任何人分享',
      ]) {
        expect(flat, isNot(contains(claim)));
      }
      expect(
        flat,
        contains(
          'Chopstats does not sell your data. It shares it only with the AI '
          'recipient you set up under Settings › AI Provider',
        ),
      );
      expect(
        policy,
        contains(
          '筷拍不会出售你的数据，'
          '只会把它发送给你在 设置 › AI 服务 里设置的那个 AI 接收方',
        ),
      );
    });

    // Google Play's User Data policy wants the developer and a privacy
    // contact in the policy (answer/10144311). Nothing personal is written
    // here: the policy points at the store pages and GitHub issues, not at
    // the iPhone-only support page.
    test('Who we are: the store pages and a contact, adults only, '
        'in English and 中文', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      expect(policy, contains('### Who we are'));
      expect(policy, contains('### 我们是谁'));
      expect(flat, contains("the developer email shown on Chopstats' Google "
          'Play page'));
      expect(flat, contains('筷拍 Google Play 页面上显示的开发者邮箱'));
      final who = flat.substring(
          flat.indexOf('### Who we are'), flat.indexOf('### What stays'));
      expect(who, contains('https://github.com/AkiyamaKunka/Chopstats/issues'));
      expect(who, isNot(contains('SUPPORT.md')));
      final zhWho = flat.substring(
          flat.indexOf('### 我们是谁'), flat.indexOf('### 留在你手机上的数据'));
      expect(zhWho, contains('https://github.com/AkiyamaKunka/Chopstats/issues'));
      expect(zhWho, isNot(contains('SUPPORT.md')));
      expect(flat, contains('Chopstats is meant for adults (18 and over).'));
      expect(flat, contains('筷拍面向成年人（18 岁及以上）'));
      // No address of its own: the one public address lives on the
      // support page (R-F14 above).
      expect(
          RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]').hasMatch(policy),
          isFalse);
    });

    // Owner decision 2 (2026-11-13): plain http:// server addresses are
    // refused everywhere from 1.7.0, so nothing goes unencrypted. The
    // policy is also the App Store's for every 1.6.x copy, which still
    // accepts http://, so it says from which version (review finding M1).
    test('your own server is https only from 1.7.0, in English and 中文', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      expect(
          flat,
          contains('From version 1.7.0 the address must start with '
              '`https://`: the app refuses an `http://` address and sends '
              'nothing to it'));
      expect(flat, contains('(Earlier versions also accepted an `http://` address'));
      expect(flat,
          contains('从 1.7.0 版本起，服务器地址必须以 `https://` 开头：应用会拒绝 '
              '`http://` 地址'));
      expect(flat,
          contains('From version 1.7.0, every request leaves the phone over an '
              'encrypted HTTPS connection.'));
      expect(flat, contains('从 1.7.0 版本起，所有请求都通过加密的 HTTPS 连接离开手机。'));
      expect(flat, contains('From version 1.7.0, on Android, API keys'));
      expect(flat, contains('从 1.7.0 版本起，在 Android 上，API Key'));
      expect(flat,
          isNot(contains('over `http://` lookups use printed brands only')));
    });

    // Owner decisions 8 and 5 (2026-11-20) narrow what Android sends: Meta
    // glasses photos are off until turned on, and the Google backup takes
    // the app's data only end-to-end encrypted. The published
    // android-v1.7.0 (b207) does neither, and every build opens this
    // policy from main, so both say from which version, as M1's do
    // (review of #72).
    test("Android's glasses default and end-to-end-only backup are from "
        '1.7.1, in English and 中文', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      expect(
          flat,
          contains('From version 1.7.1, on Android, which has no such check, '
              'that switch is off until you turn it on. (Earlier versions on '
              'Android had it on until you turned it off.)'));
      expect(
          flat,
          contains('从 1.7.1 版本起，由于 Android 上没有这项检查，这个开关在 '
              'Android 上默认关闭，需要时可以自己打开。（更早的版本在 Android '
              '上默认打开。）'));
      expect(
          flat,
          contains("From version 1.7.1, on Android, the app's data goes into "
              'the backup in your Google account only when it is end-to-end '
              'encrypted'));
      expect(
          flat,
          contains('(Earlier versions backed it up whether or not it was '
              'end-to-end encrypted, and a transfer carried it on every '
              'Android version.)'));
      expect(
          flat,
          contains('从 1.7.1 版本起，在 Android 上，只有在端到端加密时，应用数据才'
              '会进入你 Google 账户中的备份'));
      expect(
          flat,
          contains('（更早的版本无论是否端到端加密都会备份应用数据，在所有 Android '
              '版本上转移时也会带上。）'));
      // Neither sentence without its version.
      expect(flat, isNot(contains('still sent. On Android, which has no such')));
      expect(flat, isNot(contains("--> On Android, the app's data goes")));
      expect(flat, isNot(contains('--> 在 Android 上，只有在端到端加密时')));
    });

    // android-v1.7.0 (b207) carries the name 1.7.0, and the policy dates
    // two Android changes from 1.7.1, so main was 1.7.1 from PR #77 on
    // (decided on 2026-11-20), and it is 1.7.2 since the 1.7.2 prep
    // (decided on 2026-11-23, docs/RELEASING.md § 6.6), with no policy
    // change: 1.7.1 is still the newest version the policy names. Whatever
    // version the policy names last must be the next build's: while
    // pubspec is behind it, § 6.6 names the version to bump to and § 6.8
    // keeps the step before the lane play run (review of #72; RD-1).
    // release.yml's plan step refuses such an Android run (the R15 group
    // runs it).
    test('pubspec is not behind the newest version the policy names', () {
      final v = _policyVersions(policy);
      expect(v.en, contains('1.7.1'));
      expect(v.en.toSet(), v.zh.toSet(),
          reason: 'every version is named in English and in 中文');
      final pubspec = _read('pubspec.yaml');
      expect(_compareVersions(_pubspecVersion(pubspec), '1.7.1'),
          greaterThanOrEqualTo(0),
          reason: 'android-v1.7.0 went out as 1.7.0; the next build is '
              '1.7.1 or later');
      expect(
          _versionGateGaps(
              policy: policy,
              pubspec: pubspec,
              releasing: _readRepo('docs/RELEASING.md')),
          isEmpty);
    });

    test('RELEASING.md § 6.6 and § 6.8 must catch up when the policy runs '
        'ahead of pubspec', () {
      final pubspec = _read('pubspec.yaml');
      final parts =
          _pubspecVersion(pubspec).split('.').map(int.parse).toList();
      final next = '${parts[0]}.${parts[1]}.${parts[2] + 1}';
      final ahead = '$policy\nFrom version $next, on Android, X. '
          '从 $next 版本起，在 Android 上，X。\n';
      final releasing =
          _readRepo('docs/RELEASING.md').replaceAll(RegExp(r'\s+'), ' ');
      final bump = ' Before the next build, set `version:` in '
          '`app/pubspec.yaml` and `kAppVersion` '
          '(`lib/services/backup/backup_files.dart`) to `$next` or later.';
      final without = releasing.replaceAll(_kVersionStep, 'pubspec is fine');
      expect(without, isNot(contains(_kVersionStep)));

      // Today's § 6.8 has the step, and § 6.6 names no bump to `next`.
      expect(
          _versionGateGaps(policy: ahead, pubspec: pubspec, releasing: releasing)
              .single,
          contains('§ 6.6 must say to bump ("… to `$next` or later")'));
      // § 6.6 names it, but § 6.8 lost its step.
      expect(
          _versionGateGaps(
                  policy: ahead, pubspec: pubspec, releasing: without + bump)
              .single,
          contains('§ 6.8 must keep its version step'));
      // Without either.
      expect(
          _versionGateGaps(policy: ahead, pubspec: pubspec, releasing: without),
          hasLength(2));
      // The step moved after the lane play run does not count.
      final s68 = releasing.indexOf('### 6.8 Owner checklist, in order');
      final run = releasing.indexOf('Run workflow › `main` › lane `play`', s68);
      expect(releasing.indexOf(_kVersionStep, s68), inExclusiveRange(s68, run));
      final moved = releasing.substring(0, s68) +
          releasing.substring(s68, run).replaceFirst(_kVersionStep, 'see below') +
          releasing
              .substring(run)
              .replaceFirst('### 6.9 ', '$_kVersionStep. ### 6.9 ');
      expect(
          _versionGateGaps(
                  policy: ahead, pubspec: pubspec, releasing: moved + bump)
              .single,
          contains('§ 6.8'));
      // Both: nothing missing.
      expect(
          _versionGateGaps(
              policy: ahead, pubspec: pubspec, releasing: releasing + bump),
          isEmpty);
      // The 中文 sentence alone moves the newest version too.
      expect(
          _versionGateGaps(
              policy: '$policy\n从 $next 版本起，X。\n',
              pubspec: pubspec,
              releasing: releasing),
          hasLength(1));
    });

    test('Describe sends no meals; Fix sends the last 7 days', () {
      expect(policy, contains('today\'s date. No other meals are sent.'));
      expect(policy, contains('不发送其他餐食'));
      final en = AppLocalizationsEn().aiConsentBody('X');
      expect(en, contains('• what you type to describe a meal\n'));
      expect(
        en,
        contains(
          '• what you type to fix a meal, with your meals '
          'from the last 7 days',
        ),
      );
      final zh = AppLocalizationsZh().aiConsentBody('X');
      expect(zh, contains('• 你为描述一餐输入的文字\n'));
      expect(zh, contains('• 你为修正餐食输入的文字，连同最近 7 天的餐食'));
    });

    // The Edit meal note (owner 2026-11-24): the policy and the consent
    // text say what a note sends — the new note, that meal's earlier notes,
    // its description, foods and numbers; no photo, date, time or other
    // meal — that the notes are kept with the meal (exports and backups
    // included) until removed or the meal is deleted, and that an older
    // grant is asked once more at the first note.
    test('an Edit meal note: what is sent, what is kept, asked first', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      for (final sentence in [
        'A meal you corrected with a note in **Edit meal** (*Correct with a '
            'note*) keeps the notes you sent about it, each with when you '
            'sent it.',
        "included in your exports and your phone's backups (and in iCloud "
            'Backup on iPhone), until you remove them in Edit meal or '
            'delete the meal.',
        'your note, the notes you sent about that meal before (marked as '
            'already applied, so they are not applied again), and that one '
            "meal's description and foods with their calorie, protein, "
            'carbohydrate and fat estimates, as the editor shows them. No '
            'photo, no date or time, and no other meal is sent.',
        '**A note in Edit meal** sends what you typed, the notes you sent '
            'about that meal before, and its description, foods and numbers '
            '— no photo, no date or time, and no other meal.',
        'If you allowed AI analysis before notes in Edit meal were added, '
            'the app asks you once more the first time you send one, and the '
            'note goes only after you allow it.',
        '会保存你为它发送过的说明，以及每条的发送时间。',
        '并包含在导出文件和手机的备份中（iPhone 上也包括「iCloud 备份」），'
            '直到你在编辑页里删除它们，或删除这一餐。',
        '你写的说明、你以前为这一餐发送过的说明（标明已经应用，不会再次应用），'
            '以及编辑页上显示的这一餐的描述、食物和各自的热量、蛋白质、碳水、脂肪'
            '估算。不发送照片、日期或时间，也不发送其他餐食。',
        '**编辑这一餐里的说明**会发送你输入的文字、你以前为这一餐发送过的说明，'
            '以及这一餐的描述、食物和数值，不发送照片、日期或时间，也不发送其他餐食。',
        '如果你在加入「编辑这一餐」的说明修正之前就已允许 AI 分析，第一次发送说明时'
            '应用会再询问你一次；你允许之后才会发送。',
      ]) {
        expect(flat, contains(sentence), reason: sentence);
      }
      expect(
          AppLocalizationsEn().aiConsentBody('X'),
          contains('• a note you type in Edit meal to correct a meal, with '
              "that meal's description, foods and numbers and its earlier "
              'notes (kept with the meal)\n'));
      expect(
          AppLocalizationsZh().aiConsentBody('X'),
          contains('• 你在「编辑这一餐」里为修正一餐写的说明，连同这一餐的描述、'
              '食物、数值和之前的说明（说明会随这一餐保存）\n'));
      // No "From version" sentence: the feature is described additively,
      // and release.yml's Android version gate is unaffected.
      expect(flat, isNot(contains('From version 1.8')));
      expect(flat, isNot(contains('从 1.8')));
    });
  });
  group('Google Play listing (app/android/store/metadata)', () {
    const locales = ['en-US', 'zh-CN'];
    String listing(String locale, String name) =>
        _read('android/store/metadata/$locale/$name.txt');

    test("title, short and full descriptions fit Play's limits", () {
      for (final locale in locales) {
        final title = listing(locale, 'title');
        final short = listing(locale, 'short_description');
        final full = listing(locale, 'full_description');
        expect(title.trim(), 'Chopstats · 筷拍', reason: locale);
        expect(_playLength(title), lessThanOrEqualTo(30), reason: locale);
        expect(_playLength(short), inInclusiveRange(10, 80), reason: locale);
        expect(_playLength(full), inInclusiveRange(500, 4000), reason: locale);
        // Google's advice for the short description: no special characters
        // (the title's single · is fine there), no closing period.
        expect(short, isNot(contains('·')), reason: locale);
        expect(short.trim(), isNot(endsWith('.')), reason: locale);
      }
      expect(_playLength('筷拍\n'), 2, reason: 'one per character');
    });

    // The Health Content and Services policy (answer/16679511): Google's
    // disclaimer in the description, word for word, and the reminder to
    // consult a healthcare professional.
    test("the full descriptions end with Google's health disclaimer", () {
      final en = listing('en-US', 'full_description')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      expect(
          en,
          contains('Chopstats is not a medical device and does not diagnose, '
              'treat, cure, or prevent any medical condition.'));
      expect(
          en,
          endsWith('Consult a healthcare professional for medical advice, '
              'diagnosis, or treatment.'));
      final zh = listing('zh-CN', 'full_description').trim();
      expect(zh, contains('筷拍不是医疗器械，不能诊断、治疗、治愈或预防任何疾病。'));
      expect(zh, endsWith('如需医疗建议、诊断或治疗，请咨询医疗专业人士。'));
    });

    // Android facts only; nothing the first Play build lacks (decision 1:
    // no Watch Camera Roll on Play), nothing about the sideload channel,
    // and no claim nobody can check.
    test('says nothing iPhone-only, sideload-only or unverifiable', () {
      final banned = RegExp(
        r'github|\bapk\b|sideload|telegram|\bvpn\b|\bios\b|iphone|keychain|'
        r'apple maps|camera roll|glasses|photo coverage|\b174\b|%|#1|\bbest\b|'
        r'accura|worldwide|监控相册|眼镜|钥匙串|照片覆盖|准确率',
        caseSensitive: false,
      );
      for (final locale in locales) {
        for (final name in ['title', 'short_description', 'full_description']) {
          expect(banned.firstMatch(listing(locale, name))?.group(0), isNull,
              reason: '$locale/$name');
        }
      }
    });

    // Review L5: the listing says what Data safety declares as approximate
    // location: a lookup carries the country code US.
    test('the restaurant line names the country code a lookup sends', () {
      expect(listing('en-US', 'full_description'),
          contains('chain and food names and the country code US'));
      expect(listing('zh-CN', 'full_description'),
          contains('连锁店和食物名称以及国家代码 US'));
    });

    test("names the app's controls as the app does", () {
      final en = AppLocalizationsEn();
      final zh = AppLocalizationsZh();
      final enText = listing('en-US', 'full_description');
      final zhText = listing('zh-CN', 'full_description');
      expect(enText, contains(en.addUsual));
      expect(enText, contains(en.settingsSectionRestaurant));
      expect(zhText, contains(zh.addUsual));
      expect(zhText, contains('「${zh.settingsSectionRestaurant}」'));
    });

    // The zh text quotes examples and control names in 「」, as the app and
    // the policy's 中文 half do: no ASCII or curly double quotes.
    test('zh-CN quotes in 「」 only', () {
      for (final name in ['title', 'short_description', 'full_description']) {
        final text = listing('zh-CN', name);
        for (final quote in ['"', '“', '”']) {
          expect(text, isNot(contains(quote)), reason: '$name $quote');
        }
      }
      final full = listing('zh-CN', 'full_description');
      for (final example in [
        '米饭（~150 克）',
        '那碗面其实是烧鸭饭',
        '一碗牛肉面加一个鸡蛋',
        'two eggs and toast with butter',
        '素食',
        '家常菜，少油',
      ]) {
        expect(full, contains('「$example」'), reason: example);
      }
    });

    test('the answers files hold no key and no email address', () {
      for (final name in ['app_content.md', 'data_safety.md']) {
        final text = _read('android/store/$name');
        expect(RegExp(r'AIza[0-9A-Za-z_-]{20,}').hasMatch(text), isFalse,
            reason: '$name: a Google API key');
        expect(RegExp(r'\bsk-[A-Za-z0-9-]{8,}').hasMatch(text), isFalse,
            reason: '$name: an API key');
        expect(
            RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]').hasMatch(text),
            isFalse,
            reason: '$name: an email address');
      }
      expect(_read('android/store/app_content.md'),
          contains("<the demo key from the owner's release notes>"));
    });

    // Data safety by Google's definitions (answer/10787469): anything sent
    // off the phone is collected; not ephemeral; the exemptions named.
    test("data_safety.md answers by Google's definitions", () {
      final text =
          _read('android/store/data_safety.md').replaceAll(RegExp(r'\s+'), ' ');
      for (final type in [
        '**Photos and videos › Photos**',
        '**Health and fitness › Health info**',
        '**Health and fitness › Fitness info**',
        '**App activity › Other user-generated content**',
        '**Location › Approximate location**',
      ]) {
        expect(text, contains(type), reason: type);
      }
      expect(text, contains('**Shared:** No'));
      expect(text, contains('**Processed ephemerally:** No'));
      expect(text, contains('**App functionality** only'));
      expect(text, contains('My app does not allow users to create an account'));
      expect(text, contains('a specific user-initiated action'));
      expect(text,
          contains("a prominent in-app disclosure and the user's consent"));
    });
  });

  group("Play What's new (app/android/whatsnew)", () {
    test('both texts exist, fit 500 characters and point nowhere else', () {
      for (final locale in ['en-US', 'zh-CN']) {
        final text = _read('android/whatsnew/whatsnew-$locale');
        expect(text.trim(), isNotEmpty, reason: locale);
        expect(text.runes.length, lessThanOrEqualTo(500), reason: locale);
        expect(
            RegExp(r'github|\bapk\b|release notes|发布说明|camera roll|监控相册',
                    caseSensitive: false)
                .firstMatch(text)
                ?.group(0),
            isNull,
            reason: locale);
      }
    });
  });

  group('Play graphics, the themed icon and the Android 12+ splash', () {
    test('icon-512 is a 512 x 512 32-bit PNG of at most 1024 KB', () {
      final icon =
          File('${_appRoot().path}/android/store/graphics/icon-512.png');
      expect(_pngHeader(icon), (512, 512, 8, 6));
      expect(icon.lengthSync(), lessThanOrEqualTo(1024 * 1024));
    });

    test('the feature graphics are 1024 x 500 24-bit PNGs, no alpha', () {
      for (final name in ['feature-graphic.png', 'feature-graphic-zh-CN.png']) {
        final f = File('${_appRoot().path}/android/store/graphics/$name');
        expect(_pngHeader(f), (1024, 500, 8, 2), reason: name);
      }
    });

    test('the shot list asks for what Play accepts', () {
      final shots = _read('android/store/screenshots/SHOTS.md')
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(shots, contains('at least 4 portrait shots, 9:16, 1080×1920'));
      expect(shots, contains('24-bit PNG with no alpha'));
    });

    // The shots themselves (scripts/play_screenshots.py). zh-CN has no 06:
    // the Chinese API Key page says which providers need a VPN in mainland
    // China, where Play is not offered, and the listing names no VPN (PR
    // #76 review).
    test('the screenshots: 4 to 8 per language, 1080 x 1920 24-bit PNGs, '
        'no Chinese API Key page', () {
      final dir = '${_appRoot().path}/android/store/screenshots';
      for (final lang in ['en-US', 'zh-CN']) {
        final pngs = Directory('$dir/$lang')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.png'))
            .toList();
        expect(pngs.length, inInclusiveRange(4, 8), reason: lang);
        for (final png in pngs) {
          expect(_pngHeader(png), (1080, 1920, 8, 2), reason: png.path);
        }
      }
      expect(File('$dir/en-US/06_ai_provider.png').existsSync(), isTrue);
      expect(File('$dir/zh-CN/06_ai_provider.png').existsSync(), isFalse);
      final shots = _read('android/store/screenshots/SHOTS.md')
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(shots, contains('VPN or mainland-China notes'));
    });

    // Android 13+ themed icons need a monochrome layer (lint
    // MonochromeLauncherIcon). flutter_launcher_icons writes it from
    // pubspec.yaml, from the layers scripts/play_graphics.py --launcher
    // makes out of assets/app_icon.png.
    test('the adaptive icon has its monochrome layer at every density', () {
      final xml =
          _read('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
      expect(xml, contains('<monochrome>'));
      expect(xml, contains('@drawable/ic_launcher_monochrome'));
      final pubspec = _read('pubspec.yaml');
      expect(pubspec,
          contains('adaptive_icon_foreground: assets/app_icon_foreground.png'));
      expect(pubspec,
          contains('adaptive_icon_monochrome: assets/app_icon_monochrome.png'));
      for (final name in ['app_icon_foreground.png', 'app_icon_monochrome.png']) {
        expect(_pngHeader(File('${_appRoot().path}/assets/$name')),
            (1024, 1024, 8, 6),
            reason: name);
      }
      const sizes = {
        'mdpi': 108,
        'hdpi': 162,
        'xhdpi': 216,
        'xxhdpi': 324,
        'xxxhdpi': 432,
      };
      for (final MapEntry(key: density, value: px) in sizes.entries) {
        for (final layer in ['foreground', 'monochrome']) {
          final f = File('${_appRoot().path}/android/app/src/main/res/'
              'drawable-$density/ic_launcher_$layer.png');
          expect(_pngHeader(f), (px, px, 8, 6), reason: '$density $layer');
        }
      }
    });

    // Android 12+ draws its own splash screen from the launch theme: the
    // app's page colour, light and dark, instead of Theme.Light's white.
    test('the Android 12+ splash uses the page colours', () {
      String argb(int v) =>
          '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
      final light = argb(AppColors.light.page.toARGB32());
      final dark = argb(AppColors.dark.page.toARGB32());
      expect(light, '#FFF2F2F7');
      expect(dark, '#FF000000');
      for (final (folder, colour) in [
        ('values-v31', light),
        ('values-night-v31', dark),
      ]) {
        final xml = _read('android/app/src/main/res/$folder/styles.xml');
        expect(xml, contains('<style name="LaunchTheme"'), reason: folder);
        expect(
            xml,
            contains('<item name="android:windowSplashScreenBackground">'
                '$colour</item>'),
            reason: folder);
        expect(xml,
            contains('<item name="android:colorBackground">$colour</item>'),
            reason: folder);
        expect(xml, isNot(contains('<style name="NormalTheme"')),
            reason: folder);
      }
    });
  });

  group('release.yml: tags, Play tracks and the Gradle mirrors', () {
    final workflow = _readRepo('.github/workflows/release.yml');

    // Decision 4 (2026-11-13): an Android-only version ships with a
    // hand-made GitHub Release under an android-v* tag (android-v1.7.0 on
    // 2026-11-19, android-v1.7.1 on 2026-11-22, android-v1.7.2 on
    // 2026-11-24, whose tag started no Release run; the iPhone's next tag
    // from main is v1.7.2). That tag must start no run: the only push
    // trigger is tags v*.
    test('only v* tags start a run, so android-v* tags start none', () {
      final on = RegExp(r'^on:\n((?:[ \t]+.*\n|\n)*)', multiLine: true)
          .firstMatch(workflow)!
          .group(1)!;
      final push = RegExp(r'^  push:\n((?:    .*\n)*)', multiLine: true)
          .firstMatch(on)!
          .group(1)!;
      expect(push.trim().split('\n').map((l) => l.trim()).toList(),
          ['tags:', "- 'v*'"]);
      expect(on, isNot(contains('pull_request')));
      expect(_githubTagMatches('v*', 'v1.7.0'), isTrue);
      expect(_githubTagMatches('v*', 'v1.7.0+207'), isTrue);
      expect(_githubTagMatches('v*', 'android-v1.7.0'), isFalse);
      expect(_githubTagMatches('v*', 'android-v1.7.1'), isFalse);
      expect(_githubTagMatches('v*', 'android-v1.7.2'), isFalse);
      for (final r in _kAndroidReleases) {
        expect(_githubTagMatches('v*', 'android-v${r.version}'), isFalse,
            reason: 'android-v${r.version}');
      }
      // The plan job treats only refs/tags/v* as a tag build.
      expect(workflow,
          contains(r'if [[ "$GITHUB_REF" == refs/tags/v* ]]; then'));
    });

    test('Run workflow can send the bundle to the closed test; tag pushes '
        'stay on internal', () {
      const input = '''
      play_track:
        description: Play track the bundle goes to when PLAY_SERVICE_ACCOUNT_JSON is set (alpha = the closed test; a tag push always uses internal)
        type: choice
        options:
          - internal
          - alpha
        default: internal
''';
      expect(workflow, contains(input));
      expect(
          workflow,
          contains(r"tracks: ${{ github.event_name == 'workflow_dispatch' && "
              r"inputs.play_track || 'internal' }}"));
      expect(RegExp(r'^\s*tracks:', multiLine: true).allMatches(workflow),
          hasLength(1));
      expect(workflow, contains('status: completed'));
    });

    // C44: the owner's Mac needs the Aliyun mirrors; CI must never use
    // them (GitHub Actions sets CI=true). Every mirror line sits inside the
    // guarded block, in both Gradle files.
    test('the Aliyun mirrors are for local builds only', () {
      for (final (file, flag) in [
        ('android/settings.gradle.kts', 'useMirror'),
        ('android/build.gradle.kts', 'useAliyunMirror'),
      ]) {
        final text = _read(file);
        expect(text, contains('System.getenv("CI") != "true"'), reason: file);
        expect(
            text,
            contains(
                'providers.gradleProperty("chopstats.noMirror").orNull != "true"'),
            reason: file);
        final guarded =
            RegExp('if \\($flag\\) \\{\\n((?:[ \\t]+maven \\{[^\\n]*\\n)+)')
                .firstMatch(text);
        expect(guarded, isNotNull, reason: file);
        final inside = 'maven.aliyun.com'.allMatches(guarded!.group(1)!).length;
        expect(inside, greaterThan(0), reason: file);
        expect('maven.aliyun.com'.allMatches(text), hasLength(inside),
            reason: '$file: an Aliyun repository outside the guard');
      }
    });
  });

  group('RELEASING § 6 (Google Play)', () {
    final releasing = _readRepo('docs/RELEASING.md');
    final s6 = releasing
        .substring(releasing.indexOf('## 6. Google Play'),
            releasing.indexOf('## 7. China mainland'))
        .replaceAll(RegExp(r'\s+'), ' ');

    test('the old wrong answers are gone', () {
      expect(s6, isNot(contains('processed ephemerally, not stored')));
      expect(s6, isNot(contains('questionnaire → Utility/Health')));
      expect(s6,
          isNot(contains('Describe the camera-roll watcher as the core')));
      expect(s6, isNot(contains('the package name is taken from the first')));
      // Decisions 5–12 were made on 2026-11-20, and this branch ships
      // several of them.
      expect(s6, isNot(contains('Not decided yet')));
      expect(s6, isNot(contains('Decisions 5–12 can wait')));
    });

    test('carries the verified answers and the owner decisions', () {
      for (final fact in [
        'Utility, Productivity, Communication, or Other',
        "My app doesn't provide any financial features",
        'Nutrition and Weight Management',
        'Activity and Fitness',
        'at least 12 testers opted in continuously for at least 14 days',
        'internal testing does not count',
        'Trader status',
        'physical, non-rooted Android 10+ phone',
        'Provide a copy of your app signing key',
        'android-v1.7.0',
        '### 6.7 Android platform checks',
        '### 6.8 Owner checklist, in order',
        'Do not roll it out yet.',
        'Do NOT revoke the demo Gemini key',
        "The owner's decisions (2026-11-20):",
        'Read decisions 1–12 above; they are settled.',
      ]) {
        expect(s6, contains(fact), reason: fact);
      }
    });

    // RD-1: § 6.3 and § 6.6 told the owner to expect build name 1.7.0 and
    // the artifact android-1.7.0-2xx while the next build had to be 1.7.1,
    // and § 6.8 sent the APK out as android-v1.7.0 again. What they tell
    // the next run to expect is pubspec's version, and so is the tag the
    // cheat sheet pushes (release.yml refuses any other). The first Play
    // upload is the newest Android release's bundle, under the version it
    // was built as (§ 6.3): run 9's (android-v1.7.1, build 209) until
    // android-v1.7.2 went out, and run 10's (android-v1.7.2, build 210,
    // 2026-11-24) since. A version a GitHub release holds is not built
    // again under its name, so § 6.6's steps name pubspec's version only
    // while no release holds it: #87 had them call the next Android-only
    // version X.Y.Z, pubspec's version bumped first, the 1.7.2 prep
    // (2026-11-23) named 1.7.2 after its bump, and since android-v1.7.2
    // holds pubspec's 1.7.2 they call it X.Y.Z again, until the next bump.
    test("what § 6 and § 8 expect from the next run is pubspec's version",
        () {
      final version = _pubspecVersion(_read('pubspec.yaml'));
      // The newest release's run (run 10, android-v1.7.2, build 210) is
      // history: it keeps its name after the next bump, so its facts are
      // pinned as its version, and every other build name or artifact § 6
      // names is pubspec's version.
      final newest = _kAndroidReleases.last;
      final run = newest.build - 200;
      Set<String?> named(RegExp re) =>
          re.allMatches(s6).map((m) => m.group(1)).toSet();
      final buildNames = named(RegExp(r'build name `(\d+\.\d+\.\d+)`'));
      expect(buildNames, contains(newest.version));
      expect({version, newest.version}.containsAll(buildNames), isTrue,
          reason: '$buildNames');
      final artifacts =
          named(RegExp(r'`android-(\d+\.\d+\.\d+)-(?:2xx|2\d\d)`'));
      expect({version, newest.version}.containsAll(artifacts), isTrue,
          reason: '$artifacts');
      expect(
          s6,
          contains('Actions › Release › run $run. Its plan summary says '
              'build name `${newest.version}` and build number '
              '${newest.build} (`BUILD_NUMBER_OFFSET` 200 + run $run)'));
      expect(
          s6,
          contains('Download the artifact '
              '`android-${newest.version}-${newest.build}`'));
      expect(s6,
          contains('Name the release `${newest.version} (${newest.build})`'));
      expect(
          s6,
          contains('the bundle of Release run $run (lane `play`, from `main` '
              'at `${newest.sha}`, where the tag `android-v${newest.version}` '
              'is), build ${newest.build}, the same build number as the '
              'GitHub APK `android-v${newest.version}` (same run, same '
              'signer; the bundle is the Play build, without Watch Camera '
              'Roll)'));
      expect(
          s6,
          contains("run $run's GitHub APK went out by hand as "
              '`android-v${newest.version}` (build ${newest.build})'));
      expect(
          s6,
          contains('GitHub APK went out by hand as `android-v1.7.1` '
              '(build 209)'));
      expect(s6, contains('`android-v1.7.0` (build 207) is already out'));
      expect(s6, contains("the iPhone's next tag from `main` is `v$version`"));
      expect(releasing,
          contains('git tag v$version && git push origin v$version'));
      expect(s6, isNot(contains('The next Android build is 1.7.1.')),
          reason: 'the bump is done (§ 6.6)');
      final android = s6.substring(
          s6.indexOf('**An Android-only version (decision 4).**'),
          s6.indexOf('Later, when the iPhone version is ready'));
      // Whether a GitHub release holds pubspec's version: then it is the
      // newest release's, main has not been bumped since, and the steps
      // call the next one X.Y.Z, bumped first.
      final held = _kAndroidReleases.any((r) => r.version == version);
      final next = held ? 'X.Y.Z' : version;
      if (held) {
        expect(version, newest.version,
            reason: 'main never builds an older release again');
        expect(
            android,
            contains("The next one is pubspec's version at that time, bumped "
                'first (`X.Y.Z` in the steps): `android-v$version` holds '
                '$version'));
        expect(android, isNot(contains('The next one is $version')));
      } else {
        expect(android,
            contains('The next one is $version, which the steps name'));
        expect(android,
            isNot(contains("The next one is pubspec's version at that time")));
        for (final r in _kAndroidReleases) {
          expect(_compareVersions(version, r.version), greaterThan(0),
              reason: 'android-v${r.version} is out');
        }
      }
      for (final step in [
        'build name `$next`, and the artifact `android-$next-2xx`',
        "tag the run's commit `android-v$next`",
        '`git tag android-v$next <sha> && git push origin android-v$next`',
        'title `Chopstats Android $next`',
        'the APK renamed `Chopstats-v$next-b2xx-arm64-v8a.apk`',
      ]) {
        expect(android, contains(step), reason: step);
      }
      // The steps name no other version, and none that is already out: a
      // version a GitHub release holds is not built again under its name,
      // so after each release the steps need the next bump first.
      const v = r'(\d+\.\d+\.\d+|X\.Y\.Z)';
      final stepVersions = {
        for (final re in [
          RegExp('build name `$v`'),
          RegExp('`android-$v-2xx`'),
          RegExp("tag the run's commit `android-v$v`"),
          RegExp('android-v$v <sha>'),
          RegExp('Chopstats Android $v'),
          RegExp('`Chopstats-v$v-b'),
        ])
          for (final m in re.allMatches(android)) m.group(1)!,
      };
      expect(stepVersions, {next});
      for (final r in _kAndroidReleases) {
        expect(stepVersions, isNot(contains(r.version)),
            reason: 'android-v${r.version} is out');
      }
      // The previous release, which the notes start from and the new
      // build number must clear.
      expect(
          android,
          contains('for ${held ? 'the next one' : version} it is '
              '`android-v${newest.version}`, build ${newest.build}'));
      expect(android,
          contains("above `android-v${newest.version}`'s ${newest.build}"));
      // Decision 9 (RD-6): renewal after a stop is Android 12 and later
      // only, and the Play build runs the keep-alive's job too.
      expect(s6, contains('only on Android 12 and later, and only after a '
          'stop a fresh job can outlast'));
      expect(s6, isNot(contains('a job the system stops mid-request is '
          'replaced the same way')));
      expect(s6, contains("the analysis keep-alive's one-time job still runs"));
      expect(s6, isNot(contains('no WorkManager job is registered')));
    });

    // Review of #77 (RV-2, DT-1): release/1.6.1 holds a finished, untagged
    // 1.6.1 cut from v1.6.0, so "the iPhone goes from 1.6.0 to 1.7.1" and
    // "the first iPhone tag since 1.6.0, v1.7.1" held only for tags from
    // main. What RELEASING says about the next iPhone version is main's,
    // and § 6.6 says what a v1.6.1 tag on that branch does.
    test("the iPhone's next version is main's, and a 1.6.x hotfix is "
        'tagged on its own branch', () {
      final version = _pubspecVersion(_read('pubspec.yaml'));
      final flat = releasing.replaceAll(RegExp(r'\s+'), ' ');
      for (final unscoped in [
        "the iPhone's next tag is",
        'the iPhone goes from 1.6.0 to',
        'Before the first iPhone tag since 1.6.0',
        'so no build may be named below',
        'means that next App Store version',
      ]) {
        expect(flat, isNot(contains(unscoped)), reason: unscoped);
      }
      expect(s6, contains("`main`'s next iPhone version is $version"));
      expect(
          s6,
          contains('so no build of `main` may be named below the newest '
              'version it names'));
      expect(
          flat,
          contains('Before the first tag from `main` since 1.6.0, '
              '`v$version`'));
      expect(
          flat,
          contains('means the first App Store version built from `main` '
              'after 1.6.0, now $version, not a 1.6.x hotfix'));
      // § 6.3 names the hotfix branch; § 6.6 says what its tag does.
      expect(
          s6,
          contains('The 1.6.x hotfixes branch from tag `v1.6.0` (today '
              '`release/1.6.1`, § 6.6)'));
      expect(s6, contains('**A 1.6.x hotfix**'));
      final hotfix = s6.substring(s6.indexOf('**A 1.6.x hotfix**'));
      // The branch's own release.yml numbers a v1.6.1 build 100 + its run,
      // a run after the newest Android release's (run 10, android-v1.7.2,
      // since 2026-11-24), so below every Android release's build, while
      // main's offset 200 would put it above them. Today: "That is below
      // `android-v1.7.2`'s 210, `android-v1.7.1`'s 209 and
      // `android-v1.7.0`'s 207, so Android refuses it on a phone with
      // 1.7.0, 1.7.1 or 1.7.2".
      final newest = _kAndroidReleases.last;
      final newestRun = newest.build - 200;
      final below = _andList([
        for (final r in _kAndroidReleases.reversed)
          "`android-v${r.version}`'s ${r.build}",
      ]);
      final versions = [for (final r in _kAndroidReleases) r.version];
      final onPhone = '${versions.sublist(0, versions.length - 1).join(', ')}'
          ' or ${versions.last}';
      for (final fact in [
        'A `v1.6.1` tag needs no § 11, since that branch has no iCloud '
            'entitlement',
        "runs that branch's own `release.yml`: both lanes on a tag push, "
            '`BUILD_NUMBER_OFFSET` 100, and none of the checks added since '
            '1.6.0',
        'So its build is numbered 100 + its run number',
        'That is below $below, so Android refuses it on a phone with '
            '$onPhone',
        '(${100 + newestRun + 1} or more: run $newestRun built '
            '`android-v${newest.version}`)',
        'and its offset 200 would number the APK above ${newest.build}, so '
            'Android would install 1.6.1 (database schema 3) over 1.7.x '
            '(schema 4)',
        "Keep that branch's own `release.yml`",
      ]) {
        expect(hotfix, contains(fact), reason: fact);
      }

      // The 1.7.2 prep (2026-11-23): iPhone 1.7.1 never shipped either,
      // so main's next iPhone tag is v1.7.2. Every note that says what the
      // iPhone skips names each Android-only version out below main's
      // ("1.7.0 and 1.7.1"), and their v* tags stay unused. android-v1.7.2
      // (2026-11-24) holds main's own 1.7.2, which the iPhone does not
      // skip: main's next iPhone tag stays v1.7.2 until the next bump.
      final skips = _iphoneSkips(version);
      expect(s6, contains('The iPhone $skips never shipped (1.6.0 is live)'));
      expect(
          s6,
          contains('the iPhone $skips never shipped (1.6.0 is live), so '
              "`main`'s next iPhone version is $version"));
      final unused =
          _andList([for (final v in _iphoneSkipped(version)) '`v$v`']);
      expect(s6, contains('$unused stay unused'));
      expect(s6, isNot(contains('`v1.7.0` stays unused')));
      expect(s6,
          isNot(contains(RegExp('`v${RegExp.escape(version)}` stays? unused'))),
          reason: "v$version is main's next iPhone tag");
      final workflow = _readRepo('.github/workflows/release.yml')
          .replaceAll(RegExp(r'\s+'), ' ');
      for (final (path, text) in [
        ('docs/RELEASING.md', flat),
        ('.github/workflows/release.yml', workflow),
        (
          'docs/readme/src/README.md',
          _readRepo('docs/readme/src/README.md')
              .replaceAll(RegExp(r'\s+'), ' ')
        ),
        (
          'app/ios/store/marketing-src/README.md',
          _readRepo('app/ios/store/marketing-src/README.md')
              .replaceAll(RegExp(r'\s+'), ' ')
        ),
      ]) {
        final said = [
          for (final m in RegExp(r'[Tt]he iPhone skips (\d+\.\d+\.\d+'
                  r'(?:(?:, | and )\d+\.\d+\.\d+)*)')
              .allMatches(text))
            m.group(1)!,
        ];
        expect(said, isNotEmpty, reason: path);
        expect(said.toSet(), {skips}, reason: path);
      }
      // release.yml's two iCloud comments name the iPhone's next version.
      expect(
          workflow,
          contains('# iCloud Backup (iPhone $version; the iPhone skips '
              '$skips):'));
      expect(workflow,
          contains('# iCloud Backup (iPhone $version): the signed Runner'));
      expect(
          {
            for (final m
                in RegExp(r'iPhone (\d+\.\d+\.\d+)').allMatches(workflow))
              m.group(1)
          },
          {version});
    });

    // Review of #77 (DT-2): android-v1.7.0 went out on 2026-11-19 in the
    // repo's local time (run 7 at 22:09 CST, published 23:31 CST), not
    // 2026-11-20 (UTC), and main's pubspec was 1.7.1 from the merge of PR
    // #77 on, not from the day it was decided. android-v1.7.1 (run 9)
    // went out on 2026-11-22 (published 20:13 CST, which is 02:13Z on the
    // 23rd), and android-v1.7.2 (run 10) on 2026-11-24 (published 09:57
    // CST, 15:57Z). Every dated mention of a published Android tag names
    // its build, and nothing still calls android-v1.7.1 or android-v1.7.2
    // next. The 1.7.2 bump (decided on 2026-11-23) is dated by its PR too,
    // and the sentences that gave 1.7.1 as pubspec's version or as the
    // next one are gone, as are those that gave 1.7.2 as the next one.
    test('android-v1.7.0 is dated 2026-11-19, android-v1.7.1 2026-11-22 and '
        'android-v1.7.2 2026-11-24, each with its build, and each bump by '
        'its PR', () {
      final flat = releasing.replaceAll(RegExp(r'\s+'), ' ');
      final sentences = flat.split(RegExp(r'(?<=[.;])\s+'));
      for (final r in _kAndroidReleases) {
        final tag = 'android-v${r.version}';
        final dated = [
          for (final sentence in sentences)
            if (sentence.contains(tag))
              for (final d in RegExp(r'\d{4}-\d\d-\d\d').allMatches(sentence))
                (date: d.group(0)!, sentence: sentence),
        ];
        expect(dated, hasLength(greaterThanOrEqualTo(3)), reason: tag);
        for (final (:date, :sentence) in dated) {
          expect(date, r.day, reason: sentence);
          expect(sentence, contains('build ${r.build}'), reason: sentence);
        }
      }
      expect(flat, isNot(contains('So on 2026-11-20 `version:`')));
      expect(flat, isNot(contains('both were 1.7.1 on 2026-11-20')));
      expect(
          flat,
          contains('`kAppVersion` (`lib/services/backup/backup_files.dart`) '
              '`1.7.1` from PR #77 on, decided on 2026-11-20'));
      expect(
          flat,
          contains('So `version:` is `1.7.2+11` and `kAppVersion` `1.7.2` '
              'since PR #93, decided on 2026-11-23 by Claude on '
              "the owner's delegation: the 1.7.2 bump is done"));
      expect(
          flat,
          contains('(pubspec is 1.7.2 since PR #93; the '
              "policy's newest is 1.7.1)"));
      expect(
          flat,
          contains('pubspec is 1.7.2 since PR #93, so the '
              "iPhone's next tag from `main` is `v1.7.2`"));
      for (final stale in [
        'Android 1.7.1 goes out the same way',
        'and the next build of `main` is 1.7.1',
        'The next one is 1.7.1',
        'GitHub APK as `android-v1.7.1` by hand',
        'for 1.7.1 the Meta glasses sentence',
        // Made stale by the 1.7.2 prep. (Its "The next one is pubspec's
        // version at that time" is right again while a release holds
        // pubspec's version: the § 6.6 test above wants it then, and
        // forbids it after the next bump.)
        'since PR #77',
        'pubspec is 1.7.1',
        "that run's bundle is the first Play upload",
        'the first Play upload is 1.7.1',
        'and it is 1.7.1: the bundle of',
        // The prep's own number, once the PR had one.
        'the 1.7.2 prep PR',
        // Made stale by android-v1.7.2 (2026-11-24).
        'The next one is 1.7.2',
        'Android 1.7.2 goes out the same way',
        'and 1.7.2 goes out on GitHub the same way',
        "Publish 1.7.2's GitHub APK",
        'Until `android-v1.7.2` is published',
        'until `android-v1.7.2` is published',
        'Until `android-v1.7.2` is out',
        'From then on, 1.7.2',
        'for 1.7.2 it is `android-v1.7.1`',
        'when the first upload is 1.7.2',
        '(1.7.2, after `android-v1.7.2`)',
        'The steps name run 9;',
        'Actions › Release › run 9.',
      ]) {
        expect(flat, isNot(contains(stale)), reason: stale);
      }
    });

    // Review of #77 (RV-1): two maintainer notes outside RELEASING waited
    // for "1.7.0" to ship on the App Store, which the iPhone skips. The
    // 1.7.2 prep (2026-11-23): it skips 1.7.1 too, so they wait for 1.7.2.
    test('the slide and screenshot notes wait for 1.7.2, not 1.7.0 or 1.7.1',
        () {
      String flatRepo(String path) =>
          _readRepo(path).replaceAll(RegExp(r'\s+'), ' ');
      final slides = flatRepo('docs/readme/src/README.md');
      expect(slides, isNot(contains('When 1.7.0 ships')));
      expect(slides, isNot(contains('(1.7.1: the iPhone skips')));
      expect(
          slides,
          contains('When the first App Store version built from `main` '
              'after 1.6.0 ships (1.7.2: the iPhone skips 1.7.0 and 1.7.1, '
              'and a 1.6.x hotfix has neither feature'));
      final shots = flatRepo('app/ios/store/marketing-src/README.md');
      expect(shots, isNot(contains('(1.7.0, the native iOS design)')));
      expect(shots, isNot(contains('(1.7.1, the native iOS design')));
      expect(
          shots,
          contains('(1.7.2, the native iOS design; the iPhone skips 1.7.0 '
              'and 1.7.1) needs new captures first'));
    });

    // The 1.7.2 prep (decided on 2026-11-23 on the owner's delegation, as
    // PR #77's 1.7.1 was): android-v1.7.1 holds 1.7.1, so main builds
    // 1.7.2, and the hand-build +N went up by one, to 11 (§ 5). Wherever
    // RELEASING and the Play shot list give pubspec's version or +N, they
    // give today's. Review of the prep (PREP-R3, 2026-11-23): a bump that
    // left the +N at 10 passed, with § 6.6 still saying +11, because the
    // +N was held only below 200 and every CI build and § 6.6 was pinned
    // as a literal. The +N must also be above the one at every Android
    // release's commit (up by one with each bump, so a hand build installs
    // over the last one), and § 6.6 gives pubspec's version like the rest.
    // android-v1.7.2 went out from main at 1.7.2+11 (2026-11-24): main
    // keeps the newest release's version and +N, and only the newest's,
    // until the next bump, which the next Android-only version needs first
    // (§ 6.6).
    test("main builds 1.7.2 or later, and RELEASING gives pubspec's version "
        'and +N', () {
      final pubspec = _read('pubspec.yaml');
      final full = RegExp(r'^version:\s*(\S+)$', multiLine: true)
          .firstMatch(pubspec)!
          .group(1)!;
      final version = _pubspecVersion(pubspec);
      final plus = int.parse(full.split('+').last);
      expect(_compareVersions(version, '1.7.2'), greaterThanOrEqualTo(0),
          reason: 'android-v1.7.1 went out as 1.7.1; the next build is '
              '1.7.2 or later');
      // The releases themselves, oldest first: each one's version, build
      // and +N above the one before, and its day not before it.
      for (var i = 1; i < _kAndroidReleases.length; i++) {
        final (before, r) = (_kAndroidReleases[i - 1], _kAndroidReleases[i]);
        expect(_compareVersions(r.version, before.version), greaterThan(0),
            reason: r.version);
        expect(r.build, greaterThan(before.build), reason: r.version);
        expect(r.day.compareTo(before.day), greaterThanOrEqualTo(0),
            reason: r.version);
        expect(r.plus, greaterThan(before.plus),
            reason: '§ 5: the +N goes up with each version bump');
      }
      final newest = _kAndroidReleases.last;
      for (final r in _kAndroidReleases) {
        expect(plus, lessThan(r.build),
            reason: 'a Mac hand build stays below every CI build');
        if (r == newest && version == r.version) {
          expect(plus, r.plus,
              reason: "no bump since android-v${r.version}: pubspec is its "
                  '${r.version}+${r.plus}');
          continue;
        }
        expect(_compareVersions(version, r.version), greaterThan(0),
            reason: 'android-v${r.version} holds ${r.version}');
        expect(plus, greaterThan(r.plus),
            reason: '§ 5: the +N goes up by one with each version bump, and '
                "android-v${r.version}'s commit had +${r.plus}");
      }
      expect(plus, lessThan(200), reason: '§ 5: hand builds stay below 200');
      final flat = releasing.replaceAll(RegExp(r'\s+'), ' ');
      for (final fact in [
        '`app/pubspec.yaml` `version: $full` → `CFBundleShortVersionString` '
            '/ `versionName` = `$version`',
        '`app/pubspec.yaml` is `$full`; the ShareExtension',
        'the `+N` from pubspec (currently $plus; it goes up by one with '
            'each version bump',
        "Never upload a Mac hand build: it gets pubspec's `+$plus`, below "
            '207.',
        '# 1. in the shipping PR: app/pubspec.yaml version: $full (the +N',
        'So `version:` is `$full` and `kAppVersion` `$version` since',
      ]) {
        expect(flat, contains(fact), reason: fact);
      }
      expect(
          _read('android/store/screenshots/SHOTS.md')
              .replaceAll(RegExp(r'\s+'), ' '),
          contains('on each release candidate whose screens changed '
              '($version next)'));
    });

    // Decided on 2026-11-23 on the owner's delegation: the first Play
    // upload is the bundle of the newest Android release at the time of
    // that upload, so Play starts at the version and build number GitHub
    // users have. That was run 9's (1.7.1, build 209) until android-v1.7.2
    // went out on 2026-11-24, and it is run 10's since (1.7.2, build 210,
    // from main at c7a0e8a5, in the artifact android-1.7.2-210, which
    // GitHub keeps 90 days). RELEASING says so, and the READMEs' Android
    // section names android-v1.7.2, its APK and its size from the docs
    // change that followed its release, as #87 followed 1.7.1's. Until then
    // this test held that nothing said 1.7.2 was out; now it holds that
    // nothing says a version after the newest release is out. The store
    // pack says 1.7.2 since android-v1.7.2 went out. Review of the prep (2026-11-23): the rule went by the day the
    // Play account exists, which comes well before the upload in § 6.8,
    // while its bullets and its reason go by the upload (PREP-R1); the
    // bundle and the GitHub APK share a version and build number, not a
    // build, as #87's review had said (PREP-R4); and only run 9's artifact
    // had a way out once GitHub deletes it (PREP-R2). Now any release's
    // has: a new release, after a pubspec bump once a GitHub release holds
    // pubspec's version.
    test("the first Play upload is the newest Android release's bundle, "
        "1.7.2's since it went out, and nothing says a later version is out",
        () {
      final newest = _kAndroidReleases.last;
      final run = newest.build - 200;
      final everyRelease = _andList([
        for (final r in _kAndroidReleases)
          '`android-v${r.version}` (build ${r.build})',
      ]);
      final s63 = s6.substring(
          s6.indexOf('**The first upload**'), s6.indexOf('### 6.4 '));
      for (final fact in [
        '**The first upload** is still to come. It is the bundle of the '
            'newest Android release at the time of that upload',
        'so that Play starts at the version and build number GitHub users '
            'already have: an older bundle would be a downgrade for a phone '
            'moving from the GitHub APK',
        'Since `android-v${newest.version}` went out on ${newest.day}, that '
            'is ${newest.version}: the bundle of Release run $run',
        'in the artifact `android-${newest.version}-${newest.build}`, which '
            'GitHub keeps 90 days.',
        // GitHub's expires_at for it: 2027-02-22T14:12:40Z (08:12 CST).
        'GitHub deletes `android-1.7.2-210` on 2027-02-22, and a later '
            "release's artifact 90 days after its run.",
        '$everyRelease went out on GitHub only: there is no Play account '
            'yet (§ 6.6).',
        'The steps name run $run; for a later release, take its run, '
            'artifact, build number and name instead.',
        'If the artifact is gone, no run can make that bundle again, so make '
            'a new Android release (§ 6.6, steps 1 to 5; a dispatch alone '
            'creates no tag and no GitHub Release) and upload its bundle',
        "Once a GitHub release holds pubspec's version, as `android-v1.7.2` "
            "holds 1.7.2, bump pubspec first, with the owner's OK (§ 6.6).",
      ]) {
        expect(s63, contains(fact), reason: fact);
      }
      for (final fact in [
        'The first Play upload, still to come, is the bundle of the newest '
            'Android release at the time of that upload (§ 6.3).',
        'the first Play upload is the newest Android release\'s bundle at '
            'the time of that upload, § 6.3',
        'which went out on GitHub only, as 1.7.1 and 1.7.2 did after it',
        'Android 1.7.2 followed on 2026-11-24 (`android-v1.7.2`, build 210), '
            'on GitHub only as well, since there is no Play account yet',
        'Android 1.7.2 followed on 2026-11-24 (`android-v1.7.2`, build 210 '
            'from run 10, GitHub only)',
        'for the first upload, the run of the newest Android release '
            'instead, § 6.3: run $run, build ${newest.build}, which built '
            '`android-v${newest.version}`',
        "pubspec's version at the run's commit: ${newest.version} for run "
            '$run)',
        "13. Done on ${newest.day}: run $run's GitHub APK went out by hand as "
            '`android-v${newest.version}` (build ${newest.build}), before any '
            "Play upload, and the README's Android section names it",
        'Until the first Play upload, § 6.3 says which release\'s bundle '
            'that upload is.',
      ]) {
        expect(s6, contains(fact), reason: fact);
      }
      // The store pack names the newest release's version since it went
      // out (review of #95: "1.7.1 until android-v1.7.2 is published, then
      // 1.7.2" was true but read as if 1.7.2 were not out).
      for (final store in [
        'android/store/app_content.md',
        'android/store/data_safety.md',
      ]) {
        final text = _read(store).replaceAll(RegExp(r'\s+'), ' ');
        expect(
            text,
            contains('(planned then as 1.7.0; it is the newest Android '
                'release at the time of the first upload: 1.7.2 since '
                '`android-v1.7.2` went out on 2026-11-24, '
                '`docs/RELEASING.md` § 6.3)'),
            reason: store);
        expect(text, isNot(contains('until `android-v1.7.2` is published')),
            reason: store);
        expect(text, isNot(contains('it is 1.7.1, `docs/RELEASING.md`')),
            reason: store);
      }
      // What the review of the prep took out (PREP-R1, R2, R4).
      for (final path in [
        'docs/RELEASING.md',
        'app/android/store/app_content.md',
        'app/android/store/data_safety.md',
      ]) {
        final text = _readRepo(path).replaceAll(RegExp(r'\s+'), ' ');
        for (final stale in [
          'the day the Play account exists',
          'While there is no Play account, § 6.3 says',
          'the build GitHub users already have',
          'If it is gone before `android-v1.7.2` is out',
          'for 1.7.2, take its run, artifact, build number and name instead',
        ]) {
          expect(text, isNot(contains(stale)), reason: '$path: $stale');
        }
      }
      // Out since 2026-11-24: the READMEs' Android section names the
      // newest release, its APK and its size (22,702,206 bytes, "about 22
      // MB" as for 1.7.1), and README.md's maintainer note 5 names its tag,
      // with the Meta glasses sentence that is true from 1.7.1 on.
      final apk =
          'Chopstats-v${newest.version}-b${newest.build}-arm64-v8a.apk';
      final link = 'https://github.com/AkiyamaKunka/Chopstats/releases/tag/'
          'android-v${newest.version}';
      final en = _readRepo('README.md').replaceAll(RegExp(r'\s+'), ' ');
      final zh = _readRepo('README.zh-CN.md').replaceAll(RegExp(r'\s+'), ' ');
      for (final fact in [
        'The newest Android version, ${newest.version}, is on the [Releases '
            'page]($link) as an APK, the Android install file: `$apk`, '
            'about 22 MB.',
        'built and signed it from the commit tagged '
            '`android-v${newest.version}`.',
        'Today that is android-v${newest.version}. Its Meta glasses sentence '
            'is true from 1.7.1, the first version in which the switch starts '
            'off on Android.',
        'Meta glasses photos are not checked for food on the phone, so Watch '
            'Camera Roll leaves them out until you turn on **Meta glasses '
            'photos** (Settings › Photos).',
      ]) {
        expect(en, contains(fact), reason: fact);
      }
      for (final fact in [
        '最新的 Android 版本 ${newest.version} 放在 [Releases 页面]($link)上，'
            '是一个 APK（Android 的安装文件）：`$apk`，约 22 MB。',
        '它由本仓库的发布流程从打上 `android-v${newest.version}` '
            '标签的提交构建并签名',
        'Meta 眼镜拍的照片不会先在手机上检查有没有食物，所以在你打开「设置 › 照片」'
            '里的「包括 Meta 眼镜拍的照片」之前，「监控相册」不会发送它们。',
      ]) {
        expect(zh, contains(fact), reason: fact);
      }
      // The READMEs name no other Android release: every tag and APK they
      // give is the newest's.
      for (final (path, text) in [('README.md', en), ('README.zh-CN.md', zh)]) {
        for (final m
            in RegExp(r'android-v(\d+\.\d+\.\d+)').allMatches(text)) {
          expect(m.group(1), newest.version, reason: '$path: ${m.group(0)}');
        }
        for (final m
            in RegExp(r'Chopstats-v(\d+\.\d+\.\d+)-b(\d+)\b').allMatches(text)) {
          expect('${m.group(1)} (${m.group(2)})',
              '${newest.version} (${newest.build})',
              reason: '$path: ${m.group(0)}');
        }
      }
      // Nothing says a version after the newest release is out (until
      // 2026-11-24, nothing said 1.7.2 was): every build number, date, APK
      // name, "went out" or release link these pages give a version
      // belongs to a release out, with that release's build, and a release
      // link names the newest.
      final builds = {for (final r in _kAndroidReleases) r.version: r.build};
      for (final path in [
        'docs/RELEASING.md',
        'README.md',
        'README.zh-CN.md',
        'app/android/store/app_content.md',
        'app/android/store/data_safety.md',
        'app/android/store/screenshots/SHOTS.md',
      ]) {
        final text = _readRepo(path).replaceAll(RegExp(r'\s+'), ' ');
        for (final claim in [
          RegExp(r'android-v(\d+\.\d+\.\d+)`? \((?:build |b)(\d+)'),
          RegExp(r'Chopstats-v(\d+\.\d+\.\d+)-b(\d+)\b'),
        ]) {
          for (final m in claim.allMatches(text)) {
            final v = m.group(1)!;
            if (builds.containsKey(v)) {
              expect(builds[v], int.parse(m.group(2)!),
                  reason: '$path: ${m.group(0)}');
            } else {
              // Not an Android release (a 1.6.x hotfix, say): fine only
              // below the newest release (review of #95).
              expect(_compareVersions(v, newest.version), lessThan(0),
                  reason: '$path: ${m.group(0)}');
            }
          }
        }
        for (final claim in [
          RegExp(r'android-v(\d+\.\d+\.\d+)[^.;]*\d{4}-\d\d-\d\d'),
          RegExp(r'(\d+\.\d+\.\d+) (?:went out|followed|is out)'),
        ]) {
          for (final m in claim.allMatches(text)) {
            final v = m.group(1)!;
            expect(
                builds.containsKey(v) ||
                    _compareVersions(v, newest.version) < 0,
                isTrue,
                reason: '$path: ${m.group(0)}');
          }
        }
        for (final m in RegExp(r'releases/tag/android-v(\d+\.\d+\.\d+)')
            .allMatches(text)) {
          expect(m.group(1), newest.version, reason: '$path: ${m.group(0)}');
        }
      }
    });

    // § 6.8 met itself in the merge of main into #77 (2026-11-21): #76
    // rewrote step 7 (where the screenshots are) while #77 put the version
    // step after it and renumbered the rest. The steps run 1, 2, 3 … and
    // the step numbers cited elsewhere still name the steps they mean.
    test('§ 6.8: the shots, the version step and the lane play run in a '
        'row, and the step numbers cited elsewhere match', () {
      final at = releasing.indexOf('### 6.8 Owner checklist, in order');
      final numbers = <int>[];
      final steps = <int, String>{};
      int? n;
      for (final line in releasing
          .substring(at, releasing.indexOf('### 6.9 ', at))
          .split('\n')) {
        final m = RegExp(r'^(\d+)\. (.*)$').firstMatch(line);
        if (m != null) {
          n = int.parse(m.group(1)!);
          numbers.add(n);
          steps[n] = m.group(2)!;
        } else if (n != null && line.startsWith('   ')) {
          steps[n] = '${steps[n]} ${line.trim()}';
        } else {
          n = null;
        }
      }
      expect(numbers, [for (var i = 1; i <= numbers.length; i++) i]);
      int stepWith(String text) {
        final hits = [
          for (final e in steps.entries)
            if (e.value.replaceAll(RegExp(r'\s+'), ' ').contains(text)) e.key,
        ];
        expect(hits, hasLength(1), reason: text);
        return hits.single;
      }

      final shots =
          stepWith('from `app/android/store/screenshots/en-US/` and `zh-CN/`');
      final version = stepWith(_kVersionStep);
      final run = stepWith('Run workflow › `main` › lane `play`');
      expect([version, run], [shots + 1, shots + 2]);
      final https = stepWith('says `kRequireHttpsServer = true` at the run');
      expect(steps[stepWith('"encrypted in transit: Yes"')],
          contains('step $https checks it'));
      final flat = releasing.replaceAll(RegExp(r'\s+'), ' ');
      expect(flat, contains('(§ 6.8, step $version)'));
      expect(flat, contains('§ 6.8 to keep step $version.'));
      expect(
          _read('android/store/data_safety.md')
              .replaceAll(RegExp(r'\s+'), ' '),
          contains('`docs/RELEASING.md` § 6.8 step $https has you check it'));
    });

    // Review of the 1.7.2 prep (PREP-R7, 2026-11-23): § 6.6's notes step
    // let the GitHub APK and the Play build replace each other only after
    // "§ 6.3's step 2 check", since #67. Step 2 of § 6.3's Play App Signing
    // list runs PEPK; the key is checked in the step after it. § 6.6 names
    // that list and the step that checks the key.
    test('§ 6.6 cites the Play App Signing step that checks the key', () {
      final at = releasing.indexOf('**Play App Signing (decision 3).**');
      final end = releasing.indexOf('**Signing secrets in the protected', at);
      final steps = <int, String>{};
      int? n;
      for (final line in releasing.substring(at, end).split('\n')) {
        final m = RegExp(r'^(\d+)\. (.*)$').firstMatch(line);
        if (m != null) {
          n = int.parse(m.group(1)!);
          steps[n] = m.group(2)!;
        } else if (n != null && line.startsWith('   ')) {
          steps[n] = '${steps[n]} ${line.trim()}';
        } else {
          n = null;
        }
      }
      expect(steps.keys, [1, 2, 3, 4]);
      final check = [
        for (final e in steps.entries)
          if (e.value.startsWith('Check the result on the same page: the '
              "app signing key's SHA-256 must equal"))
            e.key,
      ];
      expect(check, hasLength(1));
      expect(
          s6,
          contains('can replace each other **only after** the signing-key '
              'check of § 6.3 (*Play App Signing*, step ${check.single}) has '
              'passed'));
      expect(s6, isNot(contains("§ 6.3's step 2 check")));
    });

    test('every Google page it cites carries its read date', () {
      final urls = RegExp(r'<(https://(?:support\.google\.com|developer\.'
              r'android\.com)[^>]*)>')
          .allMatches(s6)
          .map((m) => m.group(1)!)
          .toSet();
      expect(urls.length, greaterThanOrEqualTo(12));
      for (final url in urls) {
        final at = s6.indexOf(url);
        final after =
            s6.substring(at, (at + url.length + 120).clamp(0, s6.length));
        expect(after, contains('read 2026-11-13'), reason: url);
      }
    });

    // The support page stays iPhone-only (R-F14 above) until Android is in
    // production; its Android text waits in § 6.9.
    test("§ 6.9 holds the support page's Android text", () {
      final en = AppLocalizationsEn();
      const heading =
          '### 6.9 When Android ships on Google Play: the support page';
      expect(s6, contains(heading));
      final s69 = s6.substring(s6.indexOf(heading));
      for (final label in [
        en.addFromPhotos,
        en.settingsRowWatch,
        en.settingsRowExport,
      ]) {
        expect(s69, contains(label), reason: label);
      }
    });
  });
  // Review finding M1: the policy, the listing and § 6 state facts that
  // other lanes' code delivers. These gates read that code as text, so this
  // branch cannot merge with docs that are ahead of the app. They fail
  // until android/privacy, android/native and android/photos are merged.
  group('gates: what the docs say, the code has', () {
    test('plain-http servers are refused (privacy lane, decision 2)', () {
      final f = File('${_appRoot().path}/lib/core/server_transport.dart');
      expect(f.existsSync(), isTrue, reason: 'android/privacy not merged');
      expect(
          RegExp(r'^const bool kRequireHttpsServer = true;$', multiLine: true)
              .hasMatch(f.readAsStringSync()),
          isTrue);
    });

    test("API keys stay out of Android's backup and device transfer "
        '(native lane)', () {
      const files = [
        'FlutterSecureStorage.xml',
        'FlutterSecureKeyStorage.xml',
        'FlutterSecureStorageConfiguration.xml',
        'FlutterSecureStorageConfiguration:FlutterSecureStorage.xml',
      ];
      // The section's tag may carry attributes (<cloud-backup
      // disableIfNoEncryptionCapabilities="true">, owner decision 5).
      String section(String xml, String tag) {
        final m = RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true)
            .firstMatch(xml);
        expect(m, isNotNull, reason: tag);
        return m!.group(1)!;
      }

      final rules = _read('android/app/src/main/res/xml/data_extraction_rules.xml');
      // Android 9 to 11 read res/xml-v28. Android 8.1 and lower read
      // res/xml, which includes one file the app never writes and so
      // leaves the key files out with everything else.
      final legacy = _read('android/app/src/main/res/xml-v28/backup_rules.xml');
      final oldest = _read('android/app/src/main/res/xml/backup_rules.xml');
      expect(section(oldest, 'full-backup-content').trim(),
          '<include domain="file" path="no_backup_before_android_9"/>');
      for (final (name, block) in [
        ('cloud-backup', section(rules, 'cloud-backup')),
        ('device-transfer', section(rules, 'device-transfer')),
        ('full-backup-content', section(legacy, 'full-backup-content')),
      ]) {
        for (final file in files) {
          expect(block, contains('<exclude domain="sharedpref" path="$file"/>'),
              reason: '$name $file');
        }
      }
    });

    // Owner decision 5 (2026-11-20): the policy and Settings › Your Data
    // say Android's cloud backup needs a screen lock; the backup rules are
    // what makes that true (manifest_gate_test checks them in full).
    // Android 8.1 and lower cannot encrypt a backup end to end or tell it
    // from a transfer to a new phone, and their rules carry none of the
    // app's data: the policy and the footer say so too (review of #72).
    test("Android's cloud backup needs a screen lock: the policy and the "
        'footer say so, the backup rules do it', () {
      final policy = _readRepo('docs/PRIVACY.md').replaceAll(RegExp(r'\s+'), ' ');
      expect(policy, contains('only when it is end-to-end encrypted'));
      expect(policy, contains('screen lock (PIN, pattern or password)'));
      expect(policy, contains('只有在端到端加密时'));
      expect(policy, contains('屏幕锁定（PIN 码、图案或密码）'));
      expect(
          policy,
          contains('On Android 9 and later, a transfer straight to a new '
              'phone is not affected. On Android 8.1 and earlier, which '
              'cannot encrypt a backup end to end, the app\'s data goes '
              'neither to your Google account nor to a new phone in a '
              'transfer.'));
      expect(policy, isNot(contains('A transfer straight to a new phone is '
          'not affected')), reason: 'not on Android 8.1 and earlier');
      expect(
          policy,
          contains('在 Android 9 及以上版本上，直接转移到新手机不受影响。'
              'Android 8.1 及更早的版本无法对备份进行端到端加密，在这些版本上，'
              '应用数据既不会备份到你的 Google 账户，也不会在转移时带到新手机。'));
      expect(
          policy,
          contains('<!-- gated: release_decisions_test '
              '(disableIfNoEncryptionCapabilities in res/xml, requireFlags in '
              'res/xml-v28, nothing included for Android 8.1 and earlier) -->'));
      expect(AppLocalizationsEn().backupAndroidFooter,
          contains('without a screen lock, or on Android 8.1 and earlier, '
              'your log is not backed up'));
      expect(AppLocalizationsZh().backupAndroidFooter,
          contains('没有设置屏幕锁定时，或在 Android 8.1 及更早的版本上，'
              '饮食记录不会被备份'));

      final rules = _read('android/app/src/main/res/xml/data_extraction_rules.xml');
      expect(rules,
          contains('<cloud-backup disableIfNoEncryptionCapabilities="true">'));
      String uncommented(String xml) =>
          xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      final legacy = uncommented(
          _read('android/app/src/main/res/xml-v28/backup_rules.xml'));
      expect(legacy, contains('requireFlags="clientSideEncryption"'));
      expect(
          RegExp(r'<include\b(?![^>]*requireFlags=)[^>]*>').hasMatch(legacy),
          isFalse,
          reason: 'an include without requireFlags backs up unencrypted');
      final oldest =
          uncommented(_read('android/app/src/main/res/xml/backup_rules.xml'));
      expect(oldest, isNot(contains('requireFlags')),
          reason: 'Android 8.1 and lower cannot read it');
      expect(RegExp(r'<include\b[^>]*>').allMatches(oldest).single.group(0),
          '<include domain="file" path="no_backup_before_android_9"/>',
          reason: 'one include, of a file the app never writes');
    });

    test('the app reminds users to consult a healthcare professional '
        '(privacy lane)', () {
      final en = (jsonDecode(_read('lib/l10n/app_en.arb')) as Map)
          .cast<String, Object?>();
      final zh = (jsonDecode(_read('lib/l10n/app_zh.arb')) as Map)
          .cast<String, Object?>();
      expect(en['settingsHealthReminder'],
          contains('consult a healthcare professional'));
      expect(zh['settingsHealthReminder'], contains('请咨询医疗专业人士'));
      expect(_read('lib/ui/screens/settings/data_section.dart'),
          contains('settingsHealthReminder'));
    });

    test("Log › From recent photos uses Android's photo picker "
        '(photos lane)', () {
      expect(
          File('${_appRoot().path}/lib/services/photo/system_photo_picker.dart')
              .existsSync(),
          isTrue,
          reason: 'android/photos not merged');
      expect(_read('lib/ui/screens/add_flow.dart'),
          contains('platformSystemPhotoPicker()'));
    });
  });

  // The Android review of 2026-11-19, R4, R5, R15 and R16.
  group('release.yml: the Android review\'s release items', () {
    final workflow = _readRepo('.github/workflows/release.yml');

    /// The job [name], through to the next job.
    String job(String name) {
      final start = workflow.indexOf('\n  $name:\n');
      expect(start, isNonNegative, reason: name);
      final next = RegExp(r'\n  [a-z][a-z-]*:\n').firstMatch(
          workflow.substring(start + 1));
      return workflow.substring(
          start, next == null ? workflow.length : start + 1 + next.start);
    }

    /// The `needs:` of job [name], as a list.
    List<String> needs(String name) {
      final line = RegExp(r'^    needs: (.*)$', multiLine: true)
          .firstMatch(job(name))!
          .group(1)!;
      return line.replaceAll(RegExp(r'[\[\]\s]'), '').split(',');
    }

    // R4: a failed Play upload threw away the run's bundle, APK, mappings
    // and symbols (the Keep step after it was skipped), and the GitHub
    // Release, which needs the android job's success, never came.
    test('R4: the Play upload is a job of its own; the artifact is kept '
        'first and the GitHub Release does not wait for Play', () {
      final android = job('android');
      expect(android, isNot(contains('upload-google-play')));
      expect(android, contains('uses: actions/upload-artifact@'));
      expect(android, contains(r'play: ${{ steps.secrets.outputs.play }}'));
      final play = job('play');
      expect(needs('play'), ['plan', 'android']);
      expect(
          play,
          contains("if: needs.android.outputs.built == 'true' && "
              "needs.android.outputs.play == 'true'"));
      expect(play, contains('environment: release'));
      expect(play, contains('uses: r0adkll/upload-google-play@'));
      expect(play, contains('uses: actions/download-artifact@'));
      // The android job's own bundle, where it built it (the artifact's
      // root is app/build).
      expect(play, contains('path: app/build'));
      expect(play,
          contains('name: android-\${{ env.BUILD_NAME }}-\${{ env.BUILD_NUMBER }}'));
      expect(play,
          contains('mappingFile: \${{ steps.mapping.outputs.file }}'));
      expect('upload-google-play'.allMatches(workflow), hasLength(1));
      expect(needs('github-release'), isNot(contains('play')));
      expect(job('github-release'), isNot(contains('needs.play')));
    });

    // § 9 said to add `debugSymbols: <native-debug-symbols.zip>` on the
    // upload step. After R4 that step is the play job's, which sees only
    // the android job's artifact, and the artifact does not keep the zip:
    // r0adkll fails the whole upload on a debugSymbols path that is not
    // there. Any path the docs give the upload step must be kept.
    test('RELEASING § 9 gives the Play upload no file its artifact lacks',
        () {
      final releasing = _readRepo('docs/RELEASING.md');
      final android = job('android');
      final keep = android.substring(
          android.indexOf('- name: Keep the bundle, APKs, mapping'));
      for (final m in RegExp(r'debugSymbols: (\S+)').allMatches(releasing)) {
        final path = m.group(1)!.replaceAll('`', '');
        expect(keep, contains(path),
            reason: '$path is not in the android job\'s artifact');
      }
      expect(releasing, contains('The upload needs no `debugSymbols:` input'));
      expect(job('play'), isNot(contains('debugSymbols:')));
    });

    // R5: the check passed for any key but the debug key, so a wrong
    // keystore in the secrets shipped a green APK no installed copy could
    // update to.
    test('R5: the bundle and the APK must carry the pinned upload '
        'certificate; a repository variable overrides it', () {
      expect(
          workflow,
          contains('  ANDROID_UPLOAD_CERT_SHA256: '
              'd0d95f7f68be408da1c5f81d3e197dedd49f3de19b35eebdfb8effec6b7f9b7c\n'));
      final verify = job('android').substring(job('android').indexOf(
          '- name: Verify the bundle is signed with the upload key'));
      expect(
          verify,
          contains(r'UPLOAD_CERT_SHA256: ${{ vars.ANDROID_UPLOAD_CERT_SHA256 '
              r'|| env.ANDROID_UPLOAD_CERT_SHA256 }}'));
      expect(verify, contains(r'if [ "$aab_sha" != "$want" ]; then'));
      expect(verify, contains(r'if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then'));
      // After the APK == bundle check, so both carry it.
      expect(verify.indexOf(r'"$apk_sha" != "$aab_sha"'),
          lessThan(verify.indexOf(r'"$aab_sha" != "$want"')));
      expect(
          verify.indexOf(r'"$aab_sha" != "$want"'),
          lessThan(verify.indexOf('- name: Keep the bundle')),
          reason: 'a wrong key stops the run before anything is kept');
      expect(workflow, contains('ANDROID_UPLOAD_CERT_SHA256  the upload'));
      final releasing = _readRepo('docs/RELEASING.md');
      expect(releasing, contains('`ANDROID_UPLOAD_CERT_SHA256`'));
    });

    // R15: a tag's +N was checked against the offset only. RD-5: then
    // against the run's number only, not against other +N tags. RD-1: an
    // Android run took pubspec's name without the policy's newest version.
    // The plan step's own script, run as the workflow runs it.
    group('R15: a tag\'s +N is held above every number CI has used', () {
      String planScript() {
        final at = workflow.indexOf('        id: plan\n');
        final run = workflow.indexOf('        run: |\n', at);
        final lines = <String>[];
        for (final line in workflow
            .substring(run + '        run: |\n'.length)
            .split('\n')) {
          if (line.trim().isNotEmpty && !line.startsWith('          ')) break;
          lines.add(line.length >= 10 ? line.substring(10) : '');
        }
        return lines.join('\n');
      }

      final offset = RegExp(r'BUILD_NUMBER_OFFSET: (\d+)')
          .firstMatch(workflow)!
          .group(1)!;

      /// The plan step at Release run [run]. [released]: whether `gh
      /// release view` finds the tag's GitHub Release. A stub `gh` first
      /// on PATH answers it and records its calls in `gh`: the developer's
      /// own gh is never called. A stub `git` answers `git ls-remote` with
      /// the repository's [tags] (or fails, [tagsFail]) and records its
      /// calls in `git`. [pubspec] is pubspec's version, [policy]
      /// docs/PRIVACY.md (none when null), [lane] the lane input.
      Future<
          ({
            int code,
            String log,
            String out,
            List<String> gh,
            List<String> git
          })> plan(String event, String ref, int run,
          {bool released = false,
          String lane = 'both',
          String pubspec = '1.7.0+9',
          String? policy = _kStubPolicy,
          List<String> tags = const [],
          bool tagsFail = false}) async {
        final dir = Directory.systemTemp.createTempSync('ct_plan');
        addTearDown(() => dir.deleteSync(recursive: true));
        Directory('${dir.path}/app').createSync();
        File('${dir.path}/app/pubspec.yaml')
            .writeAsStringSync('version: $pubspec\n');
        if (policy != null) {
          Directory('${dir.path}/docs').createSync();
          File('${dir.path}/docs/PRIVACY.md').writeAsStringSync(policy);
        }
        final script = File('${dir.path}/plan.sh')
          ..writeAsStringSync(planScript());
        final out = File('${dir.path}/out')..createSync();
        final summary = File('${dir.path}/summary')..createSync();
        final calls = File('${dir.path}/gh-calls')..createSync();
        final gitCalls = File('${dir.path}/git-calls')..createSync();
        final refs = File('${dir.path}/tag-refs')
          ..writeAsStringSync(
              [for (final t in tags) '${'0' * 40}\trefs/tags/$t\n'].join());
        final bin = Directory('${dir.path}/bin')..createSync();
        final gh = File('${bin.path}/gh')
          ..writeAsStringSync('#!/usr/bin/env bash\n'
              'echo "\$*" >> "${calls.path}"\n'
              'exit ${released ? 0 : 1}\n');
        final git = File('${bin.path}/git')
          ..writeAsStringSync('#!/usr/bin/env bash\n'
              'echo "\$*" >> "${gitCalls.path}"\n'
              '[ "\$1" = ls-remote ] || exit 2\n'
              '${tagsFail ? 'echo "fatal: unable to access origin" >&2\n'
                  'exit 128\n' : 'cat "${refs.path}"\n'}');
        expect(
            (await Process.run('chmod', ['+x', gh.path, git.path])).exitCode,
            0);
        final r = await Process.run('bash', [script.path],
            workingDirectory: dir.path,
            environment: {
              'PATH': '${bin.path}:${Platform.environment['PATH']}',
              'GITHUB_REPOSITORY': 'owner/repo',
              'GH_TOKEN': 'token',
              'GITHUB_EVENT_NAME': event,
              'GITHUB_REF': ref,
              'GITHUB_RUN_NUMBER': '$run',
              'BUILD_NUMBER_OFFSET': offset,
              'GITHUB_OUTPUT': out.path,
              'GITHUB_STEP_SUMMARY': summary.path,
              'LANE': lane,
              'INTERNAL_ONLY_INPUT': 'true',
              'PLAY_TRACK': 'internal',
            });
        List<String> lines(File f) =>
            f.readAsLinesSync().where((l) => l.isNotEmpty).toList();
        return (
          code: r.exitCode,
          log: '${r.stdout}${r.stderr}',
          out: out.readAsStringSync(),
          gh: lines(calls),
          git: lines(gitCalls),
        );
      }

      test('a tag push below offset + run number stops, and says why',
          () async {
        for (final n in [205, 209]) {
          final r = await plan('push', 'refs/tags/v1.7.0+$n', 10);
          expect(r.code, 1, reason: '+$n at run 10');
          expect(r.log, contains('this is Release run 10'));
          expect(r.log, contains('up to 209'));
          // The corrected tag is a new push, so a new run with a higher
          // number and floor: this run's floor (210) is refused there too.
          expect(r.log, contains('Tag v1.7.0 without a +N instead'));
          expect(r.log, contains('that run is numbered 11 or later, so use '
              'more than 210'));
          expect(r.log, isNot(contains('this run numbers it')));
          expect(r.log, isNot(contains('210 or more')));
          expect(r.log, isNot(contains('not above BUILD_NUMBER_OFFSET')),
              reason: '$n is above the offset; that message would be false');
        }
        // At or below the offset: the old message, still true there.
        final low = await plan('push', 'refs/tags/v1.7.0+200', 10);
        expect(low.code, 1);
        expect(low.log, contains('not above BUILD_NUMBER_OFFSET'));
      });

      // What the owner does with the refusal: a new push, which is the
      // next run. The advice must pass there (the old "use 210 or more"
      // was refused again at run 11, whose floor is 211).
      test('the refusal\'s advice passes on the next run', () async {
        final refused = await plan('push', 'refs/tags/v1.7.0+205', 10);
        final bound = int.parse(
            RegExp(r'more than (\d+)').firstMatch(refused.log)!.group(1)!);
        expect(bound, 210);
        final plus = await plan('push', 'refs/tags/v1.7.0+${bound + 1}', 11);
        expect(plus.code, 0, reason: plus.log);
        expect(plus.out, contains('build_number=${bound + 1}\n'));
        final plain = await plan('push', 'refs/tags/v1.7.0', 11);
        expect(plain.code, 0, reason: plain.log);
        expect(plain.out, contains('build_number=211\n'));
        // The number the old message named is refused at run 11.
        expect((await plan('push', 'refs/tags/v1.7.0+$bound', 11)).code, 1);
      });

      test('at or above it a tag push passes, plain tags as before',
          () async {
        for (final (ref, number) in [
          ('refs/tags/v1.7.0+210', 210),
          ('refs/tags/v1.7.0+215', 215),
          ('refs/tags/v1.7.0', 210),
        ]) {
          final r = await plan('push', ref, 10);
          expect(r.code, 0, reason: '$ref: ${r.log}');
          expect(r.out, contains('build_number=$number\n'));
        }
      });

      test('Run workflow on a +N tag whose release is out still works, with '
          'a warning', () async {
        final r = await plan('workflow_dispatch', 'refs/tags/v1.7.0+215', 16,
            released: true);
        expect(r.code, 0, reason: r.log);
        expect(r.out, contains('build_number=215\n'));
        expect(r.log, contains('::warning::'));
        expect(r.log, contains('re-releasing build 215'));
        expect(r.gh, ['release view v1.7.0+215 --repo owner/repo']);
        final main = await plan('workflow_dispatch', 'refs/heads/main', 16);
        expect(main.code, 0);
        expect(main.out, contains('build_number=216\n'));
        expect(main.gh, isEmpty);
      });

      // A tag whose push the plan refused has no GitHub Release: Run
      // workflow on it built the low number and published it (Android
      // refuses it as a downgrade over a higher build already out).
      test('Run workflow on a +N tag with no release (its push was refused) '
          'stops before anything is built', () async {
        final pushed = await plan('push', 'refs/tags/v1.7.0+205', 8);
        expect(pushed.code, 1);
        expect(pushed.gh, isEmpty, reason: 'a push asks nothing');
        final r = await plan('workflow_dispatch', 'refs/tags/v1.7.0+205', 9);
        expect(r.code, 1, reason: r.log);
        expect(r.gh, ['release view v1.7.0+205 --repo owner/repo']);
        expect(r.log, contains('::error::Run workflow on tag v1.7.0+205: '
            'build number 205 is below 209, and v1.7.0+205 has no GitHub '
            'Release'));
        expect(r.log, contains('use a +N above 209'));
        expect(r.log, isNot(contains('::warning::')));
        expect(r.out, isNot(contains('build_number=')));
        // At or above the floor, Run workflow asks nothing.
        final high = await plan('workflow_dispatch', 'refs/tags/v1.7.0+220', 16);
        expect(high.code, 0, reason: high.log);
        expect(high.gh, isEmpty);
        expect(high.out, contains('build_number=220\n'));
      });

      // RD-5: the floor was the run's alone, so once a +N above it went
      // out, a later tag's +N or a later run's own number could land on
      // it, or below it. The plan step reads the repository's tags.
      test('another +N tag holds a tag\'s +N above its number', () async {
        const earlier = ['v1.6.9+215', 'v1.6.0', 'android-v1.7.0', 'v1.6.0+8'];
        // Run 12's own floor is 212: 213 clears it, but not 215.
        for (final n in [205, 213, 215]) {
          final r =
              await plan('push', 'refs/tags/v1.7.0+$n', 12, tags: earlier);
          expect(r.code, 1, reason: '+$n: ${r.log}');
          expect(
              r.log,
              contains('::error::tag v1.7.0+$n carries build number $n, but '
                  'tag v1.6.9+215 numbered its build 215'));
          expect(r.log, contains('Use a +N above 215.'));
          expect(r.log, isNot(contains('Tag v1.7.0 without a +N instead')),
              reason: 'a plain tag at the next run (213) is refused too');
          expect(r.out, isNot(contains('build_number=')));
          expect(r.git, ['ls-remote --tags --refs origin']);
        }
        final above =
            await plan('push', 'refs/tags/v1.7.0+216', 12, tags: earlier);
        expect(above.code, 0, reason: above.log);
        expect(above.out, contains('build_number=216\n'));
      });

      test('a run numbered offset + run number waits until it is above '
          'every +N tag', () async {
        const earlier = ['v1.6.9+215'];
        final base = int.parse(offset);
        for (final (event, ref, lane) in [
          ('push', 'refs/tags/v1.7.0', 'both'),
          ('workflow_dispatch', 'refs/heads/main', 'play'),
          ('workflow_dispatch', 'refs/heads/main', 'testflight'),
        ]) {
          for (final run in [10, 15]) {
            final r = await plan(event, ref, run, lane: lane, tags: earlier);
            expect(r.code, 1, reason: '$ref $lane at run $run: ${r.log}');
            expect(
                r.log,
                contains('::error::this is Release run $run, so its build '
                    'number is ${base + run}'));
            expect(r.log, contains('but tag v1.6.9+215 numbered its build 215'));
            expect(r.log, contains('Raise BUILD_NUMBER_OFFSET in release.yml'));
            expect(r.out, isNot(contains('build_number=')));
          }
          final next = await plan(event, ref, 16, lane: lane, tags: earlier);
          expect(next.code, 0, reason: '$ref $lane at run 16: ${next.log}');
          expect(next.out, contains('build_number=${base + 16}\n'));
        }
      });

      test('the tag being built, and tags that are not vX.Y.Z+N, do not '
          'count', () async {
        // Run workflow re-releasing v1.7.0+215 itself.
        final self = await plan('workflow_dispatch', 'refs/tags/v1.7.0+215', 16,
            released: true, tags: ['v1.7.0+215']);
        expect(self.code, 0, reason: self.log);
        expect(self.out, contains('build_number=215\n'));
        // A higher +N tag next to it: still a re-release, with a warning.
        final higher = await plan(
            'workflow_dispatch', 'refs/tags/v1.7.0+215', 16,
            released: true, tags: ['v1.7.0+215', 'v1.6.9+220']);
        expect(higher.code, 0, reason: higher.log);
        expect(higher.log, contains('re-releasing build 215 (below 221'));
        // Not released, below another tag's number: refused, and why.
        final unreleased = await plan(
            'workflow_dispatch', 'refs/tags/v1.7.0+213', 12,
            tags: ['v1.6.9+215']);
        expect(unreleased.code, 1, reason: unreleased.log);
        expect(
            unreleased.log,
            contains('::error::Run workflow on tag v1.7.0+213: build number '
                '213 is not above 215, which tag v1.6.9+215 carries'));
        // None of these is a vX.Y.Z+N tag.
        final others = await plan('workflow_dispatch', 'refs/heads/main', 8,
            tags: [
              'android-v1.7.0',
              'v1.6.0',
              'v1.7.0-rc1+300',
              'v1.7+300',
              'release/v1.6.1+300',
              'v1.6.0+8',
            ]);
        expect(others.code, 0, reason: others.log);
        expect(others.out, contains('build_number=${int.parse(offset) + 8}\n'));
      });

      test('a failed read of the tags stops the run', () async {
        final r = await plan('workflow_dispatch', 'refs/heads/main', 16,
            tagsFail: true);
        expect(r.code, 1);
        expect(
            r.log,
            contains("::error::could not read the repository's tags "
                '(git ls-remote)'));
        expect(r.out, isEmpty);
      });

      // Review of #77 (RV-3, DT-3): RELEASING § 5 said two tags pushed
      // together could each pass. A run reads the tags after the push that
      // started it, so tags pushed in one push see each other, and a tag
      // pushed after a run has read them starts a later run, which reads
      // the earlier run's tag.
      test('two tags that would collide never both pass', () async {
        /// The plan of a push of tag [name] at Release run [run], with
        /// [seen] the repository's tags then, and pubspec at its version.
        Future<({int code, String log, String out})> push(
            String name, int run, List<String> seen) async {
          final version = name.substring(1).split('+').first;
          final r = await plan('push', 'refs/tags/$name', run,
              pubspec: '$version+9', tags: seen);
          return (code: r.code, log: r.log, out: r.out);
        }

        // One push, two +N tags: each run sees both, the lower is refused.
        const pair = ['v1.7.0+215', 'v1.7.1+216'];
        final lower = await push('v1.7.0+215', 9, pair);
        expect(lower.code, 1, reason: lower.log);
        expect(lower.log, contains('but tag v1.7.1+216 numbered its build 216'));
        final higher = await push('v1.7.1+216', 10, pair);
        expect(higher.code, 0, reason: higher.log);
        expect(higher.out, contains('build_number=216\n'));
        // Equal: both are refused, whichever run starts first.
        const equal = ['v1.7.0+215', 'v1.7.1+215'];
        for (final (name, run) in [('v1.7.0+215', 9), ('v1.7.1+215', 10)]) {
          final r = await push(name, run, equal);
          expect(r.code, 1, reason: '$name: ${r.log}');
          expect(r.out, isNot(contains('build_number=')));
        }

        // Pushed after run 9 had read the tags: run 10's floor is above
        // run 9's own number, and run 10 counts run 9's +N.
        final plain = await push('v1.7.0', 9, ['v1.7.0']);
        expect(plain.out, contains('build_number=209\n'));
        final same = await push('v1.7.1+209', 10, ['v1.7.0', 'v1.7.1+209']);
        expect(same.code, 1, reason: same.log);
        final after = await push('v1.7.1+210', 10, ['v1.7.0', 'v1.7.1+210']);
        expect(after.code, 0, reason: after.log);
        expect(after.out, contains('build_number=210\n'));
        final plus = await push('v1.7.0+215', 9, ['v1.7.0+215']);
        expect(plus.out, contains('build_number=215\n'));
        for (final name in ['v1.7.1', 'v1.7.1+215']) {
          final r = await push(name, 10, ['v1.7.0+215', name]);
          expect(r.code, 1, reason: '$name: ${r.log}');
          expect(r.log, contains('but tag v1.7.0+215 numbered its build 215'));
        }
        final above =
            await push('v1.7.1+216', 10, ['v1.7.0+215', 'v1.7.1+216']);
        expect(above.code, 0, reason: above.log);

        // What RELEASING § 5 and the plan step's comment say about it.
        final releasing =
            _readRepo('docs/RELEASING.md').replaceAll(RegExp(r'\s+'), ' ');
        expect(releasing,
            isNot(contains('two tags pushed together can each pass')));
        expect(releasing,
            contains('So two tags that would collide never both pass.'));
        expect(releasing,
            contains('the checkout fetches no tag but the one being built'));
        expect(workflow, isNot(contains('one pushed while this step runs')));
        expect(workflow, isNot(contains('The checkout fetches no tags')));
        expect(workflow,
            contains('two tags that would collide never both pass'));
      });

      // Review of the 1.7.2 prep (PREP-R5, 2026-11-23): RELEASING § 5's
      // example of an earlier +N tag was `v1.7.1+215` at run 9 and
      // `v1.7.2+213` at run 12, but v1.7.1 stays unused, run 9 built
      // android-v1.7.1 (build 209), and v1.7.2 is the iPhone's real next
      // tag. No +N tag has been pushed, so RELEASING names no real version
      // in one, and the made-up case uses runs after the newest release's.
      test("RELEASING § 5's +N example names no real tag or run", () {
        final releasing =
            _readRepo('docs/RELEASING.md').replaceAll(RegExp(r'\s+'), ' ');
        expect(
            [
              for (final m
                  in RegExp(r'`v\d+\.\d+\.\d+\+\d+`').allMatches(releasing))
                m.group(0)
            ],
            isEmpty);
        final at = releasing.indexOf('In a made-up case, after a tag '
            '`vX.Y.Z+225` at run 19');
        expect(at, greaterThanOrEqualTo(0));
        final example = releasing.substring(
            at, releasing.indexOf('So take a `+N` only a little above', at));
        final lastRun = _kAndroidReleases.last.build - int.parse(offset);
        final runs = [
          for (final m in RegExp(r'\bruns? (\d+)').allMatches(example))
            int.parse(m.group(1)!),
        ];
        expect(runs, isNotEmpty);
        for (final run in runs) {
          expect(run, greaterThan(lastRun),
              reason: 'run $run: run $lastRun built '
                  'android-v${_kAndroidReleases.last.version}');
        }
        // The example's own numbers: run 19's tag holds runs 20 to 25.
        expect(
            example,
            contains('a plain tag at run 25 is numbered 225 too, and a `+223` '
                "tag at run 22 clears that run's floor (222)"));
        expect(example, contains('in the example, runs 20 to 25 are refused'));
        expect(example, contains("it plus the next run's number is above 225"));
      });

      // RD-1: Run workflow › lane play built 1.7.0 while the policy dated
      // that build's behaviour from 1.7.1.
      test('an Android run stops while pubspec is below the newest "From '
          'version" in docs/PRIVACY.md', () async {
        const ahead = 'From version 1.7.0 the address must start with '
            '`https://`.\nFrom version 1.7.1, on Android, that switch is '
            'off.\n';
        for (final (event, ref, lane) in [
          ('workflow_dispatch', 'refs/heads/main', 'play'),
          ('workflow_dispatch', 'refs/heads/main', 'both'),
          ('push', 'refs/tags/v1.7.0', 'both'),
        ]) {
          final r = await plan(event, ref, 8, lane: lane, policy: ahead);
          expect(r.code, 1, reason: '$ref $lane: ${r.log}');
          expect(
              r.log,
              contains("::error::app/pubspec.yaml says 1.7.0, but "
                  "docs/PRIVACY.md says 'From version 1.7.1', and this run "
                  'builds Android'));
          expect(r.log,
              contains('to 1.7.1 or later first (docs/RELEASING.md § 6.6)'));
          expect(r.out, isNot(contains('build_number=')));
        }
        // An iPhone-only run builds no Android.
        final ios = await plan('workflow_dispatch', 'refs/heads/main', 8,
            lane: 'testflight', policy: ahead);
        expect(ios.code, 0, reason: ios.log);
        // Bumped to it, or past it.
        for (final version in ['1.7.1+10', '1.8.0+11']) {
          final r = await plan('workflow_dispatch', 'refs/heads/main', 8,
              lane: 'play', policy: ahead, pubspec: version);
          expect(r.code, 0, reason: '$version: ${r.log}');
          expect(r.out, contains('build_name=${version.split('+').first}\n'));
        }
      });

      test('the policy check compares versions, reads across line breaks '
          'and needs the policy', () async {
        Future<({int code, String log})> android(
            String pubspec, String? policy,
            {String lane = 'play'}) async {
          final r = await plan('workflow_dispatch', 'refs/heads/main', 8,
              lane: lane, pubspec: pubspec, policy: policy);
          return (code: r.code, log: r.log);
        }

        expect((await android('1.9.0+10', 'From version 1.10.0, X.\n')).code,
            1, reason: '1.10.0 is above 1.9.0');
        expect((await android('1.10.0+10', 'From version 1.9.0, X.\n')).code,
            0);
        expect(
            (await android('1.7.0+9', 'A sentence that wraps. From\n'
                    'version 1.7.1, on Android, X.\n'))
                .code,
            1,
            reason: 'wrapped inside "From version"');
        expect(
            (await android('1.7.0+9', 'Effective date: 2026-11-20\n')).code, 0,
            reason: 'no version named');
        final missing = await android('1.7.0+9', null);
        expect(missing.code, 1);
        expect(missing.log, contains('docs/PRIVACY.md is missing'));
        expect((await android('1.7.0+9', null, lane: 'testflight')).code, 0);
      });

      // The plan step and the gate above read the real policy alike.
      test('against the real policy: pubspec passes, a version below its '
          'newest stops', () async {
        final policy = _readRepo('docs/PRIVACY.md');
        final version = RegExp(r'^version:\s*(\S+)$', multiLine: true)
            .firstMatch(_read('pubspec.yaml'))!
            .group(1)!;
        final ok = await plan('workflow_dispatch', 'refs/heads/main', 8,
            lane: 'play', policy: policy, pubspec: version);
        expect(ok.code, 0, reason: ok.log);
        final v = _policyVersions(policy).en;
        final newest =
            v.reduce((a, b) => _compareVersions(a, b) >= 0 ? a : b);
        final p = newest.split('.').map(int.parse).toList();
        final below = p[2] > 0
            ? '${p[0]}.${p[1]}.${p[2] - 1}'
            : p[1] > 0
                ? '${p[0]}.${p[1] - 1}.99'
                : '${p[0] - 1}.99.99';
        final r = await plan('workflow_dispatch', 'refs/heads/main', 8,
            lane: 'play', policy: policy, pubspec: '$below+9');
        expect(r.code, 1, reason: r.log);
        expect(r.log, contains("docs/PRIVACY.md says 'From version $newest'"));
      });

      test('the plan step has the token gh needs, and no more permission',
          () {
        final at = workflow.indexOf('        id: plan\n');
        final step = workflow.substring(
            at, workflow.indexOf('        run: |\n', at));
        expect(step, contains(r'GH_TOKEN: ${{ github.token }}'));
        expect(job('plan'), isNot(contains('permissions:')),
            reason: 'the workflow\'s contents: read is enough');
        expect(workflow, contains('\npermissions:\n  contents: read\n'));
      });
    }, skip: Platform.isWindows);

    // R16: with hasFragileUserData, an uninstall that keeps the app data
    // keeps the old signature, and a differently signed build then fails
    // to install. The notes say to leave the box unticked, as the
    // android-v1.7.0 notes do.
    test('R16: the release notes and the share script say to leave "Keep '
        'app data" unticked', () {
      final notes = job('github-release');
      expect(notes, contains('if Android offers **Keep app data**, leave it '
          'unticked'));
      expect(notes, contains('export your log (Settings › Export Data)'));
      expect(notes, isNot(contains('needs an uninstall')));
      final script = _readRepo('scripts/build_share_apk.sh');
      expect(script, contains(r'if Android offers \"Keep app data\", leave it'));
      expect(script, contains('unticked'));
      expect(_read('android/app/src/main/AndroidManifest.xml'),
          contains('android:hasFragileUserData="true"'));
    });
  });

  group('review fixes: release.yml, scripts and § 6', () {
    final workflow = _readRepo('.github/workflows/release.yml');

    // M2: Data safety's "encrypted in transit" rests on the https switch;
    // the Android job refuses to build without it.
    test('the Android job checks kRequireHttpsServer before it builds', () {
      const step = '- name: Check the app refuses plain-http servers';
      expect(workflow, contains(step));
      expect(workflow,
          contains("grep -Eq '^const bool kRequireHttpsServer = true;' \"\$f\""));
      final android = workflow.substring(workflow.indexOf('  android:'));
      expect(android.indexOf(step), greaterThan(0));
      expect(android.indexOf(step),
          lessThan(android.indexOf('- name: Build the signed app bundle')));
    });

    // L11: a later v1.7.0's generated notes must not start from the
    // hand-made android-v1.7.0 release.
    test('generated release notes start at the previous v* release', () {
      expect(workflow, contains('--notes-start-tag "\$prev"'));
      expect(workflow, contains("grep -E '^v[0-9]'"));
    });

    test('the setup-link script takes https servers only', () {
      final script = _readRepo('scripts/provision_phone.sh');
      expect(script, isNot(contains('SERVER_URL=http://')));
      expect(script, contains(r'[[ "$SERVER_URL" == https://* ]]'));
    });

    // L9: Apple's system fonts are not licensed for artwork like this.
    test('the feature graphics use Roboto and Noto Sans SC only', () {
      final script = _readRepo('scripts/play_graphics.py');
      for (final apple in ['/System/Library/Fonts', 'SFNS', 'Hiragino', 'PingFang']) {
        expect(script, isNot(contains(apple)), reason: apple);
      }
      expect(script, contains('Roboto-Bold.ttf'));
      expect(script, contains('NotoSansSC-Bold'));
    });

    test('§ 6 has the review fixes', () {
      final releasing = _readRepo('docs/RELEASING.md');
      final flat = releasing.replaceAll(RegExp(r'\s+'), ' ');
      expect(releasing, isNot(contains('~/upload-keystore.jks')));
      for (final fact in [
        'adi-registration.properties',
        'keytool -list -v -keystore <that keystore> -alias upload',
        'the log of the **v1.6.0** Release run',
        '**Done; never regenerate it.**',
        '*Request upload key reset* does not fix (it only replaces the key you upload with)',
        '`hotfix/*`',
        'Monitor and improve › Policy and programs › App content',
        'kRequireHttpsServer = true` at the run\'s commit',
        'kPolicyEffectiveDate',
      ]) {
        expect(flat, contains(fact), reason: fact);
      }
    });
  });
}
