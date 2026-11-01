/// Bottom sheet kieu iOS dung chung (chi tiet o ban do, menu dia diem, chia
/// se, thong tin, form): bo goc tren 13, thanh keo (grabber), nen kinh toi
/// mo, vuot xuong de dong; cao theo noi dung toi da ~92 % man hinh (cam
/// giac "detent" medium/large). Giam chuyen dong -> hien/an tuc thi.
///
/// - [showIosSheet] voi [title]: tieu de + nut Dong (x).
/// - [showIosSheet] voi `form: true`: noi dung tu ve [IosSheetNavBar]
///   (Huy / tieu de / Xong) de nut Xong theo trang thai form.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../utils/haptics.dart';
import '../app_scene.dart';
import '../design_tokens.dart';
import 'glass_card.dart';
import '../weather_scene.dart';
import 'glass_page.dart';

Future<T?> showIosSheet<T>(
  BuildContext context, {
  String? title,
  required Widget Function(BuildContext) builder,
  bool form = false,
  bool scrollable = true,
  bool dismissible = true,
  bool useRootNavigator = true,
}) {
  // Thieu canh (man hinh test toi gian): dung canh may dem mac dinh.
  final AppSceneData scene =
      AppScene.maybeOf(context) ??
      const AppSceneData(
        scene: WeatherScene.cloudy,
        isDay: false,
        windSpeedKmh: 0,
        intensity: 1,
        resolved: WeatherScene.cloudy,
      );
  final Color glass = scene.theme.glassColor;
  final ThemeData appTheme = Theme.of(context);
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  const shape = BorderRadius.vertical(top: Radius.circular(Radii.sheet));
  final maxH = MediaQuery.sizeOf(context).height * 0.92;
  return showModalBottomSheet<T>(
    context: context,
    // Navigator goc: sheet phu len ca thanh tab (khong doi tab khi dang mo).
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    showDragHandle: false,
    elevation: 0,
    constraints: BoxConstraints(
      maxWidth: Space.contentMaxWidth,
      maxHeight: maxH,
    ),
    shape: const RoundedRectangleBorder(borderRadius: shape),
    clipBehavior: Clip.antiAlias,
    backgroundColor: Colors.transparent,
    barrierColor: Palette.barrier,
    sheetAnimationStyle: reducedMotion
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: Motion.medium,
            reverseDuration: Motion.shortExit,
          ),
    builder: (ctx) {
      final Widget body = builder(ctx);
      return AppScene(
        data: scene,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: ClipRRect(
            key: const ValueKey('glass-sheet'),
            borderRadius: shape,
            child: BackdropGroup(
              child: GlassSurface(
                radius: 0,
                tint: Color.alphaBlend(glass, Palette.sheetSolid),
                padding: const EdgeInsets.fromLTRB(
                  Space.l + 4,
                  0,
                  Space.l + 4,
                  Space.l + 4,
                ),
                child: SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  // Noi dung sheet luon dung theme kinh (chu trang, o nhap toi)
                  // du man goi la trang sang.
                  child: glassThemed(
                    scene.theme,
                    appTheme,
                    DefaultTextStyle.merge(
                      style: const TextStyle(color: Palette.white),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const IosSheetGrabber(),
                          if (!form && title != null) ...[
                            _SheetTitleRow(title: title, ctx: ctx),
                            const SizedBox(height: Space.m),
                          ],
                          Flexible(
                            child: scrollable
                                ? SingleChildScrollView(child: body)
                                : body,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Ten cu (giu tuong thich).
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext) builder,
}) => showIosSheet<T>(context, title: title, builder: builder);

/// Thanh keo 36x5 (vung cham cao 20; keo / vuot xuong de dong).
class IosSheetGrabber extends StatelessWidget {
  const IosSheetGrabber({super.key});

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: SizedBox(
      key: ValueKey('glass-sheet-drag-handle'),
      height: 20,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Palette.highlight,
            borderRadius: BorderRadius.all(Radius.circular(Radii.bar)),
          ),
          child: SizedBox(width: 36, height: 5),
        ),
      ),
    ),
  );
}

class _SheetTitleRow extends StatelessWidget {
  const _SheetTitleRow({required this.title, required this.ctx});

  final String title;
  final BuildContext ctx;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TypeScale.title3.copyWith(color: Palette.white),
            ),
          ),
        ),
        const SizedBox(width: Space.s),
        Tooltip(
          message: 'Đóng',
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(Touch.min, Touch.min),
            pressedOpacity: reducedMotion ? 1 : Opacities.pressed,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Icon(
              CupertinoIcons.xmark_circle_fill,
              size: 30,
              color: Palette.secondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Thanh tieu de cua sheet form: "Hủy" | tieu de | "Xong" (dam).
class IosSheetNavBar extends StatelessWidget {
  const IosSheetNavBar({
    super.key,
    required this.title,
    this.onCancel,
    this.onDone,
    this.doneLabel = 'Xong',
    this.cancelLabel = 'Hủy',
    this.busy = false,
    this.doneKey = const ValueKey('ios-sheet-done'),
    this.cancelEnabled = true,
    this.showCancel = true,
  });

  /// false: an nut Huy (thay doi ap dung ngay, chi co "Xong").
  final bool showCancel;

  final String title;
  final Key doneKey;

  /// false: nut Huy bi tat (dang gui).
  final bool cancelEnabled;

  /// null -> dong sheet.
  final VoidCallback? onCancel;

  /// null -> nut Xong bi tat (form chua hop le).
  final VoidCallback? onDone;
  final String doneLabel;
  final String cancelLabel;

  /// Dang gui: thay nut Xong bang vong xoay.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    TextStyle s(bool bold, bool enabled) => TypeScale.iosBody.copyWith(
      fontFamily: TypeScale.family,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      color: enabled ? Palette.white : Palette.highlight,
    );
    final Widget titleText = Semantics(
      header: true,
      child: Text(
        title,
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TypeScale.headline.copyWith(color: Palette.white),
      ),
    );
    // Chu lon (>= 1.4x): tieu de xuong dong rieng duoi hai nut de khong tran.
    final bool stacked = MediaQuery.textScalerOf(context).scale(17) > 24;
    final List<Widget> buttons = [
      if (!showCancel)
        const SizedBox(width: Touch.min)
      else
        CupertinoButton(
          key: const ValueKey('ios-sheet-cancel'),
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          minimumSize: const Size(Touch.min, Touch.min),
          onPressed: !cancelEnabled
              ? null
              : onCancel ?? () => Navigator.of(context).maybePop(),
          child: Text(cancelLabel, style: s(false, cancelEnabled)),
        ),
    ];
    final Widget doneButton = Semantics(
      enabled: onDone != null && !busy,
      button: true,
      label: busy ? 'Đang xử lý' : null,
      child: CupertinoButton(
        key: doneKey,
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        minimumSize: const Size(Touch.min, Touch.min),
        onPressed: onDone == null || busy
            ? null
            : () {
                AppHaptics.light();
                onDone!();
              },
        child: busy
            ? const CupertinoActivityIndicator()
            : Text(doneLabel, style: s(true, onDone != null)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.m),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ...buttons,
                    const Spacer(),
                    Flexible(child: doneButton),
                  ],
                ),
                titleText,
              ],
            )
          : Row(
              children: [
                ...buttons,
                Expanded(child: titleText),
                doneButton,
              ],
            ),
    );
  }
}

