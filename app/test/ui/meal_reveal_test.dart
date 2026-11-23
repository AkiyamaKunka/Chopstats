/// "Show me that meal" (Android, view-after-share lane): the request a
/// shared photo's View and a tap on a Logged meals card make, the card
/// payload that names the meal, and the one-request channel to the shell
/// (ui/meal_reveal.dart). The shell's side is in view_after_share_test.
library;

import 'package:calorie_tracker/core/contracts.dart'
    show RefusedShareFiles, ShareRefusal;
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/di.dart' show outcomeAnnouncer;
import 'package:calorie_tracker/ui/meal_reveal.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter/foundation.dart' show Listenable;
import 'package:flutter_test/flutter_test.dart';

const _saved = PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged: Ramen — ~600 kcal',
    detail: 'Ramen — ~600 kcal',
    mealName: 'Ramen',
    kcal: '600',
    mealId: 42,
    mealDate: '2026-11-21',
    analysis: {'is_food': true, 'meal_description': 'Ramen'},
    shared: true);

const _leftover = PhotoOutcome(PhotoOutcomeKind.leftoverApplied,
    'Leftovers deducted: Noodles — −300 kcal, now ~300 kcal',
    detail: 'Noodles — −300 kcal, now ~300 kcal',
    mealName: 'Noodles',
    kcal: '300',
    deductedKcal: 300,
    mealId: 7,
    mealDate: '2026-11-21',
    analysis: {'is_food': true, 'meal_description': 'Noodles'},
    shared: true);

PhotoOutcome _notShared(PhotoOutcome o) => PhotoOutcome(o.kind, o.message,
    detail: o.detail,
    mealName: o.mealName,
    kcal: o.kcal,
    deductedKcal: o.deductedKcal,
    mealId: o.mealId,
    mealDate: o.mealDate,
    analysis: o.analysis);

