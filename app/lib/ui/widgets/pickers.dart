/// Material's date and time pickers with the text scale clamped (A6).
///
/// At the largest accessibility sizes Flutter scales the date dialog up
/// to 3x while its day grid clamps at 2x: on a 375-pt phone two-digit days
/// wrapped and lost their second digit ('19 2 21 2 2 2 2' — a wrong-day
/// meal waiting to happen), the zh header overflowed by 24 px, and the
/// 24-hour dial drew '15' and '3' as '153'. Clamping the whole dialog at
/// 1.6x keeps every label whole on every iPhone width; the picker text is
/// still well above the default size. Narrower Android screens clamp the
/// date dialog lower ([datePickerMaxTextScale]), and the date dialog's
/// selected-date headline is made smaller where the longest date would
/// not fit its one line ([fittedDatePickerHeadline]).
///
/// Same signatures and return types as [showDatePicker] /
/// [showTimePicker]; swap the call, keep the arguments.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The largest text scale inside a picker dialog: the time picker's
/// everywhere, the date picker's on a screen 375 dp or wider.
const double kPickerMaxTextScale = 1.6;

/// Below this width the date picker's clamp comes down
/// [kPickerClampPerDp] per dp, to no less than 1.0 (the user's own size
/// is never shrunk below the default).
const double kPickerFullClampWidth = 375;
const double kPickerClampPerDp = 0.01;

/// The date dialog's clamp on a screen [width] dp wide. Android's largest
/// Display size takes a phone to 320 dp, where at font size 2.0 the 1.6
/// clamp wrapped the selected '13' to a '1' in its circle and cut the
/// month to 'Novembe…' (Android push, UX run screenshot 46). Measured
/// with Roboto (test/ui/picker_width_test.dart), the most each width
/// keeps whole is 1.1 at 320 dp, 1.3 at 340, 1.5 at 360 and 1.6 at 375;
/// this line stays about 0.05 under each.
double datePickerMaxTextScale(double width) =>
    (kPickerMaxTextScale - (kPickerFullClampWidth - width) * kPickerClampPerDp)
        .clamp(1.0, kPickerMaxTextScale);

/// Material 3's date dialog as it lays out its selected-date header in
/// portrait (flutter/lib/src/material/date_picker.dart, Flutter 3.44): the
/// input mode's 328 dp, the narrower of its two widths, inside 16 dp of
/// inset on each side; the header's 24 + 12 dp of padding and the 48 dp
/// entry-mode button beside the date; and the header's own text-scale
/// clamp, 1.4 with that button.
const double _kDateDialogWidth = 328;
const double _kDateDialogInset = 16;
const double _kDateHeaderChrome = 24 + 12 + 48;
const double _kDateHeaderMaxScale = 1.4;

