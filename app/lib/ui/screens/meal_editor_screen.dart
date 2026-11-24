/// Meal editor: create a meal by hand or edit/delete an existing one.
///
/// Every rule lives in ui/meal_edit_logic.dart (parsing, bounds, the
/// analysis merge) — this file is the form around it. Saving an EXISTING
/// meal goes through updateMealFields (keeps the row id, the photo's ledger
/// provenance, and marks corrected=1). A NEW meal's provenance depends on
/// how it arrived: MealSource.appManual (typed numbers, no photo, no hash),
/// MealSource.manualText (describe-a-meal preview, no hash), or
/// MealSource.appManualPhoto WITH the photo's md5 when the user hand-enters
/// a photo the model refused.
///
/// Write safety (design R6a): an existing meal's save is a compare-and-set
/// against the analysis text the draft was loaded from
/// (MealsDao.updateMealFieldsIfUnchanged). The row is read once more as the
/// editor opens (mealSnapshot): if the list handed over an older copy and
/// nothing was typed yet, the form shows the meal as stored. A meal that
/// changed while the editor was open (a leftover deduction, a chat fix, a
/// restaurant lookup) is never overwritten with the older copy: the save
/// says so and the form reloads. While open, the editor holds the meal in
/// the [MealInUseRegistry], so the restaurant assist leaves it alone.
///
/// The restaurant source card (design R7b; widgets/assist_source_card.dart)
/// sits at the top of a stored meal: where a chain's published numbers came
/// from, and the user's answers — Use AI estimate, Use published numbers,
/// Wrong restaurant (then 'Which restaurant?', our chain table only, and a
/// lookup of the chain picked), Not from a restaurant, Correct, and Look up
/// restaurant nutrition. Each writes at once, as the user's own change,
/// against the stored text the form was loaded from (MealAssist.act /
/// lookupNow); a meal that changed meanwhile says "This meal was just
/// updated — please review." and shows the newer meal. The buttons wait
/// while the form has unsaved typing, and the form waits (read-only)
/// while one of their writes runs — a lookup the owner's server runs can
/// be polled for minutes — so a write never lands under typing.
/// Opening a meal clears its 'updated' dot.
///
/// Usual foods (opened from Today only): a photo meal of today whose foods
/// the user set numbers for before gets a "Your usual numbers" card
/// (widgets/usual_offer_card.dart) under the source card. Use my numbers
/// writes them through the same compare-and-set as a save (UsualFoods
/// .accept); Keep AI estimate writes nothing. Saving marks the rows whose
/// numbers the user changed as theirs (meal_edit_logic.dart), and a
/// describe preview starts without any mark its model wrote.
///
/// Correct with a note (owner 2026-11-24; a stored meal opened from Today
/// or History, any date): the user types what was different, and Correct
/// with AI sends the note with the meal as the form shows it and its
/// earlier notes — text only, never the photo (core/meal_correction.dart,
/// through MealNoteCorrector). It writes nothing: the answer (a patch)
/// fills the form as unsaved edits, a card lists every change with Undo,
/// and Save stays the only write, the same compare-and-set. While the AI
/// answers the form is read-only and Save waits; Stop drops the answer.
/// The notes of the corrections the saved form still holds are kept with
/// the meal (analysis.user_notes) and listed here, each removable; a later
/// note sends them again as already applied.
library;

import 'dart:convert' show jsonEncode;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../core/coerce.dart'
    show addCalendarDays, finiteAnalysis, isFoodTruthy, normalizeImageHash;
import '../../core/contracts.dart';
import '../../core/meal_correction.dart';
import '../../core/restaurant_assist_logic.dart'
    show acceptAssistSuggestion, dropAssistClaims, normalizeSourceUrl;
import '../../services/assist/meal_assist.dart'
    show
        AssistActionResult,
        AssistActionStatus,
        AssistRun,
        AssistSkip,
        AssistUserAction,
        kAssistPollInterval,
        kAssistPollWindow;
import '../../services/photo/filename_dates.dart'
    show captureWallClock, exifWallAndOffset;
import '../../services/photo/glasses.dart'
    show captureAnalysis, isMetaGlassesAnalysis;
import '../../core/server_transport.dart' show serverAddressRefused;
import '../../services/usual/usual_foods.dart';
import '../ai_consent.dart' show ensureMealNoteConsent;
import '../assist_lookup_text.dart';
import '../app_formats.dart';
import '../assist_view.dart';
import '../format.dart' show formatKcal, formatOneDecimal, isoDate;
import '../l10n.dart';
import '../large_text.dart';
import '../meal_edit_logic.dart';
import '../meal_in_use.dart';
import '../provider_names.dart' show providerDisplayLabel;
import '../restaurant_assist_controls.dart';
import '../services.dart' show SettingsStore, serverKeyForOtherAddress;
import '../widgets/assist_source_card.dart';
import '../widgets/chain_picker_sheet.dart';
import '../widgets/glasses_badge.dart';
import '../widgets/usual_offer_card.dart';
import '../widgets/restaurant_consent_sheet.dart'
    show restaurantManualLookupChoice;
import '../widgets/macro_chart.dart';
import '../widgets/small_spinner.dart';
import '../theme/app_dialog.dart';
import '../theme/app_theme.dart' show AppButtonStyles;
import '../theme/tokens.dart' show AppMotion, AppThemeContext;
import '../widgets/discard_guard.dart';
import '../widgets/pickers.dart';
import '../widgets/reply_note.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;

class MealEditorScreen extends StatefulWidget {
  const MealEditorScreen({
    super.key,
    required this.dao,
    this.meal,
    this.initialDate,
    this.now,
    this.fromPhoto,
    this.makeThumb,
    this.initialAnalysis,
    this.newMealSource = MealSource.appManual,
    this.inUse,
    this.assist,
    this.settings,
    this.openUrl,
    this.assistPollInterval = kAssistPollInterval,
    this.usual,
    this.mealsChanged,
    this.noteCorrector,
  });

  final MealsDao dao;

  /// Correct with a note (a stored meal with [settings]): sends the note
  /// with the meal as the form shows it. Null shows no note (a new meal,
  /// the describe preview, a refused photo, Photo Coverage, tests).
  final MealNoteCorrector? noteCorrector;

  /// "The meal list changed" (refresh_signal.dart mealsChangedSignal): an
  /// Undo on the app's snackbar (usual foods, the restaurant lookup) can
  /// change the meal this editor shows while it is open. On a signal the
  /// editor re-reads its row ([_MealEditorScreenState._onMealsChanged]).
  /// Null: nothing to listen to (tests, a new meal).
  final Listenable? mealsChanged;

  /// Usual foods (D31: passed by Today only): the card offering the numbers
  /// the user set for a food before. Null shows none.
  final UsualFoods? usual;

  /// The restaurant assist (design R7b): the source card's answers, the
  /// manual lookup, the card's dot. Null (tests, a new meal) shows none of
  /// it.
  final RestaurantAssistControls? assist;

  /// The assist's mode and consent (the manual lookup asks for a consent
  /// that names the current recipient first). Null hides the lookup.
  final SettingsStore? settings;

  /// Opens the source page; injectable so widget tests need no
  /// url_launcher.
  final Future<bool> Function(Uri url)? openUrl;

  /// How often a manual lookup still running on the owner's server is
  /// asked again while the editor is open (for [kAssistPollWindow]).
  final Duration assistPollInterval;

  /// Held for [meal] while the editor is open (design R6a): the restaurant
  /// assist skips a meal the user is editing. Null: nothing to tell.
  final MealInUseRegistry? inUse;

  /// null = create a new meal.
  final Meal? meal;

  /// Pre-selected date for a new meal (the day the user came from).
  final String? initialDate;

  /// Injectable clock for tests.
  final DateTime Function()? now;

  /// Pre-fill for a NEW meal (describe-by-text preview): the model's
  /// analysis lands in the form so the user can check and correct the
  /// numbers BEFORE anything is written. [meal] stays null, so this is
  /// still an insert, not an in-place edit.
  final Map<String, dynamic>? initialAnalysis;

  /// source column for the inserted row — 'manual_text' for describe-by-text
  /// (server parity, spec §4.6), 'app_manual' for a hand-typed meal.
  final String newMealSource;

  /// Creating a meal FROM a photo the analyzer refused (not-food verdict or
  /// a permanent failure): the saved meal carries the photo's identity, so
  /// the ledger is closed (no re-offer loop) and the row gets its picture.
  /// The user supplies the numbers the model wouldn't.
  final IntakePhoto? fromPhoto;

  /// Thumbnail generator seam (production: makeMealThumb in a compute
  /// isolate); null skips the thumb.
  final Future<Uint8List?> Function(Uint8List original)? makeThumb;

  bool get isNew => meal == null;

  @override
  State<MealEditorScreen> createState() => _MealEditorScreenState();
}

