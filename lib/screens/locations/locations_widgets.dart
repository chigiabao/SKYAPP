/// O tim kiem, ghi chu, tom tat thoi tiet, thanh so sanh, sheet nhan.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/place.dart';
import '../../models/weather.dart';
import '../../providers/location_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/weather_provider.dart';
import '../../ui/weather/app_scene.dart';
import '../../ui/weather/design_tokens.dart';
import '../../ui/weather/glass_ink.dart';
import '../../ui/weather/weather_icons.dart';
import '../../ui/weather/widgets/bottom_pill_bar.dart' show showGlassSheet;
import '../../ui/weather/widgets/glass_card.dart';
import 'locations_rows.dart';
import '../../ui/weather/widgets/ios_page.dart';

/// So dia diem toi da khi so sanh.
const int kMaxCompare = 3;

/// Goi y khi o tim kiem trong (cac noi hay tim).
const List<String> kPopularPlaces = [
  'Bến Thành',
  'Thủ Đức',
  'Tân Sơn Nhất',
  'Thủ Dầu Một',
  'Vũng Tàu',
  'Bình Thạnh',
];

class LocationsSearchField extends StatelessWidget {
  const LocationsSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    // Kieu o tim kiem iOS (CupertinoSearchTextField): bo 10, kinh mo, kinh
    // lup + nut xoa tron mau chu phu.
    return GlassSurface(
      radius: Radii.field,
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.s),
            child: ExcludeSemantics(
              child: Icon(
                CupertinoIcons.search,
                color: ink.secondary,
                size: 20,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: TypeScale.body.copyWith(color: Palette.white),
              cursorColor: Palette.white,
              decoration: InputDecoration(
                hintText: 'Tìm phường, xã (vd. “thu duc”)',
                hintStyle: TypeScale.body.copyWith(color: ink.secondary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                constraints: const BoxConstraints(minHeight: Touch.min),
                contentPadding: const EdgeInsets.symmetric(vertical: Space.m),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, v, _) => v.text.isEmpty
                ? const SizedBox(width: Touch.min)
                : IosBarButton(
                    icon: CupertinoIcons.xmark_circle_fill,
                    tooltip: 'Xóa tìm kiếm',
                    onPressed: onClear,
                  ),
          ),
        ],
      ),
    );
  }
}

class LocationsNote extends StatelessWidget {
  const LocationsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s),
      child: GlassSurface(
        padding: const EdgeInsets.all(Space.l),
        child: Text(text, style: TypeScale.body.copyWith(color: Palette.white)),
      ),
    );
  }
}

/// Nhiet do + icon + kha nang mua 3 gio toi cua o chua dia diem.
class PlaceWeatherSummary extends StatelessWidget {
  const PlaceWeatherSummary({super.key, required this.cell});

  final MapCell? cell;

