/// Who receives meal data when the app asks an AI, as the per-recipient
/// consent sees it (App Store guideline 5.1.2(i): disclose where personal
/// data goes, "including with third-party AI", and get explicit permission
/// first). Pure, so AppSettings and the UI name a recipient the same way.
library;

/// The consent route of a provider choice: the provider id for an API key
/// ('gemini', 'openai', …), and `server:<plan>` for the user's own server.
/// The AI company behind the server is the PLAN (Claude, GLM or Doubao),
/// so switching plans on the same server is a new recipient and asks
/// again; editing the server's address is not.
String aiConsentRoute(String provider, String serverBackend) =>
    provider == 'server'
        ? 'server:${const {'glm', 'doubao'}.contains(serverBackend) ? serverBackend : 'claude'}'
        : provider;

/// Every route the app can send to (the provider ids plus the three
/// server plans), for tests and for code that must enumerate them.
const Set<String> allAiConsentRoutes = {
  'gemini',
  'openai',
  'anthropic',
  'xai',
  'openrouter',
  'deepseek',
  'qwen',
  'doubao',
  'glm',
  'server:claude',
  'server:glm',
  'server:doubao',
};

/// Routes whose AI company processes the data in mainland China:
/// api.deepseek.com, dashscope.aliyuncs.com, ark.cn-beijing.volces.com and
/// open.bigmodel.cn — the GLM and Doubao plans reach the last two from the
/// user's server (claude_analyzer.py). The consent dialog says so.
const Set<String> aiRoutesInMainlandChina = {
  'deepseek',
  'qwen',
  'doubao',
  'glm',
  'server:glm',
  'server:doubao',
};

/// The version of the consent TEXT a grant was given under. Every new
/// grant records the current one (AppSettings.setAiConsent); a grant with
/// none recorded — every grant from before versions existed, the one-time
/// seed of a pre-consent install included — is version 1.
///
/// - 1: the original text.
/// - 2: a photo taken before 4 a.m. also carries the day before's meals
///   (B14, run 7).
/// - 3: a note typed in Edit meal goes with that meal's description, foods
///   and numbers, and the meal's earlier notes (owner 2026-11-24).
///
/// When the text changes what is sent, bump this. A grant from an older
/// version is then asked once more before the new data goes: by the app
/// shell at launch for a change to what goes on its own
/// ([aiConsentShellAskVersion]; ui/ai_consent.dart askAiConsentUpdate), or
/// at the deliberate send the change adds (ui/ai_consent.dart
/// ensureMealNoteConsent). The new data waits for that answer.
const int aiConsentWordingVersion = 3;

/// The first [aiConsentWordingVersion] that says a photo taken before
/// 04:00 also carries the previous day's meals. A grant from before it
/// keeps exactly what it agreed to: that day's meals only
/// (AppSettings.previousDayLeftoverContext → PhotoPipeline).
const int aiConsentPreviousDayVersion = 2;

/// The first [aiConsentWordingVersion] that lists a note typed in Edit
/// meal. A grant from before it is asked once more at the first note send
/// (ui/ai_consent.dart ensureMealNoteConsent); nothing else it sends
/// changes.
const int aiConsentMealNoteVersion = 3;

/// The newest consent text the app shell asks an older grant about at
/// launch (ui/ai_consent.dart aiConsentUpdateNeeded): the B14 text, which
/// changed what an automatic photo carries. A text that only adds a
/// deliberate send — version 3, the Edit meal note — is asked about at
/// that send instead, so a user who never sends one is not interrupted.
const int aiConsentShellAskVersion = 2;
