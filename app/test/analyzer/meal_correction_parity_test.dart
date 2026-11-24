// A note in Edit meal through every provider (the shared
// MultiProviderAnalyzer, as di.dart builds it, through DefaultNlExecutor):
// one text request with no image and no response_format; the zh
// reply-language directive appended once and last by a direct provider,
// left to the own server (lang: zh) there; the same canned patch, wrapped
// in each provider's envelope, read as the same correction; and the call
// counted in analyzerBusy while it runs (so a restaurant lookup waits).
import 'dart:async';
import 'dart:convert';

import 'package:calorie_tracker/core/meal_correction.dart';
import 'package:calorie_tracker/core/prompts.dart';
import 'package:calorie_tracker/core/shared_generated.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/nl/executor.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../nl/fakes.dart' show FakeDao, MemoryKeyStore;

const _meal = MealCorrectionInput(
  description: 'Braised pork with rice',
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
  ],
  totals: MealCorrectionTotals(calories: 660, protein: 32, carbs: 70, fat: 26),
  earlierNotes: ['the pork was lean'],
);
const _note = 'only half the rice';

const _patch = {
  'status': 'corrected',
  'reason': '米饭减半。',
  'changed': [
    {
      'id': 0,
      'name': 'Steamed rice (~100 g)',
      'estimated_calories': 130,
      'protein_g': 2.5,
      'carbs_g': 28.5,
      'fat_g': 0.25,
    },
  ],
};

Future<AppSettings> _settings(AiProvider p) async {
  SharedPreferences.setMockInitialValues({});
  final s = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(),
      keyStore: MemoryKeyStore());
  await s.setProvider(p);
  switch (p) {
    case AiProvider.gemini:
      await s.setGeminiApiKey('k-gemini');
    case AiProvider.openai:
      await s.setOpenaiApiKey('sk-openai');
    case AiProvider.anthropic:
      await s.setAnthropicApiKey('sk-ant');
    case AiProvider.qwen:
      await s.setQwenApiKey('sk-qwen');
    case AiProvider.doubao:
      await s.setDoubaoApiKey('ark-doubao');
    case AiProvider.glm:
      await s.setGlmApiKey('glm.key');
    case AiProvider.deepseek:
      await s.setDeepseekApiKey('sk-deepseek');
    case AiProvider.xai:
      await s.setXaiApiKey('xai-key');
    case AiProvider.openrouter:
      await s.setOpenrouterApiKey('sk-or-key');
    case AiProvider.server:
      await s.setServerBaseUrl('https://10.0.0.5');
      await s.setServerApiKey('upload-key');
  }
  await s.setAppLanguage('zh');
  return s;
}

const _json = {'content-type': 'application/json; charset=utf-8'};

/// The canned patch in [p]'s reply envelope.
http.Response _reply(AiProvider p) {
  final text = jsonEncode(_patch);
  return switch (p) {
    AiProvider.gemini => http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text}
                ]
              }
            }
          ]
        }),
        200,
        headers: _json),
    AiProvider.anthropic => http.Response(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': text}
          ]
        }),
        200,
        headers: _json),
    AiProvider.server => http.Response(
        jsonEncode({'ok': true, 'result': _patch, 'analyzed_by': 'claude'}),
        200,
        headers: _json),
    _ => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': text}
            }
          ]
        }),
        200,
        headers: _json),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final request = composeMealCorrectionRequest(_meal, _note);
  final prompt = mealCorrectionPrompt(request);
  const directive = SharedConstants.replyLanguageDirectiveZh;
  final expected =
      (parseMealCorrectionReply(_patch, _meal) as MealCorrected).proposal;

  test('the prompt itself carries no directive: each provider adds it once, '
      'last, or leaves it to the server', () {
    expect(prompt, isNot(contains(directive)));
    expect(withReplyLanguage(prompt, chinese: true), endsWith('$directive\n'));
  });

  for (final p in AiProvider.values) {
    test('${p.name}: one text request, the directive placed right, the '
        'same correction, counted while it runs', () async {
      final s = await _settings(p);
      final requests = <http.Request>[];
      final hold = Completer<void>();
      final analyzer = MultiProviderAnalyzer(s,
          client: MockClient((r) async {
        requests.add(r);
        await hold.future;
        return _reply(p);
      }));
      final executor = DefaultNlExecutor(FakeDao(), analyzer, s,
          l10n: AppLocalizationsEn());
      final out = executor.correctMeal(_meal, _note);
      for (var i = 0; i < 20 && requests.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(requests, hasLength(1));
      expect(analyzer.analyzerBusy.value, 1, reason: 'counted while it runs');
      hold.complete();
      final outcome = await out;
      expect(analyzer.analyzerBusy.value, 0);
      expect(outcome.error, isNull);

      // The same correction, whatever carried it.
      final got = (outcome.reply! as MealCorrected).proposal;
      expect(got.changed.keys, expected.changed.keys);
      expect(got.changed[0]!.name, expected.changed[0]!.name);
      expect(got.changed[0]!.numbers, expected.changed[0]!.numbers);
      expect(got.reason, '米饭减半。');

      final r = requests.single;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect(r.body, isNot(contains('image')), reason: 'no photo, ever');
      switch (p) {
        case AiProvider.server:
          expect(r.url.path, '/api/text_intent');
          expect(body['prompt'], prompt,
              reason: 'the server appends the directive from lang');
          expect(body['lang'], 'zh');
          expect(body['backend'], 'claude');
        case AiProvider.gemini:
          final parts = body['contents'][0]['parts'] as List;
          expect(parts, hasLength(1), reason: 'one text part, no image');
          expect(parts.single['text'], withReplyLanguage(prompt, chinese: true));
          expect(body['generationConfig']['response_mime_type'],
              'application/json');
        case AiProvider.anthropic:
          final content = (body['messages'] as List).single['content'] as List;
          expect(content, hasLength(1), reason: 'one text block, no image');
          expect(content.single['text'], withReplyLanguage(prompt, chinese: true));
        default:
          final content = (body['messages'] as List).single['content'];
          final text = content is String
              ? content
              : ((content as List).single as Map)['text'] as String;
          if (content is List) {
            expect(content, hasLength(1), reason: 'no image part');
          }
          expect(text, withReplyLanguage(prompt, chinese: true));
          expect(body.containsKey('response_format'), isFalse);
      }
    });
  }
}
