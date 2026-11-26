# README slides: source

The pictures in `docs/readme/slides/` (English), `docs/readme/zh/slides/`
(Chinese) and `docs/readme/social-preview.png` are rendered from this folder.
Nothing here is loaded from the internet: the phone frames, icons and
diagrams are drawn in CSS and SVG, the type is the Mac's own SF Pro and
PingFang SC, and the only photos are the five Unsplash photos in
`../photos/` (credits in `../CREDITS.md`).

| File | What it is |
|---|---|
| `deck.json` | The 13 slides. Each slide holds its layout and positions, plus an `en` and a `zh` block with that language's text and screenshots. |
| `social.json` | The 1280 × 640 social preview card (GitHub › Settings › Social preview). |
| `slides.css` | The visual system: colours, type, the CSS phone frame, photo cards, zoom cards, diagrams. |
| `render.py` | The renderer. Its docstring lists every field the JSON files accept. |
| `html/en/`, `html/zh/` | The HTML pages `render.py` generated, kept for reference. They link the screenshots with relative paths. |
| `seed_demo_data.py` | Fills a simulator's Chopstats install with the demo data the 1.6.0 screenshots show (see Screenshots for the data the 1.8.0 ones show). |
| `screens/` | The screenshots (git-ignored, see below). |

## Re-render

Needs Python 3 with Pillow, and Google Chrome in `/Applications`.

```sh
cd docs/readme/src
python3 render.py deck.json --lang en --out ../slides
python3 render.py deck.json --lang zh --out ../zh/slides
python3 render.py social.json --lang en --out .. --size 1280x640 --max-kb 1000
```

Add `--only 06-usual,07-restaurant` to render some slides, and
`--sheet /tmp/sheet.jpg` to get a contact sheet. Chrome runs headless with
its own throwaway profile in `build/` (git-ignored). In a sandboxed shell,
Chrome needs the sandbox off. A slide stops with "missing image" when a
screenshot it uses is not in `screens/`; with only the 1.8.0 screens below,
render the README's slides with `--only 01-hero,02-how,03-control,10-privacy`.

Each slide is drawn at twice its size and scaled down, then saved as JPEG
quality 90 with full colour resolution. Keep each slide under 600 KB and
all of `docs/readme/` under about 8 MB.

## Screenshots

`render.py` reads screenshots from `screens/en/` and `screens/zh/`
(`--screens` points elsewhere). They are 1320 × 2868 PNGs from an
iPhone 17 Pro Max simulator, in light mode except the `_dark_` ones. They
are not committed; re-shoot them when the App Store look changes.

No phone on a slide shows a status bar. `screen_top` (200 in `deck.json`'s
defaults and in `social.json`) is the first row a phone shows: rows 0–174
of a capture hold the status bar and, in a debug build, Flutter's DEBUG
ribbon, so a debug build is fine. Above that row the phone shows the
capture's own background colour, and every zoom crop and highlight must
start at or below it (`render.py` stops otherwise), as in the App Store set
(`app/ios/store/marketing-src/README.md`).

The 1.8.0 screens of `01-hero`, `02-how`, `03-control`, `10-privacy` and the
social preview were shot on 2026-11-25 (English) and 2026-11-26 (Chinese) on
a simulator of their own, with the build the App Store set was shot with: a
debug simulator build of `main` at 48ed353f (app 1.8.0, build 12).

1. Build and install the App Store version for the simulator (with Xcode
   27.2:
   `FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES flutter build ios --simulator --debug`).
   English with 12-hour time (24-Hour Time off) and region en_US, so a meal
   reads "8:04 AM".
