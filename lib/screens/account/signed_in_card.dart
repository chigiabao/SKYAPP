part of '../account_screen.dart';

class _SignedInCard extends StatelessWidget {
  const _SignedInCard({required this.exporter});

  final JsonExporter exporter;

  static String _time(DateTime t) {
    return ForecastFormat.dateTime(HcmTime.fromInstant(t));
  }

  @override
  Widget build(BuildContext context) {
    final a = context.watch<AccountProvider>();
    final ink = GlassInk.of(context);
    final last = a.lastSyncedAt;
    final (IconData icon, Color color, String status) = switch (a.state) {
      SyncState.syncing => (Icons.sync_rounded, Palette.white, 'Đang đồng bộ…'),
      SyncState.pending => (
        Icons.cloud_off_rounded,
        ink.warning,
        'Chưa có mạng — thay đổi sẽ được đồng bộ sau.',
      ),
      SyncState.error => (
        Icons.error_outline_rounded,
        Theme.of(context).colorScheme.error,
        'Lỗi đồng bộ: ${a.lastError ?? ''}',
      ),
      SyncState.idle => (
        Icons.cloud_done_rounded,
        Palette.white,
        last == null ? 'Chưa đồng bộ' : 'Đã đồng bộ lúc ${_time(last)}',
      ),
    };

    return IosListSection.padded(
      header: 'Tài khoản',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            a.email ?? '',
            style: TypeScale.label.copyWith(color: Palette.white),
          ),
          const SizedBox(height: Space.m),
          Semantics(
            liveRegion: true,
            label:
                'Trạng thái đồng bộ: $status'
                '${last != null && a.state != SyncState.idle ? '. Lần cuối ${_time(last)}' : ''}',
            excludeSemantics: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: IconSizes.md),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status,
                        style: TypeScale.body.copyWith(color: color),
                      ),
                      if (last != null && a.state != SyncState.idle)
                        Text(
                          'Lần cuối: ${_time(last)}',
                          style: TypeScale.small.copyWith(color: ink.secondary),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.m),
          _ActionButton(
            icon: Icons.sync_rounded,
            label: 'Đồng bộ ngay',
            onPressed: a.state == SyncState.syncing || a.busy
                ? null
                : a.syncNow,
          ),
          const SizedBox(height: Space.s),
          _ActionButton(
            icon: Icons.file_download_outlined,
            label: 'Xuất dữ liệu',
            onPressed: a.busy
                ? null
                : () => exportJson(
                    context,
                    exporter,
                    'sky-weather-export.json',
                    a.exportServerData,
                  ),
          ),
          const SizedBox(height: Space.s),
          _ActionButton(
            icon: Icons.cloud_off_outlined,
            label: 'Xóa dữ liệu đồng bộ',
            onPressed: a.busy ? null : () => _deleteData(context, a),
          ),
          const SizedBox(height: Space.s),
          _ActionButton(
            icon: Icons.logout_rounded,
            label: 'Đăng xuất',
            onPressed: a.busy ? null : () => _signOut(context, a),
          ),
          const SizedBox(height: Space.l),
          IosButton.tinted(
            expand: true,
            destructive: true,
            onPressed: a.busy ? null : () => _deleteAccount(context, a),
            icon: CupertinoIcons.trash,
            label: 'Xóa tài khoản',
          ),
        ],
      ),
    );
  }

  Future<void> _signOut(BuildContext context, AccountProvider a) async {
    final overlay = iosToastOverlay(context);
    await a.signOut();
    showIosToastIn(overlay, 'Đã đăng xuất. Dữ liệu trên máy vẫn giữ nguyên.');
  }

  Future<void> _deleteData(BuildContext context, AccountProvider a) async {
    final overlay = iosToastOverlay(context);
    final ok = await showAppAlert<bool>(
      context,
      title: 'Xóa dữ liệu đồng bộ?',
      message:
          'Dữ liệu đã đồng bộ trên máy chủ sẽ bị xóa. Tài khoản và dữ liệu '
          'trên máy này vẫn giữ nguyên; thay đổi sau này sẽ được đồng bộ '
          'lại (đăng xuất nếu không muốn đồng bộ).',
      actions: const [
        AppDialogAction(label: 'Hủy', value: false, isDefault: true),
        AppDialogAction(label: 'Xóa', value: true, isDestructive: true),
      ],
    );
    if (ok != true) return;
    final err = await a.deleteSyncedData();
    showIosToastIn(
      overlay,
      err ?? 'Đã xóa dữ liệu đồng bộ trên máy chủ.',
      tone: err == null ? IosToastTone.success : IosToastTone.error,
    );
  }

  Future<void> _deleteAccount(BuildContext context, AccountProvider a) async {
    final overlay = iosToastOverlay(context);
    final password = await showIosSheet<String>(
      context,
      form: true,
      builder: (c) => const _DeleteAccountDialog(),
    );
    if (password == null) return;
    final err = await a.deleteAccount(password);
    showIosToastIn(
      overlay,
      err ?? 'Đã xóa tài khoản và toàn bộ dữ liệu đồng bộ.',
      tone: err == null ? IosToastTone.success : IosToastTone.error,
    );
  }
}
