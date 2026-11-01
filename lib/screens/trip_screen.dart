/// Man "Ra ngoài" (nhom 6, cung ten voi tab): chon diem den / phuong tien / gio di, xem tuyen
/// to mau theo thoi tiet, bat dau / tam dung / ket thuc, lich su.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../providers/location_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/weather_provider.dart';
import '../services/gps_service.dart';
import '../services/route_service.dart';
import '../services/trip_location.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/home_tab_scope.dart';
import '../ui/weather/widgets/ios_controls.dart';
import '../ui/weather/widgets/ios_list.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../ui/weather/widgets/ios_sheet.dart';
import 'trip/driving_view.dart';
import 'trip/nowcast_card.dart';
import 'trip/route_map.dart';
import 'trip/route_summary.dart';
import 'trip/trip_history_widgets.dart';
import 'trip/trip_setup_controller.dart';
import '../ui/weather/widgets/app_segmented_control.dart';
import '../ui/weather/widgets/adaptive_dialog.dart';
import '../utils/forecast_format.dart';

export 'trip/trip_helpers.dart';

class TripScreen extends StatefulWidget {
  const TripScreen({
    super.key,
    this.locations,
    this.gps = const GeolocatorGps(),
    this.showTiles = true,
    this.quickStart = false,
  });

  /// null = lay tu Provider.
  final LocationProvider? locations;

  /// "Tôi sắp ra ngoài": diem di GPS, khong co tuyen, hien mua 2 gio toi.
  final bool quickStart;
  final GpsService gps;

