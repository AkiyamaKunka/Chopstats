# Captioned App Store screenshots (source)

Seven captioned, slide-style screenshots per language for the App Store page of
Chopstats · 筷拍, built from real **1.8.0** screens (demo data). The rendered
PNGs live in `../screenshots-marketing/en-US/` and `../screenshots-marketing/zh-Hans/`.
The plain screenshots in `../screenshots/` still show 1.6.0 (the live
version's set) and are not for 1.8.0.

This set shows **1.8.0** (the native iOS design; the iPhone skips 1.7.0,
1.7.1 and 1.7.2). It replaces the 1.6 set, which matched only the 1.6 look
(1.6.0, 1.6.1): App Review guideline 2.3 wants screenshots that match the
current version, so a release with a new look needs new captures first.

Nothing of this set is uploaded. On the owner's OK (2026-11-12) the 1.6 set's
en-US frames went to App Store version **1.6.1** through the App Store Connect
API, in two size classes: the 6.9-inch set (1320×2868) and the 6.3-inch
copies (1206×2622). Renaming that draft to 1.8.0 keeps both 1.6-look sets, so
before 1.8.0 is submitted they are deleted and replaced with this folder's
renders: `../screenshots-marketing/en-US/` (6.9-inch) and
`../screenshots-marketing-medium/en-US/` (6.3-inch, made the `--medium` way
from the same PNGs). The listing has only the en-US locale, so the zh-Hans set
is not on the store. Upload only with the owner's OK.

## The frames

The file numbers keep the 1.6 set's ids where a frame carries on, so there is
no `05` (the 1.6 set's `05_restaurant_numbers` is left out: Restaurant
nutrition is off by default, US only and not available with the default
provider). The iCloud Backup frame of the 1.8.0 plan is left out too: it needs
a simulator signed in to iCloud (a dedicated test Apple Account, the owner's
call).

| File | Caption (en-US) | Caption (zh-Hans) | Picture (real 1.8.0 UI) |
|---|---|---|---|
| `01_snap_get_numbers` | Snap a meal. / Get the numbers. — *Your AI estimates calories, protein, carbs and fat.* | 拍下这一餐 / 热量一目了然 — *你选的 AI 估算热量、蛋白质、碳水和脂肪* | Unsplash photo of the yogurt bowl → its meal card on Today (~388 kcal, P/C/F, portions) |
| `02_correct_with_note` | Not quite right? / Say what changed. — *Type a note. Your AI fills in new numbers; you check them, then save.* | 估得不对？/ 一句话改好 — *写一句说明，AI 填好新数值，你核对后再保存* | Edit meal after the note "only half the rice" / 「米饭只吃了一半」: the meal's new total, macro bar and items (rice ~200 g → ~100 g), then the card "Changed from your note — not saved yet" with a ring and the label *Your note* / 「你的说明」 (two slices of one state; see "Frame 02") |
| `03_your_ai_your_key` | Your AI, / your choice — *Nine AI providers, or your own server. No Chopstats account.* | 你的 AI / 你来选 — *9 家 AI 服务任选，或用你自己的服务器；无需注册筷拍账户* | Settings › AI with Gemini picked (ring on the AI Provider row, label *Goes to the AI you pick* / 交给你选的 AI 服务), the AI Provider page's connection type rows, and three check rows: Nine AI services to choose from / Or your own server / Switch any time in Settings (9 家 AI 服务可选 / 也可以用你自己的服务器 / 随时在设置里切换) |
| `04_usual_foods` | Your usual foods, / one tap away — *No photo, no AI, nothing sent.* | 常吃的 / 点一下就记 — *不用拍照，不用 AI，不发送任何内容* | My usual foods, touch point on the first row |
| `06_trend` (dark) | See the trend, / not just today — *30 days of History. Weight and measurements in Body.* | 不只看今天 / 也看清趋势 — *「历史」回看 30 天，「身体」记录体重和围度* | History chart and Body cards, dark mode |
| `07_log_your_way` | Photo, words, / or just numbers — *Describe a meal in any language, or type the numbers with no AI.* | 拍照、描述 / 或者只填数字 — *用任何语言描述一餐，或者手动输入，不用 AI* | The Log a meal sheet over the dimmed Today; rings on "no AI" / "any language" / "no AI" |
| `08_privacy` | We never see / your meals. — *No ads. No tracking. Open source.* | 饮食记录 / 开发者看不到 — *没有广告，不做追踪，代码公开* | Today's day page plus three check rows: No Chopstats account / Nothing is sent until you allow it / Backups stay in your own cloud drive (see "Privacy frame") |

`frames.json` holds every caption, crop, ring, touch point and label, and a
`notes` line per frame naming the facts and numbers behind it.

## Render

Needs macOS with Google Chrome in `/Applications` and Python 3 with Pillow.
Nothing is downloaded; fonts are the Mac's own (SF Pro, PingFang SC).

```sh
cd app/ios/store/marketing-src
python3 render_store.py                      # both languages, all frames
python3 render_store.py --lang en --only 03  # one frame
python3 render_store.py --medium             # also 1206x2622 copies (see below)
python3 render_store.py --html-only          # just write the HTML pages
```

- Headless Chrome runs with a fresh `--user-data-dir` inside the build folder
  (default: a new folder in `$TMPDIR`; pick one with `--build DIR`). The script
  refuses any path inside the owner's Chrome profile. In a sandboxed agent
  shell, run it with the sandbox off (Chrome needs it).
- Each picture is cropped from `screens/` or `photos/` and resized with Lanczos
  to the exact device pixels it fills; the page renders at device scale 2
  (2640×5736) and is reduced to 1320×2868 with Lanczos. Captures are never edited.
- `--medium` writes copies for both languages; only `en-US` is kept in
  `../screenshots-marketing-medium/` (the listing's one locale).
- Contact sheets for review land in the build folder, not in the repo:
  `sheet_search_300_*.png` (frames 1–3 at search-result size),
  `sheet_trio_375_*.png`, `sheet_all_690_*.png` (product-page size).

### What the script checks (it fails on any of these)

- Every PNG is exactly 1320×2868, mode RGB, no alpha (PIL and `sips -g hasAlpha`),
  sRGB profile embedded, under 8 MB.
- Headline lines fit 1144 px (EN 128 px, never under 112; ZH 132 px, never
  under 124); the sub-line keeps its explicit lines (no extra wrap, at most 2);
  the caption block stays in the top third; the pill stays 60 px from the edge.
- The picture fits between the caption and the bottom margin; labels stay
  inside the side margins; rings and touch points stay inside their crop.
- A banned-word scan of every caption, sub-line, pill, label and check row
  (list below). Allowed exceptions are explicit (`ALLOW` in the script).

## Rules this set follows

Apple (checked 2026-11-11): 1320×2868 portrait, PNG/JPEG, no alpha; 1 to 10
per size and language; screenshots show the app in use and match the current
version (2.3, 2.3.1, 2.3.3); overlays and touch points are fine but must not
hide or misrepresent the UI; no prices or pricing terms (2.3.7); 4+-suitable
imagery (2.3.8); rights to everything shown (2.3.9, Unsplash License); no other
platforms or stores (2.3.10); no third-party logos (5.2.1); no Apple device
art: the app sits in plain rounded "screen cards", no bezels, no Dynamic
Island, no buttons; status bars are cropped out.

Copy: only claims the 1.8.0 build and `docs/PRIVACY.md` back up. Never in
added text: free / no subscription / in-app purchase / any price; best, #1,
first, only (as a ranking), unique; accurate, precise, instant, in seconds;
ratings, reviews, user counts, awards, press; Android, APK, Google Play,
GitHub, any URL; "Data Not Collected", "nothing leaves your phone", offline,
encrypted; Meta or glasses; Apple Health, Watch, widgets, barcode; weight-loss
promises; iPhone, iCloud (the backup is "your own cloud drive" in added text;
the UI inside a capture may name iCloud); "New in …"; any provider or chain
name (they appear only as plain text inside the captured UI). "Snap" means the
phone's own Camera app: the app has no camera of its own, so no viewfinder or
shutter art. "No Chopstats account" is scoped on purpose: a key still needs an
account with the AI company.

Chinese: Simplified only, 「」 around UI names, no mainland-China or VPN text
(the API Key provider list and the first-run card carry it, so neither is
cropped), no line-end commas in headlines.

## Frame 02

The note's answer comes from the AI the user set up, so the capture used a
copy of the QA fake "own server" on 127.0.0.1 (never a real key), set up with
the app's setup link. Its canned answer was reworded like a real model's:
the new amount in the food's name ("Steamed rice (~100 g)") and a plain reason
line, no "QA" text. The editor's footer between the items and the card names
the recipient ("Claude (server)"), so the frame shows two slices of the same
state, without the footer, and frame 03 can show Gemini. Nothing was saved:
Undo, then Discard, so the demo data stays as imported.

## Privacy frame

Both languages show the day log plus three check rows drawn in CSS (No
Chopstats account / Nothing is sent until you allow it / Backups stay in your
own cloud drive; 无需注册筷拍账户 / 未经你同意，不发送任何内容 /
备份存在你自己的云盘里). The headline changed for 1.8.0: with iCloud Backup on
by default, "Your log stays on your phone" (the 1.6 headline) is no longer the
whole truth; "We never see your meals" / 「开发者看不到」 is (the developer
runs no server and receives none of your data; the backup goes to the user's
own iCloud Drive, `docs/PRIVACY.md` "iCloud Backup"). If a consent-dialog
version comes back, crop it to its own edges (`radius` 74 at full width), ring
the paragraph that says nothing is sent until you allow it, and label it "Asks
first" / 「未经同意不发送」 (never "asks before every send": after you allow it,
Watch Camera Roll sends new photos without asking again).

## Next version (re-shoot and re-render)

1. Build the release from its tag for a dedicated **iPhone 17 Pro Max**
   simulator (1320×2868; create your own with `xcrun simctl create`, never
   another agent's or the owner's device). With Xcode 27.2 the simulator
   build needs `FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES`
   (`flutter build ios --simulator --debug`). A simulator build is a debug
   build: Flutter's DEBUG ribbon sits in the status bar's top-right corner
   (rows 0–168 of the capture), so every crop starts below the status bar
   (y ≥ 200), as the rule above says; no capture is edited. Status bar 9:41,
   full bars (`xcrun simctl status_bar … override`); light mode except
   `06_trend`; the device language is set with `simctl spawn … defaults write
   "Apple Global Domain" AppleLanguages` / `AppleLocale` (en_US, zh_CN) and a
   reboot of that simulator. The en captures use 12-hour time (24-Hour Time
   off), as a US iPhone does: in English the app follows the phone's 24-Hour
   Time, so a meal reads "8:04 AM", not "08:04" (the Chinese screens ignore
   that setting). Check with `simctl spawn … defaults read -g
   AppleICUForce24HourTime` (the 1.8.0 maker's new simulator had it on), set
   it with `defaults write -g AppleICUForce24HourTime -bool false` and reboot.
2. Made-up demo data only:
   `python3 scripts/play_screenshots.py demo-file en-US --today <capture day> --out …`
   (and `zh-CN`), copied into the simulator's Files › On My iPhone and imported
   with Settings › Import Data… › Choose File…. Capture on that day: Today,
   History and the day pages follow the device's clock, and "Around this time"
   in My usual foods follows the time of day. English Units: Imperial.
3. Capture these screens into `screens/en/` and `screens/zh/` (git-ignored):
   `01_today`, `05b_meal_note_top` and `05b_meal_note_changes` (Edit meal of
   yesterday's Chicken curry with rice after the note; the top, then scrolled
   to the card), `11_settings_ai` and `15_ai_provider_connection` (Gemini
   picked, a placeholder key typed so the first-run card is gone; nothing is
   sent with it), `10_usual_foods`, `22_dark_history`, `23_dark_body`,
   `09_log_sheet` (Today scrolled so the dimmed card above the sheet shows
   whole), `07_day_detail` (History › Today).
4. Frame 02 needs an AI answer to a note: a copy of the QA fake server as
   "Your own server" through the setup link (see "Frame 02"). The simulator
   tool cannot type Chinese; an XCUITest `typeText` can (it typed
   米饭只吃了一半 here).
5. Re-measure every crop, ring and touch point in `frames.json` (source
   pixels). Crops end in empty background, never through text; a quick way is
   to list rows whose pixels all equal the screen background, then pick y
   values inside those bands. Rings get their box from the ink of the words.
6. Run `render_store.py` and `render_store.py --medium`, read every PNG and the
   contact sheets, and re-check every number a viewer can read (kcal, macros,
   servings, averages, weights) against the demo data.
7. Keep the captions unless a feature changed; re-check them against that
   release's description and `docs/PRIVACY.md`.

## Size classes

The 6.9-inch set (1320×2868) is the one built here. Apple's specification page,
as read for the 1.8.0 listing on 2026-11-25, lists at least one screenshot for
the 6.3-inch "medium Dynamic Island" class (1206×2622) as required and the
6.9-inch class as optional, while `docs/RELEASING.md` said the reverse on
2026-10-25. Version 1.6.0 went through review with a 6.3-inch set only, and
the 1.6.1 draft carries both classes, so 1.8.0 carries both too: `--medium`
writes 1206×2622 copies (same aspect within 0.1 %) to
`../screenshots-marketing-medium/`.

## Credits

`photos/yogurt-bowl.jpg`: Natalie Behn on Unsplash (Unsplash License), see
`photos/CREDITS.md`. The meal pictures inside the captures are the demo file's
thumbnails of the README's Unsplash photos (`../screenshots-marketing/CREDITS.md`).
All app data on screen is made-up demo data.
