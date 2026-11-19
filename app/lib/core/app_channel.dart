/// Which build this is: the GitHub APK (and every iPhone build), or the
/// Google Play build (owner decision 1, 2026-11-13).
///
/// The first Google Play build ships WITHOUT broad photo access. It is
/// built with `--dart-define=CHOPSTATS_CHANNEL=play`, and that one switch
/// does both halves:
/// - the manifest: android/app/build.gradle.kts reads the same define and
///   merges src/playChannel/AndroidManifest.xml into every variant, which
///   removes READ_MEDIA_IMAGES, READ_MEDIA_VISUAL_USER_SELECTED and
///   READ_EXTERNAL_STORAGE;
/// - the app: [photoLibraryInBuild] is false, so nothing reads the photo
///   library on its own or asks for it. Watch Camera Roll (its live
///   watcher, the launch and resume catch-ups and the WorkManager job), the
///   Meta glasses switch and Photo Coverage are left out; the system photo
///   picker (Log › From recent photos, Leftovers) and the share sheet are
///   how photos come in. A GitHub install that had Watch Camera Roll on is
///   moved over once (ui/play_channel.dart).
///
/// The GitHub APK, built without the define, keeps everything. Android
/// only: an iPhone build is the full app whatever the define says.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// The two builds.
enum AppChannel {
  /// The GitHub APK, any build from source, and every iPhone build.
  github,

  /// The Google Play build: no photo-library permission, no library reads.
  play,
}

/// The define as this build was compiled with it: 'play' for the Play
/// build, '' without the define. Compile-time, so the background engine
/// (which never runs main()) reads the same value as the app.
const String kAppChannelDefine = String.fromEnvironment('CHOPSTATS_CHANNEL');

/// Tests only: runs a test as the other build, on any host. Null (always,
/// outside tests) = the define.
@visibleForTesting
AppChannel? debugAppChannelOverride;

/// The channel as the app reads it: [AppChannel.play] only for an Android
/// build made with the define.
AppChannel get appChannel =>
    debugAppChannelOverride ??
    (kAppChannelDefine == 'play' && Platform.isAndroid
        ? AppChannel.play
        : AppChannel.github);

/// Whether this build may read the photo library: it declares the photo
/// permissions, and so offers Watch Camera Roll (the live watcher, the
/// launch and resume catch-ups, the background job), the Meta glasses
/// switch, Photo Coverage and the recent-photos grid. False in the Play
/// build, which never asks for photo access: the system photo picker and
/// the share sheet need none.
bool get photoLibraryInBuild => appChannel != AppChannel.play;