  @override
  Widget build(BuildContext context) {
    final c = cell;
    // Chi theo doi don vi (Cai dat) va ngay / dem.
    final isDay = context.select<WeatherProvider, bool>(
      (p) => c == null
          ? isDayAt(p.nowHcm)
          : isDayAt(p.nowHcm, lat: c.lat, lon: c.lon),
    );
    final units = PreferencesProvider.unitsOf(context);
    final ink = GlassInk.of(context);
    if (c == null || c.temperature == null) {
      return Text('--', style: TypeScale.label.copyWith(color: ink.secondary));
    }
    final temp = '${units.tempNumber(c.temperature!)}°';
    final rain = c.rainPercent;
    return Semantics(
      label:
          '${c.condition.description}, ${units.tempText(c.temperature!)}'
          '${rain == null ? '' : ', khả năng mưa 3 giờ tới $rain%'}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          WeatherIcon.fromCode(c.weatherCode, isDay: isDay, size: 28),
          const SizedBox(width: Space.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                temp,
                style: TypeScale.condition.copyWith(
                  color: Palette.white,
                  fontWeight: FontWeight.w500,
                  fontFeatures: kTabular,
                ),
              ),
              if (rain != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.water_drop_outlined, size: 12, color: ink.rain),
                    const SizedBox(width: 2),
                    Text(
                      '$rain%',
                      style: TypeScale.small.copyWith(
                        color: ink.rain,
                        fontWeight: FontWeight.w700,
                        fontFeatures: kTabular,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Thanh duoi khi so sanh: so dia diem da chon + nut So sanh.
class LocationsCompareBar extends StatelessWidget {
  const LocationsCompareBar({
    super.key,
    required this.count,
    required this.onCompare,
  });

  final int count;
  final VoidCallback onCompare;

  @override
  Widget build(BuildContext context) {
    final n = count;

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.m),
      child: GlassSurface(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.s, Space.s),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  n < 2
                      ? 'Chọn 2–$kMaxCompare địa điểm ($n/$kMaxCompare)'
                      : 'Đã chọn $n/$kMaxCompare địa điểm',
                  style: TypeScale.body.copyWith(color: Palette.white),
                ),
              ),
            ),
            ElevatedButton(
              onPressed: n >= 2 ? onCompare : null,
              child: const Text('So sánh'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ket qua tim kiem (sliver): tu may chu neu co, khong thi tim tai cho.
class LocationsSearchResults extends StatelessWidget {
  const LocationsSearchResults({
    super.key,
    required this.lp,
    required this.query,
    required this.remote,
    required this.hPad,
    required this.onAdd,
  });

  final LocationProvider lp;
  final String query;
  final List<Place>? remote;
  final double hPad;
  final ValueChanged<Place> onAdd;

  @override
  Widget build(BuildContext context) {
    final local = lp.search(query);
    final results = remote ?? local;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(hPad, 0, hPad, Space.xl),
      sliver: SliverList.list(
        children: [
          if (!lp.hasPlaceList)
            LocationsNote(
              'Máy chủ chưa có danh sách phường, xã. Hiện chỉ có điểm '
              'dữ liệu Tân Sơn Nhất.',
            ),
          if (results.isEmpty)
            LocationsNote(
              'Không tìm thấy “${query.trim()}”. Thử tên phường, xã '
              '(có thể gõ không dấu, ví dụ “thu duc”).',
            ),
          for (final p in results)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: LocationsResultRow(
                place: p,
                saved: lp.isSaved(p.id),
                onTap: () => onAdd(p),
              ),
            ),
        ],
      ),
    );
  }
}

/// Chon nhan cho dia diem da luu. Tra ve (nhan, ten rieng) hoac null.
Future<(PlaceLabel, String?)?> showLabelSheet(
  BuildContext context, {
  required String placeName,
  PlaceLabel initial = PlaceLabel.none,
  String? initialName,
}) {
  var label = initial;
  final name = TextEditingController(text: initialName ?? '');
  return showGlassSheet<(PlaceLabel, String?)>(
    context,
    title: 'Nhãn cho $placeName',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final l in PlaceLabel.values)
            Semantics(
              selected: l == label,
              inMutuallyExclusiveGroup: true,
              child: Pressable(
                onTap: () => setState(() => label = l),
                semanticsLabel: l == PlaceLabel.none ? 'Không nhãn' : l.text,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Touch.min),
                  child: Row(
                    children: [
                      Icon(
                        l == label
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: Palette.white,
                      ),
                      const SizedBox(width: Space.m),
                      Text(
                        l == PlaceLabel.none ? 'Không nhãn' : l.text,
                        style: TypeScale.body.copyWith(color: Palette.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (label == PlaceLabel.custom)
            Padding(
              padding: const EdgeInsets.only(top: Space.s),
              child: TextField(
                controller: name,
                autofocus: true,
                maxLength: 30,
                style: TypeScale.body.copyWith(color: Palette.white),
                decoration: const InputDecoration(
                  labelText: 'Tên riêng (vd. Nhà bà ngoại)',
                ),
              ),
            ),
          const SizedBox(height: Space.m),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, (
              label,
              label == PlaceLabel.custom ? name.text.trim() : null,
            )),
            child: const Text('Lưu'),
          ),
        ],
      ),
    ),
  );
}
