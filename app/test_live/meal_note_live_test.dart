// LIVE check of the Edit-meal note (plan § 6.4): real notes through the
// app's real executor and analyzers, against the real services. Opt-in, like
// providers_live_test.dart: `flutter test` runs only test/, so this never
// runs in CI or by accident.
//
//   cd app && flutter test test_live/meal_note_live_test.dart
//
// Targets:
// - the own server, when ~/.bitewise/server.env has SERVER_URL and
//   UPLOAD_KEY (BACKEND optional); ~/.bitewise/server_https_address.txt,
//   when present, is the address used, as the app uses the https one;
// - every direct provider with a key in ~/.bitewise/provider_keys.env or
//   the environment (the names providers_live_test.dart lists).
// A target with no key is skipped, and one that errors (a rejected key, an
// outage) stops at its first note. Values are never printed.
//
// What is asserted is the contract: the request went through and the answer
// is one the app can use (a correction, no change, or a question), and the
// three plain notes move the total the right way. The numbers are printed
// for a person to judge. A small model may answer outside the patch shape;
// the app then says "try saying it another way" and writes nothing, and this
// run fails that target so it is looked at.
import 'dart:io';

import 'package:calorie_tracker/core/meal_correction.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/nl/executor.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/nl/fakes.dart' show FakeDao, MemoryKeyStore;

const _meal = MealCorrectionInput(
  description: 'Braised pork with rice and a Coke',
  items: [
    MealCorrectionItem(
        name: 'Steamed rice (~200 g)',
        calories: 260,
        protein: 5,
        carbs: 57,
        fat: 0.5),
    MealCorrectionItem(
        name: 'Braised pork (~120 g)',
        calories: 400,
        protein: 27,
        carbs: 13,
        fat: 25.5),
    MealCorrectionItem(
        name: 'Coca-Cola (330 ml)', calories: 139, protein: 0, carbs: 35, fat: 0),
  ],
  totals: MealCorrectionTotals(calories: 799, protein: 32, carbs: 105, fat: 26),
);

/// The notes, the UI language they are sent in, and the way the total must
/// move (-1 down, 1 up, 0 either way or a question).
const _notes = [
  ('only half the rice', 'en', -1),
  ('the drink was diet coke', 'en', -1),
  ('add a fried egg', 'en', 1),
  ('this was a large size', 'en', 0),
  ('米饭只吃了一半', 'zh', -1),
];

Map<String, String> _envFile(String path) {
  final f = File(path);
  if (!f.existsSync()) return const {};
  final out = <String, String>{};
  for (final raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    var v = line.substring(eq + 1).trim();
    if (v.length >= 2 &&
        (v.startsWith('"') && v.endsWith('"') ||
            v.startsWith("'") && v.endsWith("'"))) {
      v = v.substring(1, v.length - 1);
    }
    out[line.substring(0, eq).trim()] = v;
  }
  return out;
}

/// The meal's kcal once [p] is applied, as the editor fills the form.
num _totalAfter(MealCorrectionProposal p) {
  if (p.totals != null) return p.totals!.calories;
  num sum = 0;
  for (var i = 0; i < _meal.items.length; i++) {
    if (p.removed.contains(i)) continue;
    sum += (p.changed[i] ?? _meal.items[i]).calories;
  }
  for (final a in p.added) {
    sum += a.calories;
  }
  return sum;
}

class _Target {
  _Target(this.label, this.configure, this.skip);
  final String label;
  final Future<void> Function(AppSettings s) configure;
  final String? skip;
}

