/// Hop thoai va bang hanh dong kieu iOS dung chung (CupertinoAlertDialog,
/// CupertinoActionSheet) cho moi nen tang - giong cach app chon ngon ngu
/// thiet ke iOS o khap noi (xem lib/utils/theme.dart).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../utils/haptics.dart';
import '../../../utils/theme.dart';
import 'glass_page.dart';

/// Mot nut trong hop thoai / bang hanh dong. [value] duoc tra ve khi bam.
class AppDialogAction<T> {
  const AppDialogAction({
    required this.label,
    required this.value,
    this.isDefault = false,
    this.isDestructive = false,
    this.icon,
  });

  final String label;
  final T value;
  final bool isDefault;
  final bool isDestructive;

  /// Chi dung trong bang hanh dong (hien truoc nhan).
  final IconData? icon;
}

/// Theme cua app (khong phai theme kinh) de hop thoai doc duoc tren moi nen.
/// Luon kieu toi (dong bo voi cac man kinh toi cua app, ke ca Cai dat).
Widget _appThemed(BuildContext context, Widget child) {
  final theme = AppThemeScope.maybeOf(context) ?? Theme.of(context);
  final dark = theme.brightness == Brightness.dark ? theme : AppTheme.darkTheme;
  return Theme(
    data: dark,
    child: CupertinoTheme(
      data: MaterialBasedCupertinoThemeData(materialTheme: dark)
          .copyWith(brightness: Brightness.dark),
      child: child,
    ),
  );
}

/// Hop thoai canh bao iOS. Tra ve value cua nut da bam, null neu dong.
Future<T?> showAppAlert<T>(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  required List<AppDialogAction<T>> actions,
  bool barrierDismissible = true,
}) {
  return showCupertinoDialog<T>(
    context: context,
    // Navigator goc: hop thoai phu ca thanh tab.
    useRootNavigator: true,
    barrierDismissible: barrierDismissible,
    builder: (c) => _appThemed(
      context,
      CupertinoAlertDialog(
        title: Text(title),
        content:
            content ??
            (message == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(message),
                  )),
        actions: [
          for (final a in actions)
            CupertinoDialogAction(
              isDefaultAction: a.isDefault,
              isDestructiveAction: a.isDestructive,
              onPressed: () {
                if (a.isDefault || a.isDestructive) AppHaptics.light();
                Navigator.of(c).pop(a.value);
              },
              child: Text(a.label),
            ),
        ],
      ),
    ),
  );
}

/// Bang hanh dong iOS (thay cho menu bat ra). Nut "Hủy" tach rieng.
Future<T?> showAppActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<AppDialogAction<T>> actions,
  String cancelLabel = 'Hủy',
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    useRootNavigator: true,
    builder: (c) => _appThemed(
      context,
      CupertinoActionSheet(
        title: title == null ? null : Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final a in actions)
            CupertinoActionSheetAction(
              isDefaultAction: a.isDefault,
              isDestructiveAction: a.isDestructive,
              onPressed: () {
                AppHaptics.selection();
                Navigator.of(c).pop(a.value);
              },
              child: a.icon == null
                  ? Text(a.label)
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          a.icon,
                          size: 20,
                          color: a.isDestructive
                              ? CupertinoColors.destructiveRed
                              : null,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: Text(a.label)),
                      ],
                    ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(c).pop(),
          child: Text(cancelLabel),
        ),
      ),
    ),
  );
}