  /// Tat lop nen OSM (test).
  final bool showTiles;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> with HomeTabRoot {
  /// Du lieu "mưa 2 giờ tới" cu hon moc nay -> tai lai khi mo lai tab.
  static const Duration nowcastMaxAge = Duration(minutes: 10);

  /// Lan thu tai gan nhat (ke ca loi GPS) - tranh tai lai lien tuc.
  DateTime? _nowcastTriedAt;

  late final _c = TripSetupController(
    gps: widget.gps,
    withRoute: !widget.quickStart,
    // Che do xem lai: "mưa 2 giờ tới" lay du lieu cua thoi diem xem lai.
    replayAt: () {
      final wp = context.read<WeatherProvider?>();
      return wp != null && wp.isReplay ? wp.replayAt : null;
    },
  )..addListener(_onChanged);
  final _search = TextEditingController();

  LocationProvider get _lp =>
      widget.locations ?? context.read<LocationProvider>();
  TripProvider get _trip => context.read<TripProvider>();

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    if (widget.quickStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNowcast());
    }
  }

  /// Mua 2 gio toi tai vi tri GPS hien tai.
  Future<void> _loadNowcast() async {
    if (!mounted) return;
    _nowcastTriedAt = _trip.nowHcm;
    await _c.loadNowcast(_trip);
  }

  /// Tab giu nguyen trang thai: mo lai tab "Ra ngoài" khi du lieu da cu
  /// (> [nowcastMaxAge]) -> tai lai.
  @override
  void onTabSelected() {
    if (_c.withRoute) return;
    final trip = _trip;
    if (trip.isRunning || trip.nowcastLoading) return;
    final at = trip.nowcastUpdatedAt ?? _nowcastTriedAt;
    if (at == null || trip.nowHcm.difference(at) > nowcastMaxAge) {
      _loadNowcast();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final now = _trip.nowHcm;
    final t = await showIosTimeSheet(
      context,
      title: 'Giờ khởi hành',
      initial: TimeOfDay(hour: now.hour, minute: now.minute),
    );
    if (t == null || !mounted) return;
    _c.setDepartAt(
      TripSetupController.nextDeparture(now, t.hour, t.minute),
      _trip,
    );
  }

  Future<void> _start() => _c.start(
    _trip,
    backgroundSupported: tripBackgroundSupported,
    confirmBackground: _explainBackground,
  );

  /// Giai thich truoc khi he thong hoi quyen vi tri.
  Future<bool?> _explainBackground() => showAppAlert<bool>(
    context,
    title: 'Theo dõi khi tắt màn hình',
    message:
        'Để cảnh báo mưa, dông khi bạn khóa máy hoặc dùng ứng dụng khác, '
        'Sky Weather cần dùng vị trí trong lúc chuyến đi đang chạy. '
        'Hệ thống sẽ hỏi quyền vị trí; trên iOS thanh trạng thái hiện biểu '
        'tượng vị trí, trên Android có thông báo cố định. Chỉ cập nhật khi '
        'bạn đi thêm khoảng 500 m để tiết kiệm pin. Tọa độ không được lưu; '
        'theo dõi dừng ngay khi bạn bấm Kết thúc.',
    actions: const [
      AppDialogAction(label: 'Để sau', value: false),
      AppDialogAction(label: 'Tiếp tục', value: true, isDefault: true),
    ],
  );

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final trip = context.watch<TripProvider>();
    if (trip.isRunning) return DrivingView(trip: trip);
    return IosPageScaffold(
      title: 'Ra ngoài',
      controller: tabScroll,
      onRefresh: _loadNowcast,
      children: [
        if (trip.phase == TripPhase.ended) ...[
          EndedCard(trip: trip, locations: _lp),
          const SizedBox(height: Space.cardGap),
        ],
        if (!_c.withRoute) ...[
          NowcastCard(trip: trip, onRetry: _loadNowcast),
          const SizedBox(height: Space.cardGap),
          _startCard(context, trip),
          const SizedBox(height: Space.cardGap),
        ],
        _setupCard(context, trip),
        if (_c.withRoute && trip.plan != null) ...[
          const SizedBox(height: Space.cardGap),
          RouteMap(
            route: trip.plan!,
            showTiles: widget.showTiles,
            fromLabel: trip.planFromLabel,
            toLabel: 'Điểm đến · ${trip.planToLabel}',
          ),
          const SizedBox(height: Space.cardGap),
          RouteSummary(
            trip: trip,
            fromLabel: trip.planFromLabel,
            toLabel: trip.planToLabel,
          ),
        ],
        if (_c.withRoute) ...[
          const SizedBox(height: Space.cardGap),
          _startCard(context, trip),
        ],
        const SizedBox(height: Space.cardGap),
        HistoryCard(trip: trip, locations: _lp),
      ],
    );
  }

  Widget _setupCard(BuildContext context, TripProvider trip) {
    final ink = GlassInk.of(context);
    final saved = [
      for (final s in _lp.saved) (s.labelText, _lp.placeById(s.locationId)),
    ];
    return GlassCard(
      title: 'LÊN KẾ HOẠCH',
      icon: Icons.route_rounded,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSegmentedControl<bool>(
              segments: const [
                AppSegment(value: true, label: 'Có tuyến đường'),
                AppSegment(value: false, label: 'Không có tuyến'),
              ],
              selected: _c.withRoute,
              onChanged: (v) => _c.setWithRoute(v, trip),
            ),
            const SizedBox(height: Space.s),
            if (!_c.withRoute)
              Text(
                'Kiểm tra thời tiết tại nơi bạn đang ở mỗi khi sang khu vực '
                'khác hoặc mỗi 15 phút.',
                style: TypeScale.body.copyWith(color: ink.secondary),
              )
            else ...[
              IosListSection(
                margin: EdgeInsets.zero,
                dividerIndent: Space.l + IconSizes.md + Space.m,
                children: [
                  IosListRow(
                    key: const ValueKey('trip-from'),
                    leading: const Icon(
                      CupertinoIcons.location,
                      color: Palette.white,
                    ),
                    title: 'Điểm đi',
                    subtitle: _c.from == null
                        ? 'Vị trí hiện tại (GPS)'
                        : _fromLabel(saved, _c.from!),
                    onTap: () => _pickFrom(saved),
                  ),
                  if (_c.to != null)
                    IosListRow(
                      leading: const Icon(
                        CupertinoIcons.flag,
                        color: Palette.white,
                      ),
                      title: 'Điểm đến',
                      subtitle: _c.to!.name,
                      trailing: IosBarButton(
                        tooltip: 'Đổi điểm đến',
                        icon: CupertinoIcons.xmark_circle_fill,
                        onPressed: () => _c.clearDestination(trip),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Space.s),
              if (_c.to == null) ...[
                Semantics(
                  label: 'Tìm điểm đến (phường, xã)',
                  textField: true,
                  child: CupertinoSearchTextField(
                    controller: _search,
                    placeholder: 'Tìm điểm đến (phường, xã)',
                    style: TypeScale.iosBody.copyWith(
                      fontFamily: TypeScale.family,
                      color: Palette.white,
                    ),
                    placeholderStyle: TypeScale.iosBody.copyWith(
                      fontFamily: TypeScale.family,
                      color: ink.secondary,
                    ),
                    itemColor: ink.secondary,
                    backgroundColor: Palette.subtleFill,
                    borderRadius: BorderRadius.circular(Radii.field),
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.s,
                      vertical: Space.m,
                    ),
                    suffixIcon: const Icon(CupertinoIcons.xmark_circle_fill),
                    onSubmitted: (q) => _c.runSearch(_lp, q),
                  ),
                ),
                if (_c.searching)
                  const Padding(
                    padding: EdgeInsets.all(Space.s),
                    child: CupertinoActivityIndicator(),
                  ),
                if (_c.results.isNotEmpty) ...[
                  const SizedBox(height: Space.s),
                  IosListSection(
                    margin: EdgeInsets.zero,
                    children: [
                      for (final p in _c.results)
                        IosListRow(
                          title: p.name,
                          subtitle: p.region == null
                              ? null
                              : friendlyRegion(p.region!),
                          onTap: () => _c.pickDestination(p, trip),
                        ),
                    ],
                  ),
                ],
                if (_c.results.isEmpty && saved.isNotEmpty)
                  Wrap(
                    spacing: Space.s,
                    children: [
                      for (final (label, p) in saved)
                        IosPill(
                          icon: CupertinoIcons.flag,
                          label: label ?? p.name,
                          selected: false,
                          selectable: false,
                          onChanged: (_) => _c.pickDestination(p, trip),
                        ),
                    ],
                  ),
              ],
              const SizedBox(height: Space.s),
              AppSegmentedControl<TripProfile>(
                segments: [
                  for (final p in TripProfile.values)
                    AppSegment(value: p, label: p.label),
                ],
                selected: _c.profile,
                onChanged: (profile) => _c.setProfile(profile, trip),
              ),
              const SizedBox(height: Space.s),
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.start,
                overflowSpacing: Space.xs,
                children: [
                  Text(
                    _c.departAt == null
                        ? 'Khởi hành: bây giờ'
                        : 'Khởi hành: ${ForecastFormat.dateTime(_c.departAt!)}',
                    style: TypeScale.body.copyWith(color: Palette.white),
                  ),
                  // Chi hien khi da chon gio khac (ve lai "bây giờ"); dang
                  // khoi hanh bay gio thi dong tren da noi ro.
                  if (_c.departAt != null)
                    IosButton.plain(
                      onPressed: () => _c.setDepartAt(null, trip),
                      label: 'Bây giờ',
                    ),
                  IosButton.tinted(
                    onPressed: _pickTime,
                    icon: CupertinoIcons.clock,
                    label: 'Chọn giờ',
                  ),
                ],
              ),
              const SizedBox(height: Space.s),
              if (trip.planning)
                const Padding(
                  padding: EdgeInsets.all(Space.s),
                  child: CupertinoActivityIndicator(),
                ),
              IosButton.filled(
                expand: true,
                onPressed: _c.to == null || trip.planning
                    ? null
                    : () => _c.plan(trip),
                icon: CupertinoIcons.arrow_branch,
                label: trip.planning
                    ? 'Đang tìm tuyến…'
                    : 'Xem tuyến và thời tiết',
              ),
              if (_c.to == null) ...[
                const SizedBox(height: Space.xs),
                Text(
                  'Chọn điểm đến để xem tuyến.',
                  style: TypeScale.small.copyWith(color: ink.secondary),
                ),
              ],
              if (trip.planError != null) ...[
                const SizedBox(height: Space.s),
                Text(
                  trip.planError!,
                  style: TypeScale.body.copyWith(color: Palette.stale),
                ),
              ],
            ],
            if (_c.message != null) ...[
              const SizedBox(height: Space.s),
              Text(
                _c.message!,
                style: TypeScale.body.copyWith(color: Palette.stale),
              ),
              if (!kIsWeb &&
                  _c.gpsIssue != null &&
                  _c.gpsIssue != GpsStatus.unavailable)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IosButton.plain(
                    icon: CupertinoIcons.settings,
                    label: 'Mở cài đặt',
                    onPressed: () => _c.gpsIssue == GpsStatus.serviceDisabled
                        ? _c.gps.openLocationSettings()
                        : _c.gps.openAppSettings(),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _fromLabel(List<(String?, Place)> saved, Place p) {
    for (final (label, q) in saved) {
      if (q.id == p.id) return label == null ? p.name : '$label · ${p.name}';
    }
    return p.name;
  }

  Future<void> _pickFrom(List<(String?, Place)> saved) async {
    final id = await showAppActionSheet<String>(
      context,
      title: 'Điểm đi',
      actions: [
        AppDialogAction(
          label: 'Vị trí hiện tại (GPS)',
          value: '',
          isDefault: _c.from == null,
          icon: CupertinoIcons.location_fill,
        ),
        for (final (label, p) in saved)
          AppDialogAction(
            label: label == null ? p.name : '$label · ${p.name}',
            value: p.id,
            isDefault: _c.from?.id == p.id,
          ),
      ],
    );
    if (id == null || !mounted) return;
    _c.setFrom(id.isEmpty ? null : _lp.placeById(id), _trip);
  }

  Widget _startCard(BuildContext context, TripProvider trip) {
    final ink = GlassInk.of(context);
    final canStart = _c.canStart(trip);
    return GlassCard(
      title: 'THEO DÕI',
      icon: Icons.notifications_active_outlined,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Âm thanh thông báo'),
              subtitle: const Text(
                'Tắt để chỉ hiện thông báo ngắn, không kêu.',
              ),
              value: trip.sound,
              onChanged: trip.setSound,
            ),
            if (tripBackgroundSupported)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tiếp tục khi tắt màn hình'),
                subtitle: const Text(
                  'Theo dõi cả khi khóa máy; tốn pin hơn một chút.',
                ),
                value: _c.background,
                onChanged: _c.setBackground,
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: Text(
                  kIsWeb
                      ? 'Trên trình duyệt, chỉ theo dõi khi tab này đang mở.'
                      : 'Thiết bị này chỉ theo dõi khi ứng dụng đang mở.',
                  style: TypeScale.body.copyWith(color: ink.secondary),
                ),
              ),
            const SizedBox(height: Space.s),
            IosButton.filled(
              key: const ValueKey('trip-start'),
              expand: true,
              // Nut chinh lon (de bam khi dang di chuyen).
              minHeight: 64,
              onPressed: canStart ? _start : null,
              icon: CupertinoIcons.play_fill,
              label: _c.withRoute ? 'Bắt đầu theo tuyến' : 'Bắt đầu theo dõi',
            ),
            // Chua chon diem den: goi y da hien o nut "Xem tuyến" phia tren.
            if (!canStart && _c.to != null) ...[
              const SizedBox(height: Space.xs),
              Text(
                'Bấm "Xem tuyến và thời tiết" trước khi bắt đầu.',
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
            ],
            if (!_c.withRoute) ...[
              const SizedBox(height: Space.s),
              IosButton.tinted(
                key: const ValueKey('trip-pick-destination'),
                expand: true,
                onPressed: () => _c.setWithRoute(true, trip),
                icon: CupertinoIcons.flag,
                label: 'Chọn điểm đến',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
