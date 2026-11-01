import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/units.dart';
import '../../models/weather_alerts.dart';
import '../../providers/location_provider.dart';
import '../../providers/planner_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../ui/weather/design_tokens.dart';
import 'settings_common.dart';
import '../../ui/weather/widgets/ios_controls.dart';
import '../../ui/weather/widgets/ios_sheet.dart';

/// "Địa điểm": bat/tat canh bao va nguong rieng cho tung dia diem.
class SettingsPlacesSection extends StatelessWidget {
  const SettingsPlacesSection({super.key});

  static LocationProvider? _locations(BuildContext context) {
    try {
      return Provider.of<LocationProvider>(context);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final planner = maybePlanner(context);
    final lp = _locations(context);
    if (planner == null || lp == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(Space.l),
          child: SettingsNote('Chưa tải được danh sách địa điểm.'),
        ),
      );
    }
    final s = planner.settings;
    final pages = lp.pages;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(Space.l, Space.l, Space.l, 0),
            child: SettingsNote(
              'Bật/tắt cảnh báo cho từng nơi; đặt ngưỡng riêng nếu muốn. '
              'Cài đặt theo hoạt động nằm ở mục Hoạt động.',
            ),
          ),
          for (final e in pages) ...[
            Builder(
              builder: (context) {
                final place = lp.placeById(e.locationId);
                final label = lp.labelFor(e);
                final o = s.placeOverride(e.locationId);
                final title = label == null
                    ? place.name
                    : '$label · ${place.name}';
                final custom = o.thresholds.length;
                return Column(
                  children: [
                    SettingsSwitchTile(
                      secondary: const SettingsIcon(CupertinoIcons.location),
                      title: Text(title),
                      subtitle: Text(
                        !o.enabled
                            ? 'Đã tắt cảnh báo'
                            : custom == 0
                            ? 'Dùng ngưỡng chung'
                            : '$custom ngưỡng riêng',
                      ),
                      value: o.enabled,
                      onChanged: (v) => planner.setSettings(
                        s.withPlace(e.locationId, o.copyWith(enabled: v)),
                      ),
                    ),
                    if (o.enabled)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: Space.s),
                          child: TextButton.icon(
                            onPressed: () => showIosSheet<void>(
                              context,
                              form: true,
                              scrollable: false,
                              builder: (_) => _PlaceThresholdDialog(
                                placeId: e.locationId,
                                placeName: title,
                                planner: planner,
                                units: PreferencesProvider.unitsOf(context),
                                formatTemp: PreferencesProvider.unitsOf(context)
                                    .tempText,
                              ),
                            ),
                            icon: const Icon(
                              CupertinoIcons.slider_horizontal_3,
                            ),
                            label: Text('Ngưỡng riêng cho ${place.name}'),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Hop thoai nguong rieng: moi loai co cong tac "Riêng" + thanh truot.
/// Gia tri luu theo don vi goc; nhan hien theo don vi nguoi dung chon.
class _PlaceThresholdDialog extends StatelessWidget {
  const _PlaceThresholdDialog({
    required this.placeId,
    required this.placeName,
    required this.planner,
    required this.units,
    required this.formatTemp,
  });

  final String placeId;
  final String placeName;
  final PlannerProvider planner;
  final UnitPrefs units;
  final String Function(double c) formatTemp;

  /// (min, max, buoc) theo don vi goc.
  static const Map<AlertType, (double, double, double)> ranges = {
    AlertType.rain: (30, 100, 5),
    AlertType.heavyRain: (2, 50, 1),
    AlertType.heat: (30, 42, 1),
    AlertType.uv: (3, 11, 1),
    AlertType.wind: (20, 100, 5),
    AlertType.aqi: (51, 301, 50),
  };

  String _fmt(AlertType t, double v) => switch (t) {
    AlertType.rain => '${v.round()}%',
    AlertType.heavyRain => units.rainRateText(v),
    AlertType.heat => formatTemp(v),
    AlertType.wind => units.windText(v),
    _ => '${v.round()}',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: planner,
      builder: (context, _) {
        final s = planner.settings;
        final o = s.placeOverride(placeId);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IosSheetNavBar(
              title: 'Ngưỡng riêng · $placeName',
              showCancel: false,
              onDone: () => Navigator.of(context).pop(),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final t in ranges.keys)
                      if (s.isEnabled(t)) ...[
                        SettingsSwitchTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(t.label),
                          subtitle: Text(
                            o.thresholds[t] == null
                                ? 'Chung: ${_fmt(t, s.thresholdOf(t)!)}'
                                : 'Riêng: ${_fmt(t, o.thresholds[t]!)}',
                          ),
                          value: o.thresholds[t] != null,
                          onChanged: (v) => planner.setSettings(
                            s.withPlace(
                              placeId,
                              o.withThreshold(t, v ? s.thresholdOf(t) : null),
                            ),
                          ),
                        ),
                        if (o.thresholds[t] != null)
                          IosSlider(
                            value: o.thresholds[t]!
                                .clamp(ranges[t]!.$1, ranges[t]!.$2)
                                .toDouble(),
                            min: ranges[t]!.$1,
                            max: ranges[t]!.$2,
                            divisions:
                                ((ranges[t]!.$2 - ranges[t]!.$1) /
                                        ranges[t]!.$3)
                                    .round(),
                            valueLabel: _fmt(t, o.thresholds[t]!),
                            semanticLabel: 'Ngưỡng riêng ${t.label}',
                            semanticValue: (v) => _fmt(t, v),
                            onChanged: (v) => planner.setSettings(
                              s.withPlace(placeId, o.withThreshold(t, v)),
                            ),
                          ),
                      ],
                  ],
                ),
              ),
            ),
            IosButton.plain(
              onPressed: () {
                planner.setSettings(
                  s.withPlace(placeId, PlaceAlertOverride(enabled: o.enabled)),
                );
              },
              icon: CupertinoIcons.arrow_counterclockwise,
              label: 'Dùng ngưỡng chung',
            ),
          ],
        );
      },
    );
  }
}
