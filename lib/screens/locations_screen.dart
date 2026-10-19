/// Man hinh "Địa điểm": dia diem da luu (keo de doi thu tu, vuot de xoa),
/// tim kiem khong dau, "Dùng vị trí hiện tại", chon 2-3 diem de so sanh.
///
/// Tra ve (pop) chi so trang Home can mo; null neu chi dong.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../models/weather.dart';
import '../providers/location_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/app_scene.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/weather_icons.dart';
import '../ui/weather/widgets/bottom_pill_bar.dart' show showGlassSheet;
import '../ui/weather/widgets/glass_card.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../utils/constants.dart';
import 'compare_screen.dart';

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

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key, required this.locations});

  final LocationProvider locations;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  List<Place>? _remote;
  Timer? _debounce;
  int _searchToken = 0;
  bool _compare = false;
  final List<String> _picked = [];

  /// Dong vua them (hien dan vao) / dang an (truoc khi xoa).
  String? _appearing;
  final Set<String> _hiding = {};

  LocationProvider get _lp => widget.locations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final wp = context.read<WeatherProvider>();
      // Mot request cho moi dong (nhiet do / mua theo o ban do).
      _lp.refreshMap(at: wp.isReplay ? wp.replayAt : null);
      if (!_lp.hasPlaceList) _lp.refreshPlaces();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    setState(() {
      _query = q;
      _remote = null;
    });
    _debounce?.cancel();
    if (foldVietnamese(q).isEmpty) return;
    final token = ++_searchToken;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final r = await _lp.searchRemote(q);
      if (!mounted || token != _searchToken || r == null || r.isEmpty) return;
      setState(() => _remote = r);
    });
  }

  void _clearSearch() {
    _search.clear();
    _onQuery('');
  }

  void _snack(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  void _open(String locationId) {
    final i = _lp.pageIndexOf(locationId);
    Navigator.pop(context, i < 0 ? null : i);
  }

  void _add(Place p) {
    if (_lp.addSaved(p.id)) {
      HapticFeedback.lightImpact();
      _appearing = p.id;
      FocusScope.of(context).unfocus();
      _clearSearch();
      _snack(
        'Đã lưu ${p.name}',
        action: SnackBarAction(label: 'Xem', onPressed: () => _open(p.id)),
      );
    } else {
      _open(p.id);
    }
  }

  /// Xoa tu menu: thu gon dong truoc roi moi xoa.
  void _removeAnimated(int index) {
    final id = _lp.saved[index].locationId;
    if (MediaQuery.of(context).disableAnimations) return _remove(index);
    setState(() => _hiding.add(id));
  }

  void _remove(int index) {
    HapticFeedback.lightImpact();
    _hiding.remove(_lp.saved[index].locationId);
    final name = _lp.placeById(_lp.saved[index].locationId).name;
    final removed = _lp.removeSavedAt(index);
    _picked.remove(removed.locationId);
    _snack(
      'Đã xóa $name',
      action: SnackBarAction(
        label: 'Hoàn tác',
        onPressed: () {
          _appearing = removed.locationId;
          _lp.insertSaved(index, removed);
        },
      ),
    );
  }

  Future<void> _editLabel(int index) async {
    final s = _lp.saved[index];
    final r = await showLabelSheet(
      context,
      placeName: _lp.placeById(s.locationId).name,
      initial: s.label,
      initialName: s.customName,
    );
    if (r == null || !mounted) return;
    _lp.setLabel(index, r.$1, customName: r.$2);
  }

  void _togglePick(String id) {
    setState(() {
      if (_picked.contains(id)) {
        _picked.remove(id);
      } else if (_picked.length >= kMaxCompare) {
        _snack('Chọn tối đa $kMaxCompare địa điểm để so sánh.');
      } else {
        _picked.add(id);
      }
    });
  }

  void _openCompare() {
    final lp = _lp;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            CompareScreen(locations: lp, locationIds: List.of(_picked)),
      ),
    );
  }

  Future<void> _useGps() async {
    final o = await _lp.useCurrentLocation();
    if (!mounted) return;
    if (o.ok) _snack('Vị trí hiện tại: ${o.place!.name}');
  }

  @override
  Widget build(BuildContext context) =>
      GlassPage(child: Builder(builder: _buildPage));

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Địa điểm',
          style: AppTextStyles.heading2.copyWith(
            color: theme.textTheme.titleLarge?.color,
          ),
        ),
        actions: [
          // An khi chua du 2 noi de so sanh.
          ListenableBuilder(
            listenable: _lp,
            builder: (context, _) => !_compare && _lp.saved.length < 2
                ? const SizedBox.shrink()
                : TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(Touch.min, Touch.min),
                    ),
                    onPressed: () => setState(() {
                      _compare = !_compare;
                      _picked.clear();
                      if (_compare) _clearSearch();
                    }),
                    icon: Icon(
                      _compare
                          ? Icons.close_rounded
                          : Icons.compare_arrows_rounded,
                    ),
                    label: Text(_compare ? 'Xong' : 'So sánh'),
                  ),
          ),
          const SizedBox(width: Space.xs),
        ],
      ),
      body: ListenableBuilder(
        listenable: _lp,
        builder: (context, _) => _body(context),
      ),
      bottomNavigationBar: _compare ? _compareBar(context) : null,
    );
  }

  Widget _compareBar(BuildContext context) {
    final n = _picked.length;
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
              onPressed: n >= 2 ? _openCompare : null,
              child: const Text('So sánh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final mq = MediaQuery.of(context);
    final gutter = Space.gutter(mq.size.width);
    final hPad = mq.size.width > Space.contentMaxWidth + 2 * gutter
        ? (mq.size.width - Space.contentMaxWidth) / 2
        : gutter;
    final searching = foldVietnamese(_query).isNotEmpty;
    final ink = GlassInk.of(context);

    final slivers = <Widget>[
      if (!_compare)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, Space.m),
            child: _SearchField(
              controller: _search,
              onChanged: _onQuery,
              onClear: _clearSearch,
            ),
          ),
        ),
    ];

    if (searching) {
      final local = _lp.search(_query);
      final results = _remote ?? local;
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, Space.xl),
          sliver: SliverList.list(
            children: [
              if (!_lp.hasPlaceList)
                _Note(
                  'Máy chủ chưa có danh sách phường, xã. Hiện chỉ có điểm '
                  'dữ liệu Tân Sơn Nhất.',
                ),
              if (results.isEmpty)
                _Note(
                  'Không tìm thấy “${_query.trim()}”. Thử tên phường, xã '
                  '(có thể gõ không dấu, ví dụ “thu duc”).',
                ),
              for (final p in results)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.s),
                  child: _ResultRow(
                    place: p,
                    saved: _lp.isSaved(p.id),
                    onTap: () => _add(p),
                  ),
                ),
            ],
          ),
        ),
      );
    } else {
      if (!_compare) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, Space.m),
              child: Wrap(
                spacing: Space.s,
                children: [
                  for (final name in kPopularPlaces)
                    ActionChip(
                      avatar: const Icon(Icons.search_rounded, size: 18),
                      label: Text(name),
                      onPressed: () {
                        _search.text = name;
                        _onQuery(name);
                      },
                    ),
                ],
              ),
            ),
          ),
        );
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, Space.l),
              child: _GpsCard(lp: _lp, onUse: _useGps, onOpen: _open),
            ),
          ),
        );
      }
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(hPad + Space.xs, 0, hPad, Space.s),
            child: Text(
              _compare ? 'CHỌN ĐỂ SO SÁNH' : 'ĐÃ LƯU',
              style: TypeScale.cardTitle.copyWith(color: ink.headerSecondary),
            ),
          ),
        ),
      );
      final saved = _lp.saved;
      if (saved.isEmpty) {
        slivers.add(
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            sliver: SliverToBoxAdapter(
              child: _Note(
                'Chưa lưu địa điểm nào. Tìm phường, xã ở ô phía trên để thêm. '
                'Trang chủ đang hiển thị điểm mặc định Tân Sơn Nhất.',
              ),
            ),
          ),
        );
      }
      final selected = _lp.selectedPage;
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          sliver: SliverReorderableList(
            itemCount: saved.length,
            onReorderItem: _lp.moveSaved,
            itemBuilder: (context, i) {
              final s = saved[i];
              final place = _lp.placeById(s.locationId);
              final row = _SavedRow(
                index: i,
                count: saved.length,
                place: place,
                saved: s,
                cell: _lp.cellFor(s.locationId),
                viewing:
                    !selected.isCurrentLocation && selected.savedIndex == i,
                compareMode: _compare,
                picked: _picked.contains(s.locationId),
                onTap: _compare
                    ? () => _togglePick(s.locationId)
                    : () =>
                          Navigator.pop(context, _lp.pageIndexOf(s.locationId)),
                onLabel: () => _editLabel(i),
                onMove: (to) => _lp.moveSaved(i, to),
                onRemove: () => _removeAnimated(i),
              );
              final appear = _appearing == s.locationId;
              if (appear) _appearing = null;
              return _AnimatedRow(
                key: ValueKey('saved-${s.locationId}'),
                appear: appear,
                visible: !_hiding.contains(s.locationId),
                onHidden: () {
                  final j = _lp.saved.indexWhere(
                    (x) => x.locationId == s.locationId,
                  );
                  if (j >= 0) _remove(j);
                },
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Space.s),
                  child: _compare
                      ? row
                      : Dismissible(
                          key: ValueKey('dismiss-${s.locationId}'),
                          direction: DismissDirection.endToStart,
                          background: const _DeleteBackground(),
                          onDismissed: (_) => _remove(i),
                          child: row,
                        ),
                ),
              );
            },
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hPad, Space.s, hPad, Space.xxl),
          sliver: SliverToBoxAdapter(child: _Footer(lp: _lp)),
        ),
      );
    }

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: slivers,
    );
  }
}

