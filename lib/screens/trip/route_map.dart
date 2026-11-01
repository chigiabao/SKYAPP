import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../config/map_tiles.dart';
import '../../services/route_service.dart';
import '../../ui/weather/design_tokens.dart';
import '../../widgets/map_attribution_link.dart';
import 'trip_helpers.dart';
import 'route_endpoint_badge.dart';

/// Ban do tuyen + marker doan xau nhat + attribution.
class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    required this.route,
    required this.showTiles,
    this.tileProvider,
    this.fromLabel = 'Điểm đi',
    this.toLabel = 'Điểm đến',
  });

  final TripRoute route;
  final bool showTiles;
  final TileProvider? tileProvider;
  final String fromLabel;
  final String toLabel;

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  bool _tilesFailed = false;
  int _tileGeneration = 0;

  @override
  void didUpdateWidget(covariant RouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route != widget.route ||
        oldWidget.showTiles != widget.showTiles) {
      _tilesFailed = false;
      _tileGeneration++;
    }
  }

  void _onTileError(int generation) {
    if (_tilesFailed || generation != _tileGeneration) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _tileGeneration && !_tilesFailed) {
        setState(() => _tilesFailed = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final generation = _tileGeneration;
    final g = route.geometry;
    final worst = route.worstAlert;
    // Leave map space when attribution grows with accessibility text.
    final scaledHeight =
        280.0 * MediaQuery.textScalerOf(context).scale(14) / 14;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.card),
      child: SizedBox(
        height: scaledHeight < 280 ? 280 : scaledHeight,
        child: g.length < 2
            ? const Center(child: Text('Không có dữ liệu hình tuyến.'))
            : FlutterMap(
                key: ValueKey(route),
                options: MapOptions(
                  initialCameraFit: CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(g),
                    padding: const EdgeInsets.fromLTRB(48, 72, 48, 80),
                  ),
                ),
                children: [
                  if (widget.showTiles)
                    TileLayer(
                      key: ValueKey(generation),
                      urlTemplate: kMapTileUrl,
                      fallbackUrl: kMapTileFallbackUrl.isEmpty
                          ? null
                          : kMapTileFallbackUrl,
                      userAgentPackageName: kMapTileUserAgent,
                      tileProvider: widget.tileProvider,
                      maxNativeZoom: 19,
                      errorTileCallback: (_, _, _) => _onTileError(generation),
                    ),
                  PolylineLayer(polylines: routeWeatherPolylines(route)),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: g.first,
                        width: 40,
                        height: 40,
                        child: Semantics(
                          container: true,
                          label: 'A · ${widget.fromLabel}',
                          child: Tooltip(
                            message: 'A · ${widget.fromLabel}',
                            excludeFromSemantics: true,
                            child: const RouteEndpointBadge(
                              destination: false,
                              size: 40,
                            ),
                          ),
                        ),
                      ),
                      Marker(
                        point: g.last,
                        width: 40,
                        height: 40,
                        child: Semantics(
                          container: true,
                          label: 'B · ${widget.toLabel}',
                          child: Tooltip(
                            message: 'B · ${widget.toLabel}',
                            excludeFromSemantics: true,
                            child: const RouteEndpointBadge(
                              destination: true,
                              size: 40,
                            ),
                          ),
                        ),
                      ),
                      if (worst != null)
                        Marker(
                          point: worst.point,
                          width: 40,
                          height: 64,
                          alignment: Alignment.topCenter,
                          child: Semantics(
                            label: 'Đoạn xấu nhất',
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Icon(
                                Icons.warning_rounded,
                                size: 32,
                                color: hazardColor(worst.hazard),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      color: DataColors.attributionBg,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: MapAttributionLink(
                        text: widget.showTiles
                            ? '$kMapTileAttribution · OSRM'
                            : route.attribution,
                        style: TypeScale.caption1.copyWith(
                          color: DataColors.attributionText,
                        ),
                      ),
                    ),
                  ),
                  if (widget.showTiles && _tilesFailed)
                    Positioned(
                      top: 8,
                      left: 8,
                      right: 8,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text('Không tải được nền bản đồ.'),
                              ),
                              IconButton(
                                tooltip: 'Thử tải lại bản đồ nền',
                                onPressed: () => setState(() {
                                  _tilesFailed = false;
                                  _tileGeneration++;
                                }),
                                icon: const Icon(Icons.refresh_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
