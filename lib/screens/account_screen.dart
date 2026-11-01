import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/hcm_time.dart';
import '../providers/account_provider.dart';
import '../services/account_service.dart';
import '../services/download/download_file.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/adaptive_dialog.dart';
import '../ui/weather/widgets/app_segmented_control.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/ios_controls.dart';
import '../ui/weather/widgets/ios_list.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../ui/weather/widgets/ios_sheet.dart';
import 'account/password_reset_dialog.dart';
import '../ui/weather/widgets/ios_toast.dart';
import '../utils/haptics.dart';
import '../utils/forecast_format.dart';

part 'account/account_widgets.dart';
part 'account/sign_in_card.dart';
part 'account/signed_in_card.dart';
part 'account/delete_account_dialog.dart';

/// Luu / chia se file JSON; tra ve duong dan da luu (null tren web = tai
/// xuong qua trinh duyet).
typedef JsonExporter = Future<String?> Function(String fileName, String json);

/// Mobile / desktop: ghi vao thu muc tai lieu cua app (path_provider) roi mo
/// bang chia se. Web: tai file JSON xuong (Blob + the a, khong Web Share).
Future<String?> defaultJsonExporter(String fileName, String json) async {
  final bytes = Uint8List.fromList(utf8.encode(json));
  if (kIsWeb) {
    downloadBytes(bytes, fileName, 'application/json');
    return null;
  }
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: fileName,
      ),
    );
  } catch (e) {
    // Desktop co the khong co bang chia se: file da luu.
    debugPrint('share: $e');
  }
  return file.path;
}

final RegExp _emailRe = RegExp(r'^[^@\s]{1,64}@[^@\s]+\.[^@\s]{2,}$');

/// "Tài khoản và đồng bộ" (tuy chon): dang nhap / dang ky, trang thai dong
/// bo, xuat / xoa du lieu, xoa tai khoan, chinh sach quyen rieng tu.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, this.exporter = defaultJsonExporter});

  final JsonExporter exporter;

  @override
  Widget build(BuildContext context) => GlassPage(
    child: Builder(builder: (context) => _AccountBody(exporter: exporter)),
  );
}

class _AccountBody extends StatelessWidget {
  const _AccountBody({required this.exporter});

  final JsonExporter exporter;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final account = context.watch<AccountProvider>();
    final notice = account.notice;

    return IosPageScaffold(
      title: 'Tài khoản',
      children: [
        IosListSection.padded(
          header: 'Tài khoản tùy chọn',
          child: Text(
            'Không cần tài khoản để dùng app. Tài khoản chỉ để đồng bộ địa '
            'điểm đã lưu, cài đặt và lịch hoạt động giữa các thiết bị. '
            'Không bao giờ gửi tọa độ GPS; thói quen chỉ được đồng bộ khi '
            'bạn đã đồng ý học thói quen.',
            style: TypeScale.body.copyWith(color: Palette.white),
          ),
        ),
        if (notice != null) ...[
          const SizedBox(height: Space.cardGap),
          _NoticeCard(text: notice, onClose: account.clearNotice),
        ],
        const SizedBox(height: Space.cardGap),
        if (account.isLoggedIn)
          _SignedInCard(exporter: exporter)
        else if (account.isReady)
          const _SignInCard()
        else
          IosListSection.padded(
            child: Center(child: CupertinoActivityIndicator()),
          ),
        const SizedBox(height: Space.cardGap),
        IosListSection.padded(
          header: 'Dữ liệu trên máy',
          footer:
              'Tệp JSON gồm địa điểm đã lưu, cài đặt, hoạt động và thói quen '
              'trên thiết bị này. Không có tọa độ GPS.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ActionButton(
                icon: Icons.download_rounded,
                label: 'Xuất dữ liệu trên máy',
                onPressed: () => exportJson(
                  context,
                  exporter,
                  'sky-weather-du-lieu-tren-may.json',
                  () async => account.exportLocalData(),
                ),
              ),
              const SizedBox(height: Space.s),
              _ActionButton(
                icon: Icons.privacy_tip_outlined,
                label: 'Chính sách quyền riêng tư',
                onPressed: () => showPrivacyDialog(context, account),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.l),
        Text(
          'Tài khoản không hoạt động 2 năm sẽ bị xóa cùng toàn bộ dữ liệu.',
          textAlign: TextAlign.center,
          style: TypeScale.small.copyWith(color: ink.secondary),
        ),
      ],
    );
  }
}

/// Xuat [load] ra tep [fileName] qua [exporter] + bao ket qua.
Future<void> exportJson(
  BuildContext context,
  JsonExporter exporter,
  String fileName,
  Future<String> Function() load,
) async {
  final overlay = iosToastOverlay(context);
  try {
    final path = await exporter(fileName, await load());
    showIosToastIn(
      overlay,
      path == null ? 'Đã tải tệp $fileName.' : 'Đã lưu tệp tại $path',
      tone: IosToastTone.success,
    );
  } on AccountException catch (e) {
    showIosToastIn(overlay, e.message, tone: IosToastTone.error);
  } catch (e) {
    debugPrint('export: $e');
    showIosToastIn(
      overlay,
      'Không xuất được dữ liệu.',
      tone: IosToastTone.error,
    );
  }
}

// ---------------------------------------------------------------------------