class _MealEditorScreenState extends State<MealEditorScreen>
    with WidgetsBindingObserver {
  late MealDraft _draft;
  late final TextEditingController _desc;
  late final TextEditingController _cal;
  late final TextEditingController _pro;
  late final TextEditingController _carb;
  late final TextEditingController _fat;
  final List<({TextEditingController name, TextEditingController cal,
      TextEditingController pro, TextEditingController carb,
      TextEditingController fat})> _itemCtrls = [];
  List<String> _errors = const [];
  bool _saving = false;
  final ScrollController _scroll = ScrollController();

  /// The stored meal the form shows (design R6a): [MealEditorScreen.meal]
  /// at first, the row as re-read after a reload. Null for a new meal.
  Meal? _meal;

  /// A re-read of the row ([_confirmBasis], [_readBasis]) while it runs; a
  /// save of an existing meal waits for it. Never completes with an error.
  Future<void>? _basisRead;

  /// The stored row no longer matches what the form was loaded from (or is
  /// gone), and the user already typed over the older copy: the next save
  /// is answered with the conflict dialog instead of a write.
  bool _basisStale = false;

  /// The form's contents right after a load: equal to [_signature] while
  /// the user has typed nothing.
  String _loadedSignature = '';

  MealInUseHold? _hold;

  /// An answer to the restaurant source card is being written.
  bool _assistBusy = false;

  /// A manual restaurant lookup is running (polled while a server job).
  bool _lookingUp = false;

  /// The last lookup was answered by a saved lookup answer (usual foods
  /// D9): the next press asks the provider, whatever the button.
  bool _freshNext = false;

  /// [_load] is setting the fields one by one: their listener must not copy
  /// a half-updated form into the draft.
  bool _loading = false;

  /// Whether the last build showed the form as having unsaved typing: a
  /// text edit that changes it rebuilds, so the cards' buttons wait.
  bool _shownDirty = false;

  /// Whether the last build held back for unsaved changes ([_unsaved]): a
  /// text edit that changes it rebuilds, so a back gesture asks first.
  bool _shownUnsaved = false;

  /// The usual numbers offered for [_meal] (never stored), the meal they
  /// were worked out for, and the reply that may still set them.
  UsualOffer? _usualOffer;
  Meal? _usualFor;
  int _usualGen = 0;

  /// Use my numbers or Keep AI estimate is being written.
  bool _usualBusy = false;

  // ── Correct with a note ──

  /// The note being typed (Correct with a note).
  final TextEditingController _note = TextEditingController();

  /// The note field's focus: gaining it brings Correct with AI into view
  /// ([_revealNote]).
  final FocusNode _noteFocus = FocusNode(debugLabel: 'mealNote');

  /// The note's checks and consent question are open: the cards' meals
  /// signal is caught up when they end ([_refreshBasis]).
  bool _noteAsking = false;

  /// The note's request is in flight: the form is read-only and Save
  /// waits, as for the cards' own writes.
  bool _correcting = false;

  /// Bumped by every send and by Stop: an answer to an older one is
  /// dropped.
  int _noteGen = 0;

  /// The last answer that changed nothing, or a refusal, on the page.
  String? _noteReply;

  /// The note section's header: what an answer scrolls to the top.
  final GlobalKey _noteHeaderKey = GlobalKey();

  /// Each note that filled the form this visit, oldest first: what Undo
  /// steps back through, and the notes Save keeps ([_notesToSave]).
  final List<_NoteStep> _noteSteps = [];
  int _noteStepIds = 0;

  /// The notes kept on the meal as loaded (analysis.user_notes, oldest
  /// first), and the ones the user removed this visit (by position): an
  /// unsaved change until Save.
  List<MealNote> _storedNotes = const [];
  final Set<int> _removedNotes = {};

  /// What the last build showed: a note typed (Send enabled, back asks)
  /// and Undo offered.
  bool _shownNoteTyped = false;
  bool _shownNoteUndo = false;

  /// The note's field with its footer and Correct with AI (one block),
  /// the button itself, and Save, as laid out ([_revealNote]).
  final GlobalKey _noteBlockBox = GlobalKey();
  final GlobalKey _noteSendBox = GlobalKey();
  final GlobalKey _saveButtonBox = GlobalKey();

  /// The keyboard's height at the last metrics change, and a reveal already
  /// waiting for the frame ([_scheduleNoteReveal]).
  double _lastBottomInset = 0;
  bool _noteRevealScheduled = false;

  @override
  void initState() {
    super.initState();
    final clock = widget.now ?? DateTime.now;
    final meal = widget.meal;
    final photo = widget.fromPhoto;
    // A describe preview's reply is no evidence that a chain published
    // anything or that the user set a number (design R6a, usual foods
    // D25): its claims go before the form is built, so the only marks a
    // new meal is saved with are this session's own.
    final prefill = _withoutClaims(widget.initialAnalysis);
    // The photo's capture moment in the zone it was TAKEN in — the same
    // clock the automatic pipeline dates by, so a manual log of a photo
    // from before a flight agrees with an automatic one.
    final captured = photo?.capturedAt;
    final shot = (photo == null || captured == null)
        ? null
        : captureWallClock(captured, exifWallAndOffset(photo.bytes));
    _draft = meal != null
        ? MealDraft.fromMeal(meal)
        : (prefill != null
            // Describe-by-text preview: load the model's estimate into the
            // form. The synthetic row exists only to reuse the draft loader;
            // widget.meal stays null, so saving INSERTS.
            ? MealDraft.fromMeal(Meal(
                id: 0,
                date: shot != null
                    ? isoDate(shot)
                    : (widget.initialDate ?? isoDate(clock())),
                time: shot != null ? formatClock(shot) : formatClock(clock()),
                timestamp: clock().toIso8601String(),
                source: widget.newMealSource,
                analysis: prefill,
              ))
            : (MealDraft.blank(clock())
              // A photo's own capture moment beats "now" for a manual log.
              ..dateIso = shot != null
                  ? isoDate(shot)
                  : (widget.initialDate ?? MealDraft.blank(clock()).dateIso)
              ..time = shot != null
                  ? formatClock(shot)
                  : MealDraft.blank(clock()).time));
    _desc = TextEditingController(text: _draft.description)
      ..addListener(_watchDirty);
    _cal = TextEditingController(text: _draft.calories);
    _pro = TextEditingController(text: _draft.protein);
    _carb = TextEditingController(text: _draft.carbs);
    _fat = TextEditingController(text: _draft.fat);
    for (final it in _draft.items) {
      _itemCtrls.add(_controllersFor(it));
    }
    // Live macro chart: rebuild as the user types.
    for (final c in [_cal, _pro, _carb, _fat]) {
      c.addListener(_syncTotals);
      c.addListener(_watchDirty);
    }
    _meal = meal;
    _storedNotes = readUserNotes(meal?.analysis);
    _note.addListener(_watchDirty);
    _noteFocus.addListener(() {
      if (_noteFocus.hasFocus) _scheduleNoteReveal();
    });
    WidgetsBinding.instance.addObserver(this);
    // What the form opened with, a new meal's included: a back gesture
    // asks before it drops anything typed since ([_unsaved]).
    _loadedSignature = _signature();
    if (meal != null) {
      _hold = widget.inUse?.acquire(meal.id);
      _readBasis();
      widget.mealsChanged?.addListener(_onMealsChanged);
      // Opened: the card's 'updated' dot goes (design R7b).
      final seen = widget.assist?.markSeen;
      if (seen != null) {
        seen(meal.id).then((_) {}, onError: (Object _) {});
      }
      _refreshUsual();
    }
  }

  @override
  void didUpdateWidget(MealEditorScreen old) {
    super.didUpdateWidget(old);
    if (old.mealsChanged != widget.mealsChanged && widget.meal != null) {
      old.mealsChanged?.removeListener(_onMealsChanged);
      widget.mealsChanged?.addListener(_onMealsChanged);
    }
  }

  /// Some meal changed while the editor is open; it may be this one (an
  /// Undo tapped on the snackbar over the editor). The row is read again
  /// ([_refreshBasis]): an untouched form shows the meal as stored, a
  /// typed-over one gets the save's conflict, an unchanged row only
  /// renews the basis. Skipped while a save, one of the cards' writes or
  /// a note is under way: each reads the row again itself when it is done.
  void _onMealsChanged() {
    if (!mounted || _meal == null) return;
    if (_saving || _usualBusy || _assistBusy || _lookingUp) return;
    if (_correcting || _noteAsking) return;
    _refreshBasis();
  }

  /// Starts [_confirmBasis] as [_basisRead], the read a save waits for.
  /// The handle is cleared only by the read it names: with two reads
  /// under way, the first to finish must not leave a save waiting on
  /// nothing while the newer one still runs.
  Future<void> _readBasis() {
    late final Future<void> read;
    read = _confirmBasis().whenComplete(() {
      if (identical(_basisRead, read)) _basisRead = null;
    });
    _basisRead = read;
    return read;
  }

  /// A text edit that makes the form dirty (or clean again) rebuilds it:
  /// the cards' buttons wait while there is unsaved typing, a back gesture
  /// asks before it drops it, the note's Send waits for a note, and Undo
  /// goes once the form no longer shows what the note did.
  void _watchDirty() {
    if (_loading || !mounted) return;
    if (_dirty != _shownDirty ||
        _unsaved != _shownUnsaved ||
        _noteTyped != _shownNoteTyped ||
        _noteUndoAvailable != _shownNoteUndo) {
      setState(() {});
    }
  }

  /// A copy of [analysis] without the assist block, published flags and
  /// user marks a model may have written ([dropAssistClaims]).
  static Map<String, dynamic>? _withoutClaims(Map<String, dynamic>? analysis) {
    if (analysis == null) return null;
    final copy = Map<String, dynamic>.from(analysis);
    dropAssistClaims(copy);
    return copy;
  }

  /// Everything the form shows, as one string: unchanged while the user has
  /// typed nothing since the last load.
  String _signature() => [
        _desc.text,
        _cal.text,
        _pro.text,
        _carb.text,
        _fat.text,
        _draft.dateIso,
        _draft.time,
        for (final r in _itemCtrls) ...[
          r.name.text,
          r.cal.text,
          r.pro.text,
          r.carb.text,
          r.fat.text,
        ],
      ].join('\u0000');

  static String? _analysisText(Map<String, dynamic> analysis) {
    try {
      return jsonEncode(finiteAnalysis(analysis));
    } catch (_) {
      return null;
    }
  }

  /// [stored] is the meal [shown] was: same day, clock and analysis.
  static bool _sameBasis(Meal stored, Meal shown) {
    if (stored.date != shown.date || stored.time != shown.time) return false;
    final a = _analysisText(stored.analysis);
    return a != null && a == _analysisText(shown.analysis);
  }

  /// Reads the stored row behind the form (design R6a). Still the meal the
  /// form shows: its raw text becomes the save's compare-and-set basis. A
  /// newer row while nothing was typed and no save is under way: the form
  /// shows it instead (the list was a moment stale). A newer row the user
  /// is already typing over or saving, or a meal that is gone: the save
  /// answers with the conflict dialog. A failed read leaves the basis
  /// unknown; the save reads again.
  Future<void> _confirmBasis() async {
    final shown = _meal;
    if (shown == null) return;
    final MealSnapshot? snap;
    try {
      snap = await widget.dao.mealSnapshot(shown.id);
    } catch (_) {
      return;
    }
    if (!mounted || !identical(shown, _meal)) return;
    if (snap == null) {
      _basisStale = true;
    } else if (_sameBasis(snap.meal, shown)) {
      _draft.expectedRaw = snap.rawAnalysis;
    } else if (!_saving && !_formChanged) {
      _load(snap);
      setState(() {});
    } else {
      _basisStale = true;
    }
  }

  /// The form, rebuilt from [snap]: the draft, every field and the item
  /// rows, with [snap]'s raw text as the save's basis. The notes this
  /// visit filled the form with are gone with the older form; the last
  /// one goes back into an empty note field, to be sent again. A note in
  /// the field now counts as unsent ([_noteUnsent]): the meal shown holds
  /// nothing of it, so Save asks first.
  void _load(MealSnapshot snap) {
    _meal = snap.meal;
    _showDraft(
        MealDraft.fromMeal(snap.meal)..expectedRaw = snap.rawAnalysis);
    _basisStale = false;
    _loadedSignature = _signature();
    _storedNotes = readUserNotes(snap.meal.analysis);
    _removedNotes.clear();
    if (_noteSteps.isNotEmpty) {
      if (_note.text.trim().isEmpty) _note.text = _noteSteps.last.note;
      _noteSteps.clear();
    }
    _sentNotes.clear();
    _refreshUsual();
  }

  /// Shows [draft] in the form: every field and the item rows, rebuilt
  /// ([_load]'s field half). The basis, the loaded signature and [_meal]
  /// stay: what it shows counts as unsaved typing.
  void _showDraft(MealDraft draft) {
    for (final row in _itemCtrls) {
      row.name.dispose();
      row.cal.dispose();
      row.pro.dispose();
      row.carb.dispose();
      row.fat.dispose();
    }
    _itemCtrls.clear();
    // The total fields' listener (_syncTotals) copies all four into the
    // draft. Unmuted, setting kcal first copied the macros the form still
    // showed from the OLDER meal over the fresh draft's, so after an
    // accept (or Use AI estimate, a manual lookup, a conflict reload) the
    // form read the new kcal over the old macros, and Save wrote them.
    _loading = true;
    try {
      _desc.text = draft.description;
      _cal.text = draft.calories;
      _pro.text = draft.protein;
      _carb.text = draft.carbs;
      _fat.text = draft.fat;
    } finally {
      _loading = false;
    }
    _draft = draft;
    for (final it in draft.items) {
      _itemCtrls.add(_controllersFor(it));
    }
  }

  ({TextEditingController name, TextEditingController cal,
      TextEditingController pro, TextEditingController carb,
      TextEditingController fat}) _controllersFor(MealItemDraft it) {
    final row = (
      name: TextEditingController(text: it.name)..addListener(_watchDirty),
      cal: TextEditingController(text: it.calories),
      pro: TextEditingController(text: it.protein),
      carb: TextEditingController(text: it.carbs),
      fat: TextEditingController(text: it.fat),
    );
    // Totals are DERIVED from the items (user decision 2026-08-06):
    // editing any item number moves the meal total in the same frame,
    // so a deleted or corrected row can never leave a stale total.
    for (final c in [row.cal, row.pro, row.carb, row.fat]) {
      c.addListener(_recomputeTotalsFromItems);
      // An edit that leaves the total as it was ('0100' for '100') still
      // counts as typing for the back question.
      c.addListener(_watchDirty);
    }
    return row;
  }

  /// True when the totals are owned by the item rows. With no items the
  /// totals stay hand-editable — that is the manual-entry path.
  bool get _totalsDerived => _draft.items.isNotEmpty;

  /// Push the item sum into the total fields. Silent on the no-item path,
  /// and guarded against the listener loop (_cal's own listener fires
  /// _syncTotals, never this).
  /// [afterRemoval] lets the LAST item's deletion zero the totals.
  /// Without it the guard below trips — the row is already gone, so
  /// `_totalsDerived` is false — and the meal keeps the totals of an item
  /// that no longer exists (found on-device 2026-08-17: deleting the only
  /// item of a 350 kcal meal left the totals reading 350). The guard still
  /// protects a meal that never had an item breakdown, where hand-typed
  /// totals are the only source of truth.
  void _recomputeTotalsFromItems({bool afterRemoval = false}) {
    if (!_totalsDerived && !afterRemoval) return;
    for (var i = 0; i < _draft.items.length && i < _itemCtrls.length; i++) {
      final c = _itemCtrls[i];
      _draft.items[i]
        ..name = c.name.text
        ..calories = c.cal.text
        ..protein = c.pro.text
        ..carbs = c.carb.text
        ..fat = c.fat.text;
    }
    final t = _draft.itemTotals();
    final next = [
      _plain(t.calories.clamp(0, maxMealCalories)),
      _plain(t.protein.clamp(0, maxMacroGrams)),
      _plain(t.carbs.clamp(0, maxMacroGrams)),
      _plain(t.fat.clamp(0, maxMacroGrams)),
    ];
    final ctrls = [_cal, _pro, _carb, _fat];
    for (var i = 0; i < ctrls.length; i++) {
      // Assign only on CHANGE: an unconditional write would move the
      // caret and re-enter through the controller's own listener.
      if (ctrls[i].text != next[i]) ctrls[i].text = next[i];
    }
  }

  @override
  void dispose() {
    widget.mealsChanged?.removeListener(_onMealsChanged);
    _hold?.release();
    _scroll.dispose();
    for (final c in [_desc, _cal, _pro, _carb, _fat, _note]) {
      c.dispose();
    }
    _noteFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    for (final row in _itemCtrls) {
      row.name.dispose();
      row.cal.dispose();
      row.pro.dispose();
      row.carb.dispose();
      row.fat.dispose();
    }
    super.dispose();
  }

  void _syncTotals() {
    if (_loading) return;
    setState(() {
      _draft.calories = _cal.text;
      _draft.protein = _pro.text;
      _draft.carbs = _carb.text;
      _draft.fat = _fat.text;
    });
  }

  void _harvest() {
    _draft.description = _desc.text;
    _draft.calories = _cal.text;
    _draft.protein = _pro.text;
    _draft.carbs = _carb.text;
    _draft.fat = _fat.text;
    for (var i = 0; i < _draft.items.length; i++) {
      final c = _itemCtrls[i];
      _draft.items[i]
        ..name = c.name.text
        ..calories = c.cal.text
        ..protein = c.pro.text
        ..carbs = c.carb.text
        ..fat = c.fat.text;
    }
  }

  Future<void> _save() async {
    // Not while a note is being answered: a save now would drop the answer
    // in silence (the button is disabled meanwhile too).
    if (_saving || _correcting) return;
    // A note typed and never sent: a save never sends it, so say so first.
    if (_noteUnsent && await _confirmUnsentNote() != true) return;
    if (!mounted || _saving || _correcting) return;
    // The open-time read decides what this save compares against: wait for
    // it (milliseconds). Landing now, a newer row no longer replaces the
    // form — the user pressed Save on what they saw — it is a conflict.
    final basis = _basisRead;
    if (basis != null) {
      // Also the re-entry guard, and built: a back gesture meanwhile is a
      // save under way, not a question (DiscardChangesGuard busy).
      setState(() => _saving = true);
      try {
        await basis;
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      if (!mounted) return;
    }
    _harvest();
    final errors = _draft.validate(context.l10n);
    if (errors.isNotEmpty) {
      await _showErrors(errors);
      return;
    }
    setState(() {
      _errors = const [];
      _saving = true;
    });
    try {
      // The marks of the rows changed here (usual foods §3.1) carry the
      // editor's clock. The meal's notes change only when this visit
      // changed them ([_notesToSave]).
      final analysis = _draft.toAnalysis(
          now: (widget.now ?? DateTime.now)(), notes: _notesToSave());
      if (widget.isNew) {
        final photo = widget.fromPhoto;
        // How the photo was taken (design G2a), from the intake's reading
        // of its bytes — never from a model's preview — as the automatic
        // pipeline stores it. Nor an assist block or a published flag a
        // describe preview's model wrote (design R6a): only a verified
        // restaurant lookup writes those. The rows' user marks stay: the
        // prefill lost the model's when the editor opened, so these are
        // the numbers the user set in this session (usual foods D25).
        analysis.remove('capture');
        dropAssistClaims(analysis, keepUserMarks: true);
        final capture = photo?.capture;
        if (capture != null) analysis['capture'] = captureAnalysis(capture);
        // md5 of the ORIGINAL bytes: the same identity the watcher uses, so
        // marking the ledger 'saved' stops this photo being re-offered
        // forever (spec §6.2/§2.3).
        final hash = photo == null
            ? ''
            : normalizeImageHash(md5.convert(photo.bytes).toString());
        final result = await widget.dao.saveMealWithOutcome(
          Meal(
            id: 0, // assigned on insert
            date: _draft.dateIso.trim(),
            time: _draft.time.trim(),
            timestamp: (widget.now ?? DateTime.now)().toIso8601String(),
            // Photo-backed manual logs keep their own source; otherwise the
            // caller decides ('manual_text' for describe-by-text, server
            // parity spec §4.6; 'app_manual' for a hand-typed meal).
            source: photo == null
                ? widget.newMealSource
                : MealSource.appManualPhoto,
            imageHash: hash,
            fileId: photo?.assetId ?? '',
            analysis: analysis,
          ),
          markStatus: photo == null ? null : IngestionStatus.saved,
        );
        if (!result.inserted) {
          // The meals-table backstop: this photo already has a meal (a
          // background scan or an import settled it while the editor was
          // open) and the typed numbers were NOT written. Say so instead of
          // closing as a plain success, and go back with true so the add
          // flow closes too — Today then shows the meal that IS logged,
          // which is where the snackbar sends the user to edit it.
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              key: const Key('editorPhotoAlreadyLogged'),
              content: Text(context.l10n.editorPhotoAlreadyLogged)));
          Navigator.of(context).pop(true);
          return;
        }
        if (photo != null && widget.makeThumb != null) {
          try {
            final thumb = await widget.makeThumb!(photo.bytes);
            if (thumb != null) {
              await widget.dao.saveMealThumb(result.id, thumb);
            }
          } catch (_) {
            // A missing thumb is cosmetic; the meal is already saved.
          }
        }
      } else if (!await _saveExisting(analysis)) {
        if (!mounted) return;
        await _conflict();
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(true); // changed
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errors = [context.l10n.editorSaveFailed('$e')];
      });
    }
  }

  /// The form's [errors], shown as Save shows them: the error card, a
  /// snackbar where the finger is, and a scroll to the top.
  Future<void> _showErrors(List<String> errors) async {
    setState(() => _errors = errors);
    // The error card is the FIRST list child while Save is a pinned FAB:
    // on a scrolled form the rejection would be invisible and Save would
    // look like a dead button. Say it where the finger is, then scroll.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(errors.length == 1
            ? errors.single
            : context.l10n.editorErrsNeedFixing(errors.length))));
    if (_scroll.hasClients) {
      await _scroll.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  /// The compare-and-set save of a stored meal (design R6a). False — nothing
  /// written — when the row changed since the form was loaded, is gone, or
  /// the basis could not be read.
  Future<bool> _saveExisting(Map<String, dynamic> analysis) async {
    final meal = _meal!;
    if (_basisStale) return false;
    if (_draft.expectedRaw == null) {
      // The open-time read failed: try once more (typing since then means a
      // newer row cannot replace the form — it becomes a conflict).
      await _confirmBasis();
      if (!mounted) return false;
    }
    final raw = _draft.expectedRaw;
    if (raw == null || _basisStale) return false;
    return widget.dao.updateMealFieldsIfUnchanged(
      meal.id,
      expectedRaw: raw,
      analysis: analysis,
      date: _draft.dateIso.trim(),
      time: _draft.time.trim(),
    );
  }

  /// The meal changed while the editor was open: say so, then show it as
  /// it is now. The user's typed changes are not written over the newer
  /// meal; they redo them on the fresh form. A meal deleted meanwhile
  /// closes the editor.
  Future<void> _conflict() async {
    // The spinner stops before the dialog (an animating FAB behind a modal
    // never settles), and until the reload below every save is this
    // conflict again.
    setState(() {
      _saving = false;
      _basisStale = true;
    });
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('editorSaveConflict'),
        content: Text(ctx.l10n.editorSaveConflict),
        actions: [
          TextButton(
              key: const Key('editorSaveConflictOk'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(ctx.l10n.okButton)),
        ],
      ),
    );
    if (!mounted) return;
    final MealSnapshot? snap;
    try {
      snap = await widget.dao.mealSnapshot(_meal!.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors = [context.l10n.editorSaveFailed('$e')]);
      return;
    }
    if (!mounted) return;
    if (snap == null) {
      Navigator.of(context).pop(true);
      return;
    }
    _load(snap);
    setState(() => _errors = const []);
  }

  // ── The restaurant source card (design R7b) ──

  /// The form changed since the last load: something typed or picked, a
  /// note's correction, or a kept note removed.
  bool get _formChanged =>
      _signature() != _loadedSignature || _removedNotes.isNotEmpty;

  /// The form shows something the user typed since the last load.
  bool get _dirty => _meal != null && _formChanged;

  /// Like [_dirty], for a new meal too (manual entry, a describe preview,
  /// a refused photo): something typed or picked since the editor opened
  /// or last loaded, or a note typed. A back gesture asks before it drops
  /// that.
  bool get _unsaved => _formChanged || _noteTyped;

  /// One of the cards' own writes is running: a lookup the user started
  /// (polled for up to [kAssistPollWindow] on the owner's server), an
  /// answer to the source card, or Use my numbers. The form is read-only
  /// meanwhile. It was open before: typing during a lookup made the
  /// lookup's write land under it, nothing was said or shown, and the
  /// next Save answered "This meal was just updated" and threw the typing
  /// away.
  /// A note's request in flight locks it the same way: its answer fills
  /// the form, so typing meanwhile would be thrown away.
  bool get _formLocked =>
      _lookingUp || _assistBusy || _usualBusy || _correcting;

  bool get _assistOn =>
      widget.settings != null && widget.settings!.restaurantAssist != 'off';

  /// The app has left the foreground (unknown counts as foreground).
  static bool _inBackground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  void _say(String text, {Key? key}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(key: key, content: Text(text)));
  }

  /// Re-reads the row behind the form after an assist write: an untouched
  /// form shows the newer meal; typing over an older copy becomes the
  /// save's conflict ([_confirmBasis]).
  Future<void> _refreshBasis() async {
    await _readBasis();
    if (mounted) setState(() {});
    _refreshUsual();
  }

  // ── Your usual numbers (usual foods §3.4-§3.6) ──

  /// Works the offer out again for the meal the form shows. Fire and
  /// forget: a reply for an older meal is dropped, and a failure shows no
  /// card. A different meal hides the old card at once.
  void _refreshUsual() {
    final usual = widget.usual;
    final meal = _meal;
    if (usual == null || meal == null) return;
    final gen = ++_usualGen;
    if (!identical(meal, _usualFor)) {
      _usualOffer = null;
      _usualFor = meal;
    }
    Future<UsualOffer?> offer;
    try {
      offer = usual.offerFor(meal);
    } catch (_) {
      return;
    }
    offer.then((o) {
      if (!mounted || gen != _usualGen || !identical(meal, _meal)) return;
      setState(() => _usualOffer = o);
    }, onError: (Object _) {
      if (!mounted || gen != _usualGen) return;
      setState(() => _usualOffer = null);
    });
  }

  /// Use my numbers: every offered food at once, through the compare-and-
  /// set against the stored text the form shows (nothing changes without
  /// this tap). The snackbar says the meal's totals and has Undo. Past
  /// midnight the card goes quietly.
  Future<void> _useUsual() async {
    final usual = widget.usual;
    final meal = _meal;
    final offer = _usualOffer;
    if (usual == null || meal == null || offer == null) return;
    if (_usualBusy || _assistBusy || _saving || _lookingUp || _correcting) {
      return;
    }
    final l = context.l10n;
    if (_dirty) {
      _say(l.assistEditFirst, key: const Key('assistEditFirstSnack'));
      return;
    }
    // Past midnight the meal is no longer today's and is offered nothing:
    // the card goes, and nothing is said (the meal did not change).
    if (meal.date != isoDate((widget.now ?? DateTime.now)())) {
      setState(() {
        _usualOffer = null;
        _usualGen++; // a reply still on its way must not bring it back
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _usualBusy = true);
    UsualAcceptStatus status = UsualAcceptStatus.conflict;
    UsualAcceptResult? result;
    try {
      final basis = _basisRead;
      if (basis != null) await basis;
      final raw = _draft.expectedRaw;
      if (!mounted) return;
      if (raw != null && !_basisStale && identical(meal, _meal)) {
        result = await usual.accept(meal.id, shown: offer, expectedRaw: raw);
        status = result.status;
      }
    } catch (_) {
      status = UsualAcceptStatus.conflict;
    } finally {
      if (mounted) setState(() => _usualBusy = false);
    }
    if (!mounted) return;
    switch (status) {
      case UsualAcceptStatus.written:
        // The offer is used: the card goes now, not when the form has
        // reloaded, so a second tap in between has nothing to use.
        setState(() {
          _usualOffer = null;
          _usualGen++;
        });
        await _refreshBasis();
        showUsualUsedSnack(messenger, l, usual, result!, onUndone: () {
          if (mounted) _refreshBasis();
        });
      case UsualAcceptStatus.busy:
        return;
      case UsualAcceptStatus.conflict:
      case UsualAcceptStatus.gone:
        await _assistConflict();
    }
  }

  /// Keep AI estimate: the offer is turned down for this meal (two on
  /// different meals mute the food). The meal is not written.
  Future<void> _keepAi() async {
    final usual = widget.usual;
    final offer = _usualOffer;
    if (usual == null || offer == null || _usualBusy) return;
    setState(() => _usualBusy = true);
    try {
      await usual.decline(offer);
    } catch (_) {
      // The card goes either way: the user chose the AI estimate.
    }
    if (!mounted) return;
    setState(() {
      _usualBusy = false;
      _usualOffer = null;
      _usualGen++; // a reply still on its way must not bring it back
    });
  }

  /// The usual-numbers card, or null when nothing is offered.
  Widget? _usualSection(bool dirty) {
    final offer = _usualOffer;
    if (offer == null || widget.usual == null || _meal == null) return null;
    return UsualOfferCard(
      offer: offer,
      busy: _usualBusy || _assistBusy || _saving || _lookingUp || _correcting,
      editFirst: dirty,
      onUse: _useUsual,
      onKeepAi: _keepAi,
    );
  }

  /// The meal changed under an answer: say so, show the meal as it is now.
  Future<void> _assistConflict({Key key = const Key('assistConflict')}) async {
    _say(context.l10n.editorSaveConflict, key: key);
    final MealSnapshot? snap;
    try {
      snap = await widget.dao.mealSnapshot(_meal!.id);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (snap == null) {
      Navigator.of(context).pop(true);
      return;
    }
    _load(snap);
    setState(() {});
  }

  /// One of the source card's answers, written at once against the stored
  /// text the form shows. 'Wrong restaurant' then asks which chain it was
  /// and looks that one up (mode on).
  Future<void> _assistAct(AssistUserAction action) async {
    final meal = _meal;
    final act = widget.assist?.act;
    if (meal == null || act == null) return;
    if (_assistBusy || _saving || _lookingUp || _correcting) return;
    final l = context.l10n;
    if (_dirty) {
      _say(l.assistEditFirst, key: const Key('assistEditFirstSnack'));
      return;
    }
    final view = AssistView.of(meal.analysis);
    // A shared plate, a combo, an unclear size or unit: the published
    // numbers may not be what was eaten, so the user sees the new total
    // and confirms first.
    if (action == AssistUserAction.acceptSuggestion &&
        view.acceptNeedsConfirm &&
        await _confirmAccept(meal, view) != true) {
      return;
    }
    if (!mounted || !identical(meal, _meal)) return;
    setState(() => _assistBusy = true);
    AssistActionResult result;
    try {
      final basis = _basisRead;
      if (basis != null) await basis;
      final raw = _draft.expectedRaw;
      if (!mounted) return;
      if (raw == null || _basisStale || !identical(meal, _meal)) {
        result = const AssistActionResult(AssistActionStatus.changed);
      } else {
        result = await act(meal.id, action, expectedRaw: raw);
      }
    } finally {
      if (mounted) setState(() => _assistBusy = false);
    }
    if (!mounted) return;
    if (result.status == AssistActionStatus.changed) {
      await _assistConflict();
      return;
    }
    await _refreshBasis();
    if (!mounted) return;
    if (result.status == AssistActionStatus.done) {
      if (action == AssistUserAction.notFromRestaurant) {
        _say(l.assistNotRestaurantDone, key: const Key('assistDoneSnack'));
      } else if ((action == AssistUserAction.correct ||
              action == AssistUserAction.acceptSuggestion) &&
          result.placeLearned) {
        // Never a silent confirmation: the spot is remembered.
        _say(l.assistCorrectDone(view.brandLabel(l)),
            key: const Key('assistDoneSnack'));
      }
    }
    if (action == AssistUserAction.wrongRestaurant &&
        _assistOn &&
        widget.assist?.lookupNow != null &&
        _pickSendable()) {
      final pick = await showChainPickerSheet(context, exclude: view.chainKey);
      if (pick != null && mounted) await _lookUp(chainKey: pick);
    }
  }

  /// A chain the user picks can be looked up: not to the owner's server
  /// over http, whose https gate sends printed brands only (the pick is
  /// neither), and not where lookups cannot run at all.
  bool _pickSendable() {
    try {
      final support = widget.assist!.lookupSupport();
      return support.supported && support.locationAllowed;
    } catch (_) {
      return false;
    }
  }

  /// 'Use published numbers' on a suggestion whose numbers may not fit what
  /// was eaten: why, and the meal's total after it. True to go on.
  Future<bool?> _confirmAccept(Meal meal, AssistView view) {
    final l = context.l10n;
    final clock = widget.now ?? DateTime.now;
    final after = acceptAssistSuggestion(meal.analysis, now: clock());
    final total = after?['total_calories'];
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('assistAcceptConfirm'),
        // The title, why and the new total scroll together above the
        // buttons: not scrollable, from the third accessibility text size
        // the total was cut off (or its box squeezed to nothing), and at
        // the largest one on a 320 pt phone the confirm button was below
        // the screen.
        scrollable: true,
        title: Text(l.assistAcceptTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (view.whyText(l) case final why?) Text(why),
            if (total is num) ...[
              const SizedBox(height: 8),
              Text(l.assistAcceptTotal(formatKcal(total))),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel)),
          FilledButton(
              key: const Key('assistAcceptConfirmOk'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.assistUsePublished)),
        ],
      ),
    );
  }

  /// 'Look up restaurant nutrition' (or the chain picked after 'Wrong
  /// restaurant'): the consent first when it does not name the current
  /// recipient, then MealAssist.lookupNow — asked again every
  /// [MealEditorScreen.assistPollInterval] while the owner's server still
  /// runs it, for up to [kAssistPollWindow] (later, the sweep collects it).
  ///
  /// [fresh] is Search again (usual foods §2.4): the provider is asked,
  /// never a saved lookup answer. The press right after a saved answer
  /// was used is fresh too ([_freshNext], D9).
  Future<void> _lookUp({String? chainKey, bool fresh = false}) async {
    final meal = _meal;
    final assist = widget.assist;
    final settings = widget.settings;
    final lookupNow = assist?.lookupNow;
    if (meal == null || assist == null || settings == null) return;
    if (lookupNow == null ||
        _lookingUp ||
        _assistBusy ||
        _saving ||
        _correcting) {
      return;
    }
    final l = context.l10n;
    if (_dirty) {
      _say(l.assistEditFirst, key: const Key('assistEditFirstSnack'));
      return;
    }
    final choice = await restaurantManualLookupChoice(context,
        settings: settings, controls: assist);
    if (choice == null || !mounted) return;
    final useLocation = chainKey == null && choice.useLocation;
    // One answer for every poll of this press: a pending fresh search is
    // never answered by the saved answer it is replacing.
    final f = fresh || _freshNext;
    // The block before this lookup, for what a fresh search over applied
    // numbers or a suggestion says when it writes nothing.
    final before = meal.analysis;
    final beforeKind = AssistView.of(before).kind;
    // The form goes read-only; a field left focused would bring the
    // keyboard back up when the lookup ends.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _lookingUp = true);
    var run = const AssistRun(AssistSkip.error);
    try {
      final tries = kAssistPollWindow.inMicroseconds ~/
              widget.assistPollInterval.inMicroseconds +
          1;
      for (var i = 0; i < tries; i++) {
        if (i > 0) {
          await Future<void>.delayed(widget.assistPollInterval);
          if (!mounted) return;
          // Foreground only: in the background the server's job is left
          // to the sweep, which collects it when the app is back.
          if (_inBackground()) {
            run = const AssistRun(AssistSkip.background);
            break;
          }
        }
        run = await lookupNow(meal.id,
            useLocation: useLocation, chainKey: chainKey, fresh: f);
        if (!mounted) return;
        // Pending on the server, or the automatic lookup of this meal
        // still running here (its result is dropped: the editor holds the
        // meal): asked again shortly.
        if (run.code != AssistSkip.pending && run.code != AssistSkip.working) {
          break;
        }
      }
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
    _freshNext = run.fromCache;
    if (!mounted) return;
    if (run.wrote) {
      await _refreshBasis();
      if (!mounted) return;
      if (run.fromCache) {
        // Never "used": on Claude Plan a saved answer is a suggestion.
        final on = run.decision?.fetchedOn ??
            AssistView.of((_meal ?? meal).analysis).fetchedOn;
        _say(l.assistFoundSaved(on), key: const Key('assistFoundSavedSnack'));
      }
      return;
    }
    if (run.code == AssistSkip.casMiss) {
      _say(l.editorSaveConflict, key: const Key('assistConflict'));
      await _refreshBasis();
      return;
    }
    final message = manualLookupMessage(l, run,
        fresh: f, beforeKind: beforeKind, before: before);
    if (message != null) {
      _say(message, key: const Key('assistLookupSnack'));
    }
  }

  /// Opens the source page: only a normalized https address, in the
  /// browser.
  Future<void> _openSource(String url) async {
    if (normalizeSourceUrl(url) != url) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;
    final open = widget.openUrl ??
        (u) => launcher.launchUrl(u,
            mode: launcher.LaunchMode.externalApplication);
    try {
      await open(uri);
    } catch (_) {}
  }

  /// The source card for the stored meal, or null when there is nothing to
  /// show or do.
  Widget? _assistSection() {
    final meal = _meal;
    final assist = widget.assist;
    if (meal == null || assist == null) return null;
    final view = AssistView.of(meal.analysis);
    var supported = false;
    // Off never asks who a lookup would reach (that builds the lookup
    // client).
    if (_assistOn) {
      try {
        supported = assist.lookupSupport().supported;
      } catch (_) {}
    }
    final photoMeal = meal.source == MealSource.appWatch ||
        meal.source == MealSource.appPhoto;
    final canLookUp = _assistOn &&
        supported &&
        photoMeal &&
        assist.lookupNow != null &&
        isFoodTruthy(meal.analysis['is_food']);
    final act = assist.act;
    if (!view.hasSource &&
        view.kind != AssistViewKind.contextOnly &&
        !canLookUp &&
        !_lookingUp) {
      return null;
    }
    var canLearn = false;
    try {
      canLearn = assist.canLearnPlace?.call(meal) ?? false;
    } catch (_) {}
    VoidCallback? answer(AssistUserAction a) =>
        act == null ? null : () => _assistAct(a);
    return AssistSourceCard(
      key: const Key('editorAssistCard'),
      view: view,
      busy: _assistBusy || _saving || _correcting,
      lookingUp: _lookingUp,
      editFirst: _dirty,
      onUseEstimate: answer(AssistUserAction.useEstimate),
      onAccept: answer(AssistUserAction.acceptSuggestion),
      onWrongRestaurant: answer(AssistUserAction.wrongRestaurant),
      onNotRestaurant: answer(AssistUserAction.notFromRestaurant),
      // Correct teaches the spot, so only where the place step named the
      // chain there: a printed brand says nothing about where it was eaten.
      onCorrect: canLearn && view.namedByPlace
          ? answer(AssistUserAction.correct)
          : null,
      onLookUp: canLookUp ? () => _lookUp() : null,
      // On a block decided on a saved lookup answer (the card shows it
      // only there): a fresh lookup.
      onSearchAgain: canLookUp ? () => _lookUp(fresh: true) : null,
      onOpenSource: _openSource,
    );
  }

  // ── Correct with a note (core/meal_correction.dart) ──

  /// The note is offered on a stored meal, opened with the settings and a
  /// corrector (Today and History › day): never on a new meal.
  bool get _noteOffered =>
      !widget.isNew &&
      widget.settings != null &&
      widget.noteCorrector != null &&
      _meal != null;

  bool get _noteTyped => _note.text.trim().isNotEmpty;

  /// Each note sent about the form shown, as sent ([cleanMealNote]);
  /// cleared when the form is reloaded ([_load]).
  final Set<String> _sentNotes = {};

  /// A note in the field that was never sent: Save asks first.
  bool get _noteUnsent =>
      _noteOffered &&
      _noteTyped &&
      !_sentNotes.contains(cleanMealNote(_note.text));

  /// Something else is under way: no note starts.
  bool get _noteBusy =>
      _saving ||
      _assistBusy ||
      _usualBusy ||
      _lookingUp ||
      _correcting ||
      _noteAsking;

  /// Undo is offered while the form shows exactly what the last note left
  /// (so it never throws away typing done since) and is not locked.
  bool get _noteUndoAvailable =>
      _noteSteps.isNotEmpty &&
      !_formLocked &&
      _signature() == _noteSteps.last.afterSignature;

  /// Whether the form still holds a change [step] made (call after
  /// [_harvest]).
  bool _holds(_NoteStep step) => _draft.holdsNote(step.id,
      removed: step.removed,
      removedFrom: step.before,
      descBefore: step.descBefore,
      totalsBefore: step.totalsBefore);

  /// The notes a correction is sent with as already applied: the kept
  /// ones the user did not remove, then this visit's whose changes the
  /// form still holds, oldest first (call after [_harvest]).
  List<String> _earlierNotes() => [
        for (var i = 0; i < _storedNotes.length; i++)
          if (!_removedNotes.contains(i)) _storedNotes[i].text,
        for (final s in _noteSteps)
          if (_holds(s)) s.note,
      ];

  /// The meal's notes this save writes, or null to keep them as stored:
  /// the kept ones the user did not remove, then those of this visit's
  /// corrections the saved form still holds (one undone in the form, or
  /// never answered with a usable correction, is not kept). Call after
  /// [_harvest].
  List<MealNote>? _notesToSave() {
    if (_meal == null) return null;
    final held = [
      for (final s in _noteSteps)
        if (_holds(s)) MealNote(s.note, s.sentAt),
    ];
    if (held.isEmpty && _removedNotes.isEmpty) return null;
    return [
      for (var i = 0; i < _storedNotes.length; i++)
        if (!_removedNotes.contains(i)) _storedNotes[i],
      ...held,
    ];
  }

  /// Save with a note that was never sent: Keep editing (false) or Save
  /// anyway (true).
  Future<bool?> _confirmUnsentNote() => showDialog<bool>(
        context: context,
        builder: (ctx) {
          final l = ctx.l10n;
          return appAlertDialog(
            key: const Key('mealNoteUnsentDialog'),
            title: Text(l.mealNoteUnsentTitle),
            content: Text(l.mealNoteUnsentBody),
            actions: [
              TextButton(
                  key: const Key('mealNoteUnsentKeep'),
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l.discardChangesKeep)),
              FilledButton(
                  key: const Key('mealNoteUnsentSave'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(l.mealNoteUnsentSave)),
            ],
          );
        },
      );

  /// After the frame, scrolls the note's section to the top of the form,
  /// so its field, the button and the answer under them (a reply or the
  /// card of changes) show together. Brought to the bottom edge instead,
  /// the card's last lines sat under the Save button (device check,
  /// 2026-11-24), and with the keyboard up an answer would land under it.
  void _scrollNoteIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _noteHeaderKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(target,
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.curve);
    });
  }

  /// An answer that changed nothing, or a refusal: on the page, under the
  /// button, until the next send.
  void _showNoteReply(String text) {
    setState(() => _noteReply = text);
    _scrollNoteIntoView();
  }

  /// Correct with AI: the note and the meal as the form shows it go to
  /// the AI; the answer fills the form. In order: the form must be one a
  /// Save could write; what cannot be sent is said with no model call and
  /// no question; then the consent (an older grant is asked once more,
  /// ensureMealNoteConsent); then the send, with the form locked. Nothing
  /// is written here.
  Future<void> _sendNote() async {
    final corrector = widget.noteCorrector;
    final settings = widget.settings;
    final meal = _meal;
    if (!_noteOffered || corrector == null || settings == null) return;
    if (meal == null || !_noteTyped || _noteBusy) return;
    final l = context.l10n;
    // The open-time read decides whether the form is the stored meal's
    // (milliseconds).
    final basis = _basisRead;
    if (basis != null) {
      setState(() => _noteAsking = true);
      try {
        await basis;
      } finally {
        if (mounted) setState(() => _noteAsking = false);
      }
      if (!mounted || !identical(meal, _meal)) return;
    }
    // Typed over a newer meal: the save's conflict; nothing is sent.
    if (_basisStale) {
      await _conflict();
      return;
    }
    // Only a form a Save could write is sent (the editor's own bounds).
    _harvest();
    final errors = _draft.validate(l);
    if (errors.isNotEmpty) {
      await _showErrors(errors);
      return;
    }
    if (_errors.isNotEmpty) setState(() => _errors = const []);
    // What cannot be sent: said on the page, before any question.
    final refusal = corrector.noteRefusal() ??
        (settings.provider == 'server' &&
                serverAddressRefused(settings.serverBaseUrl)
            ? '❌ ${l.errServerNeedsHttps}'
            : serverKeyForOtherAddress(settings)
                ? '❌ ${l.errServerKeyOtherHost}'
                : null);
    if (refusal != null) {
      _showNoteReply(refusal);
      return;
    }
    setState(() {
      _noteAsking = true;
      _noteReply = null;
    });
    final bool allowed;
    try {
      allowed = await ensureMealNoteConsent(context, settings);
    } finally {
      if (mounted) setState(() => _noteAsking = false);
    }
    if (!mounted) return;
    if (!allowed) {
      // Not now: nothing was sent (it said so); a meals signal skipped
      // while the question was open is caught up.
      _refreshBasis();
      return;
    }
    if (!identical(meal, _meal) || !_noteTyped || _noteBusy) return;
    if (_basisStale) {
      await _conflict();
      return;
    }
    _harvest();
    final note = cleanMealNote(_note.text);
    final input = _draft.correctionInput(earlierNotes: _earlierNotes());
    final before = _draft.copy();
    final gen = ++_noteGen;
    final sentAt = (widget.now ?? DateTime.now)().toUtc().toIso8601String();
    _sentNotes.add(note);
    setState(() {
      _correcting = true;
      _noteReply = null;
    });
    // The form is read-only now; a field left focused would bring the
    // keyboard back up when the answer lands.
    FocusManager.instance.primaryFocus?.unfocus();
    MealNoteOutcome outcome;
    try {
      outcome = await corrector.correctMeal(input, note);
    } catch (_) {
      outcome = MealNoteOutcome(error: l.nlErrorContactingAi);
    }
    // Stopped, or the editor closed: the answer is dropped.
    if (!mounted || gen != _noteGen) return;
    // The row once more, the form still locked: a meal that changed while
    // the AI answered is never filled over.
    await _readBasis();
    if (!mounted || gen != _noteGen) return;
    setState(() => _correcting = false);
    if (!identical(meal, _meal) || _basisStale) {
      await _assistConflict(key: const Key('mealNoteConflict'));
      return;
    }
    switch (outcome.reply) {
      case null:
        _showNoteReply(outcome.error ?? l.nlErrorContactingAi);
      case MealUnclear(reply: final question):
        _showNoteReply(l.mealNoteUnclear(question));
      case MealNoChange(reply: final said):
        _showNoteReply(
            said.isEmpty ? l.mealNoteNoChangeBare : l.mealNoteNoChange(said));
      case MealReplyUnusable(emptiesMeal: final empties):
        _showNoteReply(empties ? l.mealNoteEmpties : l.mealNoteUnusable);
      case MealCorrected(proposal: final proposal):
        _applyCorrection(proposal,
            input: input, before: before, note: note, sentAt: sentAt);
    }
  }

  /// A usable answer fills the form as unsaved edits (nothing is written):
  /// one Undo step, the note field cleared, and the card listing every
  /// change brought into view.
  void _applyCorrection(MealCorrectionProposal proposal,
      {required MealCorrectionInput input,
      required MealDraft before,
      required String note,
      required String sentAt}) {
    final id = ++_noteStepIds;
    _showDraft(_draft.withCorrection(proposal, step: id));
    final step = _NoteStep(
      id: id,
      note: note,
      sentAt: sentAt,
      before: before,
      diff: mealCorrectionDiff(input, proposal),
      removed: proposal.removed,
      descBefore: proposal.description == null ? null : input.description,
      totalsBefore: input.items.isEmpty && proposal.totals != null
          ? [before.calories, before.protein, before.carbs, before.fat]
          : null,
      afterSignature: _signature(),
    );
    _note.clear();
    setState(() {
      _noteSteps.add(step);
      _noteReply = null;
    });
    _scrollNoteIntoView();
  }

  /// Undo: the form exactly as it was before the last note, and that note
  /// back in the field — unless a note typed since and never sent is
  /// there: that one is never written over ([_noteUnsent]). Offered only
  /// while the form shows what the note left ([_noteUndoAvailable]).
  void _undoNote() {
    if (!_noteUndoAvailable) return;
    final step = _noteSteps.removeLast();
    _showDraft(step.before.copy()..expectedRaw = _draft.expectedRaw);
    if (!_noteUnsent) _note.text = step.note;
    setState(() {});
  }

  /// Stop: the answer is no longer waited for (a late one is dropped) and
  /// the form unlocks; nothing was written. The request itself is not
  /// cancelled.
  void _stopNote() {
    if (!_correcting) return;
    _noteGen++;
    setState(() => _correcting = false);
    _refreshBasis();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    final inset = view.viewInsets.bottom;
    // The keyboard coming up (frame by frame) on the note.
    if (inset > _lastBottomInset && _noteFocus.hasFocus) _scheduleNoteReveal();
    _lastBottomInset = inset;
  }

  /// [_revealNote] after the frame, once however many asked for it.
  void _scheduleNoteReveal() {
    if (_noteRevealScheduled) return;
    _noteRevealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _noteRevealScheduled = false;
      _revealNote();
    });
  }

  /// The note field has focus (and the keyboard is coming up): Correct with
  /// AI shows too, above the keyboard and clear of Save. The field's own
  /// reveal is its caret's line and 120 pt under it, and the button sat
  /// half under the keyboard, under Save at larger text (device check,
  /// 2026-11-24). From the field's top down to the button and past Save,
  /// when that fits what the keyboard leaves; otherwise (2x on a 6.1-inch
  /// phone, AX5) the field's top goes to the top, so the note's start
  /// stays in view and the rest scrolls. Measured inside the block: as the
  /// keyboard shrinks the list, the field can lie past what the list lays
  /// out, kept only for its focus, where it has no place on screen.
  void _revealNote() {
    if (!mounted || !_noteFocus.hasFocus || !_scroll.hasClients) return;
    RenderBox? box(GlobalKey key) {
      final o = key.currentContext?.findRenderObject();
      return o is RenderBox && o.attached && o.hasSize ? o : null;
    }

    final block = box(_noteBlockBox);
    final send = box(_noteSendBox);
    if (block == null || send == null) return;
    // The button's bottom, a little air so it does not sit on the
    // keyboard, and Save's height with its margin over the keyboard.
    var below = send
            .localToGlobal(Offset(0, send.size.height), ancestor: block)
            .dy +
        8;
    final save = box(_saveButtonBox);
    if (save != null) below += save.size.height + kFloatingActionButtonMargin;
    // The floated label sits half above the field's box.
    const above = 12.0;
    final room = _scroll.position.viewportDimension;
    block.showOnScreen(
        rect: Rect.fromLTRB(
            0, -above, block.size.width, min(below, room - above)));
  }

  /// A kept note removed: an unsaved change until Save (Back asks).
  void _removeStoredNote(int index) {
    if (_formLocked || _saving) return;
    setState(() => _removedNotes.add(index));
  }

  /// The note's section, the form's last block: header, field, what goes
  /// where, Correct with AI (or the request's progress with Stop), the
  /// last answer that changed nothing, the card of what the last note
  /// changed, and the notes kept on the meal.
  List<Widget> _noteSection(ThemeData theme) {
    final l = context.l10n;
    final settings = widget.settings!;
    final provider =
        providerDisplayLabel(l, settings.provider, settings.serverBackend);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: context.colors.secondaryLabel);
    final locked = _formLocked;
    final reply = _noteReply;
    final kept = [
      for (var i = 0; i < _storedNotes.length; i++)
        if (!_removedNotes.contains(i)) i,
    ];
    final now = (widget.now ?? DateTime.now)();
    return [
      const SizedBox(height: 24),
      Semantics(
        key: _noteHeaderKey,
        header: true,
        child: Text(l.mealNoteHeader,
            key: const Key('mealNoteHeader'),
            style: theme.textTheme.titleSmall),
      ),
      SizedBox(height: _gapAboveField(context, 8)),
      // The field, what goes where, and Correct with AI: one child of the
      // list, so the button is laid out whenever the field is
      // ([_revealNote]).
      Column(
        key: _noteBlockBox,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('mealNoteField'),
            controller: _note,
            focusNode: _noteFocus,
            readOnly: locked || _noteAsking,
            minLines: 2,
            maxLines: isLargeText(context) ? null : 4,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendNote(),
            inputFormatters: [
              LengthLimitingTextInputFormatter(kMealNoteMaxChars)
            ],
            // The caret's line and 120 pt under it; with the keyboard up,
            // the button under the footer too ([_revealNote]).
            scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
            decoration: InputDecoration(
              labelText: l.mealNoteLabel,
              hintText: l.mealNoteHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(l.mealNoteFooter(provider),
              key: const Key('mealNoteFooter'), style: muted),
          const SizedBox(height: 12),
          if (_correcting)
            Semantics(
              liveRegion: true,
              container: true,
              child: Wrap(
                key: const Key('mealNoteAsking'),
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  const SmallSpinner(),
                  Text(l.mealNoteAsking(provider)),
                  TextButton(
                      key: const Key('mealNoteStop'),
                      onPressed: _stopNote,
                      child: Text(l.mealNoteStop)),
                ],
              ),
            )
          else
            // Start-aligned: the extended Save button covers it only at
            // large text, and then not with the keyboard up where there is
            // room ([_revealNote]).
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: KeyedSubtree(
                key: _noteSendBox,
                child: FilledButton.tonalIcon(
                  key: const Key('mealNoteSend'),
                  onPressed: _noteTyped && !locked && !_saving && !_noteAsking
                      ? _sendNote
                      : null,
                  icon: const Icon(Icons.auto_fix_high_outlined),
                  label: Text(l.mealNoteSend),
                ),
              ),
            ),
        ],
      ),
      if (reply != null && !_correcting)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ReplyNote(
              key: const Key('mealNoteReplyNote'),
              message: reply,
              textKey: const Key('mealNoteReply')),
        ),
      if (_noteSteps.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _NoteChangesCard(
              step: _noteSteps.last,
              onUndo: _noteUndoAvailable ? _undoNote : null),
        ),
      if (kept.isNotEmpty) ...[
        const SizedBox(height: 20),
        Semantics(
          header: true,
          child: Text(l.mealNoteSavedHeader,
              key: const Key('mealNoteSavedHeader'),
              style: theme.textTheme.titleSmall),
        ),
        for (final i in kept)
          Padding(
            key: Key('mealNoteSaved$i'),
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: MergeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (DateTime.tryParse(_storedNotes[i].at)
                              case final at?)
                            Text(
                                AppFormats.shortDate(
                                    context, isoDate(at.toLocal()),
                                    now: now),
                                style: muted),
                          Text(_storedNotes[i].text,
                              key: Key('mealNoteSavedText$i')),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: Key('mealNoteRemove$i'),
                  tooltip: l.mealNoteRemoveLabel,
                  icon: const Icon(Icons.close),
                  onPressed: locked || _saving
                      ? null
                      : () => _removeStoredNote(i),
                ),
              ],
            ),
          ),
      ],
    ];
  }

  Future<void> _delete() async {
    final meal = widget.meal;
    if (meal == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.l10n.editorDeleteTitle),
        content: Text(ctx.l10n.editorDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('confirmDeleteMeal'),
              style: AppButtonStyles.destructive(ctx),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.dao.deleteMeal(meal.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errors = [context.l10n.editorDeleteFailed('$e')];
      });
    }
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_draft.dateIso) ?? (widget.now ?? DateTime.now)();
    final picked = await showAppDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      // Tomorrow as a CALENDAR day: now + 24 h is still today at 00:xx on
      // the day DST ends (tomorrow could not be picked), and the day after
      // tomorrow at 23:xx on the eve of its start.
      lastDate: addCalendarDays((widget.now ?? DateTime.now)(), 1),
    );
    if (picked == null || !mounted) return;
    setState(() => _draft.dateIso = isoDate(picked));
  }

  Future<void> _pickTime() async {
    final parsed = parseClock(_draft.time);
    final picked = await showAppTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: parsed?.hour ?? 12, minute: parsed?.minute ?? 0),
    );
    if (picked == null || !mounted) return;
    setState(() => _draft.time = formatClock(DateTime(
        2026, 1, 1, picked.hour, picked.minute)));
  }

  /// Remove by IDENTITY, never by the index captured at build time: two
  /// taps inside one frame otherwise delete the wrong row (or throw
  /// RangeError on the second).
  void _removeItem(MealItemDraft item) {
    _harvest();
    final i = _draft.items.indexOf(item);
    if (i < 0) return; // already gone (double tap)
    setState(() {
      final row = _itemCtrls.removeAt(i);
      row.name.dispose();
      row.cal.dispose();
      row.pro.dispose();
      row.carb.dispose();
      row.fat.dispose();
      _draft.items.removeAt(i);
    });
    // The whole point of the report: removing a row must move the total —
    // including the last row, whose sum is zero.
    _recomputeTotalsFromItems(afterRemoval: true);
  }

  static String _plain(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  /// The meal's photo came from Meta glasses (design G2a): the stored
  /// meal says so, or the photo being logged by hand does.
  bool get _fromMetaGlasses {
    final meal = _meal;
    if (meal != null) return isMetaGlassesAnalysis(meal.analysis);
    return widget.fromPhoto?.capture?.isMetaGlasses ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kcalNow =
        parseNumberField(_cal.text, label: 'Calories', max: maxMealCalories)
                .value ??
            0;
    final assistCard = _assistSection();
    _shownDirty = _dirty;
    _shownUnsaved = _unsaved;
    _shownNoteTyped = _noteTyped;
    _shownNoteUndo = _noteUndoAvailable;
    final locked = _formLocked;
    final usualCard = _usualSection(_shownDirty);
    // Back asks first while something is unsaved; Save, Delete and the
    // conflict paths pop with Navigator.pop, which is never held.
    return DiscardChangesGuard(
      dirty: _shownUnsaved,
      busy: _saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.isNew
              ? context.l10n.editorTitleAdd
              : context.l10n.editorTitleEdit),
          actions: [
            if (!widget.isNew)
              IconButton(
                key: const Key('deleteMealButton'),
                tooltip: context.l10n.editorDeleteTooltip,
                icon: const Icon(Icons.delete_outline),
                onPressed: _saving ? null : _delete,
              ),
          ],
        ),
        body: ListView(
          controller: _scroll,
          // Room for the first field's floated label at large text: it was
          // clipped under the app bar at AX5.
          padding: EdgeInsets.fromLTRB(16, _gapAboveField(context, 8), 16, 96),
          children: [
            if (_errors.isNotEmpty)
              Card(
                key: const Key('editorErrors'),
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final e in _errors)
                        Text(e,
                            style: TextStyle(
                                color: theme.colorScheme.onErrorContainer)),
                    ],
                  ),
                ),
              ),
            if (_fromMetaGlasses)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: MetaGlassesBadge(key: Key('editorMetaGlassesBadge')),
                ),
              ),
            // The card right above the description leaves room for its
            // floated label at large text: 16 pt let it cover the card's
            // bottom edge at AX5. Unchanged at the default size.
            if (assistCard != null)
              Padding(
                padding: EdgeInsets.only(
                    bottom: usualCard == null ? _gapAboveField(context, 16) : 16),
                child: assistCard,
              ),
            if (usualCard != null)
              Padding(
                padding: EdgeInsets.only(bottom: _gapAboveField(context, 16)),
                child: usualCard,
              ),
            TextField(
              key: const Key('editorDescription'),
              controller: _desc,
              readOnly: locked,
              textCapitalization: TextCapitalization.sentences,
              // Wraps at large text ('Pan-fried du' at AX5); still one line
              // of content with a Done key.
              maxLines: isLargeText(context) ? null : 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
              decoration: InputDecoration(
                labelText: context.l10n.editorDescriptionLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // At large text the two pills stack: side by side, the date
            // wrapped onto two lines.
            _fieldGrid(
              perRow: isLargeText(context) ? 1 : 2,
              gap: 8,
              [
                OutlinedButton.icon(
                  key: const Key('editorDateButton'),
                  onPressed: locked ? null : _pickDate,
                  icon: const Icon(Icons.event_outlined, size: 18),
                  // 'Jul 24' / '7月24日', with the year when it is not
                  // this year's (the raw '2026-07-24' read as a code).
                  label: Text(AppFormats.shortDate(context, _draft.dateIso,
                      now: (widget.now ?? DateTime.now)())),
                ),
                OutlinedButton.icon(
                  key: const Key('editorTimeButton'),
                  onPressed: locked ? null : _pickTime,
                  icon: const Icon(Icons.schedule_outlined, size: 18),
                  // Locale clock (24h in zh), like every other time in the UI.
                  label: Text(context.clock(_draft.time)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(context.l10n.editorTotalsHeader, style: theme.textTheme.titleSmall),
            SizedBox(height: _gapAboveField(context, 8)),
            // Bare name + unit suffix, like the macro fields below: at the
            // largest iOS text size a NEW meal's empty field rested
            // 'Calories (kcal)' at the full 3.1x and cut it to 'Calories (kc…'
            // until tapped (a filled meal floats the label at 0.75x and fits).
            _NumberField(
              fieldKey: const Key('editorCalories'),
              controller: _cal,
              readOnly: locked,
              label: context.l10n.editorCaloriesLabel,
              suffixText: context.l10n.editorKcalSuffix,
            ),
            SizedBox(height: _gapAboveField(context, 8)),
            // At large text each macro field takes the full width, like
            // Calories: a third of the row cut 'Protein (g)' / '蛋白质（克）'
            // to 'Pr…'. At the default size a NEW meal's empty fields rest
            // their labels inside that third, and on a 375–411 pt phone
            // 'Protein (g)' / '蛋白质（克）' (and even '蛋白（克）') still cut,
            // so the label is the bare name and the unit is a suffix — shown
            // once the field is focused or filled, i.e. once the label has
            // floated, so the unit is never out of sight while typing.
            _fieldGrid(
              perRow: isLargeText(context) ? 1 : 3,
              gap: 8,
              runGap: _gapAboveField(context, 8),
              [
                _NumberField(
                    fieldKey: const Key('editorProtein'),
                    controller: _pro,
                    readOnly: locked,
                    label: context.l10n.editorProteinLabel,
                    suffixText: context.l10n.editorGramsSuffix),
                _NumberField(
                    fieldKey: const Key('editorCarbs'),
                    controller: _carb,
                    readOnly: locked,
                    label: context.l10n.editorCarbsLabel,
                    suffixText: context.l10n.editorGramsSuffix),
                _NumberField(
                    fieldKey: const Key('editorFat'),
                    controller: _fat,
                    readOnly: locked,
                    label: context.l10n.editorFatLabel,
                    suffixText: context.l10n.editorGramsSuffix),
              ],
            ),
            const SizedBox(height: 16),
            // Live composition of what's typed above.
            Text('~${context.l10n.kcalAmount(formatKcal(kcalNow))}',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            MacroBreakdownBar(
              proteinG: _num(_pro.text),
              carbsG: _num(_carb.text),
              fatG: _num(_fat.text),
            ),
            const SizedBox(height: 24),
            // A Wrap, not a Row: the unflexed hint took the whole width at
            // the largest text sizes, drawing 'Items' one glyph per line and
            // overflowing the row. Side by side when both fit, the hint drops
            // under the header (and wraps there) when they don't.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 2,
              children: [
                Text(context.l10n.editorItemsHeader,
                    style: theme.textTheme.titleSmall),
                if (_totalsDerived)
                  Text(context.l10n.editorTotalsDerivedHint,
                      key: const Key('totalsDerivedHint'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
            for (var i = 0; i < _draft.items.length; i++)
              _ItemRow(
                // Identity key: element (and focus) state must travel WITH the
                // item when a row above it is removed. Without it, removing a
                // row left the keyboard bound to the next item's controller
                // and silently typed into the wrong food.
                key: ObjectKey(_draft.items[i]),
                index: i,
                ctrls: _itemCtrls[i],
                locked: locked,
                onRemove: () => _removeItem(_draft.items[i]),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('addItemRow'),
                onPressed: locked ? null : () {
                  _harvest();
                  setState(() {
                    // The first row is seeded from the hand-typed totals
                    // (MealDraft.addItem), so the recompute below reproduces
                    // them instead of wiping them.
                    _itemCtrls.add(_controllersFor(_draft.addItem()));
                  });
                  _recomputeTotalsFromItems();
                },
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.l10n.editorAddItem),
              ),
            ),
            // Last, inside the Save button's clearance: the description stays
            // the first field and the meal's own numbers first on screen.
            if (_noteOffered) ..._noteSection(theme),
          ],
        ),
        floatingActionButton: KeyedSubtree(
          key: _saveButtonBox,
          child: FloatingActionButton.extended(
            key: const Key('saveMealButton'),
            onPressed: _saving || _correcting ? null : _save,
            // Waiting for a note's answer, Save is drawn as unavailable, as
            // the other controls the request locks are (a FAB's own look
            // does not change without onPressed).
            backgroundColor: _correcting ? context.colors.fill : null,
            foregroundColor: _correcting
                ? context.colors.label.withValues(alpha: 0.38)
                : null,
            disabledElevation: _correcting ? 0 : null,
            icon: _saving
                ? const SmallSpinner(size: 18)
                : const Icon(Icons.check),
            label:
                Text(widget.isNew ? context.l10n.editorAdd : context.l10n.save),
          ),
        ),
      ),
    );
  }

  static num _num(String raw) =>
      parseNumberField(raw, label: 'x', max: maxMacroGrams).value ?? 0;
}

/// [children] [perRow] to a row, sharing each row's width equally, [gap]
/// apart across and [runGap] (default [gap]) between rows. With every
/// child in one row it is exactly the plain Row of Expanded children the
/// editor used before large-text stacking.
Widget _fieldGrid(List<Widget> children,
    {required int perRow, required double gap, double? runGap}) {
  final rows = <Widget>[];
  for (var i = 0; i < children.length; i += perRow) {
    final chunk = children.sublist(i, min(i + perRow, children.length));
    if (rows.isNotEmpty) rows.add(SizedBox(height: runGap ?? gap));
    rows.add(Row(children: [
      for (var j = 0; j < chunk.length; j++) ...[
        if (j > 0) SizedBox(width: gap),
        Expanded(child: chunk[j]),
      ],
    ]));
  }
  return rows.length == 1 ? rows.single : Column(children: rows);
}

/// The space above an outlined field: [base], or more once enlarged text
/// makes the field's floated label reach further. InputDecorator draws
/// that label centred on the top border at 0.75x, so half of it sits
/// OUTSIDE the field's box; at AX5 (~26 pt) it covered the 8-pt gap and
/// the header or field above it. Unchanged at the default size.
double _gapAboveField(BuildContext context, double base) {
  final scaler = MediaQuery.textScalerOf(context);
  if (scaler.scale(1) <= 1.0) return base;
  final tp = TextPainter(
    text: TextSpan(
        text: 'Hg', style: Theme.of(context).textTheme.bodyLarge),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final reach = tp.height * 0.75 / 2;
  tp.dispose();
  final needed = reach + 4;
  return needed > base ? needed : base;
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.suffixText,
    this.readOnly = false,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;

  /// One of the editor's own writes is running ([_MealEditorScreenState
  /// ._formLocked]).
  final bool readOnly;

  /// The unit, kept out of [label] where a third of the row can't hold it.
  final String? suffixText;

  @override
  Widget build(BuildContext context) => TextField(
        key: fieldKey,
        controller: controller,
        readOnly: readOnly,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffixText,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.index,
    required this.ctrls,
    required this.onRemove,
    this.locked = false,
  });

  final int index;

  /// The form is read-only ([_MealEditorScreenState._formLocked]).
  final bool locked;
  final ({TextEditingController name, TextEditingController cal,
      TextEditingController pro, TextEditingController carb,
      TextEditingController fat}) ctrls;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: _gapAboveField(context, 6), bottom: 6),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: Key('itemName$index'),
                    controller: ctrls.name,
                    // Wraps at large text, as the description does.
                    maxLines: isLargeText(context) ? null : 1,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.singleLineFormatter
                    ],
                    readOnly: locked,
                    decoration: InputDecoration(
                      labelText: context.l10n.editorItemLabel,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  key: Key('removeItem$index'),
                  tooltip: context.l10n.editorRemoveItemTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: locked ? null : onRemove,
                ),
              ],
            ),
            SizedBox(height: _gapAboveField(context, 6)),
            // At large text a 2x2 grid: a quarter of the row cut 'kcal'
            // to 'k…'. The labels are short enough for half.
            _fieldGrid(
              perRow: isLargeText(context) ? 2 : 4,
              gap: 6,
              runGap: _gapAboveField(context, 6),
              [
                _NumberField(
                    fieldKey: Key('itemCal$index'),
                    controller: ctrls.cal,
                    readOnly: locked,
                    label: context.l10n.editorItemKcalLabel),
                _NumberField(
                    fieldKey: Key('itemPro$index'),
                    controller: ctrls.pro,
                    readOnly: locked,
                    label: '${context.l10n.macroProteinShort} g'),
                _NumberField(
                    fieldKey: Key('itemCarb$index'),
                    controller: ctrls.carb,
                    readOnly: locked,
                    label: '${context.l10n.macroCarbsShort} g'),
                _NumberField(
                    fieldKey: Key('itemFat$index'),
                    controller: ctrls.fat,
                    readOnly: locked,
                    label: '${context.l10n.macroFatShort} g'),
              ],
            ),
          ],
        ),
      );
}

