#!/usr/bin/env python3
"""Recapture the Google Play phone screenshots (app/android/store/screenshots/).

Does what app/android/store/screenshots/SHOTS.md asks for, on an Android
emulator, from the release build of the Play variant:

    cd app && flutter build apk --release --dart-define=CHOPSTATS_CHANNEL=play && cd ..
    python3 scripts/play_screenshots.py avd       # create + boot the AVD
    python3 scripts/play_screenshots.py shots     # en-US 01-07, zh-CN the same but 06
    python3 scripts/play_screenshots.py stop      # stop the emulator (the AVD stays)

    python3 scripts/play_screenshots.py demo-file en-US --out demo.json   # the import file only
    python3 scripts/play_screenshots.py shots --lang zh-CN --only 01,04   # a subset

`avd` creates the AVD `play_shots` (device profile pixel_2: 1080 x 1920,
420 dpi, 9:16) on the system image system-images;android-35;google_apis;
arm64-v8a, which must already be installed (nothing is downloaded), and
boots it headless on port 5562 (adb serial emulator-5562).

`shots` first checks that the APK is a release build of the Play variant
(not debuggable, no READ_MEDIA_IMAGES). Then, for each language:
animations off, gesture navigation, light mode, default font and display
size, system language = the shot's language (adb root, persist.sys.locale
and a reboot; the image is userdebug), a clean status bar (SystemUI demo
mode: 20:45, full Wi-Fi and battery, no notification icons), and the
clock set to Friday 2026-11-20, 20:30 with automatic time off (DEMO_NOW),
so every recapture shows the same days and numbers. Then a FRESH install
of the APK, notifications denied for it so nothing pops up over it, and
the demo import file pushed to the emulator's Download folder and
imported the way a user would: Settings > Import Data... > Choose File... >
Android's file picker. Then the shots, by tapping through the app with
uiautomator, captured with `adb exec-out screencap -p`, flattened to RGB
and checked with `scripts/play_graphics.py --check-shots`. Shot 07
switches the system to dark mode and back. zh-CN has no 06 (see SHOTS).

The demo data (`demo-file`) is a full export in the app's own format
(MealsDao.exportJson / BackupFileWriter.writeFull, kind "full"): 30 days of
plausible meals, today's four as photo meals with the app's own kind of
thumbnail (160 px long side, JPEG quality 70) made from the README demo
photos in docs/readme/photos/ (Unsplash License, docs/readme/CREDITS.md),
the other days as described meals, and a weight and girth trend. Every
item's numbers are consistent with its macros (4/4/9 kcal per gram) and
every total is the sum of its items. No key, no server address, no real
meal. Dates are relative to the emulator's date, which `shots` sets to
DEMO_NOW (`--today` for demo-file, by default the same date).

Needs Python 3 with Pillow, and the Android SDK at $ANDROID_HOME (or
$ANDROID_SDK_ROOT; default ~/Library/Android/sdk on macOS, ~/Android/Sdk
elsewhere). Temporary files go to $TMPDIR/play-screenshots.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import io
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PHOTOS = ROOT / "docs" / "readme" / "photos"
SHOTS_DIR = ROOT / "app" / "android" / "store" / "screenshots"
DEFAULT_APK = ROOT / "app" / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
PLAY_GRAPHICS = ROOT / "scripts" / "play_graphics.py"

AVD = "play_shots"
DEVICE_PROFILE = "pixel_2"
SYSTEM_IMAGE = "system-images;android-35;google_apis;arm64-v8a"
PORT = 5562
SERIAL = f"emulator-{PORT}"
PACKAGE = "dev.calorietracker.calorie_tracker"
ACTIVITY = f"{PACKAGE}/.MainActivity"
LANGS = ("en-US", "zh-CN")
STATUS_CLOCK = "2045"  # the demo-mode status bar clock, hhmm
# What the emulator's clock is set to before each language's capture, so
# every recapture shows the committed shots' dates and numbers. A Friday:
# the demo history's weekend days take extra random draws, so the weekday
# decides every earlier day's meals (another Friday gives the same numbers
# on other dates).
DEMO_NOW = dt.datetime(2026, 11, 20, 20, 30)

TMP = Path(tempfile.gettempdir()) / "play-screenshots"


# ---------------------------------------------------------------- demo data
#
# One item: (English name, Chinese name, kcal, protein g, carbs g, fat g).
# Names carry the portion the AI assumed, as the photo prompt asks
# (shared/prompts/food_detection_prompt.txt); the Chinese ones are what the
# reply-language directive makes the model write.

Item = tuple[str, str, int, int, int, int]

TODAY_PHOTO_MEALS = [
    # (photo, clock, description en, description zh, items, confidence note en, zh,
    #  restaurant_context)
    ("yogurt-bowl.jpg", (8, 4),
     "Greek yogurt with blackberries and granola",
     "黑莓格兰诺拉酸奶碗",
     [("Plain Greek yogurt (~200 g)", "原味希腊酸奶（约200克）", 146, 20, 8, 4),
      ("Granola with nuts and seeds (~45 g)", "坚果格兰诺拉麦片（约45克）", 212, 5, 25, 10),
      ("Blackberries (~70 g)", "黑莓（约70克）", 30, 1, 7, 0)],
     "Calibrated against the spoon next to the bowl; standard bowl portion.",
     "以碗边的勺子为参照；按一碗的常规分量估算。", "home"),
    ("chicken-salad.jpg", (12, 38),
     "Chicken Caesar salad with soft-boiled egg",
     "鸡肉凯撒沙拉配溏心蛋",
     [("Grilled chicken breast (~130 g)", "烤鸡胸肉（约130克）", 215, 40, 0, 5),
      ("Soft-boiled egg (1 large)", "溏心蛋（1个）", 72, 6, 0, 5),
      ("Caesar salad, croutons, parmesan (~170 g)", "凯撒沙拉配面包丁和帕玛森（约170克）", 300, 9, 15, 23)],
     "Calibrated against the dinner plate behind; dressing assumed mixed in.",
     "以后面的餐盘为参照；酱汁按已拌入估算。", "restaurant"),
    ("iced-latte.jpg", (15, 22),
     "Iced latte",
     "冰拿铁",
     [("Iced latte, 2% milk (~350 mL)", "冰拿铁，低脂牛奶（约350毫升）", 130, 8, 12, 5)],
     "No scale reference; a standard 12 oz glass assumed.",
     "没有参照物；按标准12盎司杯估算。", "restaurant"),
    ("burrito-bowl.jpg", (19, 12),
     "Chicken burrito bowl",
     "墨西哥鸡肉饭碗",
     [("Chili-rubbed chicken thigh (~120 g)", "香料烤鸡腿肉（约120克）", 215, 30, 0, 10),
      ("White rice (~150 g)", "白米饭（约150克）", 195, 4, 42, 0),
      ("Black beans (~90 g)", "黑豆（约90克）", 119, 8, 21, 0),
      ("Charred corn (~70 g)", "烤玉米粒（约70克）", 67, 2, 15, 1),
      ("Sautéed bell peppers (~80 g)", "炒彩椒（约80克）", 45, 1, 6, 2),
      ("Chipotle mayo (~30 g)", "烟熏辣椒蛋黄酱（约30克）", 150, 0, 1, 16)],
     "Calibrated against the fork beside the bowl; mayo from the side dish.",
     "以碗边的叉子为参照；蛋黄酱按旁边小碟估算。", "home"),
]

# The other days: described meals (Log > Describe a meal).
BREAKFASTS: list[tuple[str, str, list[Item]]] = [
    ("Greek yogurt with blackberries and granola", "黑莓格兰诺拉酸奶碗",
     [("Plain Greek yogurt (~200 g)", "原味希腊酸奶（约200克）", 146, 20, 8, 4),
      ("Granola with nuts and seeds (~45 g)", "坚果格兰诺拉麦片（约45克）", 212, 5, 25, 10),
      ("Blackberries (~70 g)", "黑莓（约70克）", 30, 1, 7, 0)]),
    ("Oatmeal with banana and peanut butter", "香蕉花生酱燕麦粥",
     [("Oatmeal made with milk (~250 g)", "牛奶燕麦粥（约250克）", 290, 14, 43, 7),
      ("Banana (1 medium)", "香蕉（1根）", 105, 1, 27, 0),
      ("Peanut butter (~16 g)", "花生酱（约16克）", 95, 4, 3, 8)]),
    ("Scrambled eggs on whole-grain toast", "全麦吐司配炒蛋",
     [("Scrambled eggs (2 large)", "炒蛋（2个鸡蛋）", 182, 12, 2, 14),
      ("Whole-grain toast (2 slices)", "全麦吐司（2片）", 176, 9, 29, 3),
      ("Coffee with milk (~250 mL)", "咖啡加牛奶（约250毫升）", 30, 2, 3, 1)]),
    ("Avocado toast with a fried egg", "牛油果吐司配煎蛋",
     [("Sourdough toast (1 slice)", "酸面包吐司（1片）", 160, 6, 30, 1),
      ("Avocado (~70 g)", "牛油果（约70克）", 112, 1, 6, 10),
      ("Fried egg (1 large)", "煎蛋（1个）", 90, 6, 0, 7)]),
    ("Steamed pork buns with soy milk", "猪肉包子配豆浆",
     [("Steamed pork buns (2)", "猪肉包子（2个）", 430, 16, 52, 17),
      ("Unsweetened soy milk (~300 mL)", "无糖豆浆（约300毫升）", 100, 9, 4, 5)]),
]
LUNCHES: list[tuple[str, str, list[Item]]] = [
    ("Chicken Caesar salad", "鸡肉凯撒沙拉",
     [("Grilled chicken breast (~130 g)", "烤鸡胸肉（约130克）", 215, 40, 0, 5),
      ("Caesar salad, croutons, parmesan (~170 g)", "凯撒沙拉配面包丁和帕玛森（约170克）", 300, 9, 15, 23)]),
    ("Turkey and cheese sandwich with an apple", "火鸡芝士三明治和一个苹果",
     [("Turkey and cheese sandwich (~220 g)", "火鸡芝士三明治（约220克）", 450, 32, 42, 16),
      ("Apple (1 medium)", "苹果（1个）", 95, 0, 25, 0)]),
    ("Beef pho", "越南牛肉河粉",
     [("Beef pho with rice noodles (~650 g)", "牛肉河粉（约650克）", 520, 32, 65, 12),
      ("Bean sprouts and herbs (~40 g)", "豆芽和香草（约40克）", 10, 1, 2, 0)]),
    ("Salmon poke bowl", "三文鱼波奇饭",
     [("Raw salmon (~100 g)", "三文鱼（约100克）", 208, 20, 0, 13),
      ("Sushi rice (~180 g)", "寿司饭（约180克）", 250, 4, 56, 0),
      ("Edamame (~50 g)", "毛豆（约50克）", 60, 6, 4, 3),
      ("Avocado (~40 g)", "牛油果（约40克）", 64, 1, 3, 6),
      ("Soy-sesame dressing (~15 g)", "酱油芝麻汁（约15克）", 40, 1, 3, 3)]),
    ("Tomato and egg stir-fry with rice", "番茄炒蛋盖饭",
     [("Tomato and egg stir-fry (~220 g)", "番茄炒蛋（约220克）", 260, 13, 12, 18),
      ("Steamed rice (~180 g)", "米饭（约180克）", 234, 4, 51, 0)]),
    ("Pan-fried pork dumplings", "猪肉煎饺",
     [("Pan-fried pork dumplings (10)", "猪肉煎饺（10个）", 550, 22, 55, 26),
      ("Shredded cabbage (~60 g)", "卷心菜丝（约60克）", 15, 1, 3, 0)]),
    ("Chicken shawarma wrap", "鸡肉沙威玛卷饼",
     [("Chicken shawarma wrap (~300 g)", "鸡肉沙威玛卷饼（约300克）", 610, 38, 55, 25)]),
]
DINNERS: list[tuple[str, str, list[Item]]] = [
    ("Grilled salmon with quinoa and roasted vegetables", "烤三文鱼配藜麦和烤蔬菜",
     [("Grilled salmon fillet (~150 g)", "烤三文鱼（约150克）", 310, 33, 0, 19),
      ("Quinoa (~150 g)", "藜麦（约150克）", 180, 7, 32, 3),
      ("Roasted broccoli and carrots (~150 g)", "烤西兰花和胡萝卜（约150克）", 110, 4, 14, 5)]),
    ("Spaghetti bolognese", "意式肉酱面",
     [("Spaghetti (~200 g cooked)", "意大利面（约200克）", 316, 12, 62, 2),
      ("Bolognese sauce (~200 g)", "肉酱（约200克）", 300, 18, 12, 20),
      ("Grated parmesan (~10 g)", "帕玛森芝士碎（约10克）", 40, 4, 0, 3)]),
    ("Beef and broccoli stir-fry with rice", "西兰花炒牛肉配米饭",
     [("Beef and broccoli stir-fry (~250 g)", "西兰花炒牛肉（约250克）", 380, 30, 14, 22),
      ("Steamed rice (~200 g)", "米饭（约200克）", 260, 5, 57, 0)]),
    ("Mapo tofu with rice", "麻婆豆腐配米饭",
     [("Mapo tofu (~250 g)", "麻婆豆腐（约250克）", 330, 18, 10, 24),
      ("Steamed rice (~200 g)", "米饭（约200克）", 260, 5, 57, 0)]),
    ("Cheeseburger with a side salad", "芝士汉堡配蔬菜沙拉",
     [("Cheeseburger (~220 g)", "芝士汉堡（约220克）", 550, 30, 35, 31),
      ("Side salad with vinaigrette (~100 g)", "油醋汁蔬菜沙拉（约100克）", 80, 1, 5, 6)]),
    ("Chicken curry with rice", "咖喱鸡肉饭",
     [("Chicken curry (~250 g)", "咖喱鸡（约250克）", 380, 28, 14, 23),
      ("Steamed rice (~200 g)", "米饭（约200克）", 260, 5, 57, 0)]),
    ("Roast chicken with potatoes and green beans", "烤鸡配土豆和四季豆",
     [("Roast chicken leg (~200 g with bone)", "烤鸡腿（约200克，带骨）", 330, 34, 0, 21),
      ("Roasted potatoes (~180 g)", "烤土豆（约180克）", 230, 4, 36, 8),
      ("Green beans (~100 g)", "四季豆（约100克）", 45, 2, 7, 1)]),
]
SNACKS: list[tuple[str, str, list[Item]]] = [
    ("Iced latte", "冰拿铁",
     [("Iced latte, 2% milk (~350 mL)", "冰拿铁，低脂牛奶（约350毫升）", 130, 8, 12, 5)]),
    ("Apple and almonds", "苹果和杏仁",
     [("Apple (1 medium)", "苹果（1个）", 95, 0, 25, 0),
      ("Almonds (~20 g)", "杏仁（约20克）", 116, 4, 4, 10)]),
    ("Protein bar", "蛋白棒",
     [("Protein bar (~60 g)", "蛋白棒（约60克）", 220, 20, 23, 6)]),
    ("Banana", "香蕉",
     [("Banana (1 medium)", "香蕉（1根）", 105, 1, 27, 0)]),
    ("Hummus with carrot sticks", "鹰嘴豆泥配胡萝卜条",
     [("Hummus (~60 g)", "鹰嘴豆泥（约60克）", 100, 5, 9, 6),
      ("Carrot sticks (~100 g)", "胡萝卜条（约100克）", 41, 1, 10, 0)]),
    ("Dark chocolate", "黑巧克力",
     [("Dark chocolate, 70% (~20 g)", "70%黑巧克力（约20克）", 120, 2, 9, 9)]),
]
WEEKEND_TREATS: list[tuple[str, str, list[Item]]] = [
    ("Butter croissant", "黄油可颂",
     [("Butter croissant (1)", "黄油可颂（1个）", 232, 5, 26, 12)]),
    ("Vanilla ice cream", "香草冰淇淋",
     [("Vanilla ice cream (~100 g)", "香草冰淇淋（约100克）", 211, 4, 24, 11)]),
]


def _check_item(item: Item) -> None:
    """kcal must agree with 4/4/9 kcal per gram of protein/carbs/fat
    (within 12 % or 15 kcal: fibre and rounding)."""
    name, _, kcal, p, c, f = item
    atwater = 4 * p + 4 * c + 9 * f
    if abs(atwater - kcal) > max(15, 0.12 * kcal):
        raise SystemExit(f"demo item {name!r}: {kcal} kcal but macros say {atwater}")


def _analysis(lang: str, desc: tuple[str, str], items: list[Item],
              photo_fields: dict | None = None) -> dict:
    zh = lang == "zh-CN"
    for it in items:
        _check_item(it)
    food = []
    for en, cn, kcal, p, c, f in items:
        row = {"name": cn if zh else en, "estimated_calories": kcal,
               "protein_g": p, "carbs_g": c, "fat_g": f}
        if photo_fields is not None:
            row.update({"brand": "", "qty": 1, "unit": ""})
        food.append(row)
    out = {
        "is_food": True,
        "food_items": food,
        "total_calories": sum(i[2] for i in items),
        "total_protein_g": sum(i[3] for i in items),
        "total_carbs_g": sum(i[4] for i in items),
        "total_fat_g": sum(i[5] for i in items),
        "meal_description": desc[1] if zh else desc[0],
    }
    if photo_fields is not None:
        out.update(photo_fields)
    else:
        out["confidence_note"] = ("按描述和常规分量估算。" if zh
                                  else "Estimated from the description with standard portions.")
    return out


def _thumb_jpeg(photo: Path) -> bytes:
    """The app's history thumbnail (services/analyzer/normalize.dart
    makeMealThumb): long side 160 px, never enlarged, JPEG quality 70,
    no EXIF."""
    with Image.open(photo) as im:
        im = im.convert("RGB")
        w, h = im.size
        scale = 160 / max(w, h)
        if scale < 1:
            im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))),
                           Image.Resampling.BOX)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=70)
    data = buf.getvalue()
    if len(data) > 64 * 1024 or data[:2] != b"\xff\xd8":
        raise SystemExit(f"thumbnail of {photo.name} is not a small JPEG")
    return data


def _iso_local(t: dt.datetime) -> str:
    """Dart's DateTime.toIso8601String() for a local time, milliseconds."""
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}"


