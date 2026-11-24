/// A note typed in Edit meal (docs/APP_PORT_SPEC.md §9.0, "Meal note
/// correction"): what is sent, how the answer is read, and the notes kept
/// on the meal. Pure: no Flutter, no I/O.
///
/// What is sent is a whitelist by construction: [composeMealCorrectionRequest]
/// reads only a [MealCorrectionInput] the editor builds from its form (the
/// description, each food's name and four numbers, the four totals) and the
/// meal's earlier notes. Never the photo, the date or time, another meal,
/// the dietary profile, or any other key of the stored analysis.
///
/// What comes back is a PATCH, never a whole meal: foods `changed` (by id),
/// `added` and `removed`, or `no_change` / `unclear` with a sentence.
/// [parseMealCorrectionReply] reads it field by field against the editor's
/// own bounds; a wrong shape anywhere makes the whole answer unusable, and
/// nothing is ever silently read as 0. The answer only fills the form; the
/// user's Save is the only write.
///
/// The notes (`analysis.user_notes`, owner 2026-11-24): a list of
/// `{"text", "at"}`, oldest first, at most [kUserNotesMax] (the newest).
/// The editor writes them at Save for the corrections the saved form still
/// holds, and a later correction of the same meal sends them again as
/// earlier notes, already applied ([MealCorrectionInput.earlierNotes]).
/// Every other writer keeps them exactly as they are ([keepUserNotes]);
/// a model's reply never writes them (restaurant_assist_logic
/// dropAssistClaims).
library;

import 'dart:convert' show jsonEncode;

import 'coerce.dart' show cleanShortText;

/// Longest note, in code points (the field's formatter and the composer).
const int kMealNoteMaxChars = 500;

/// Longest food name sent or read back, in code points.
const int kMealNoteNameMax = 120;

/// Longest description sent or read back (the editor's own limit).
const int kMealNoteDescMax = 300;

/// Longest reason (the 💬 line) and reply sentence read back.
const int kMealNoteReasonMax = 200;
const int kMealNoteReplyMax = 300;

/// The editor's bounds (ui/meal_edit_logic.dart maxItemsPerMeal,
/// maxMealCalories, maxMacroGrams): an answer outside them is unusable,
/// never clamped in silence.
const int kMealNoteMaxFoods = 40;
const num kMealNoteMaxKcal = 20000;
const num kMealNoteMaxGrams = 2000;

/// The analysis key the notes are kept under.
const String kUserNotesKey = 'user_notes';

/// At most this many notes are kept on a meal (the newest) and sent again.
const int kUserNotesMax = 20;