/// One note that filled the form this visit: what Undo restores, the
/// card's lines, and what tells whether the saved form still holds it
/// (MealDraft.holdsNote).
class _NoteStep {
  _NoteStep({
    required this.id,
    required this.note,
    required this.sentAt,
    required this.before,
    required this.diff,
    required this.removed,
    required this.descBefore,
    required this.totalsBefore,
    required this.afterSignature,
  });

  final int id;

  /// As sent (cleanMealNote), and when (ISO-8601 UTC).
  final String note;
  final String sentAt;

  /// The form right before the note was sent.
  final MealDraft before;
  final MealCorrectionDiff diff;

  /// The foods it removed: positions among [before]'s filled rows.
  final Set<int> removed;

  /// The description before, when the note changed it.
  final String? descBefore;

  /// A row-less meal's four total texts before, when the note changed
  /// them.
  final List<String>? totalsBefore;

  /// The form's signature right after the fill: Undo is offered while it
  /// still reads so.
  final String afterSignature;
}

/// "Changed from your note — not saved yet": what the last note changed,
/// for the user to check before Save, with Undo while the form still
/// shows exactly that. A live region: it appears after a round trip.
class _NoteChangesCard extends StatelessWidget {
  const _NoteChangesCard({required this.step, this.onUndo});