/// Chon ngay / gio bang CupertinoDatePicker trong sheet (Huy / Xong).
/// Tra ve null khi huy.
Future<DateTime?> showIosDateTimeSheet(
  BuildContext context, {
  required String title,
  required DateTime initial,
  CupertinoDatePickerMode mode = CupertinoDatePickerMode.time,
  DateTime? minimum,
  DateTime? maximum,
  int minuteInterval = 1,
}) {
  DateTime value = initial;
  return showIosSheet<DateTime>(
    context,
    form: true,
    scrollable: false,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSheetNavBar(
          title: title,
          onDone: () => Navigator.of(ctx).pop(value),
        ),
        SizedBox(
          height: 216,
          child: CupertinoTheme(
            data: CupertinoTheme.of(ctx).copyWith(
              brightness: Brightness.dark,
              textTheme: CupertinoTheme.of(ctx).textTheme.copyWith(
                dateTimePickerTextStyle: CupertinoTheme.of(ctx)
                    .textTheme
                    .dateTimePickerTextStyle
                    .copyWith(color: Palette.white),
              ),
            ),
            child: CupertinoDatePicker(
              key: const ValueKey('ios-date-picker'),
              mode: mode,
              use24hFormat: true,
              initialDateTime: initial,
              minimumDate: minimum,
              maximumDate: maximum,
              minuteInterval: minuteInterval,
              onDateTimeChanged: (d) => value = d,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Chon gio (TimeOfDay) - thay showTimePicker.
Future<TimeOfDay?> showIosTimeSheet(
  BuildContext context, {
  required String title,
  required TimeOfDay initial,
}) async {
  final now = DateTime.now();
  final d = await showIosDateTimeSheet(
    context,
    title: title,
    initial: DateTime(
      now.year,
      now.month,
      now.day,
      initial.hour,
      initial.minute,
    ),
  );
  return d == null ? null : TimeOfDay(hour: d.hour, minute: d.minute);
}

/// Sheet giai thich (nut (i)): tieu de + doan chu, dong bang x / vuot xuong.
Future<void> showIosInfoSheet(
  BuildContext context, {
  required String title,
  required String message,
}) => showIosSheet<void>(
  context,
  title: title,
  builder: (c) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s),
    child: Text(
      message,
      style: TypeScale.iosBody.copyWith(color: Palette.white),
    ),
  ),
);
