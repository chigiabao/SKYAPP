import 'package:flutter/material.dart';

import '../../ui/weather/design_tokens.dart';

class RouteEndpointBadge extends StatelessWidget {
  const RouteEndpointBadge({
    super.key,
    required this.destination,
    this.size = 32,
  });

  final bool destination;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: destination ? DataColors.seriesB : DataColors.seriesA,
        shape: BoxShape.circle,
        border: Border.all(color: Palette.white, width: 3),
        boxShadow: const [
          BoxShadow(color: DataColors.pinShadow, blurRadius: 4),
        ],
      ),
      child: Text(
        destination ? 'B' : 'A',
        textScaler: TextScaler.noScaling,
        style: TypeScale.headline.copyWith(color: Palette.ink),
      ),
    ),
  );
}
