// Which library images are screenshots, as the app's catch-up asks
// (2026-11-28): it checks the newest day's other photos first
// (watcher_screenshots_test).
//
// iOS marks them itself: PHAssetMediaSubtypePhotoScreenshot, bit 2 of
// PHAsset.mediaSubtypes, which photo_manager 3.10.0 hands on as
// AssetEntity.subtype. Android's library has no such mark; the platform's
// own place for them is the Screenshots folder
// (Environment.DIRECTORY_SCREENSHOTS), which photo_manager gives as each
// image's relative path. Anything else is not told apart, and the scan
// then keeps its order.
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'watcher_test.dart' show FakeAsset, bytesOf;

AssetEntity _entity({int subtype = 0, String? relativePath}) => AssetEntity(
    id: 'asset',
    typeInt: AssetType.image.index,
    width: 1170,
    height: 2532,
    subtype: subtype,
    relativePath: relativePath);

void main() {
  test('iOS: the screenshot bit of the media subtypes, alone or beside '
      'others; no other bit', () {
    expect(iosScreenshotSubtype, 4, reason: 'PHAssetMediaSubtypePhotoScreenshot');
    expect(isScreenshotAsset(libraryAssetOf(_entity(subtype: 4))), isTrue);
    // With HDR (bit 1) beside it.
    expect(isScreenshotAsset(libraryAssetOf(_entity(subtype: 4 | 2))), isTrue);
    // A camera photo, a panorama, an HDR photo, a Live Photo, a portrait.
    for (final subtype in [0, 1, 2, 8, 16, 8 | 2]) {
      expect(isScreenshotAsset(libraryAssetOf(_entity(subtype: subtype))),
          isFalse,
          reason: 'subtype $subtype');
    }
  });

  test('Android: an image in a folder called Screenshots, wherever the '
      'maker keeps it; the camera folder and the rest are not', () {
    for (final path in [
      'Pictures/Screenshots/',
      'DCIM/Screenshots/',
      'Pictures/Screenshots',
      'DCIM/Screenshots/com.android.chrome/',
      'Pictures/screenshots/',
      'DCIM/Screenshot/',
      // Below Android 10: the parent folder's path.
      '/storage/emulated/0/Pictures/Screenshots',
    ]) {
      expect(inScreenshotsFolder(path), isTrue, reason: path);
      expect(
          isScreenshotAsset(libraryAssetOf(_entity(relativePath: path))),
          isTrue,
          reason: path);
    }
    for (final path in [
      'DCIM/Camera/',
      'Pictures/',
      'Pictures/WeChat/',
      'Download/',
      'Pictures/MyScreenshots/',
      'Pictures/Screenshots of recipes/',
      '',
    ]) {
      expect(inScreenshotsFolder(path), isFalse, reason: path);
      expect(
          isScreenshotAsset(libraryAssetOf(_entity(relativePath: path))),
          isFalse,
          reason: path);
    }
    expect(inScreenshotsFolder(null), isFalse, reason: 'iOS gives no path');
  });

  test('an asset the library cannot speak for is not a screenshot, and a '
      'mark that throws reads as none', () {
    expect(
        isScreenshotAsset(
            FakeAsset('a', 'IMG_a.jpg', DateTime(2026, 11, 27, 12), bytesOf(1))),
        isFalse);
    expect(isScreenshotAsset(_Throwing()), isFalse);
  });
}

class _Throwing extends FakeAsset implements ScreenshotMarked {
  _Throwing() : super('t', 'IMG_t.png', DateTime(2026, 11, 27, 12), bytesOf(2));

  @override
  bool get isScreenshot => throw StateError('no answer');
}
