// The notes kept on a meal corrected in Edit meal (analysis.user_notes)
// travel with the meal: Export holds them, Import Data brings them back
// on another phone, and an iCloud Backup (its record tables, restored
// through the same import) carries them too. Android's Auto Backup copies
// the database file itself, so they are in it as stored.
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/meal_correction.dart';
import 'package:calorie_tracker/data/db.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database dbA;
  late Database dbB;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ct_user_notes');
    dbA = await openAppDatabase(path: '${tmp.path}/a.db');
    dbB = await openAppDatabase(path: '${tmp.path}/b.db');
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tmp.delete(recursive: true);
  });

  const notes = [
    {'text': 'only half the rice', 'at': '2026-11-24T12:00:00.000Z'},
    {'text': '米饭只吃了一半（大约１００克）', 'at': '2026-11-24T12:05:00.000Z'},
  ];
  final meal = Meal(
    id: 0,
    date: '2026-11-24',
    time: '12:00 PM',
    timestamp: '2026-11-24T12:00:00.000',
    source: MealSource.appPhoto,
    imageHash: 'abc123',
    analysis: {
      'is_food': true,
      'meal_description': 'Braised pork with rice',
      'total_calories': 530,
      'food_items': [
        {'name': 'Steamed rice (~100 g)', 'estimated_calories': 130},
        {'name': 'Braised pork (~120 g)', 'estimated_calories': 400},
      ],
      kUserNotesKey: notes,
    },
  );

  test('export, then import on another phone, keeps the notes', () async {
    final daoA = SqfliteMealsDao(dbA);
    await daoA.saveMeal(meal);
    final export = await daoA.exportJson();
    expect(export, contains('only half the rice'));

    final daoB = SqfliteMealsDao(dbB);
    final summary = await daoB.importJson(export);
    expect(summary.added['meals'], 1);
    final back = (await daoB.mealsBetween('2026-11-24', '2026-11-24')).single;
    expect(back.analysis[kUserNotesKey], notes);
    expect(readUserNotes(back.analysis).map((n) => n.text),
        ['only half the rice', '米饭只吃了一半（大约１００克）']);
  });

  test("an iCloud Backup's record tables carry them", () async {
    final daoA = SqfliteMealsDao(dbA);
    await daoA.saveMeal(meal);
    final tables = await daoA.backupRecordTables();
    final row = tables['meals']!.single;
    final stored = jsonDecode(row['analysis'] as String) as Map;
    expect(stored[kUserNotesKey], notes);
  });
}