  final _NoteStep step;
  final VoidCallback? onUndo;

  /// Food lines shown before "and N more changes".
  static const int _maxFoodLines = 6;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final d = step.diff;
    String line(MealCorrectionLine x) => switch (x.kind) {
          MealCorrectionLineKind.changed => l.mealNoteItemChanged(
              x.name, formatKcal(x.kcalBefore), formatKcal(x.kcalAfter)),
          MealCorrectionLineKind.renamed => l.mealNoteItemRenamed(
              x.name,
              x.newName ?? x.name,
              formatKcal(x.kcalBefore),
              formatKcal(x.kcalAfter)),
          MealCorrectionLineKind.added =>
            l.mealNoteItemAdded(x.name, formatKcal(x.kcalAfter)),
          MealCorrectionLineKind.removed =>
            l.mealNoteItemRemoved(x.name, formatKcal(x.kcalBefore)),
        };
    final shown = d.lines.take(_maxFoodLines).toList();
    final more = d.lines.length - shown.length;
    final macros = [
      (l.macroProtein, d.totalsBefore.protein, d.totalsAfter.protein),
      (l.macroCarbs, d.totalsBefore.carbs, d.totalsAfter.carbs),
      (l.macroFat, d.totalsBefore.fat, d.totalsAfter.fat),
    ];
    final descBefore = d.descBefore;
    final descAfter = d.descAfter;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        key: const Key('mealNoteChanges'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.mealNoteChangedTitle, style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(l.mealNoteYourNote(step.note),
                  key: const Key('mealNoteYourNote')),
              if (descBefore != null && descAfter != null)
                Text(l.mealNoteDescChange(descBefore, descAfter),
                    key: const Key('mealNoteDescChange')),
              Text(
                  l.mealNoteTotalChange(formatKcal(d.totalsBefore.calories),
                      formatKcal(d.totalsAfter.calories)),
                  key: const Key('mealNoteTotalChange')),
              for (final (name, before, after) in macros)
                if ((after - before).abs() >= 0.05)
                  Text(l.mealNoteMacroChange(name, formatOneDecimal(before),
                      formatOneDecimal(after))),
              for (final x in shown) Text(line(x)),
              if (more > 0) Text(l.mealNoteMoreChanges(more)),
              if (d.unchangedCount > 0)
                Text(l.mealNoteUnchangedCount(d.unchangedCount),
                    key: const Key('mealNoteUnchanged')),
              if (d.reason.isNotEmpty)
                Text('💬 ${d.reason}', key: const Key('mealNoteReason')),
              const SizedBox(height: 6),
              Text(l.mealNoteCheckThenSave),
              if (onUndo != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const Key('mealNoteUndo'),
                    onPressed: onUndo,
                    // Read as what it undoes, not a bare "Undo".
                    child: Semantics(
                      label: l.mealNoteUndoLabel,
                      child: ExcludeSemantics(child: Text(l.assistUndo)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
