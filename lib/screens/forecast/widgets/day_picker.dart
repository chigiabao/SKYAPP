part of '../forecast_widgets.dart';

class DayPicker extends StatefulWidget {
  const DayPicker({
    super.key,
    required this.days,
    required this.selectedIndex,
    required this.nowHcm,
    required this.onSelect,
  });

  final List<DailyForecast> days;
  final int selectedIndex;
  final DateTime nowHcm;
  final ValueChanged<int> onSelect;

  @override
  State<DayPicker> createState() => _DayPickerState();
}

class _DayPickerState extends State<DayPicker> {
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scrollToSelected();
  }

  @override
  void didUpdateWidget(DayPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) _scrollToSelected();
  }

  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: chartMotionOff(ctx)
            ? Duration.zero
            : const Duration(milliseconds: 200),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final summary = SourceSummary.of(widget.days.map((d) => d.source));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.days.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: Space.s),
              child: _DayChip(
                key: i == widget.selectedIndex ? _selectedKey : null,
                day: widget.days[i],
                nowHcm: widget.nowHcm,
                selected: i == widget.selectedIndex,
                onTap: () {
                  if (i != widget.selectedIndex) AppHaptics.selection();
                  widget.onSelect(i);
                },
                sourceTag: summary.marks(widget.days[i].source)
                    ? (widget.days[i].source ?? SourceSummary.fallback)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    super.key,
    required this.day,
    required this.nowHcm,
    required this.selected,
    required this.onTap,
    this.sourceTag,
  });

  final DailyForecast day;
  final DateTime nowHcm;
  final bool selected;
  final VoidCallback onTap;
  final DataSource? sourceTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final glass = GlassThemeMarker.isGlass(context);
    // Tren nen kinh: chon = trang dac + chu toi (~17:1); chua chon = kinh.
    // Ngoai kinh: chon = #1976D2, chu trang ~4.6:1.
    const onSelectedGlass = Palette.ink;
    final bg = selected
        ? (glass ? Colors.white : Tones.brandDeep)
        : glass
        ? (theme.cardTheme.color ?? Colors.transparent)
        : (isDark ? Tones.navyCard : Colors.white);
    final fg = selected
        ? (glass ? onSelectedGlass : Colors.white)
        : theme.textTheme.bodyLarge?.color;
    final sub = selected
        ? (glass ? onSelectedGlass : Tones.onBrandSecondary)
        : theme.textTheme.bodySmall?.color;
    final border = selected
        ? (glass ? Colors.white : Tones.brandDeep)
        : glass
        ? Colors.white.withValues(alpha: 0.18)
        : (isDark ? Colors.white24 : Colors.black12);

    return Semantics(
      button: true,
      selected: selected,
      label: ForecastFormat.title(day.date),
      hint: [
        if (sourceTag != null) sourceTag!.shortLabel,
        if (day.isLowConfidence) 'xu hướng, độ tin cậy thấp',
      ].join(', '),
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.medium),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 68, minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.l,
                vertical: Space.s,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ForecastFormat.relativeDay(day.date, nowHcm),
                    style: TypeScale.bodyMedium.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ForecastFormat.dayMonth(day.date),
                    style: TypeScale.bodySmall.copyWith(color: sub),
                  ),
                  const SizedBox(height: 4),
                  Opacity(
                    opacity: day.isLowConfidence ? kLowConfidenceOpacity : 1,
                    child: WeatherIcon.fromCode(
                      day.displayWeatherCode ?? wmoForCondition(day.condition),
                      isDay: true,
                      size: IconSizes.inline,
                      color: selected ? fg : null,
                    ),
                  ),
                  if (sourceTag != null) ...[
                    const SizedBox(height: 2),
                    SourceTag(
                      source: sourceTag!,
                      onColor: selected ? fg : null,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chip nguon du lieu + do moi (cache).
