part of '../onboarding_screen.dart';

class _PlacesStep extends StatelessWidget {
  const _PlacesStep({super.key});

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<PlannerProvider>();
    final lp = context.watch<LocationProvider>();
    final c = planner.commute;
    return _StepFrame(
      scene: WeatherScene.partlyCloudyDay,
      title: 'Bạn đi lại giữa đâu?',
      body:
          'Chọn phường nơi bạn ở và nơi làm, học. Sky Weather báo mưa đúng '
          'chỗ lúc bạn đi và về.',
      children: [
        _PlaceTile(
          icon: Icons.home_outlined,
          label: 'Nhà',
          place: c.homeId == null ? null : lp.placeById(c.homeId!),
          onTap: () => _pick(context, home: true),
        ),
        const SizedBox(height: Space.cardGap),
        _PlaceTile(
          icon: Icons.work_outline_rounded,
          label: 'Nơi làm / học',
          place: c.workId == null ? null : lp.placeById(c.workId!),
          onTap: () => _pick(context, home: false),
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context, {required bool home}) async {
    final lp = context.read<LocationProvider>();
    final planner = context.read<PlannerProvider>();
    final place = await showIosSheet<Place>(
      context,
      title: home ? 'Chọn Nhà' : 'Chọn Nơi làm / học',
      scrollable: false,
      builder: (_) => ChangeNotifierProvider.value(
        value: lp,
        child: const _PlaceSearchSheet(),
      ),
    );
    if (place == null) return;
    final label = home ? PlaceLabel.home : PlaceLabel.work;
    final i = lp.saved.indexWhere((s) => s.locationId == place.id);
    if (i < 0) {
      lp.addSaved(place.id, label: label);
    } else if (lp.saved[i].label == PlaceLabel.none) {
      lp.setLabel(i, label);
    }
    planner.setCommute(
      home
          ? planner.commute.copyWith(homeId: place.id)
          : planner.commute.copyWith(workId: place.id),
    );
    planner.syncCommutePlaces(lp);
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.icon,
    required this.label,
    required this.place,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Place? place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final p = place;
    return GlassSurface(
      child: Pressable(
        onTap: onTap,
        semanticsLabel:
            '$label: ${p == null ? 'chưa chọn' : p.name}. Chạm để chọn',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.l,
              vertical: Space.m,
            ),
            child: Row(
              children: [
                Icon(icon, color: Palette.white, size: IconSizes.md),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TypeScale.small.copyWith(color: ink.secondary),
                      ),
                      Text(
                        p == null ? 'Tìm phường hoặc dùng GPS' : p.name,
                        style: TypeScale.body.copyWith(
                          color: Palette.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  p == null ? Icons.add_rounded : Icons.edit_outlined,
                  color: Palette.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tim phuong / xa (khong dau, tren may truoc, may chu sau) hoac dung GPS.
class _PlaceSearchSheet extends StatefulWidget {
  const _PlaceSearchSheet();

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final _ctrl = TextEditingController();
  List<Place> _results = const [];
  String? _message;
  int _token = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final lp = context.read<LocationProvider>();
    final t = ++_token;
    var r = lp.search(q);
    setState(() {
      _results = r;
      _message = null;
    });
    if (r.isEmpty && q.trim().length >= 2) {
      final remote = await lp.searchRemote(q);
      if (!mounted || t != _token) return;
      r = remote ?? const [];
      setState(() {
        _results = r;
        _message = remote == null
            ? 'Không tìm được trên máy chủ. Kiểm tra kết nối rồi thử lại.'
            : r.isEmpty
            ? 'Không thấy "$q". Thử tên phường khác, gõ không dấu cũng được.'
            : null;
      });
    }
  }

  Future<void> _gps() async {
    final lp = context.read<LocationProvider>();
    final o = await lp.useCurrentLocation();
    if (!mounted) return;
    if (o.ok && o.place != null) {
      Navigator.pop(context, o.place);
    } else {
      setState(() => _message = o.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lp = context.watch<LocationProvider>();
    // showIosSheet da lo tieu de, nut Dong, ban phim va vung an toan.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            labelText: 'Tên phường, xã',
            hintText: 'Ví dụ: Bến Thành, Thủ Đức',
            prefixIcon: Icon(Icons.search_rounded),
          ),
          onChanged: _search,
        ),
        const SizedBox(height: Space.s),
        OutlinedButton.icon(
          onPressed: lp.gpsBusy ? null : _gps,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(Touch.min),
          ),
          icon: lp.gpsBusy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CupertinoActivityIndicator(radius: 9),
                )
              : const Icon(Icons.my_location_rounded),
          label: Text(
            lp.gpsBusy ? 'Đang lấy vị trí…' : 'Dùng vị trí hiện tại (GPS)',
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Semantics(liveRegion: true, child: Text(_message!)),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (_results.isNotEmpty)
                IosListSection(
                  margin: const EdgeInsets.only(top: Space.m),
                  dividerIndent: Space.l + IconSizes.md + Space.m,
                  children: [
                    for (final p in _results.take(20))
                      IosListRow(
                        leading: const Icon(
                          CupertinoIcons.location,
                          size: IconSizes.md,
                          color: Palette.white,
                        ),
                        title: p.name,
                        subtitle: p.friendlyDetail,
                        semanticsLabel: '${p.name}, ${p.friendlyDetail}',
                        chevron: false,
                        onTap: () => Navigator.pop(context, p),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Buoc 2: gio di / ve