void main() {
  group('the card payload', () {
    test('names the meal and reads back', () {
      expect(const MealReveal(42).payload, 'meal:42');
      expect(MealReveal.fromPayload('meal:42'), const MealReveal(42));
    });

    test('anything else names no meal', () {
      for (final payload in [
        null,
        '',
        'meal:',
        'meal:0',
        'meal:-3',
        'meal:4x',
        'meal: 4',
        'meal:1234567890123456',
        'MEAL:4',
        // The daily summary's own payload.
        'daily:2026-11-21T03:30:00.000Z@2026-11-20',
      ]) {
        expect(MealReveal.fromPayload(payload), isNull, reason: '$payload');
      }
    });
  });

  group('which verdicts name a meal', () {
    test("a shared photo's save and leftover deduction", () {
      expect(revealForShared(_saved), const MealReveal(42));
      expect(revealForShared(_leftover), const MealReveal(7),
          reason: 'the meal its leftovers were deducted from');
    });

    test('not for a photo that was not shared (picked, automatic)', () {
      expect(revealForShared(_notShared(_saved)), isNull);
      expect(revealForShared(_notShared(_leftover)), isNull);
      // A Logged meals card names its meal whoever logged it.
      expect(revealForMeal(_notShared(_saved)), const MealReveal(42));
    });

    test('not for a refusal, a failure, or a save without its id', () {
      for (final o in [
        const PhotoOutcome(PhotoOutcomeKind.skipped, 'No food',
            shared: true),
        const PhotoOutcome(PhotoOutcomeKind.alreadyTracked, 'Already',
            shared: true),
        const PhotoOutcome(PhotoOutcomeKind.failed, 'Network',
            retryable: true,
            errorKind: AnalysisErrorKind.network,
            shared: true),
        const PhotoOutcome(PhotoOutcomeKind.saved, 'Meal logged',
            shared: true),
        // A share's line on its files that gave no photo (#81): no meal.
        refusedFilesOutcome(const RefusedShareFiles([ShareRefusal.photoType],
            photoTypes: ['AVIF'])),
      ]) {
        expect(revealForShared(o), isNull, reason: o.kind.name);
        expect(revealForMeal(o), isNull, reason: o.kind.name);
      }
    });
  });

  group('MealReveals', () {
    test('a request made before the shell is up waits for it', () {
      final reveals = MealReveals();
      reveals.request(const MealReveal(5));
      var woken = 0;
      reveals.attach(() => woken++, canShowNow: () => true);
      expect(woken, 1);
      expect(reveals.take(), const MealReveal(5));
      expect(reveals.waiting, isNull, reason: 'taken once');
    });

    test('a request wakes the shell; the newest one waits', () {
      final reveals = MealReveals();
      var woken = 0;
      reveals.attach(() => woken++, canShowNow: () => true);
      expect(woken, 0, reason: 'nothing waiting');
      reveals.request(const MealReveal(1));
      reveals.request(const MealReveal(2));
      expect(woken, 2);
      expect(reveals.take(), const MealReveal(2));
    });

    test('a request older than the wait limit is dropped', () {
      var now = DateTime(2026, 11, 21, 12);
      final reveals = MealReveals(clock: () => now);
      reveals.request(const MealReveal(9));
      now = now.add(MealReveals.waitLimit);
      expect(reveals.waiting, const MealReveal(9));
      now = now.add(const Duration(seconds: 1));
      expect(reveals.waiting, isNull);
      expect(reveals.take(), isNull);
    });

    // Review of PR 80: a request kept for 5 minutes fired on whichever
    // Back finally reached the tabs, long after the tap.
    test('the wait is a minute: a request still waiting after that is '
        'dropped', () {
      var now = DateTime(2026, 11, 21, 12);
      final reveals = MealReveals(clock: () => now);
      reveals.request(const MealReveal(9));
      now = now.add(const Duration(seconds: 59));
      expect(reveals.waiting, const MealReveal(9));
      now = now.add(const Duration(seconds: 2));
      expect(reveals.waiting, isNull);
    });

    test("the shell's changes reach whoever listens (the View on a "
        'message)', () {
      final reveals = MealReveals();
      var heard = 0;
      void listener() => heard++;
      reveals.availability.addListener(listener);
      reveals.availabilityChanged();
      reveals.availabilityChanged();
      expect(heard, 2);
      reveals.availability.removeListener(listener);
      reveals.availabilityChanged();
      expect(heard, 2);
    });

    test('a clock set back drops it too', () {
      var now = DateTime(2026, 11, 21, 12);
      final reveals = MealReveals(clock: () => now);
      reveals.request(const MealReveal(9));
      now = now.subtract(const Duration(hours: 1));
      expect(reveals.waiting, isNull);
    });

    test('canShowNow: no with no shell, or when the shell cannot say', () {
      final reveals = MealReveals();
      expect(reveals.canShowNow, isFalse);
      void wake() {}
      reveals.attach(wake, canShowNow: () => true);
      expect(reveals.canShowNow, isTrue);
      reveals.detach(() {}); // another shell's: nothing changes
      expect(reveals.canShowNow, isTrue);
      reveals.detach(wake);
      expect(reveals.canShowNow, isFalse);
      reveals.attach(wake, canShowNow: () => throw StateError('gone'));
      expect(reveals.canShowNow, isFalse);
    });

    test('a shell whose wake throws does not lose the request', () {
      final reveals = MealReveals();
      reveals.attach(() => throw StateError('disposed'),
          canShowNow: () => false);
      reveals.request(const MealReveal(3));
      expect(reveals.waiting, const MealReveal(3));
    });
  });

  group('MealCardTaps (a tap on a Logged meals card)', () {
    test('a meal card asks for its meal; any other card for nothing', () {
      final reveals = MealReveals();
      final taps = MealCardTaps(reveals);
      taps.onTap('daily:2026-11-21T03:30:00.000Z@2026-11-20');
      expect(reveals.waiting, isNull);
      taps.onTap(null); // the paused notice
      expect(reveals.waiting, isNull);
      taps.onTap('meal:42');
      expect(reveals.waiting, const MealReveal(42));
    });

    test('the card that started the app asks for its meal', () async {
      final reveals = MealReveals();
      await MealCardTaps(reveals).launch(() async => 'meal:7');
      expect(reveals.waiting, const MealReveal(7));
      final none = MealReveals();
      await MealCardTaps(none).launch(() async => null);
      expect(none.waiting, isNull);
    });

    test('a recreated activity: the tap that reached onTap during init is '
        'not asked for again as the launch', () async {
      final reveals = MealReveals();
      final taps = MealCardTaps(reveals)..onTap('meal:7');
      expect(reveals.take(), const MealReveal(7));
      var read = 0;
      await taps.launch(() async {
        read++;
        return 'meal:7';
      });
      expect(read, 0, reason: 'not even read');
      expect(reveals.waiting, isNull);
    });

    test('a tap while the launch is read wins over it', () async {
      final reveals = MealReveals();
      final taps = MealCardTaps(reveals);
      await taps.launch(() async {
        taps.onTap('meal:9');
        return 'meal:7';
      });
      expect(reveals.waiting, const MealReveal(9));
    });
  });

  group("di.dart's snackbar sink (outcomeAnnouncer)", () {
    test("Android: a shared photo's save gets View, in the app language",
        () {
      for (final (l, label, line) in [
        (AppLocalizationsEn(), 'View', 'Meal logged: Ramen — ~600 kcal'),
        (AppLocalizationsZh(), '查看', '已记录：Ramen —— 约 600 千卡'),
      ]) {
        final plain = <String>[];
        final views = <(
          String,
          String,
          void Function(),
          bool Function(),
          Listenable
        )>[];
        final reveals = MealReveals();
        outcomeAnnouncer(
            l10n: () => l,
            notify: plain.add,
            reveals: reveals,
            notifyView: (m, a, onAction, available, changes) =>
                views.add((m, a, onAction, available, changes)))(_saved);
        expect(plain, isEmpty);
        expect(views, hasLength(1));
        final (message, action, onAction, available, changes) = views.single;
        expect(message, line);
        expect(action, label);
        expect(available(), isFalse, reason: 'no shell attached');
        expect(changes, same(reveals.availability),
            reason: 'View is asked again as the shell changes');
        onAction();
        expect(reveals.waiting, const MealReveal(42),
            reason: 'View asks the shell for the meal');
      }
    });

    test('everything else is the plain line it was', () {
      final plain = <String>[];
      var views = 0;
      final announce = outcomeAnnouncer(
          l10n: AppLocalizationsEn.new,
          notify: plain.add,
          reveals: MealReveals(),
          notifyView: (_, _, _, _, _) => views++);
      announce(_notShared(_saved)); // a picked photo, an automatic one
      announce(const PhotoOutcome(PhotoOutcomeKind.skipped, 'No food',
          shared: true));
      announce(refusedFilesOutcome(const RefusedShareFiles(
          [ShareRefusal.photoType],
          photoTypes: ['AVIF'])));
      expect(views, 0);
      expect(plain, [
        'Meal logged: Ramen — ~600 kcal',
        isNotEmpty,
        "One shared file was skipped: Chopstats can't read AVIF photos yet.",
      ]);
    });

    test('iPhone (no reveals): no View, a shared save included', () {
      final plain = <String>[];
      var views = 0;
      outcomeAnnouncer(
          l10n: AppLocalizationsEn.new,
          notify: plain.add,
          notifyView: (_, _, _, _, _) => views++)(_saved);
      expect(views, 0);
      expect(plain, ['Meal logged: Ramen — ~600 kcal']);
    });
  });
}