def _clock(t: dt.datetime) -> str:
    """meals.time, core/coerce.dart formatClock: 'hh:mm AM'."""
    h = t.hour % 12 or 12
    return f"{h:02d}:{t.minute:02d} {'AM' if t.hour < 12 else 'PM'}"


def _history_day(rng: random.Random, day: dt.date, prev: dict[str, int]) -> list:
    """(slot, (hour, minute), meal) for one earlier day; the same meal never
    two days running in a slot."""
    def pick(slot: str, pool: list) -> tuple:
        choices = [i for i in range(len(pool)) if i != prev.get(slot)]
        i = rng.choice(choices)
        prev[slot] = i
        return pool[i]

    weekend = day.weekday() >= 5
    plan = [("breakfast", (rng.randint(7, 8) + (1 if weekend else 0), rng.randint(0, 55)),
             pick("breakfast", BREAKFASTS)),
            ("lunch", (12, rng.randint(5, 55)), pick("lunch", LUNCHES))]
    roll = rng.random()
    snacks = 0 if roll < 0.12 else 2 if roll > 0.6 else 1
    for n in range(snacks):
        plan.append(("snack", (15 + n * 2, rng.randint(0, 50)),
                     pick(f"snack{n}", SNACKS)))
    plan.append(("dinner", (rng.randint(18, 19), rng.randint(0, 50)),
                 pick("dinner", DINNERS)))
    if weekend and rng.random() < 0.8:
        treat = rng.choice(WEEKEND_TREATS)
        plan.append(("treat", (10, rng.randint(0, 40)) if treat is WEEKEND_TREATS[0]
                     else (20, rng.randint(15, 45)), treat))
    return plan