2. Demo data: the App Store set's demo file, made-up meals, weights and
   measurements only. Never shoot real data.
   `python3 scripts/play_screenshots.py demo-file en-US --today <capture day> --out <file>`
   (and `zh-CN`), copied into the simulator's Files › On My iPhone and
   imported on an empty install with Settings › Import Data… › Choose File….
   Shoot on that day: Today shows the meals of the device's date. For
   Chinese, set Settings › Language to 简体中文 (the 1.8.0 shots set the
   app's own language; the device stayed in English).
3. Settings: Gemini with a placeholder key such as `demo-key-not-real`
   typed under Settings › AI Provider › API Key (never a real key; nothing
   is sent with it), and sending to Gemini allowed, so that Stop Sharing
   with Gemini shows. To allow it without sending anything, shut the
   simulator down, add `flutter.settings.ai_consent_routes` = `[gemini]`
   and `flutter.settings.ai_consent_versions` = `[gemini=3]` to the app's
   preferences (`Library/Preferences/dev.calorietracker.calorieTracker.plist`
   in its data container), then boot it again. A plist written while the
   simulator runs does not stick: its preferences daemon keeps its own copy.
4. Open each screen and save it with
   `xcrun simctl io <device> screenshot screens/en/<name>.png` (Chinese:
   `screens/zh/`).

| Name | Screen (1.8.0) |
|---|---|
| `01_today` | Today, top |
| `02_today_meals` | Today scrolled to the meal cards, the Chicken Caesar salad in the middle (English) |
| `05_meal_editor` | Edit meal (English: the Chicken Caesar salad; Chinese: the yogurt bowl) |
| `11_settings_ai` | Settings at the top: AI Provider (Gemini) and Stop Sharing with Gemini |

The slides off the page use names that have no 1.8.0 capture yet:
`04_usual_numbers_card`, `06_history`, `07_day_detail`, `09_log_sheet`,
`10_usual_foods`, `11_settings_watch_camera_roll_glasses`,
`20_dark_today`, `21_dark_restaurant_source_card`, `22_dark_history` and
`23_dark_body` (`12-languages` needs only `01_today`). Their 1.6.0 shots
used `seed_demo_data.py`, which writes its own demo data straight into the
app's database (close the app first):
`python3 seed_demo_data.py en "$(xcrun simctl get_app_container <device> <bundle id> data)" ../../../app/lib/data/db.dart ../photos`

Zoom cards and highlights in `deck.json` are crops in screenshot pixels
(`[x, y, width, height]`). If a re-shot screen moves, update those numbers
and look at every slide again. A crop is easiest to place in a band of rows
that are all background, so it never cuts through text.

## Slides tied to a release

Since 2026-11-13 the README shows only `01-hero`, `02-how`, `03-control` and
`10-privacy`. The items below for `06-usual`, `07-restaurant` and
`09-glasses` matter only if one of those slides goes back on the page.

- `01-hero`, `02-how`, `03-control` and `10-privacy` (in both languages)
  and the social preview (English only) show 1.8.0, the App Store
  version, in its native iOS look: the Today screen's large title and
  meal cards (`01-hero`, `02-how`, the social preview), Edit meal
  (`02-how`, `03-control`) and the Settings rows that `10-privacy` crops,
  shot as described under Screenshots. Neither the tab bar nor the
  **+ Log** button is in frame. The four slides' footer says
  "Version 1.8 · demo data" (`deck.json`'s default `note`, and
  `01-hero`'s own `cnote`); the social preview's says "Demo data", and
  the README's hero caption names 1.8. When an App Store version changes
  the look, all five need new captures, and the four footers and the
  caption the new version.
- iCloud Backup (on by default in 1.8.0, after a notice) copies the log to
  the user's own iCloud Drive, so no slide says the log stays on the
  phone. `01-hero`'s chip says "Developer never sees your log"
  (开发者看不到你的记录). `10-privacy` says "The developer never sees your
  log." (饮食记录，开发者看不到。) and that the photos and text you log
  go to the AI you pick, and a backup of your log to your own iCloud
  Drive (weight, measurements and meals entered by number send nothing
  to the AI, so the slide does not say "what you log"); its diagram has a
  second arrow, "iCloud Backup copies your log, never your API key", to
  your iCloud Drive, "On by default, after a notice." These follow
  docs/PRIVACY.md (*What is sent, and to whom*, *iCloud Backup*): check
  them again when a release changes what leaves the phone.
- The other slides in `deck.json` are off the page and their rendered
  JPEGs still show 1.6.0. Before one comes back it needs 1.8.0 captures
  (its screen names are listed under Screenshots) and, where it sets its
  own `note` (`04-trend`, `09-glasses`, `11-cost`), a footer naming the
  version it shows.
- `06-usual`, `07-restaurant` and `09-glasses` carry the "New in 1.6" pill,
  which goes if one of them comes back: 1.6 is no longer the newest
  version.
- `13-next` ("Coming next") showed what was on `main` but not in the App
  Store build (the native iOS look, iCloud Backup). It has no entry in
  `deck.json`, and its leftover HTML pages are gone from `html/`. The
  first App Store version built from `main` after 1.6.0, 1.8.0 (the iPhone
  skips 1.7.0, 1.7.1 and 1.7.2, and a 1.6.x hotfix has neither feature;
  docs/RELEASING.md § 6.6), shipped both, and they went into the README's
  lists (What else it does, More features), not onto a slide.
- `07-restaurant` shows Chipotle's published numbers as demo data, with
  "not affiliated" in the footer. All calorie, protein, carb and fat values
  match Chipotle's US nutrition PDF (July 2022); the 1.6.0 shots show the
  fajita veggies serving as 2.5 oz where the PDF says 2 oz.
  `seed_demo_data.py` now uses 2 oz.
