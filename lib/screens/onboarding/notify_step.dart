part of '../onboarding_screen.dart';

class _NotifyStep extends StatefulWidget {
  const _NotifyStep({super.key});

  @override
  State<_NotifyStep> createState() => _NotifyStepState();
}

class _NotifyStepState extends State<_NotifyStep> {
  String? _message;
  bool _busy = false;

  Future<void> _enable() async {
    setState(() => _busy = true);
    final ok = await context.read<PlannerProvider>().setMorningBrief(true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok
          ? null
          : 'Chưa được cấp quyền thông báo. Bạn vẫn xem cảnh báo trong ứng '
                'dụng; bật lại trong Cài đặt bất cứ lúc nào.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ink = GlassInk.of(context);
    final planner = context.watch<PlannerProvider>();
    final c = planner.commute;
    final on = planner.notifySettings.system && c.briefEnabled;
    final supported = NotificationService.isSupportedPlatform;
    return _StepFrame(
      scene: WeatherScene.thunderstorm,
      title: 'Biết mưa trước khi ra đường',
      body:
          'Mỗi sáng lúc ${clockHm(c.briefHour, c.briefMinute)}, một thông báo '
          'ngắn tóm tắt mưa trong ngày ở Nhà và Nơi làm. Cảnh báo dông, mưa '
          'lớn cũng được gửi ngay. Không quảng cáo, tôn trọng giờ yên lặng.',
      children: [
        // Vi du minh hoa (khong phai du lieu that).
        Semantics(
          label:
              'Ví dụ thông báo: Hôm nay mưa 15 đến 18 giờ ở nơi làm, mang áo '
              'mưa khi về',
          excludeSemantics: true,
          child: GlassSurface(
            padding: const EdgeInsets.all(Space.l),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.notifications_active_outlined,
                  color: Palette.white,
                ),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ví dụ · Thời tiết đi làm hôm nay',
                        style: TypeScale.small.copyWith(color: ink.secondary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Hôm nay: mưa 15–18h ở Bến Thành, mang áo mưa khi về.',
                        style: TypeScale.body.copyWith(color: Palette.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.l),
        if (!supported)
          Text(
            'Trình duyệt / thiết bị này chưa hỗ trợ thông báo của Sky '
            'Weather. Cảnh báo vẫn hiện trong ứng dụng; bật thông báo trên '
            'điện thoại Android hoặc iPhone.',
            textAlign: TextAlign.center,
            style: TypeScale.body.copyWith(color: ink.secondary),
          )
        else if (on)
          Semantics(
            liveRegion: true,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle_rounded, color: Palette.white),
                const SizedBox(width: Space.s),
                Flexible(
                  child: Text(
                    'Đã bật · ${clockHm(c.briefHour, c.briefMinute)} mỗi sáng',
                    style: TypeScale.body.copyWith(
                      color: Palette.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: _busy ? null : _enable,
            style: OutlinedButton.styleFrom(
              foregroundColor: Palette.white,
              side: const BorderSide(color: Palette.white),
              minimumSize: const Size.fromHeight(Touch.min),
            ),
            icon: const Icon(Icons.notifications_none_rounded),
            label: const Text('Bật thông báo buổi sáng'),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _message!,
                textAlign: TextAlign.center,
                style: TypeScale.small.copyWith(color: ink.secondary),
              ),
            ),
          ),
        if (supported && !on)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Text(
              'Điện thoại sẽ hỏi quyền thông báo sau khi bạn bấm.',
              textAlign: TextAlign.center,
              style: TypeScale.small.copyWith(color: ink.secondary),
            ),
          ),
      ],
    );
  }
}