def build_demo_export(lang: str, today: dt.date, now: dt.datetime | None = None) -> dict:
    """The demo data as a full export (kind 'full'), for [today]."""
    if lang not in LANGS:
        raise SystemExit(f"language must be one of {', '.join(LANGS)}")
    now = now or dt.datetime.combine(today, DEMO_NOW.time())
    rng = random.Random(20261120)  # seeded: the same date makes the same file
    meals: list[dict] = []
    ledger: list[dict] = []
    thumbs: list[dict] = []

    def add_meal(day: dt.date, hm: tuple[int, int], analysis: dict, source: str,
                 logged_after_s: int, image_hash: str = "") -> None:
        at = dt.datetime.combine(day, dt.time(*hm))
        logged = at + dt.timedelta(seconds=logged_after_s,
                                   milliseconds=rng.randint(0, 999))
        meals.append({
            "id": len(meals) + 1, "chat_id": 1, "date": day.isoformat(),
            "time": _clock(at), "timestamp": _iso_local(logged), "source": source,
            "image_hash": image_hash, "file_id": "",
            "analysis": json.dumps(analysis, ensure_ascii=False, separators=(",", ":")),
            "corrected": 0,
        })
        if image_hash:
            stamp = _iso_local(logged)
            ledger.append({"chat_id": 1, "image_hash": image_hash, "first_seen_at": stamp,
                           "last_seen_at": stamp, "source": source, "status": "saved",
                           "meal_id": len(meals)})

    prev: dict[str, int] = {}
    for back in range(29, 0, -1):
        day = today - dt.timedelta(days=back)
        for _slot, hm, (en, cn, items) in _history_day(rng, day, prev):
            add_meal(day, hm, _analysis(lang, (en, cn), items), "manual_text",
                     rng.randint(300, 2400))

    zh = lang == "zh-CN"
    for photo, hm, en, cn, items, note_en, note_cn, context in TODAY_PHOTO_MEALS:
        path = PHOTOS / photo
        digest = hashlib.md5(path.read_bytes()).hexdigest()
        fields = {
            "confidence_note": note_cn if zh else note_en,
            "estimate_confidence": "medium",
            "restaurant_context": context,
            "portion_state": "whole",
            "order_merchant": "",
            "capture": {"has_gps": False},
        }
        add_meal(today, hm, _analysis(lang, (en, cn), items, fields), "app_photo",
                 rng.randint(25, 70), image_hash=digest)
        thumbs.append({"chat_id": 1, "image_hash": digest,
                       "jpeg_b64": base64.b64encode(_thumb_jpeg(path)).decode("ascii")})

    # Weight: about five mornings a week, ~0.4 kg a week down, day-to-day noise.
    weights: list[dict] = []
    wrng = random.Random(7)
    for back in range(29, -1, -1):
        if back not in (0, 1) and wrng.random() < 0.3:
            continue
        day = today - dt.timedelta(days=back)
        kg = 74.8 - (29 - back) * (1.7 / 29) + wrng.uniform(-0.25, 0.25)
        logged = dt.datetime.combine(day, dt.time(7, wrng.randint(0, 40), wrng.randint(0, 59)))
        weights.append({"id": len(weights) + 1, "chat_id": 1, "date": day.isoformat(),
                        "weight_kg": round(kg, 1), "source": "manual", "note": "",
                        "logged_at": _iso_local(logged)})
    # Girth: once a week.
    girth = []
    for n, back in enumerate((28, 21, 14, 7, 0)):
        day = today - dt.timedelta(days=back)
        logged = dt.datetime.combine(day, dt.time(7, 45 + n))
        girth.append({"id": n + 1, "chat_id": 1, "date": day.isoformat(),
                      "waist_cm": [86.0, 85.6, 85.3, 84.9, 84.6][n],
                      "chest_cm": [98.5, 98.4, 98.2, 98.0, 97.9][n],
                      "hip_cm": [100.0, 99.8, 99.5, 99.3, 99.0][n],
                      "note": "", "logged_at": _iso_local(logged)})

    first = meals[0]["date"]
    month = today.strftime("%Y-%m")
    header = {
        "kind": "full",
        "install_id": hashlib.md5(b"chopstats play screenshots demo").hexdigest(),
        "seq": 0, "platform": "android", "app_version": app_version(),
        "meals": len(meals), "thumbs": len(thumbs), "thumbs_skipped": 0,
        "first_date": first, "last_date": today.isoformat(),
        "months": {month: len(thumbs)},
    }
    utc = now.astimezone(dt.timezone.utc) if now.tzinfo else now
    return {
        "format": "calorie_tracker_export",
        "version": 2,
        "exported_at": utc.strftime("%Y-%m-%dT%H:%M:%S.") + f"{utc.microsecond // 1000:03d}Z",
        "backup": header,
        "tables": {
            "meals": meals,
            "photo_ingestions": ledger,
            "body_weight": weights,
            "body_measurements": girth,
            "workouts": [],
            "activities": [],
            "fitness_profile": [],
            "meal_thumbs": thumbs,
        },
    }