/// The selected-date header's headline at this size (Android QA Q8). The
/// header gives the date one line and cuts it with an ellipsis: in Chinese
/// at 320 dp and font size 2.0 the weekday went ('11月13日周…'), and from
/// about font size 1.3 the Chinese date did not fit on wider phones
/// either. Null keeps the theme's headline (Material 3: 32 sp), as long as
/// the longest date of a year fits; otherwise the largest size that fits
/// it, measured as the header lays it out. Portrait only: landscape gives
/// the date two lines and more.
@visibleForTesting
TextStyle? fittedDatePickerHeadline(BuildContext context) {
  if (!Theme.of(context).useMaterial3 ||
      MediaQuery.orientationOf(context) != Orientation.portrait) {
    return null;
  }
  final style = DatePickerTheme.of(context).headerHeadlineStyle ??
      DatePickerTheme.defaults(context).headerHeadlineStyle;
  final size = style?.fontSize;
  if (style == null || size == null) return null;
  final scaler = MediaQuery.textScalerOf(context);
  final titleScaler = scaler.clamp(
      maxScaleFactor: math.min(scaler.scale(14) / 14, _kDateHeaderMaxScale));
  final room = math.min(_kDateDialogWidth,
          MediaQuery.sizeOf(context).width - 2 * _kDateDialogInset) -
      _kDateHeaderChrome;
  final l = MaterialLocalizations.of(context);
  final direction = Directionality.of(context);
  final locale = Localizations.maybeLocaleOf(context);
  // Every month, on seven days in a row (every weekday), two-digit days.
  var widest = 0.0;
  for (var month = 1; month <= 12; month++) {
    for (var day = 22; day <= 28; day++) {
      final painter = TextPainter(
        text: TextSpan(
            text: l.formatMediumDate(DateTime(2026, month, day)),
            style: style),
        textDirection: direction,
        textScaler: titleScaler,
        locale: locale,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
  }
  if (widest <= room) return null;
  // The largest half point at which the widest date leaves a whole pixel
  // of the room, for the rounding a real layout does. A date's width
  // follows its scaled font size (headlineLarge has no letter spacing,
  // which a scaler leaves alone), so the measurement at [size] gives the
  // width at any other size through the header's own scaler. Start from
  // the size in proportion and come down half a point while that is too
  // wide: Android 14 and later scale a smaller size by more (at font size
  // 2.0, 32 sp draws 1.24x and 29 sp 1.30x), where the size in proportion
  // still cut the date ('12月30日周…' at 345.6 dp). With a linear scaler
  // (iOS, Android 13 and earlier) it already fits, and the 1e-6 keeps a
  // rounding error from stepping it down. The steps stop at 8 sp.
  final at = titleScaler.scale(size);
  var fitted = (size * (room - 1) / widest * 2).floorToDouble() / 2;
  while (fitted > 8 &&
      widest * titleScaler.scale(fitted) / at > room - 1 + 1e-6) {
    fitted -= 0.5;
  }
  return style.copyWith(fontSize: fitted);
}

/// The date dialog under [fittedDatePickerHeadline]'s headline. Always
/// the same widget above the dialog, so a rotation never rebuilds the
/// dialog's state.
class _DateHeaderFit extends StatelessWidget {
  const _DateHeaderFit({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = DatePickerTheme.of(context);
    final fitted = fittedDatePickerHeadline(context);
    return DatePickerTheme(
      data: fitted == null
          ? theme
          : theme.copyWith(headerHeadlineStyle: fitted),
      child: child,
    );
  }
}

/// The clamp at [maxScale], with a caller's [builder] running INSIDE it
/// (its context sees the clamped scale, so a MediaQuery copy there cannot
/// undo it).
Widget _clamped(BuildContext context, Widget? child, TransitionBuilder? builder,
        {double maxScale = kPickerMaxTextScale}) =>
    MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxScale,
      child: builder == null
          ? child!
          : Builder(builder: (context) => builder(context, child)),
    );

/// [showDatePicker] with the dialog's text scale clamped at
/// [datePickerMaxTextScale] for the screen's width. A caller's [builder]
/// still runs, inside the clamp.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  DateTime? initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTime? currentDate,
  DatePickerEntryMode initialEntryMode = DatePickerEntryMode.calendar,
  SelectableDayPredicate? selectableDayPredicate,
  String? helpText,
  String? cancelText,
  String? confirmText,
  Locale? locale,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  TextDirection? textDirection,
  TransitionBuilder? builder,
  DatePickerMode initialDatePickerMode = DatePickerMode.day,
  String? errorFormatText,
  String? errorInvalidText,
  String? fieldHintText,
  String? fieldLabelText,
  TextInputType? keyboardType,
  Offset? anchorPoint,
  ValueChanged<DatePickerEntryMode>? onDatePickerModeChange,
  Icon? switchToInputEntryModeIcon,
  Icon? switchToCalendarEntryModeIcon,
}) =>
    showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      currentDate: currentDate,
      initialEntryMode: initialEntryMode,
      selectableDayPredicate: selectableDayPredicate,
      helpText: helpText,
      cancelText: cancelText,
      confirmText: confirmText,
      locale: locale,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      textDirection: textDirection,
      // The headline fits the header ([fittedDatePickerHeadline]), under
      // the clamp and a caller's builder, which see the dialog as before.
      builder: (context, child) => _clamped(
          context, _DateHeaderFit(child: child!), builder,
          maxScale: datePickerMaxTextScale(MediaQuery.sizeOf(context).width)),
      initialDatePickerMode: initialDatePickerMode,
      errorFormatText: errorFormatText,
      errorInvalidText: errorInvalidText,
      fieldHintText: fieldHintText,
      fieldLabelText: fieldLabelText,
      keyboardType: keyboardType,
      anchorPoint: anchorPoint,
      onDatePickerModeChange: onDatePickerModeChange,
      switchToInputEntryModeIcon: switchToInputEntryModeIcon,
      switchToCalendarEntryModeIcon: switchToCalendarEntryModeIcon,
    );

/// [showTimePicker] with the dialog's text scale clamped at
/// [kPickerMaxTextScale]. A caller's [builder] still runs, inside the clamp.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  TransitionBuilder? builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  TimePickerEntryMode initialEntryMode = TimePickerEntryMode.dial,
  String? cancelText,
  String? confirmText,
  String? helpText,
  String? errorInvalidText,
  String? hourLabelText,
  String? minuteLabelText,
  RouteSettings? routeSettings,
  EntryModeChangeCallback? onEntryModeChanged,
  Offset? anchorPoint,
  Orientation? orientation,
  Icon? switchToInputEntryModeIcon,
  Icon? switchToTimerEntryModeIcon,
}) =>
    showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) => _clamped(context, child, builder),
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useRootNavigator: useRootNavigator,
      initialEntryMode: initialEntryMode,
      cancelText: cancelText,
      confirmText: confirmText,
      helpText: helpText,
      errorInvalidText: errorInvalidText,
      hourLabelText: hourLabelText,
      minuteLabelText: minuteLabelText,
      routeSettings: routeSettings,
      onEntryModeChanged: onEntryModeChanged,
      anchorPoint: anchorPoint,
      orientation: orientation,
      switchToInputEntryModeIcon: switchToInputEntryModeIcon,
      switchToTimerEntryModeIcon: switchToTimerEntryModeIcon,
    );