/// One food as the editor shows it.
class MealCorrectionItem {
  const MealCorrectionItem({
    required this.name,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final String name;
  final num calories;
  final num protein;
  final num carbs;
  final num fat;

  List<num> get numbers => [calories, protein, carbs, fat];

  @override
  String toString() => 'MealCorrectionItem($name, $numbers)';
}

/// The meal's four totals as the editor shows them.
class MealCorrectionTotals {
  const MealCorrectionTotals({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final num calories;
  final num protein;
  final num carbs;
  final num fat;

  List<num> get numbers => [calories, protein, carbs, fat];

  @override
  String toString() => 'MealCorrectionTotals($numbers)';
}

/// What a note is sent with: the meal as the form shows it (filled rows
/// only, in screen order; their position is their id) and the meal's
/// earlier notes, oldest first, which the meal shown already includes.
class MealCorrectionInput {
  const MealCorrectionInput({
    required this.description,
    required this.items,
    required this.totals,
    this.earlierNotes = const [],
  });

  final String description;
  final List<MealCorrectionItem> items;
  final MealCorrectionTotals totals;
  final List<String> earlierNotes;
}

/// A note as it is sent and kept: whitespace collapsed; control, bidi,
/// invisible characters and every `<` `>` dropped; at most
/// [kMealNoteMaxChars] code points. Full-width text stays as typed.
/// Non-strings are "".
String cleanMealNote(Object? note) =>
    cleanShortText(note, kMealNoteMaxChars, keepWidth: true);

/// A number for the request: whole numbers without a decimal point.
num _plain(num v) => v == v.roundToDouble() ? v.round() : v;

/// The request JSON for [note] about [input]: `meal`, `items` (each `id`,
/// `name` and the four numbers), `totals`, the earlier notes when there
/// are any (`earlier_notes_already_applied`, the newest [kUserNotesMax])
/// and `new_note`, in that order. Text is cleaned as [cleanMealNote]
/// cleans it, so nothing can close the prompt's data block.
String composeMealCorrectionRequest(MealCorrectionInput input, String note) {
  final earlier = [
    for (final n in input.earlierNotes) cleanMealNote(n),
  ]..removeWhere((n) => n.isEmpty);
  final kept = earlier.length > kUserNotesMax
      ? earlier.sublist(earlier.length - kUserNotesMax)
      : earlier;
  final t = input.totals;
  return jsonEncode({
    'meal': cleanShortText(input.description, kMealNoteDescMax,
        keepWidth: true),
    'items': [
      for (var i = 0; i < input.items.length; i++)
        {
          'id': i,
          'name': cleanShortText(input.items[i].name, kMealNoteNameMax,
              keepWidth: true),
          'estimated_calories': _plain(input.items[i].calories),
          'protein_g': _plain(input.items[i].protein),
          'carbs_g': _plain(input.items[i].carbs),
          'fat_g': _plain(input.items[i].fat),
        },
    ],
    'totals': {
      'total_calories': _plain(t.calories),
      'total_protein_g': _plain(t.protein),
      'total_carbs_g': _plain(t.carbs),
      'total_fat_g': _plain(t.fat),
    },
    if (kept.isNotEmpty) 'earlier_notes_already_applied': kept,
    'new_note': cleanMealNote(note),
  });
}

/// The AI's answer to a note, read ([parseMealCorrectionReply]).
sealed class MealCorrectionReply {
  const MealCorrectionReply();
}

/// A usable correction: what fills the form.
final class MealCorrected extends MealCorrectionReply {
  const MealCorrected(this.proposal);
  final MealCorrectionProposal proposal;
}

/// The note changes nothing in this meal; [reply] may be empty.
final class MealNoChange extends MealCorrectionReply {
  const MealNoChange(this.reply);
  final String reply;
}

/// The AI asks what the note means; [reply] is its question.
final class MealUnclear extends MealCorrectionReply {
  const MealUnclear(this.reply);
  final String reply;
}

/// Nothing in the answer can be used. [emptiesMeal]: it would leave the
/// meal with no food (every row removed, or a meal with only totals at
/// 0 kcal) — the same silent-delete guard Fix meals applies.
final class MealReplyUnusable extends MealCorrectionReply {
  const MealReplyUnusable({this.emptiesMeal = false});
  final bool emptiesMeal;
}

/// A validated patch against the [MealCorrectionInput] it answers.
class MealCorrectionProposal {
  const MealCorrectionProposal({
    this.description,
    this.changed = const {},
    this.added = const [],
    this.removed = const {},
    this.totals,
    this.reason = '',
  });

  /// The new description, or null to keep the current one.
  final String? description;

  /// Rows changed, by id: their new name and four numbers.
  final Map<int, MealCorrectionItem> changed;

  /// Foods added, in the answer's order.
  final List<MealCorrectionItem> added;

  /// Rows removed, by id.
  final Set<int> removed;

  /// The new totals of a meal with no rows; null otherwise.
  final MealCorrectionTotals? totals;

  /// What the AI says it changed (may be empty).
  final String reason;
}

/// kcal are whole, grams to 0.1 (as the leftover deduction rounds).
num _roundKcal(num v) => v.round();
num _roundGrams(num v) {
  final r = (v * 10).round() / 10;
  return r == r.roundToDouble() ? r.round() : r;
}

/// A number the answer gave: a num or a numeric string, never a bool,
/// finite, at least 0 and at most [max]; null when it is none of these.
num? _number(Object? v, num max) {
  num? n;
  if (v is num) {
    n = v;
  } else if (v is String) {
    n = num.tryParse(v.trim());
  }
  if (n == null || !n.isFinite || n < 0 || n > max) return null;
  return n;
}

/// A row id the answer gave: an int, an integral double or a numeric
/// string, in [0, [count]); null otherwise.
int? _id(Object? v, int count) {
  num? n;
  if (v is num) {
    n = v;
  } else if (v is String) {
    n = num.tryParse(v.trim());
  }
  if (n == null || !n.isFinite || n != n.roundToDouble()) return null;
  final i = n.toInt();
  return i >= 0 && i < count ? i : null;
}

/// Thrown inside the parser for a wrong shape; never escapes it.
class _Unusable implements Exception {
  const _Unusable();
}

const List<String> _itemNumberKeys = [
  'estimated_calories',
  'protein_g',
  'carbs_g',
  'fat_g',
];
const List<String> _totalNumberKeys = [
  'total_calories',
  'total_protein_g',
  'total_carbs_g',
  'total_fat_g',
];

/// The four numbers of [m] under [keys]; each missing (or null) one is
/// [keep]'s, each given one must be valid ([_number]) and is rounded.
List<num> _numbers(Map m, List<String> keys, List<num>? keep) {
  final out = <num>[];
  for (var i = 0; i < 4; i++) {
    final raw = m[keys[i]];
    if (raw == null) {
      if (keep == null) throw const _Unusable();
      out.add(keep[i]);
      continue;
    }
    final n = _number(raw, i == 0 ? kMealNoteMaxKcal : kMealNoteMaxGrams);
    if (n == null) throw const _Unusable();
    out.add(i == 0 ? _roundKcal(n) : _roundGrams(n));
  }
  return out;
}

/// Equal after rounding, number by number.
bool _sameNumbers(List<num> a, List<num> b) {
  for (var i = 0; i < 4; i++) {
    final x = i == 0 ? _roundKcal(a[i]) : _roundGrams(a[i]);
    final y = i == 0 ? _roundKcal(b[i]) : _roundGrams(b[i]);
    if (x != y) return false;
  }
  return true;
}

/// A list the answer gave under [key]: absent or null is empty, anything
/// but a list is unusable.
List<Object?> _list(Map json, String key) {
  final v = json[key];
  if (v == null) return const [];
  if (v is! List) throw const _Unusable();
  return v;
}

/// Reads the AI's answer to a note about [sent] (module doc). [json] is
/// what the text-intent seam returned: a bare JSON array comes back as
/// `{'actions': list}` and is unusable.
MealCorrectionReply parseMealCorrectionReply(
    Object? json, MealCorrectionInput sent) {
  if (json is! Map) return const MealReplyUnusable();
  final rawStatus = json['status'];
  final status = rawStatus is String ? rawStatus.trim().toLowerCase() : null;
  if (status == 'no_change') {
    return MealNoChange(cleanShortText(json['reply'], kMealNoteReplyMax,
        keepWidth: true));
  }
  if (status == 'unclear') {
    final reply =
        cleanShortText(json['reply'], kMealNoteReplyMax, keepWidth: true);
    return reply.isEmpty ? const MealReplyUnusable() : MealUnclear(reply);
  }
  // 'corrected', or a missing or unknown status next to a patch key (a
  // model that forgot the status still answered with a patch). Anything
  // else, a bare array's {'actions': …} included, is unusable.
  const patchKeys = [
    'changed',
    'added',
    'removed',
    'totals',
    'meal_description',
  ];
  if (status != 'corrected' && !patchKeys.any(json.containsKey)) {
    return const MealReplyUnusable();
  }
  try {
    return _readPatch(json, sent);
  } on _Unusable {
    return const MealReplyUnusable();
  }
}

MealCorrectionReply _readPatch(Map json, MealCorrectionInput sent) {
  final n = sent.items.length;
  final changed = <int, MealCorrectionItem>{};
  for (final e in _list(json, 'changed')) {
    if (e is! Map) throw const _Unusable();
    final id = _id(e['id'], n);
    if (id == null || changed.containsKey(id)) throw const _Unusable();
    final was = sent.items[id];
    final rawName = e['name'];
    if (rawName != null && rawName is! String) throw const _Unusable();
    final name = cleanShortText(rawName, kMealNoteNameMax, keepWidth: true);
    final numbers = _numbers(e, _itemNumberKeys, was.numbers);
    changed[id] = MealCorrectionItem(
      name: name.isEmpty
          ? cleanShortText(was.name, kMealNoteNameMax, keepWidth: true)
          : name,
      calories: numbers[0],
      protein: numbers[1],
      carbs: numbers[2],
      fat: numbers[3],
    );
  }
  final added = <MealCorrectionItem>[];
  for (final e in _list(json, 'added')) {
    if (e is! Map) throw const _Unusable();
    final rawName = e['name'];
    if (rawName is! String) throw const _Unusable();
    final name = cleanShortText(rawName, kMealNoteNameMax, keepWidth: true);
    if (name.isEmpty) throw const _Unusable();
    final numbers = _numbers(e, _itemNumberKeys, null);
    added.add(MealCorrectionItem(
      name: name,
      calories: numbers[0],
      protein: numbers[1],
      carbs: numbers[2],
      fat: numbers[3],
    ));
  }
  final removed = <int>{};
  for (final e in _list(json, 'removed')) {
    final id = _id(e, n);
    if (id == null || !removed.add(id) || changed.containsKey(id)) {
      throw const _Unusable();
    }
  }
  // A meal with only totals has no rows to change, add to or remove from.
  if (n == 0 && (changed.isNotEmpty || added.isNotEmpty || removed.isNotEmpty)) {
    throw const _Unusable();
  }

  final rawDesc = json['meal_description'];
  if (rawDesc != null && rawDesc is! String) throw const _Unusable();
  final description =
      cleanShortText(rawDesc, kMealNoteDescMax, keepWidth: true);
  final sentDesc =
      cleanShortText(sent.description, kMealNoteDescMax, keepWidth: true);
  final String? newDescription =
      description.isEmpty || description == sentDesc ? null : description;

  final rawReason = json['reason'];
  final reason = rawReason is String
      ? cleanShortText(rawReason, kMealNoteReasonMax, keepWidth: true)
      : '';

  MealCorrectionTotals? totals;
  if (n == 0) {
    final rawTotals = json['totals'];
    if (rawTotals != null) {
      if (rawTotals is! Map) throw const _Unusable();
      final t = _numbers(rawTotals, _totalNumberKeys, sent.totals.numbers);
      totals = MealCorrectionTotals(
          calories: t[0], protein: t[1], carbs: t[2], fat: t[3]);
    }
    final kcal = (totals ?? sent.totals).calories;
    if (kcal <= 0) return const MealReplyUnusable(emptiesMeal: true);
    if (totals != null && _sameNumbers(totals.numbers, sent.totals.numbers)) {
      totals = null;
    }
  } else {
    // A changed row that the answer left as it was (after rounding) is no
    // change.
    changed.removeWhere((id, item) {
      final was = sent.items[id];
      return item.name ==
              cleanShortText(was.name, kMealNoteNameMax, keepWidth: true) &&
          _sameNumbers(item.numbers, was.numbers);
    });
    final left = n - removed.length + added.length;
    if (left <= 0) return const MealReplyUnusable(emptiesMeal: true);
    if (left > kMealNoteMaxFoods) return const MealReplyUnusable();
    // The rows' sums must fit the editor's bounds: it would clamp the
    // derived totals in silence (meal_editor_screen.dart
    // _recomputeTotalsFromItems).
    final sums = <num>[0, 0, 0, 0];
    for (var i = 0; i < n; i++) {
      if (removed.contains(i)) continue;
      final numbers = (changed[i] ?? sent.items[i]).numbers;
      for (var k = 0; k < 4; k++) {
        sums[k] += numbers[k];
      }
    }
    for (final a in added) {
      for (var k = 0; k < 4; k++) {
        sums[k] += a.numbers[k];
      }
    }
    if (sums[0] > kMealNoteMaxKcal ||
        sums.skip(1).any((g) => g > kMealNoteMaxGrams)) {
      return const MealReplyUnusable();
    }
  }

  if (changed.isEmpty &&
      added.isEmpty &&
      removed.isEmpty &&
      totals == null &&
      newDescription == null) {
    return MealNoChange(reason);
  }
  return MealCorrected(MealCorrectionProposal(
    description: newDescription,
    changed: changed,
    added: added,
    removed: removed,
    totals: totals,
    reason: reason,
  ));
}

/// How a food line of [MealCorrectionDiff] reads.
enum MealCorrectionLineKind { changed, renamed, added, removed }

class MealCorrectionLine {
  const MealCorrectionLine(this.kind,
      {required this.name,
      this.newName,
      required this.kcalBefore,
      required this.kcalAfter});

  final MealCorrectionLineKind kind;

  /// The food's name before (its only name for added and removed).
  final String name;

  /// The new name of a [MealCorrectionLineKind.renamed] food.
  final String? newName;

  /// 0 for an added food's before and a removed food's after.
  final num kcalBefore;
  final num kcalAfter;
}

/// What a correction changes, for the editor's card.
class MealCorrectionDiff {
  const MealCorrectionDiff({
    this.descBefore,
    this.descAfter,
    required this.totalsBefore,
    required this.totalsAfter,
    required this.lines,
    required this.unchangedCount,
    required this.reason,
  });

  /// Both set only when the description changed.
  final String? descBefore;
  final String? descAfter;

  /// The form's totals before, and after the fill: the rows' sums (the
  /// editor's totals follow its rows), or a row-less meal's new totals.
  final MealCorrectionTotals totalsBefore;
  final MealCorrectionTotals totalsAfter;

  /// Changed and renamed foods in form order, then added, then removed.
  final List<MealCorrectionLine> lines;

  /// Foods the correction left as they were.
  final int unchangedCount;
  final String reason;
}

/// Sums as the editor shows them: whole kcal-style numbers stay whole,
/// others keep two decimals (meal_edit_logic.dart itemTotals).
num _tidy(num v) {
  if (v == v.roundToDouble()) return v.round();
  return num.parse(v.toStringAsFixed(2));
}

/// The rows [p] leaves on [sent], in form order: kept and changed rows by
/// id, then the added ones.
List<MealCorrectionItem> correctedRows(
    MealCorrectionInput sent, MealCorrectionProposal p) => [
      for (var i = 0; i < sent.items.length; i++)
        if (!p.removed.contains(i)) p.changed[i] ?? sent.items[i],
      ...p.added,
    ];

/// [p]'s changes to [sent], for the card ([MealCorrectionDiff]).
MealCorrectionDiff mealCorrectionDiff(
    MealCorrectionInput sent, MealCorrectionProposal p) {
  final MealCorrectionTotals after;
  if (sent.items.isEmpty) {
    after = p.totals ?? sent.totals;
  } else {
    final sums = <num>[0, 0, 0, 0];
    for (final r in correctedRows(sent, p)) {
      for (var k = 0; k < 4; k++) {
        sums[k] += r.numbers[k];
      }
    }
    after = MealCorrectionTotals(
        calories: _tidy(sums[0]),
        protein: _tidy(sums[1]),
        carbs: _tidy(sums[2]),
        fat: _tidy(sums[3]));
  }
  final lines = <MealCorrectionLine>[
    for (final id in (p.changed.keys.toList()..sort()))
      p.changed[id]!.name.trim() == sent.items[id].name.trim()
          ? MealCorrectionLine(MealCorrectionLineKind.changed,
              name: p.changed[id]!.name,
              kcalBefore: sent.items[id].calories,
              kcalAfter: p.changed[id]!.calories)
          : MealCorrectionLine(MealCorrectionLineKind.renamed,
              name: sent.items[id].name,
              newName: p.changed[id]!.name,
              kcalBefore: sent.items[id].calories,
              kcalAfter: p.changed[id]!.calories),
    for (final a in p.added)
      MealCorrectionLine(MealCorrectionLineKind.added,
          name: a.name, kcalBefore: 0, kcalAfter: a.calories),
    for (final id in (p.removed.toList()..sort()))
      MealCorrectionLine(MealCorrectionLineKind.removed,
          name: sent.items[id].name,
          kcalBefore: sent.items[id].calories,
          kcalAfter: 0),
  ];
  final desc = p.description;
  return MealCorrectionDiff(
    descBefore: desc == null ? null : sent.description,
    descAfter: desc,
    totalsBefore: sent.totals,
    totalsAfter: after,
    lines: lines,
    unchangedCount: sent.items.length - p.changed.length - p.removed.length,
    reason: p.reason,
  );
}

/// One note kept on a meal: what was sent ([text], cleaned) and when
/// ([at], ISO-8601 UTC, as sent; may be empty on an imported meal).
class MealNote {
  const MealNote(this.text, this.at);

  final String text;
  final String at;

  Map<String, String> toJson() => {'text': text, 'at': at};

  @override
  bool operator ==(Object other) =>
      other is MealNote && other.text == text && other.at == at;

  @override
  int get hashCode => Object.hash(text, at);

  @override
  String toString() => 'MealNote($text, $at)';
}

/// The notes kept on [analysis], oldest first, read as untrusted (an
/// imported meal can carry anything): an entry that is not a map with a
/// non-blank text is skipped, the text is cleaned ([cleanMealNote]) and a
/// non-string `at` reads as empty. At most the newest [kUserNotesMax].
List<MealNote> readUserNotes(Map? analysis) {
  final raw = analysis?[kUserNotesKey];
  if (raw is! List) return const [];
  final out = <MealNote>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final text = cleanMealNote(e['text']);
    if (text.isEmpty) continue;
    final at = e['at'];
    out.add(MealNote(text, at is String ? at.trim() : ''));
  }
  return out.length > kUserNotesMax
      ? out.sublist(out.length - kUserNotesMax)
      : out;
}

/// Sets [analysis]'s notes to [notes] (the newest [kUserNotesMax]), or
/// removes the key when there are none.
void writeUserNotes(Map<String, dynamic> analysis, List<MealNote> notes) {
  if (notes.isEmpty) {
    analysis.remove(kUserNotesKey);
    return;
  }
  final kept = notes.length > kUserNotesMax
      ? notes.sublist(notes.length - kUserNotesMax)
      : notes;
  analysis[kUserNotesKey] = [for (final n in kept) n.toJson()];
}

/// [written] with exactly the notes [current] holds (its raw value, or no
/// key when it has none), in place; returns [written]. For a writer that
/// builds a meal's analysis from something other than the stored row (a
/// Fix meals reply, an undo's earlier copy): the notes stay as they are.
Map<String, dynamic> keepUserNotes(
    Map<String, dynamic> written, Map current) {
  if (current.containsKey(kUserNotesKey)) {
    written[kUserNotesKey] = current[kUserNotesKey];
  } else {
    written.remove(kUserNotesKey);
  }
  return written;
}