def app_version() -> str:
    """x.y.z of pubspec's version (what BackupFileWriter writes)."""
    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)", (ROOT / "app" / "pubspec.yaml").read_text(),
                  re.M)
    return m.group(1) if m else "0.0.0"


def demo_summary(export: dict) -> str:
    meals = export["tables"]["meals"]
    per_day: dict[str, int] = {}
    for m in meals:
        per_day[m["date"]] = per_day.get(m["date"], 0) + json.loads(m["analysis"])["total_calories"]
    days = sorted(per_day)
    vals = [per_day[d] for d in days]
    w = export["tables"]["body_weight"]
    return (f"{len(meals)} meals over {len(days)} days ({days[0]} to {days[-1]}), "
            f"daily kcal {min(vals)}-{max(vals)} (mean {sum(vals) // len(vals)}), "
            f"today {vals[-1]} kcal; {len(w)} weigh-ins {w[0]['weight_kg']} -> "
            f"{w[-1]['weight_kg']} kg; {len(export['tables']['meal_thumbs'])} pictures")


def write_demo_file(lang: str, today: dt.date, out: Path) -> Path:
    export = build_demo_export(lang, today)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Compact, like the app's own writer (jsonEncode).
    out.write_text(json.dumps(export, ensure_ascii=False, separators=(",", ":")),
                   encoding="utf-8")
    print(f"{out}: {demo_summary(export)}")
    return out


