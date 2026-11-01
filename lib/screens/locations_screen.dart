/// Man hinh "Địa điểm": dia diem da luu (keo de doi thu tu, vuot de xoa),
/// tim kiem khong dau, "Dùng vị trí hiện tại", chon 2-3 diem de so sanh.
///
/// Tra ve (pop) chi so trang Home can mo; null neu chi dong.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:provider/provider.dart';

import '../models/place.dart';
import '../providers/location_provider.dart';
import '../providers/weather_provider.dart';
import '../ui/weather/design_tokens.dart';
import '../ui/weather/glass_ink.dart';
import '../ui/weather/widgets/glass_page.dart';
import '../ui/weather/widgets/home_tab_scope.dart';
import '../ui/weather/widgets/ios_controls.dart';
import '../ui/weather/widgets/ios_page.dart';
import '../ui/weather/widgets/ios_toast.dart';
import '../utils/haptics.dart';
import 'compare_screen.dart';
import 'locations/locations_rows.dart';
import 'locations/locations_widgets.dart';
import 'locations/locations_gps.dart';

export 'locations/locations_widgets.dart'
    show PlaceWeatherSummary, kMaxCompare, kPopularPlaces, showLabelSheet;

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key, required this.locations, this.onOpenPage});

  final LocationProvider locations;

  /// Tab Dia diem: mo trang Home [int] (chuyen tab) thay vi pop; null ->
  /// pop tra ve chi so (khi duoc push).
  final ValueChanged<int>? onOpenPage;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> with HomeTabRoot {
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

  void _snack(String text, {String? actionLabel, VoidCallback? onAction}) {
    showIosToast(context, text, actionLabel: actionLabel, onAction: onAction);
  }

  void _open(String locationId) {
    final i = _lp.pageIndexOf(locationId);
    final open = widget.onOpenPage;
    if (open == null) {
      Navigator.pop(context, i < 0 ? null : i);
    } else if (i >= 0) {
      open(i);
    }
  }

  void _add(Place p) {
    if (_lp.addSaved(p.id)) {
      HapticFeedback.lightImpact();
      _appearing = p.id;
      FocusScope.of(context).unfocus();
      _clearSearch();
      _snack(
        'Đã lưu ${p.name}',
        actionLabel: 'Xem',
        onAction: () {
          if (mounted) _open(p.id);
        },
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
    AppHaptics.warning();
    _hiding.remove(_lp.saved[index].locationId);
    final name = _lp.placeById(_lp.saved[index].locationId).name;
    final removed = _lp.removeSavedAt(index);
    _picked.remove(removed.locationId);
    _snack(
      'Đã xóa $name',
      actionLabel: 'Hoàn tác',
      onAction: () {
        _appearing = removed.locationId;
        _lp.insertSaved(index, removed);
      },
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
    return ListenableBuilder(
      listenable: _lp,
      builder: (context, _) => IosPageScaffold(
        title: 'Địa điểm',
        controller: tabScroll,
        actions: [
          // An khi chua du 2 noi de so sanh.
          if (_compare || _lp.saved.length >= 2)
            IosBarTextButton(
              icon: _compare ? null : CupertinoIcons.arrow_right_arrow_left,
              bold: _compare,
              label: _compare ? 'Xong' : 'So sánh',
              onPressed: () => setState(() {
                _compare = !_compare;
                _picked.clear();
                if (_compare) _clearSearch();
              }),
            ),
        ],
        bottomBar: _compare
            ? LocationsCompareBar(
                count: _picked.length,
                onCompare: _openCompare,
              )
            : null,
        slivers: _body(context),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
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
            child: LocationsSearchField(
              controller: _search,
              onChanged: _onQuery,
              onClear: _clearSearch,
            ),
          ),
        ),
    ];

    if (searching) {
      slivers.add(
        LocationsSearchResults(
          lp: _lp,
          query: _query,
          remote: _remote,
          hPad: hPad,
          onAdd: _add,
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
                runSpacing: Space.xs,
                children: [
                  for (final name in kPopularPlaces)
                    IosPill(
                      icon: CupertinoIcons.search,
                      label: name,
                      selected: false,
                      selectable: false,
                      semanticsLabel: 'Tìm $name',
                      onChanged: (_) {
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
              child: LocationsGpsCard(lp: _lp, onUse: _useGps, onOpen: _open),
            ),
          ),
        );
      }
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            // Cung kieu tieu de nhom iOS (IosListSection).
            padding: EdgeInsets.fromLTRB(hPad + Space.l, 0, hPad, Space.s - 2),
            child: Semantics(
              header: true,
              child: Text(
                _compare ? 'CHỌN ĐỂ SO SÁNH' : 'ĐÃ LƯU',
                style: TypeScale.footnote.copyWith(color: ink.headerSecondary),
              ),
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
              child: LocationsNote(
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
              final row = LocationsSavedRow(
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
                    : () => _open(s.locationId),
                onLabel: () => _editLabel(i),
                onMove: (to) => _lp.moveSaved(i, to),
                onRemove: () => _removeAnimated(i),
              );
              final appear = _appearing == s.locationId;
              if (appear) _appearing = null;
              return LocationsAnimatedRow(
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
                  padding: EdgeInsets.zero,
                  child: _compare
                      ? row
                      : Dismissible(
                          key: ValueKey('dismiss-${s.locationId}'),
                          direction: DismissDirection.endToStart,
                          background: const LocationsDeleteBackground(),
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
          sliver: SliverToBoxAdapter(
            child: LocationsFooter(lp: _lp, showEditHint: !_compare),
          ),
        ),
      );
    }

    return slivers;
  }
}