/// Dong hien dan (them) / thu gon (xoa) 220 ms; tat khi giam chuyen dong.
class _AnimatedRow extends StatefulWidget {
  const _AnimatedRow({
    super.key,
    required this.appear,
    required this.visible,
    required this.onHidden,
    required this.child,
  });

  final bool appear;
  final bool visible;
  final VoidCallback onHidden;
  final Widget child;

  @override
  State<_AnimatedRow> createState() => _AnimatedRowState();
}

class _AnimatedRowState extends State<_AnimatedRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.short,
    value: widget.appear ? 0 : 1,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _c,
    curve: Motion.enter,
    reverseCurve: Motion.exit,
  );

  @override
  void initState() {
    super.initState();
    if (widget.appear) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.of(context).disableAnimations) {
          _c.value = 1;
        } else {
          _c.forward();
        }
      });
    }
  }

  @override
  void didUpdateWidget(_AnimatedRow old) {
    super.didUpdateWidget(old);
    if (old.visible && !widget.visible) {
      _c.reverse().then((_) {
        if (mounted && !widget.visible) widget.onHidden();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _curve,
    alignment: Alignment.topCenter,
    child: FadeTransition(opacity: _curve, child: widget.child),
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({
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
    return GlassSurface(
      radius: Radii.pill,
      padding: const EdgeInsets.symmetric(horizontal: Space.s),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.all(Space.s),
            child: Icon(Icons.search_rounded, color: Palette.white),
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
                isDense: true,
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, v, _) => v.text.isEmpty
                ? const SizedBox(width: Touch.min)
                : GlassIconButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Xóa tìm kiếm',
                    onPressed: onClear,
                  ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

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
    final provider = context.watch<WeatherProvider>();
    final ink = GlassInk.of(context);
    if (c == null || c.temperature == null) {
      return Text('--', style: TypeScale.label.copyWith(color: ink.secondary));
    }
    final temp = '${provider.formatTempValue(c.temperature!)}°';
    final rain = c.rainPercent;
    return Semantics(
      label:
          '${c.condition.description}, ${provider.formatTemperature(c.temperature!)}'
          '${rain == null ? '' : ', khả năng mưa 3 giờ tới $rain%'}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          WeatherIcon.fromCode(
            c.weatherCode,
            isDay: isDayAt(provider.nowHcm),
            size: 28,
          ),
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

enum _RowAction { label, up, down, remove }

class _SavedRow extends StatelessWidget {
  const _SavedRow({
    required this.index,
    required this.count,
    required this.place,
    required this.saved,
    required this.cell,
    required this.viewing,
    required this.compareMode,
    required this.picked,
    required this.onTap,
    required this.onLabel,
    required this.onMove,
    required this.onRemove,
  });

  final int index;
  final int count;
  final Place place;
  final SavedPlace saved;
  final MapCell? cell;
  final bool viewing;
  final bool compareMode;
  final bool picked;
  final VoidCallback onTap;
  final VoidCallback onLabel;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final label = saved.labelText;
    final sub = [?label, place.detail].join(' · ');
    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
      child: Row(
        children: [
          if (compareMode)
            Semantics(
              checked: picked,
              label: 'Chọn ${place.name} để so sánh',
              excludeSemantics: true,
              child: Pressable(
                onTap: onTap,
                button: false,
                child: SizedBox.square(
                  dimension: Touch.min,
                  child: Icon(
                    picked
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: picked ? ink.accent : Palette.white,
                  ),
                ),
              ),
            )
          else
            ReorderableDragStartListener(
              index: index,
              child: Tooltip(
                message: 'Kéo để đổi thứ tự',
                child: const SizedBox(
                  width: 40,
                  height: Touch.min + 16,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    color: Palette.secondary,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Pressable(
              onTap: onTap,
              semanticsLabel: [
                place.name,
                sub,
                if (viewing) 'đang xem',
                if (compareMode) picked ? 'đã chọn' : 'chưa chọn',
              ].join(', '),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.m),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            place.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TypeScale.label.copyWith(
                              color: Palette.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (viewing) ...[
                                const Text(
                                  'Đang xem',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  ' · ',
                                  style: TypeScale.small.copyWith(
                                    color: ink.secondary,
                                  ),
                                ),
                              ],
                              Expanded(
                                child: Text(
                                  sub,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TypeScale.small.copyWith(
                                    fontSize: 13,
                                    color: ink.secondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.s),
                    ExcludeSemantics(child: PlaceWeatherSummary(cell: cell)),
                  ],
                ),
              ),
            ),
          ),
          if (!compareMode)
            PopupMenuButton<_RowAction>(
              tooltip: 'Tùy chọn cho ${place.name}',
              icon: const Icon(Icons.more_vert_rounded, color: Palette.white),
              onSelected: (a) {
                switch (a) {
                  case _RowAction.label:
                    onLabel();
                  case _RowAction.up:
                    onMove(index - 1);
                  case _RowAction.down:
                    onMove(index + 1);
                  case _RowAction.remove:
                    onRemove();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _RowAction.label,
                  child: Text('Đổi nhãn'),
                ),
                if (index > 0)
                  const PopupMenuItem(
                    value: _RowAction.up,
                    child: Text('Chuyển lên'),
                  ),
                if (index < count - 1)
                  const PopupMenuItem(
                    value: _RowAction.down,
                    child: Text('Chuyển xuống'),
                  ),
                const PopupMenuItem(
                  value: _RowAction.remove,
                  child: Text('Xóa'),
                ),
              ],
            )
          else
            const SizedBox(width: Space.s),
        ],
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: Space.xl),
      decoration: BoxDecoration(
        color: const Color(0xCCB91C1C),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline_rounded, color: Palette.white),
          SizedBox(width: Space.s),
          Text(
            'Xóa',
            style: TextStyle(color: Palette.white, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.place,
    required this.saved,
    required this.onTap,
  });

  final Place place;
  final bool saved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final sub = place.region == null
        ? place.kind.label
        : '${place.kind.label} · ${place.region}';
    return Pressable(
      onTap: onTap,
      semanticsLabel:
          '${place.name}, $sub, ${saved ? 'đã lưu, mở' : 'lưu địa điểm'}',
      child: GlassSurface(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.m, Space.m),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name,
                    style: TypeScale.label.copyWith(
                      color: Palette.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    sub,
                    style: TypeScale.small.copyWith(
                      fontSize: 13,
                      color: ink.secondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              saved ? Icons.check_rounded : Icons.add_circle_outline_rounded,
              color: Palette.white,
            ),
            const SizedBox(width: Space.xs),
            Text(
              saved ? 'Đã lưu' : 'Lưu',
              style: TypeScale.small.copyWith(
                color: Palette.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GpsCard extends StatelessWidget {
  const _GpsCard({required this.lp, required this.onUse, required this.onOpen});

  final LocationProvider lp;
  final VoidCallback onUse;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final id = lp.currentLocationId;
    final outcome = lp.gpsOutcome;
    final viewing = lp.selectedPage.isCurrentLocation;
    final children = <Widget>[];
    if (id != null) {
      final p = lp.placeById(id);
      children.add(
        Row(
          children: [
            Expanded(
              child: Pressable(
                onTap: () => onOpen(id),
                semanticsLabel:
                    'Vị trí hiện tại: ${p.name}${viewing ? ', đang xem' : ''}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.xs),
                  child: Row(
                    children: [
                      const Icon(Icons.near_me_rounded, color: Palette.white),
                      const SizedBox(width: Space.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Vị trí hiện tại',
                              style: TypeScale.small.copyWith(
                                fontSize: 13,
                                color: ink.secondary,
                              ),
                            ),
                            Text(
                              p.name,
                              style: TypeScale.label.copyWith(
                                color: Palette.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ExcludeSemantics(
                        child: PlaceWeatherSummary(cell: lp.cellFor(id)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            GlassIconButton(
              icon: lp.gpsBusy
                  ? Icons.hourglass_top_rounded
                  : Icons.refresh_rounded,
              tooltip: 'Cập nhật vị trí',
              onPressed: lp.gpsBusy ? null : onUse,
            ),
            GlassIconButton(
              icon: Icons.location_disabled_rounded,
              tooltip: 'Tắt vị trí hiện tại',
              onPressed: lp.disableCurrentLocation,
            ),
          ],
        ),
      );
    } else {
      children.add(
        Pressable(
          onTap: lp.gpsBusy ? null : onUse,
          semanticsLabel: 'Dùng vị trí hiện tại',
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Touch.min),
            child: Row(
              children: [
                const Icon(Icons.near_me_outlined, color: Palette.white),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Dùng vị trí hiện tại',
                        style: TypeScale.label.copyWith(
                          color: Palette.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Chỉ lưu tên phường, xã — không lưu tọa độ.',
                        style: TypeScale.small.copyWith(
                          fontSize: 13,
                          color: ink.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (lp.gpsBusy)
                  const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.chevron_right_rounded, color: Palette.white),
              ],
            ),
          ),
        ),
      );
    }
    if (outcome != null && !outcome.ok) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: Space.m),
          child: Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  outcome.kind == GpsOutcomeKind.outsideArea
                      ? Icons.wrong_location_outlined
                      : Icons.location_off_outlined,
                  color: ink.warning,
                  size: IconSizes.md - 4,
                ),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Text(
                    outcome.message,
                    style: TypeScale.small.copyWith(
                      fontSize: 14,
                      color: Palette.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: Space.s),
          child: Wrap(
            spacing: Space.s,
            children: [
              if (outcome.canOpenSettings)
                OutlinedButton.icon(
                  onPressed: () => lp.openSettingsFor(outcome),
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Mở cài đặt'),
                ),
              TextButton(
                onPressed: lp.clearGpsOutcome,
                child: const Text('Đóng'),
              ),
            ],
          ),
        ),
      );
    }
    return GlassSurface(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.xs, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.lp});

  final LocationProvider lp;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final lines = <String>[
      'Nhiệt độ và khả năng mưa 3 giờ tới lấy theo ô dữ liệu ≈ 8 km chứa '
          'địa điểm.',
      if (lp.cellsStale && lp.cells.isNotEmpty)
        'Dữ liệu cũ${lp.cellsSavedAt == null ? '' : ' (lưu ${DateFormat('HH:mm dd/MM').format(lp.cellsSavedAt!)})'}.',
      if (lp.cells.isEmpty && !lp.mapLoading)
        'Chưa có số liệu nhanh cho danh sách (máy chủ chưa hỗ trợ hoặc '
            'đang ngoại tuyến).',
      'Vuốt sang trái để xóa; giữ biểu tượng ⋮⋮ và kéo để đổi thứ tự.',
    ];
    return Text(
      lines.join('\n'),
      style: TypeScale.small.copyWith(
        fontSize: 13,
        color: ink.headerSecondary,
        height: 1.45,
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