# ---------------------------------------------------------------- the device

def sdk_root() -> Path:
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(var):
            return Path(os.environ[var]).expanduser()
    mac = Path.home() / "Library" / "Android" / "sdk"
    return mac if mac.exists() else Path.home() / "Android" / "Sdk"


def tool(*parts: str) -> str:
    path = sdk_root().joinpath(*parts)
    if not path.exists():
        raise SystemExit(f"{path} not found (set ANDROID_HOME)")
    return str(path)


def run(cmd: list[str], check: bool = True, capture: bool = True, timeout: int = 120,
        input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, text=True, timeout=timeout, input=input_text,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


class Device:
    def __init__(self, serial: str = SERIAL):
        self.serial = serial
        self.adb_path = tool("platform-tools", "adb")

    def adb(self, *args: str, check: bool = True, timeout: int = 120) -> str:
        return run([self.adb_path, "-s", self.serial, *args], check=check,
                   timeout=timeout).stdout or ""

    def sh(self, command: str, check: bool = True) -> str:
        return self.adb("shell", command, check=check)

    def wait_boot(self, timeout: int = 300) -> None:
        self.adb("wait-for-device", timeout=timeout)
        end = time.time() + timeout
        while time.time() < end:
            if self.sh("getprop sys.boot_completed", check=False).strip() == "1":
                time.sleep(3)
                return
            time.sleep(2)
        raise SystemExit("the emulator did not finish booting")

    # -- system settings
    def prepare(self, lang: str) -> None:
        """Animations off, gesture navigation, light mode, default font and
        display size, the system language, a clean status bar."""
        self.set_locale(lang)
        for key in ("window_animation_scale", "transition_animation_scale",
                    "animator_duration_scale"):
            self.sh(f"settings put global {key} 0")
        self.sh("cmd overlay enable-exclusive --category "
                "com.android.internal.systemui.navbar.gestural", check=False)
        self.sh("cmd uimode night no")
        self.sh("settings put system font_scale 1.0")
        self.sh("wm density reset")
        self.sh("wm size reset")
        self.sh("settings put system screen_off_timeout 1800000")
        self.sh("svc power stayon true")
        self.demo_mode()

    def root(self) -> None:
        """adbd as root (the image is userdebug); a no-op when it is."""
        self.adb("root")
        time.sleep(2)
        self.adb("wait-for-device")

    def set_locale(self, lang: str) -> None:
        if self.sh("getprop persist.sys.locale").strip() == lang:
            return
        self.root()
        self.sh(f"setprop persist.sys.locale {lang}")
        # The system reads persist.sys.locale as it starts.
        self.adb("reboot", check=False)
        time.sleep(10)
        self.wait_boot()
        got = self.sh("getprop persist.sys.locale").strip()
        if got != lang:
            raise SystemExit(f"system language is {got!r}, not {lang}")

    def pin_clock(self, at: dt.datetime) -> None:
        """Set the system clock to [at], local time, with automatic time
        off so nothing sets it back. A reboot takes the host's time again,
        so this comes after set_locale."""
        self.root()
        self.sh("settings put global auto_time 0")
        self.sh(f"date {at:%m%d%H%M%Y.%S}")  # toybox: MMDDhhmmCCYY.ss
        got = self.sh("date +%Y-%m-%dT%H:%M").strip()
        if not got.startswith(f"{at:%Y-%m-%dT%H:}"):
            raise SystemExit(f"the emulator's clock reads {got!r}, not {at:%Y-%m-%d %H:%M}")

    def demo_mode(self) -> None:
        self.sh("settings put global sysui_demo_allowed 1")
        demo = "am broadcast -a com.android.systemui.demo -e command"
        for args in ("enter",
                     f"clock -e hhmm {STATUS_CLOCK}",
                     "battery -e level 100 -e plugged false",
                     "network -e wifi show -e level 4 -e fully true",
                     "network -e mobile hide",
                     "notifications -e visible false",
                     "status -e bluetooth hide -e volume hide -e alarm hide -e sync hide "
                     "-e tty hide -e eri hide -e mute hide -e speakerphone hide "
                     "-e location hide -e managed_profile hide"):
            self.sh(f"{demo} {args}")

    def night(self, on: bool) -> None:
        self.sh(f"cmd uimode night {'yes' if on else 'no'}")
        time.sleep(2)

    # -- the app
    def fresh_install(self, apk: Path) -> None:
        self.adb("uninstall", PACKAGE, check=False)
        self.adb("install", str(apk), timeout=300)
        # Nothing may pop up over a shot: no notification prompt, no
        # notification.
        self.sh(f"pm revoke {PACKAGE} android.permission.POST_NOTIFICATIONS", check=False)
        self.sh(f"pm set-permission-flags {PACKAGE} android.permission.POST_NOTIFICATIONS "
                "user-set user-fixed", check=False)

    def launch(self) -> None:
        self.sh(f"am start -W -n {ACTIVITY}")
        time.sleep(3)

    # -- uiautomator
    def nodes(self) -> list[dict]:
        for _ in range(5):
            out = self.sh("uiautomator dump /sdcard/window.xml", check=False)
            if "dumped" in out:
                break
            time.sleep(1)
        xml = self.adb("exec-out", "cat", "/sdcard/window.xml")
        root = ET.fromstring(xml[xml.index("<"):])
        found = []
        for n in root.iter("node"):
            b = re.findall(r"\d+", n.get("bounds", ""))
            if len(b) != 4:
                continue
            x1, y1, x2, y2 = map(int, b)
            found.append({"text": n.get("text", ""), "desc": n.get("content-desc", ""),
                          "id": n.get("resource-id", ""), "pkg": n.get("package", ""),
                          "cls": n.get("class", ""), "click": n.get("clickable") == "true",
                          "bounds": (x1, y1, x2, y2)})
        return found

    def find(self, pattern: str, timeout: float = 15, where=None) -> dict:
        """The first node whose text or content-desc matches [pattern]
        (a regex, searched)."""
        rx = re.compile(pattern, re.S)
        end = time.time() + timeout
        while True:
            for n in self.nodes():
                if (rx.search(n["text"]) or rx.search(n["desc"])) and (where is None or where(n)):
                    return n
            if time.time() > end:
                raise SystemExit(f"nothing on screen matches {pattern!r}")
            time.sleep(1)

    def exists(self, pattern: str) -> bool:
        rx = re.compile(pattern, re.S)
        return any(rx.search(n["text"]) or rx.search(n["desc"]) for n in self.nodes())

    def tap(self, node_or_xy, settle: float = 1.5) -> None:
        if isinstance(node_or_xy, dict):
            x1, y1, x2, y2 = node_or_xy["bounds"]
            x, y = (x1 + x2) // 2, (y1 + y2) // 2
        else:
            x, y = node_or_xy
        self.sh(f"input tap {x} {y}")
        time.sleep(settle)

    def swipe(self, x1: int, y1: int, x2: int, y2: int, ms: int = 400, settle: float = 1.2) -> None:
        self.sh(f"input swipe {x1} {y1} {x2} {y2} {ms}")
        time.sleep(settle)

    def drag(self, x: int, y1: int, y2: int, settle: float = 1.2) -> None:
        """Scroll by exactly y1 - y2 px: the first move only crosses the
        touch slop (Android's 8 dp = 21 px here; Flutter starts the drag
        where the slop was crossed), and the finger is held still before
        it lifts, so nothing flings."""
        sign = -1 if y2 < y1 else 1
        start = y1 + sign * 22
        end = start + (y2 - y1)
        steps = 10
        cmds = [f"input motionevent DOWN {x} {y1}", f"input motionevent MOVE {x} {start}"]
        for i in range(1, steps + 1):
            cmds.append(f"input motionevent MOVE {x} {start + (end - start) * i // steps}")
        cmds += ["sleep 0.6", f"input motionevent UP {x} {end}"]
        self.sh("; ".join(cmds))
        time.sleep(settle)

    def white_band(self, bounds: tuple[int, int, int, int], x: int = 70) -> int | None:
        """The middle of the first white (light-mode cell) band inside
        [bounds], looking down column [x]: a row inside a node the
        accessibility tree merged with its section header and footer."""
        raw = subprocess.run([self.adb_path, "-s", self.serial, "exec-out", "screencap", "-p"],
                             check=True, stdout=subprocess.PIPE, timeout=60).stdout
        with Image.open(io.BytesIO(raw)) as im:
            px = im.convert("RGB").load()
            start = None
            for y in range(bounds[1], bounds[3]):
                white = all(v >= 250 for v in px[x, y])
                if white and start is None:
                    start = y
                elif not white and start is not None:
                    if y - start >= 60:
                        return (start + y) // 2
                    start = None
        return None

    def tap_row(self, label: str, settle: float = 2) -> None:
        """Tap the grouped row titled [label], also when the accessibility
        tree merged it into its section's node."""
        node = self.find(rf"(^|\n){re.escape(label)}(\n|$)")
        lines = (node["desc"] or node["text"]).split("\n")
        x1, y1, x2, y2 = node["bounds"]
        y = (y1 + y2) // 2
        if lines[0] != label:
            y = self.white_band(node["bounds"]) or y
        self.tap(((x1 + x2) // 2, y), settle=settle)

    def back(self, settle: float = 1.2) -> None:
        self.sh("input keyevent KEYCODE_BACK")
        time.sleep(settle)

    def screencap(self, out: Path) -> Path:
        raw = subprocess.run([self.adb_path, "-s", self.serial, "exec-out", "screencap", "-p"],
                             check=True, stdout=subprocess.PIPE, timeout=60).stdout
        with Image.open(io.BytesIO(raw)) as im:
            rgba = im.convert("RGBA")
        if rgba.size != (1080, 1920):
            raise SystemExit(f"screen is {rgba.size}, not 1080x1920")
        flat = Image.new("RGB", rgba.size, (255, 255, 255))
        flat.paste(rgba, mask=rgba.getchannel("A"))
        out.parent.mkdir(parents=True, exist_ok=True)
        flat.save(out, optimize=True)
        print(f"  {out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}")
        return out


# ---------------------------------------------------------------- the UI walk

LABELS = {
    "en-US": {"today": "Today", "history": "History", "body": "Body", "settings": "Settings",
              "log": "Log", "import": "Import Data…", "choose": "Choose File…",
              "provider": "AI Provider", "api_key": "API Key", "downloads": "Downloads"},
    "zh-CN": {"today": "今天", "history": "历史", "body": "身体", "settings": "设置",
              "log": "记录", "import": "导入数据…", "choose": "选择文件…",
              "provider": "AI 服务", "api_key": "API Key", "downloads": "下载"},
}


def tab(device: Device, lang: str, name: str) -> None:
    label = LABELS[lang][name]
    # NavigationBar destinations read "<label>\nTab n of 4".
    node = device.find(rf"^{re.escape(label)}(\n|$)",
                       where=lambda n: n["bounds"][1] > 1500)
    device.tap(node, settle=2)


def scroll_to_top(device: Device) -> None:
    for _ in range(3):
        device.swipe(540, 600, 540, 1500, ms=250, settle=0.6)
    time.sleep(1)


def import_demo(device: Device, lang: str, file_name: str) -> None:
    L = LABELS[lang]
    device.launch()
    tab(device, lang, "settings")
    for _ in range(12):
        if device.exists(rf"^{re.escape(L['import'])}"):
            break
        device.swipe(540, 1400, 540, 500, ms=300)
    device.tap(device.find(rf"^{re.escape(L['import'])}"))
    device.tap(device.find(rf"^{re.escape(L['choose'])}"), settle=3)
    # Android's file picker (DocumentsUI): the file in Recent, or Downloads.
    try:
        node = device.find(rf"^{re.escape(file_name)}$", timeout=6)
    except SystemExit:
        device.tap(device.find(r"^(Show roots|显示根目录)$", timeout=6))
        device.tap(device.find(rf"^{re.escape(L['downloads'])}$"), settle=2)
        node = device.find(rf"^{re.escape(file_name)}$")
    device.tap(node, settle=8)  # the import, then its snackbar goes
    # Proof that it landed: today's breakfast on Today.
    tab(device, lang, "today")
    breakfast = TODAY_PHOTO_MEALS[0][3 if lang == "zh-CN" else 2]
    device.find(rf"^{re.escape(breakfast)}", timeout=20)
    print(f"  imported {file_name}")


# How far 01 and 07 scroll Today. The large title collapses into the bar
# after 69 dp, 181.1 px at this size, and the bar shows its small title
# (and its chrome colour) only once the scroll is past that (SliverAppBar:
# shrinkOffset > maxExtent - minExtent), so at least 182 px. Then the
# totals card sits right under the bar and the meal cards get the room.
# The lunch card's item lines must end above the tab bar (its hairline is
# at y=1710) or start below it. Chinese: at 196 px the second line showed
# its top 13 px; at 182 it starts on the hairline, out of sight. English:
# at 196 the egg line ends at y=1706; at 182 the tab bar would cut it.
TODAY_SCROLL = {"en-US": 196, "zh-CN": 182}


def today_framed(device: Device, lang: str) -> None:
    """Today with the large title collapsed into the bar and no line cut
    by the tab bar."""
    tab(device, lang, "today")
    scroll_to_top(device)
    device.drag(540, 1300, 1300 - TODAY_SCROLL[lang])


def shot_today(device: Device, lang: str, out: Path) -> None:
    today_framed(device, lang)
    device.screencap(out)


def shot_editor(device: Device, lang: str, out: Path) -> None:
    tab(device, lang, "today")
    scroll_to_top(device)
    desc = TODAY_PHOTO_MEALS[3][3 if lang == "zh-CN" else 2]
    for _ in range(6):
        if device.exists(rf"^{re.escape(desc)}"):
            break
        device.swipe(540, 1400, 540, 700)
    device.tap(device.find(rf"^{re.escape(desc)}"), settle=2.5)
    device.screencap(out)
    device.back()


def shot_log_sheet(device: Device, lang: str, out: Path) -> None:
    tab(device, lang, "today")
    scroll_to_top(device)
    device.tap(device.find(rf"^{re.escape(LABELS[lang]['log'])}$",
                           where=lambda n: n["bounds"][1] > 1300), settle=2.5)
    device.screencap(out)
    device.back()


def shot_history(device: Device, lang: str, out: Path) -> None:
    """History framed as Today is: 196 px of scroll collapse the large
    title into the bar and lift the chart card to y=195, so the tab bar
    cuts between a day's bar and the next day's text, in both languages:
    six whole days."""
    tab(device, lang, "history")
    scroll_to_top(device)
    device.drag(540, 1300, 1300 - 196)
    device.screencap(out)


def shot_body(device: Device, lang: str, out: Path) -> None:
    tab(device, lang, "body")
    scroll_to_top(device)
    device.screencap(out)


def shot_provider(device: Device, lang: str, out: Path) -> None:
    L = LABELS[lang]
    tab(device, lang, "settings")
    scroll_to_top(device)
    device.tap_row(L["provider"])
    device.tap_row(L["api_key"])
    # Unscrolled: the whole provider list and the top of the (empty) key
    # field. Scrolled further, the key field's footer comes into view
    # with the provider's key-page address; part way, the large title is
    # cut in half.
    device.screencap(out)
    device.back()
    device.back()


def shot_dark_today(device: Device, lang: str, out: Path) -> None:
    device.night(True)
    try:
        today_framed(device, lang)
        time.sleep(1)
        device.screencap(out)
    finally:
        device.night(False)


SHOTS = [
    # (number, name, take, the languages that have it)
    ("01", "today", shot_today, LANGS),
    ("02", "meal_editor", shot_editor, LANGS),
    ("03", "log_sheet", shot_log_sheet, LANGS),
    ("04", "history", shot_history, LANGS),
    ("05", "body", shot_body, LANGS),
    # English only: in Chinese the API Key page notes on every provider row
    # but one whether it needs a VPN or connects directly in China, and its
    # footer sends mainland users to four providers (需要 VPN, 中国直连,
    # 中国大陆请选择…). Not for a listing Play shows outside mainland China.
    ("06", "ai_provider", shot_provider, ("en-US",)),
    ("07", "dark_today", shot_dark_today, LANGS),
]


def device_today(device: Device) -> dt.date:
    return dt.date.fromisoformat(device.sh("date +%Y-%m-%d").strip())


def capture(device: Device, lang: str, apk: Path, only: set[str] | None) -> Path:
    print(f"{lang}:")
    out_dir = SHOTS_DIR / lang
    device.prepare(lang)
    device.pin_clock(DEMO_NOW)  # before the install: nothing dated after "now"
    device.fresh_install(apk)
    today = device_today(device)
    name = f"chopstats-{today.isoformat()}.json"  # the app's own export name
    local = write_demo_file(lang, today, TMP / lang / name)
    device.sh("rm -f /sdcard/Download/chopstats-*.json", check=False)
    device.adb("push", str(local), f"/sdcard/Download/{name}")
    import_demo(device, lang, name)
    for num, slug, take, langs in SHOTS:
        out = out_dir / f"{num}_{slug}.png"
        if lang not in langs:
            out.unlink(missing_ok=True)  # an old capture's copy must not be uploaded
            continue
        if only and num not in only:
            continue
        take(device, lang, out)
        device.demo_mode()  # a SystemUI restart (dark mode) leaves demo mode
    device.sh("rm -f /sdcard/Download/chopstats-*.json", check=False)
    return out_dir


# ---------------------------------------------------------------- commands

def cmd_avd(args) -> None:
    avds = run([tool("emulator", "emulator"), "-list-avds"]).stdout.split()
    if AVD not in avds:
        image = sdk_root().joinpath(*SYSTEM_IMAGE.split(";"))
        if not image.exists():
            raise SystemExit(f"{SYSTEM_IMAGE} is not installed; install it with sdkmanager first")
        avdmanager = tool("cmdline-tools", "latest", "bin", "avdmanager")
        run([avdmanager, "create", "avd", "-n", AVD, "-k", SYSTEM_IMAGE, "-d", DEVICE_PROFILE],
            input_text="no\n")
        print(f"created AVD {AVD} ({DEVICE_PROFILE}, {SYSTEM_IMAGE})")
    device = Device()
    if SERIAL in run([device.adb_path, "devices"]).stdout:
        print(f"{SERIAL} is already running")
    else:
        TMP.mkdir(parents=True, exist_ok=True)
        log = open(TMP / "emulator.log", "w")
        subprocess.Popen([tool("emulator", "emulator"), "-avd", AVD, "-port", str(PORT),
                          "-no-window", "-no-audio", "-no-boot-anim",
                          "-gpu", "swiftshader_indirect", "-no-snapshot"],
                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        print(f"booting {AVD} headless on port {PORT} (log: {TMP / 'emulator.log'})")
    device.wait_boot()
    size = device.sh("wm size").strip()
    print(f"{SERIAL} ready: {size}, density {device.sh('wm density').strip()}")


def cmd_demo_file(args) -> None:
    today = dt.date.fromisoformat(args.today) if args.today else DEMO_NOW.date()
    write_demo_file(args.lang, today, Path(args.out))


def check_apk(apk: Path) -> None:
    """A release build of the Play variant: not debuggable (no DEBUG
    banner), without the photo permissions the GitHub APK asks for."""
    if not apk.exists():
        raise SystemExit(f"{apk} not found; build it: cd app && flutter build apk --release "
                         "--dart-define=CHOPSTATS_CHANNEL=play")
    tools = sorted(sdk_root().joinpath("build-tools").glob("*/aapt2"))
    if not tools:
        raise SystemExit("aapt2 not found under $ANDROID_HOME/build-tools")
    badging = run([str(tools[-1]), "dump", "badging", str(apk)]).stdout
    if "application-debuggable" in badging:
        raise SystemExit(f"{apk.name} is a debuggable build; capture from the release build")
    if "READ_MEDIA_IMAGES" in badging:
        raise SystemExit(f"{apk.name} asks for READ_MEDIA_IMAGES: that is the GitHub APK, "
                         "build with --dart-define=CHOPSTATS_CHANNEL=play")
    m = re.search(r"versionCode='(\d+)' versionName='([^']+)'", badging)
    print(f"{apk.name}: Play variant, release, {m.group(2)} ({m.group(1)})" if m else apk.name)


def cmd_shots(args) -> None:
    apk = Path(args.apk).resolve()
    check_apk(apk)
    device = Device()
    if f"{SERIAL}\tdevice" not in run([device.adb_path, "devices"]).stdout:
        raise SystemExit(f"{SERIAL} is not running; start it with: "
                         "python3 scripts/play_screenshots.py avd")
    device.wait_boot(timeout=60)
    if device.sh("wm size").split()[-1] != "1080x1920":
        raise SystemExit("the emulator's screen is not 1080x1920 (use the play_shots AVD)")
    only = set(args.only.split(",")) if args.only else None
    langs = LANGS if args.lang == "all" else (args.lang,)
    failed = False
    for lang in langs:
        out_dir = capture(device, lang, apk, only)
        result = run([sys.executable, str(PLAY_GRAPHICS), "--check-shots", str(out_dir)],
                     check=False)
        print(result.stdout.rstrip())
        failed |= result.returncode != 0
    if failed:
        raise SystemExit("play_graphics.py --check-shots failed")
    print("Look at every PNG before committing: no key, address, provider logo, "
          "Watch Camera Roll, Photo Coverage or Meta glasses row, and no VPN or "
          "mainland-China note (需要 VPN, 中国直连, 中国大陆请选择…) in view.")


def cmd_stop(args) -> None:
    device = Device()
    device.adb("emu", "kill", check=False)
    print(f"stopped {SERIAL}; the AVD {AVD} stays")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("avd", help=f"create the {AVD} AVD if needed and boot it headless")
    p = sub.add_parser("demo-file", help="write the demo import file")
    p.add_argument("lang", choices=LANGS)
    p.add_argument("--today", help=f"YYYY-MM-DD (default: {DEMO_NOW:%Y-%m-%d}, the date "
                   "`shots` sets the emulator to)")
    p.add_argument("--out", required=True)
    p = sub.add_parser("shots", help="capture the shots on the running emulator")
    p.add_argument("--lang", choices=(*LANGS, "all"), default="all")
    p.add_argument("--apk", default=str(DEFAULT_APK),
                   help="the Play-variant release APK (default: app/build/.../app-release.apk)")
    p.add_argument("--only", help="comma-separated shot numbers, e.g. 01,04")
    sub.add_parser("stop", help="stop the emulator (the AVD stays)")
    args = ap.parse_args(argv)
    {"avd": cmd_avd, "demo-file": cmd_demo_file, "shots": cmd_shots,
     "stop": cmd_stop}[args.cmd](args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
