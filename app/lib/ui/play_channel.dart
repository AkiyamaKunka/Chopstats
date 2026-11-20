/// The Google Play build's move off Watch Camera Roll (core/app_channel.dart).
///
/// The GitHub APK and the Play build are one package signed with one key
/// (owner decision 2026-11-13), so the Play build installs over a GitHub
/// install in place, meal log and settings kept. That install may have had
/// Watch Camera Roll on; the Play build has no such feature and no photo
/// permission. Its first launch turns the setting off (di.dart) before
/// anything reads it, the launch's job sync cancels the WorkManager job,
/// and the app shell shows ONE notice (app.dart) saying so and how to log
/// photos instead. Should WorkManager start the old job before the app is
/// opened, that run does the same and cancels its own job
/// (background_glue.dart). Nothing is deleted: meals, the ledger and every
/// other setting stay as they were.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_channel.dart';
import '../services/settings/app_settings.dart';

/// Set while the notice is owed; removed once the user dismissed it.
const String watchRetiredNoticePrefsKey = 'play_channel.watch_retired_notice';

/// In a build without the photo library ([photoLibraryInBuild] false):
/// turns Watch Camera Roll off when it is on, and owes the notice. True
/// when it did. The notice is noted FIRST, so a process killed between the
/// two writes leaves the switch on and the next launch does both again:
/// never a switch turned off without its notice. Anywhere else (the GitHub
/// APK, every iPhone build) it does nothing.
Future<bool> retireWatchCameraRoll(
    AppSettings settings, SharedPreferences prefs) async {
  if (photoLibraryInBuild || !settings.watcherEnabled) return false;
  await prefs.setBool(watchRetiredNoticePrefsKey, true);
  await settings.setWatcherEnabled(false);
  return true;
}

/// Whether the notice is owed. Never in a build with the photo library.
bool watchRetiredNoticeOwed(SharedPreferences prefs) =>
    !photoLibraryInBuild &&
    (prefs.getBool(watchRetiredNoticePrefsKey) ?? false);

/// The user dismissed the notice: it is not shown again.
Future<void> watchRetiredNoticeShown(SharedPreferences prefs) =>
    prefs.remove(watchRetiredNoticePrefsKey);
