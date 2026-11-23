/// Coach-notification strings for the HEADLESS path.
///
/// The WorkManager isolate has no BuildContext, so it cannot use
/// `context.l10n`. These read the SAME generated localization classes the
/// UI uses, selected by the user's saved language preference — one source
/// of wording, two delivery paths.
library;

import 'dart:ui' show PlatformDispatcher;

import '../core/app_channel.dart' show photoLibraryInBuild;
import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';
import '../l10n/app_localizations_zh.dart';
import '../services/report/coach_summary.dart';
import '../services/report/daily_summary.dart' show SummaryDayNaming;

/// [appLanguage] is the persisted 'system' | 'en' | 'zh'.
CoachStrings coachStringsFor(String appLanguage) {
  final l = localizationsFor(appLanguage);
  return CoachStrings(
    title: l.coachTitle,
    titleYesterday: l.coachTitleYesterday,
    // The Play build logs nothing on its own (core/app_channel.dart): no
    // "it lands here automatically" there.
    empty: photoLibraryInBuild ? l.coachEmpty : l.coachEmptyPlay,
    emptyYesterday:
        photoLibraryInBuild ? l.coachEmptyYesterday : l.coachEmptyYesterdayPlay,
    underGoal: l.coachUnderGoal,
    underTypical: l.coachUnderTypical,
    partialGoal: l.coachPartialGoal,
    partialTypical: l.coachPartialTypical,
    onTarget: l.coachOnTarget,
    onTypical: l.coachOnTypical,
    overGoal: l.coachOverGoal,
    overTypical: l.coachOverTypical,
    noReference: l.coachNoReference,
    detail: l.coachDetail,
  );
}

/// Android's day-named card wording (SummaryDayNaming, daily_summary.dart)
/// in [appLanguage]: 'Thu: 1,850 kcal' / '周四：1,850 千卡'.
SummaryDayNaming summaryDayNamingFor(String appLanguage) {
  final l = localizationsFor(appLanguage);
  const keys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  return SummaryDayNaming(
    dayName: (day) => l.coachWeekday(keys[day.weekday - 1]),
    title: l.coachTitleOnDay,
    empty: photoLibraryInBuild ? l.coachEmptyOnDay : l.coachEmptyOnDayPlay,
  );
}

/// The daily summary's Android notification channel, name and
/// description, in the app language — Android shows them in its own
/// Settings and in a card's long-press menu, and never translates them
/// itself.
({String name, String description}) notificationChannelFor(
    String appLanguage) {
  final l = localizationsFor(appLanguage);
  return (
    name: l.notificationChannelName,
    description: l.notificationChannelDescription,
  );
}

/// The meal cards' Android channel (Play push), likewise.
({String name, String description}) mealNotificationChannelFor(
    String appLanguage) {
  final l = localizationsFor(appLanguage);
  return (
    name: l.notificationMealChannelName,
    description: l.notificationMealChannelDescription,
  );
}

/// The summary the app posts over two or more Logged meals cards on
/// Android (ReportNotifier.mealGroupKey, PR80-B2), title and body, in the
/// app language.
({String title, String body}) mealGroupSummaryFor(String appLanguage) {
  final l = localizationsFor(appLanguage);
  return (title: l.mealGroupSummaryTitle, body: l.mealGroupSummaryBody);
}

AppLocalizations localizationsFor(String appLanguage) {
  if (appLanguage == 'zh') return AppLocalizationsZh();
  if (appLanguage == 'en') return AppLocalizationsEn();
  // 'system': the background isolate still knows the platform locale, so a
  // headless notification matches the UI the user reads.
  final code = PlatformDispatcher.instance.locale.languageCode.toLowerCase();
  return code == 'zh' ? AppLocalizationsZh() : AppLocalizationsEn();
}
