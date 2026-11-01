/// Chu giai, nhan tren o, huy hieu va ghim dia diem.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../providers/preferences_provider.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/widgets/glass_card.dart';
import '../../widgets/map_attribution_link.dart';
import '../map_screen.dart';

/// Chu giai lop + ghi chu do phan giai + ghi cong OSM.
///
/// Gon (mac dinh tren dien thoai, be ngang < 600): MOT hang thang mau co
/// SO tung moc (khong chi dua vao mau) + o "Không có dữ liệu" + nut
/// "Chú giải" mo phan day du; ghi cong OSM luon hien.
class MapLegend extends StatefulWidget {
  const MapLegend({
    super.key,
    required this.layer,
    required this.entries,
    this.outlookSource,
    this.hasMissing = false,
    this.initiallyExpanded,
  });

  final MapLayerKind layer;
  final List<LegendEntry> entries;

  /// `outlook_source` cua khung (lop mua: ghi nguon "3 gio toi").
  final String? outlookSource;

  /// Co o khong co so lieu cho lop nay -> them o mau "Không có dữ liệu".
  final bool hasMissing;

  /// null: mo san khi man rong (>= 600), gon tren dien thoai.
  final bool? initiallyExpanded;

  @override
  State<MapLegend> createState() => _MapLegendState();
}

class _MapLegendState extends State<MapLegend> {
  bool? _expanded;

  MapLayerKind get layer => widget.layer;
  List<LegendEntry> get entries => widget.entries;
  String? get outlookSource => widget.outlookSource;
  bool get hasMissing => widget.hasMissing;

  List<LegendEntry> get _all => [
    ...entries,
    if (hasMissing) const LegendEntry(MapScale.noData, 'Không có dữ liệu'),
  ];

  /// O mau chu giai = mau o THUC TE tren ban do (cung do mo
  /// [kCellFillAlpha] tron len nen), khong dung mau dac.
  static Widget swatch(Color c) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      color: cellFillOnBase(c),
      borderRadius: BorderRadius.circular(2),
      border: Border.all(color: Palette.white, width: 1),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final expanded =
        _expanded ??
        widget.initiallyExpanded ??
        MediaQuery.sizeOf(context).width >= 600;
    final toggle = Semantics(
      button: true,
      expanded: expanded,
      label: expanded ? 'Thu gọn chú giải' : 'Chú giải',
      excludeSemantics: true,
      child: CupertinoButton(
        key: const ValueKey('map-legend-toggle'),
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        minimumSize: const Size(Touch.min, Touch.min),
        onPressed: () => setState(() => _expanded = !expanded),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              expanded ? 'Thu gọn' : 'Chú giải',
              style: TypeScale.subhead.copyWith(
                color: Palette.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: Space.xs),
            Icon(
              expanded
                  ? CupertinoIcons.chevron_down
                  : CupertinoIcons.chevron_up,
              size: 14,
              color: Palette.white,
            ),
          ],
        ),
      ),
    );
    if (expanded) {
      return KeyedSubtree(
        key: const ValueKey('map-legend-expanded'),
        child: _details(context, toggle),
      );
    }
    final small = TypeScale.small.copyWith(color: Palette.white);
    return GlassSurface(
      key: const ValueKey('map-legend-compact'),
      tint: Palette.sheetBase,
      padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.xs, Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  label: 'Thang màu: ${_all.map((e) => e.label).join(', ')}',
                  excludeSemantics: true,
                  child: Wrap(
                    spacing: Space.s,
                    runSpacing: 2,
                    children: [
                      for (final e in _all)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            swatch(e.color),
                            const SizedBox(width: 3),
                            Text(
                              e.label,
                              style: small.copyWith(fontFeatures: kTabular),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              toggle,
            ],
          ),
          MapAttributionLink(
            text: kOsmAttribution,
            style: small.copyWith(color: Palette.secondary),
          ),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, Widget toggle) {
    final small = TypeScale.small.copyWith(color: Palette.white);
    return GlassSurface(
      tint: Palette.sheetBase,
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(switch (layer) {
                  MapLayerKind.temperature =>
                    'NHIỆT ĐỘ · MÀU THEO THẤP–CAO KHUNG NÀY',
                  MapLayerKind.rain => 'KHẢ NĂNG MƯA 3 GIỜ TỚI',
                  MapLayerKind.wind =>
                    'GIÓ (${PreferencesProvider.unitsOf(context).wind.label.toUpperCase()}) '
                        '· MŨI TÊN CHỈ HƯỚNG GIÓ THỔI TỚI',
                }, style: TypeScale.cardTitle.copyWith(color: Palette.title)),
              ),
              toggle,
            ],
          ),
          if (layer == MapLayerKind.rain &&
              outlookSourceLabel(outlookSource) != null)
            Text(
              'Nguồn: ${outlookSourceLabel(outlookSource)}',
              style: small.copyWith(color: Palette.secondary),
            ),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: Space.m,
            runSpacing: Space.xs,
            children: [
              for (final e in [
                ...entries,
                if (hasMissing)
                  const LegendEntry(MapScale.noData, 'Không có dữ liệu'),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    swatch(e.color),
                    const SizedBox(width: Space.xs),
                    Text(
                      e.label,
                      style: small.copyWith(fontFeatures: kTabular),
                    ),
                  ],
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 14,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.fromBorderSide(
                                BorderSide(color: Palette.alert, width: 2),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: -5,
                          top: -5,
                          child: MapAlertBadge(size: 10),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  Text('Ô có cảnh báo mưa/dông', style: small),
                ],
              ),
              if (layer == MapLayerKind.wind)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MapGustBadge(),
                    const SizedBox(width: Space.xs),
                    Text(
                      'Giật ≥ '
                      '${PreferencesProvider.unitsOf(context).windText(kStrongGustKmh)}',
                      style: small,
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: Space.s),
          // Khong chi dua vao mau: so hien tren o khi phong to; cham o / nut
          // danh sach de doc gia tri.
          Text(
            'Phóng to để hiện số trên ô; chạm ô hoặc mở danh sách để đọc '
            'giá trị.',
            style: small.copyWith(color: Palette.secondary),
          ),
          const SizedBox(height: 2),
          Text(
            kMapResolutionNote,
            style: small.copyWith(color: Palette.secondary),
          ),
          const SizedBox(height: 2),
          MapAttributionLink(
            text: kOsmAttribution,
            style: small.copyWith(color: Palette.secondary),
          ),
        ],
      ),
    );
  }
}

