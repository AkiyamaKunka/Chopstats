/// Chinese lines that keep a number with its unit (2026-11-25).
///
/// The line breaker (ICU, on both phones) may break Chinese text between
/// any two ideographs and after any space. A line that ends in a number
/// and its unit wrapped as '…260 → 130 千' / '卡' (Edit meal's Correct
/// with a note card on an iPhone 17 Pro Max), and could as '…130' / '千卡'
/// or '米饭（约200' / '克）'.
///
/// Only what is DRAWN changes. [keepUnitsTogether] puts a no-break space
/// (U+00A0) where a space stood between a number and its unit, a word
/// joiner (U+2060, invisible) where the unit touches the number, and a
/// word joiner inside 千卡 wherever it stands. [unitText] and [unitSpan]
/// draw that and keep the string as it was for screen readers, through
/// the span's semanticsLabel: VoiceOver and TalkBack get the same label,
/// byte for byte, and find.text still finds it. The ARB strings stay as
/// they are, and so does every string that is not drawn here:
/// notifications (the OS draws those), the clipboard, what is sent.
///
/// Chinese only ([AppLocalizations.localeName] zh): the English UI draws
/// what it always did.
library;

import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

/// U+00A0: a space that is never a line break.
const String noBreakSpace = ' ';

/// U+2060: no line break here, and nothing drawn.
const String wordJoiner = '⁠';

/// A number (a digit, or '?', the unknown-kcal mark in '~? 千卡'), then a
/// Chinese unit with or without a space, or a Latin unit the Chinese
/// strings use ('蛋 25 g') after a space. Longer units first ('毫克'
/// before '克'). A Latin unit that runs on into a word ('5 grams') is not
/// one; a Latin unit right after the digit ('20g') never breaks anyway.
final RegExp _numberUnit = RegExp(
    r'([0-9?])( ?)(千卡|大卡|千克|毫克|公斤|毫升|公里|克|升)'
    r'|([0-9?]) (kcal|kg|mg|ml|mL|km|g)(?![A-Za-z])');

/// [s] with each number held to its unit and 千卡 held together across a
/// line break (see the library comment). Nothing else changes: the digits
/// and words stay where they were, so the result reads the same.
String keepUnitsTogether(String s) {
  final joined = s.replaceAllMapped(_numberUnit, (m) {
    final cjk = m[3];
    if (cjk != null) {
      final gap = m[2]!.isEmpty ? wordJoiner : noBreakSpace;
      return '${m[1]}$gap${cjk.split('').join(wordJoiner)}';
    }
    return '${m[4]}$noBreakSpace${m[5]}';
  });
  // 千卡 with no number before it ('千卡 / 天', '克与千卡。').
  return joined.replaceAll('千卡', '千$wordJoiner卡');
}

/// [s] as [l]'s language draws it: [keepUnitsTogether] in Chinese, [s]
/// itself elsewhere.
String drawnUnits(AppLocalizations l, String s) =>
    l.localeName.startsWith('zh') ? keepUnitsTogether(s) : s;

/// A span that draws [drawnUnits] of [s] and reads [s]. [before] is the
/// text drawn right before this span, in the same paragraph: a number
/// there keeps its unit here ('1,909' + ' 千卡 / 天').
TextSpan unitSpan(AppLocalizations l, String s,
    {TextStyle? style, String before = ''}) {
  final lead = before.isEmpty ? '' : before.substring(before.length - 1);
  final drawn = drawnUnits(l, '$lead$s').substring(lead.length);
  return TextSpan(
      text: drawn, style: style, semanticsLabel: drawn == s ? null : s);
}

/// A [Text] of [s] that keeps numbers with their units in Chinese. When
/// nothing changes (English, or no number and unit in [s]) it is the very
/// `Text(s)` it replaces.
Text unitText(
  AppLocalizations l,
  String s, {
  Key? key,
  TextStyle? style,
  TextAlign? textAlign,
  bool? softWrap,
  TextOverflow? overflow,
  int? maxLines,
}) {
  final span = unitSpan(l, s);
  if (span.semanticsLabel == null) {
    return Text(s,
        key: key,
        style: style,
        textAlign: textAlign,
        softWrap: softWrap,
        overflow: overflow,
        maxLines: maxLines);
  }
  return Text.rich(span,
      key: key,
      style: style,
      textAlign: textAlign,
      softWrap: softWrap,
      overflow: overflow,
      maxLines: maxLines);
}
