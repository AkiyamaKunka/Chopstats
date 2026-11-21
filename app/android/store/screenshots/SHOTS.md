# Google Play phone screenshots: the shot list

The shots in `en-US/` and `zh-CN/` (01 to 07, in Play order) were captured
on 2026-11-20 with
[`scripts/play_screenshots.py`](../../../../scripts/play_screenshots.py)
from the **release build of the Play variant** (1.7.0; no Watch Camera
Roll, no Photo Coverage; decision 1, 2026-11-13: `flutter build apk
--release --dart-define=CHOPSTATS_CHANNEL=play`, `docs/RELEASING.md`
§ 6.3), never from a debug build (the DEBUG banner) and never from the
iPhone sets, which Play refuses (1320×2868 and 1206×2622 are about
2.17:1). Redo them the same way on each release candidate whose screens
changed (1.7.1 next), and look at every PNG before committing it.

## What Play accepts

From "Add preview assets to showcase your app"
(<https://support.google.com/googleplay/android-developer/answer/9866151>,
read 2026-11-13):

- JPEG or 24-bit PNG, **no alpha**; each side 320 to 3840 px; the long
  side at most twice the short side. At least 2 to publish, up to 8 per
  device type.
- To be eligible for recommendations: at least 4 screenshots of at
  least 1080 px.

What we capture, per language: **at least 4 portrait shots, 9:16,
1080×1920** (or larger at 9:16), 24-bit PNG with no alpha, en-US and
zh-CN.

## Recapture

```bash
cd app && flutter build apk --release --dart-define=CHOPSTATS_CHANNEL=play && cd ..
python3 scripts/play_screenshots.py avd     # create play_shots if needed, boot it headless
python3 scripts/play_screenshots.py shots   # en-US and zh-CN, 01-07, then --check-shots
python3 scripts/play_screenshots.py stop    # stop the emulator; the AVD stays
```

`shots --lang zh-CN --only 01,07` redoes some of them; `shots --apk PATH`
takes another Play-variant APK (for a release candidate, build it as above
at the candidate's commit: CI's Play build is an `.aab`); `demo-file en-US
--out demo.json` writes only the import file. It needs Python 3 with
Pillow and the Android SDK (`$ANDROID_HOME`). What it does, which is also
how to do it by hand:

- **The emulator.** The AVD `play_shots`: device profile `pixel_2`
  (1080×1920, 420 dpi, 9:16) on the system image
  `system-images;android-35;google_apis;arm64-v8a`, which must already be
  installed (nothing is downloaded), made with the `avdmanager` under
  `$ANDROID_HOME/cmdline-tools` (not Homebrew's) and booted headless on
  port 5562 (`emulator-5562`):

  ```bash
  "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd -n play_shots \
      -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_2
  "$ANDROID_HOME/emulator/emulator" -avd play_shots -port 5562 -no-window \
      -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot
  ```

  The AVD `ct_e2e` is a Pixel 7 at 1080×2400 (2.22:1), which Play refuses;
  squeezing it with `adb shell wm size 1080x1920` changes the layout the
  app was laid out for, so that is only a fallback.
- **The device.** Animations off, gesture navigation, light mode except
  shot 07, font and display size at default, system language as the
  shot's language (`adb root`, `adb shell setprop persist.sys.locale
  zh-CN`, `adb reboot`), the status bar clean (`adb shell settings put
  global sysui_demo_allowed 1` and the `com.android.systemui.demo`
  broadcasts: 20:45, full Wi-Fi and battery, no notification icons), and
  notifications denied to the app, so nothing pops up over a shot.
- **The app.** A fresh install of the APK, which the script first checks
  is the Play variant's release build (not debuggable, no
  `READ_MEDIA_IMAGES`). No API key is entered (the key field on 06 is
  empty) and no server address.
- **The data.** An import file in the app's own export format (a full
  export, `MealsDao.exportJson` / `BackupFileWriter.writeFull`), pushed to
  the emulator's Download folder as `chopstats-YYYY-MM-DD.json` and
  imported the way a user would: Settings › Import Data… › Choose File… ›
  Android's file picker. A release build refuses plain-http servers and
  is not debuggable, so no fake server and no `run-as`.
- **The capture.** The shots are taken by tapping through the app with
  uiautomator, captured with `adb exec-out screencap -p` (RGBA), flattened
  onto white and checked with `python3 scripts/play_graphics.py
  --check-shots app/android/store/screenshots/en-US` (and `zh-CN`), which
  refuses a wrong size, ratio or format. Files are named `NN_name.png` in
  Play order.

## The demo data

Demo data only: no real meal, no API key, no server address, no
notification content from any account. Dates follow the emulator's own
date. 30 days of plausible meals: today a breakfast, lunch, snack and
dinner logged from photos (1,896 kcal), the 29 days before it described
meals, a little more at weekends (in the committed shots the days run
from 1,637 to 2,312 kcal, average 1,891); a weight trend from 74.6 to
73.2 kg weighed on most mornings, and waist, chest and hip once a week.
Every food item's calories agree with its protein, carbs and fat (4/4/9
kcal per gram) and every total is the sum of its items. The Chinese file
has the same meals with the names the Chinese reply language makes the
AI write.

The photos are the README demo pictures in `docs/readme/photos/`, under
the Unsplash License (<https://unsplash.com/license>, licence lines from
`docs/readme/CREDITS.md`). Today's four photo meals carry the app's own
kind of thumbnail (160 px, JPEG quality 70) made from:

- yogurt-bowl.jpg: Natalie Behn, https://unsplash.com/photos/qj_zfYm-sdI
  (breakfast; in view on 01 and 07)
- chicken-salad.jpg: Katka Pavlickova, https://unsplash.com/photos/_QUVNqu3WKQ
  (lunch; in view on 01 and 07)
- iced-latte.jpg: Demi DeHerrera, https://unsplash.com/photos/L-sm1B4L1Ns
  (snack; in the file, not in view)
- burrito-bowl.jpg: Andrew Relf, https://unsplash.com/photos/iku1zhSNRU8
  (dinner, the meal open on 02; in the file, its picture not in view)

`dumplings.jpg` is not used.

## The shots (same order in both languages)

| # | File | Screen | Shows |
|---|---|---|---|
| 1 | `01_today.png` | Today, its large title collapsed | The day's calories and macros (1,896 kcal, 4 meals, typical day ~1,860) and the first two meal cards with their photos |
| 2 | `02_meal_editor.png` | Today's dinner, a photo meal, open in the editor | The totals, then the food items with the portion the AI assumed and their editable numbers |
| 3 | `03_log_sheet.png` | The Log sheet over Today | From recent photos, My usual foods, Leftovers, Describe a meal, Enter manually, Fix or delete a meal |
| 4 | `04_history.png` | History | The 30-day chart with its average, and the daily totals |
| 5 | `05_body.png` | Body | The weight trend and the measurements |
| 6 | `06_ai_provider.png` | Settings › AI Provider › API Key | The provider list and the top of the empty key field (scrolled further, the field's footer names the provider's key page) |
| 7 | `07_dark_today.png` | Today in dark mode | As shot 1 |

Never in a shot: Watch Camera Roll, Photo Coverage, Meta glasses rows,
anything that names the GitHub APK, a real key or address, a provider's
logo, or accuracy or user-count claims.

After capture, the owner uploads them under **Grow users › Store presence
› Main store listing** (and the zh-CN translation) with the graphics from
`app/android/store/graphics/`, in file order (01 first).
