// The Google Play build (owner decision 1, 2026-11-13): one switch,
// `--dart-define=CHOPSTATS_CHANNEL=play`, read at compile time. Production
// reads the define; tests run either build through debugAppChannelOverride.
import 'package:calorie_tracker/core/app_channel.dart';
import 'package:calorie_tracker/services/photo/background.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    debugAppChannelOverride = null;
    debugIsIOSOverride = null;
  });

  test('without the define (every test run, the GitHub APK): the full build',
      () {
    expect(kAppChannelDefine, '');
    expect(appChannel, AppChannel.github);
    expect(photoLibraryInBuild, isTrue);
  });

  test('the override runs a test as either build', () {
    debugAppChannelOverride = AppChannel.play;
    expect(appChannel, AppChannel.play);
    expect(photoLibraryInBuild, isFalse);
    debugAppChannelOverride = AppChannel.github;
    expect(photoLibraryInBuild, isTrue);
  });

  group('backgroundJobWanted', () {
    test('the GitHub APK on Android: only while Watch Camera Roll is on', () {
      debugIsIOSOverride = false;
      expect(backgroundJobWanted(watcherEnabled: true), isTrue);
      expect(backgroundJobWanted(watcherEnabled: false), isFalse);
    });

    test('the Play build: never, even with the setting a GitHub install left '
        'on', () {
      debugIsIOSOverride = false;
      debugAppChannelOverride = AppChannel.play;
      expect(backgroundJobWanted(watcherEnabled: true), isFalse);
      expect(backgroundJobWanted(watcherEnabled: false), isFalse);
    });

    test('iOS: always, as before', () {
      debugIsIOSOverride = true;
      expect(backgroundJobWanted(watcherEnabled: false), isTrue);
    });
  });
}