void main() {
  final home = Platform.environment['HOME'] ?? '.';
  final keys = <String, String>{
    ..._envFile(Platform.environment['BITEWISE_PROVIDER_KEYS'] ??
        '$home/.bitewise/provider_keys.env'),
    for (final e in Platform.environment.entries)
      if (e.value.isNotEmpty) e.key: e.value,
  };
  final server = _envFile(Platform.environment['BITEWISE_SERVER_ENV'] ??
      '$home/.bitewise/server.env');
  final httpsFile = File('$home/.bitewise/server_https_address.txt');
  final serverUrl = httpsFile.existsSync()
      ? httpsFile.readAsStringSync().trim()
      : server['SERVER_URL'];
  final serverKey = server['UPLOAD_KEY'];

  final inner = HttpClient();
  if ((Platform.environment['HTTPS_PROXY'] ??
          Platform.environment['https_proxy'] ??
          '')
      .isNotEmpty) {
    inner.findProxy = HttpClient.findProxyFromEnvironment;
  }
  final http.Client client = IOClient(inner);

  final targets = <_Target>[
    _Target('Own server', (s) async {
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl(serverUrl!);
      await s.setServerApiKey(serverKey!);
      final b = server['BACKEND'];
      if (b != null && b.isNotEmpty) await s.setServerBackend(b);
    },
        (serverUrl == null || serverKey == null)
            ? 'no ~/.bitewise/server.env'
            : null),
  ];
  void direct(String label, AiProvider p, List<String> names,
      Future<void> Function(AppSettings s, String k) setKey) {
    String? k;
    for (final n in names) {
      final v = keys[n]?.trim();
      if (v != null && v.isNotEmpty) {
        k = v;
        break;
      }
    }
    targets.add(_Target(label, (s) async {
      await s.setProvider(p);
      await setKey(s, k!);
    }, k == null ? 'no key (${names.first})' : null));
  }

  direct('Gemini', AiProvider.gemini, ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
      (s, k) => s.setGeminiApiKey(k));
  direct('OpenAI', AiProvider.openai, ['OPENAI_API_KEY'],
      (s, k) => s.setOpenaiApiKey(k));
  direct('Claude API', AiProvider.anthropic, ['ANTHROPIC_API_KEY'],
      (s, k) => s.setAnthropicApiKey(k));
  direct('DeepSeek', AiProvider.deepseek, ['DEEPSEEK_API_KEY'],
      (s, k) => s.setDeepseekApiKey(k));
  direct('xAI Grok', AiProvider.xai, ['XAI_API_KEY', 'GROK_API_KEY'],
      (s, k) => s.setXaiApiKey(k));
  direct('Qwen', AiProvider.qwen, ['QWEN_API_KEY', 'DASHSCOPE_API_KEY'],
      (s, k) => s.setQwenApiKey(k));
  direct('Doubao', AiProvider.doubao, ['DOUBAO_API_KEY', 'ARK_API_KEY'],
      (s, k) => s.setDoubaoApiKey(k));
  direct('GLM', AiProvider.glm, ['GLM_API_KEY', 'ZHIPU_API_KEY'],
      (s, k) => s.setGlmApiKey(k));
  direct('OpenRouter', AiProvider.openrouter, ['OPENROUTER_API_KEY'],
      (s, k) => s.setOpenrouterApiKey(k));

  final lines = <String>[];

  for (final t in targets) {
    test('${t.label}: live Edit-meal notes', () async {
      if (t.skip != null) {
        lines.add('${t.label.padRight(11)} SKIPPED: ${t.skip}');
        markTestSkipped(t.skip!);
        return;
      }
      final problems = <String>[];
      for (final (note, lang, way) in _notes) {
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        final s = await AppSettings.load(
            prefs: await SharedPreferences.getInstance(),
            keyStore: MemoryKeyStore());
        await t.configure(s);
        await s.setAppLanguage(lang);
        final AppLocalizations l =
            lang == 'zh' ? AppLocalizationsZh() : AppLocalizationsEn();
        final executor = DefaultNlExecutor(
            FakeDao(), createMultiProviderAnalyzer(s, client: client), s,
            l10n: l);
        final sw = Stopwatch()..start();
        final out = await executor.correctMeal(_meal, note);
        final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
        final String said;
        switch (out.reply) {
          case MealCorrected(:final proposal):
            final after = _totalAfter(proposal);
            final moved = (after - _meal.totals.calories).sign;
            said = 'CORRECTED ${_meal.totals.calories} -> $after kcal'
                ' (${proposal.changed.length} changed, '
                '${proposal.added.length} added, '
                '${proposal.removed.length} removed) "${proposal.reason}"';
            if (way != 0 && moved != way) {
              problems.add('"$note": the total moved the wrong way');
            }
          case MealNoChange(:final reply):
            said = 'NO CHANGE "$reply"';
            if (way != 0) problems.add('"$note": no change');
          case MealUnclear(:final reply):
            said = 'QUESTION "$reply"';
            if (way != 0) problems.add('"$note": asked instead');
          case MealReplyUnusable(:final emptiesMeal):
            said = 'UNUSABLE${emptiesMeal ? ' (empties the meal)' : ''}';
            problems.add('"$note": unusable answer');
          case null:
            said = 'ERROR ${out.error}';
            problems.add('"$note": ${out.error}');
        }
        lines.add('${t.label.padRight(11)} ${secs.padLeft(5)}s '
            '[$lang] "$note" → $said');
        // A rejected key or an outage answers every note the same way.
        if (out.reply == null) break;
      }
      expect(problems, isEmpty, reason: '${t.label}: ${problems.join('; ')}');
    }, timeout: const Timeout(Duration(minutes: 8)));
  }

  tearDownAll(() {
    client.close();
    // ignore: avoid_print
    print('\n${lines.join('\n')}');
  });
}