/// Nhan tren o (chi ve khi o du rong): so + mui ten gio (lop gio). Mau chu
/// chon theo do sang nen o, them vien sang/toi nguoc mau de luon >= 4.5:1.
class CellLabel extends StatelessWidget {
  const CellLabel({super.key, required this.data, required this.arrow});

  final CellMarkerData data;
  final bool arrow;

  @override
  Widget build(BuildContext context) {
    final ink = labelInkFor(cellFillOnBase(data.color));
    final halo = ink == Palette.white ? kLabelDark : Palette.white;
    final shadows = [
      for (final o in const [
        Offset(1, 0),
        Offset(-1, 0),
        Offset(0, 1),
        Offset(0, -1),
      ])
        Shadow(color: halo, offset: o, blurRadius: 1.5),
    ];
    final angle = data.arrowAngle;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (arrow && angle != null)
              Transform.rotate(
                key: const ValueKey('wind-arrow'),
                angle: angle,
                child: Icon(
                  Icons.navigation_rounded,
                  size: 16,
                  color: ink,
                  shadows: shadows,
                ),
              ),
            Text(
              data.value,
              style: TypeScale.footnote.copyWith(
                height: 1.1,
                fontWeight: FontWeight.w800,
                color: ink,
                shadows: shadows,
                fontFeatures: kTabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Huy hieu canh bao o goc tren-phai cua o.
class MapAlertBadge extends StatelessWidget {
  const MapAlertBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Palette.alert,
        shape: BoxShape.circle,
        border: Border.all(color: MapScale.ink, width: 1),
      ),
      child: Icon(
        Icons.priority_high_rounded,
        size: size * 0.7,
        color: Palette.onAlert,
      ),
    );
  }
}

/// Nhan gio giat manh (vien trang + nen do dam, icon >= 3:1).
class MapGustBadge extends StatelessWidget {
  const MapGustBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: MapScale.gust,
        shape: BoxShape.circle,
        border: Border.all(color: Palette.white, width: 1),
      ),
      child: Icon(Icons.air_rounded, size: size * 0.7, color: Palette.white),
    );
  }
}

class MapPlacePin extends StatelessWidget {
  const MapPlacePin({
    super.key,
    required this.name,
    required this.current,
    required this.focused,
    required this.onTap,
  });

  final String name;
  final bool current;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label:
          '${current ? 'Vị trí hiện tại' : 'Địa điểm đã lưu'}: $name'
          '${focused ? ', đang xem' : ''}',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox.square(
            dimension: 32,
            child: Icon(
              current ? Icons.near_me_rounded : Icons.location_on_rounded,
              size: 30,
              color: focused ? Palette.alert : Palette.white,
              shadows: const [
                Shadow(color: DataColors.pinShadow, blurRadius: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
