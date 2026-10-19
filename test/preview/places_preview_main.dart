/// Ban xem truoc (chi de chup man hinh): mo thang man Chuyến đi / Bản đồ /
/// Địa điểm / So sánh theo `?s=`. GPS gia dat o Ben Thanh.
/// flutter build web -t test/preview/places_preview_main.dart
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:sky_weather_app/models/app_settings.dart';
import 'package:sky_weather_app/providers/location_provider.dart';
import 'package:sky_weather_app/providers/planner_provider.dart';
import 'package:sky_weather_app/providers/preferences_provider.dart';
import 'package:sky_weather_app/providers/trip_provider.dart';
import 'package:sky_weather_app/providers/weather_provider.dart';
import 'package:sky_weather_app/screens/compare_screen.dart';
import 'package:sky_weather_app/screens/locations_screen.dart';
import 'package:sky_weather_app/screens/map_screen.dart';
import 'package:sky_weather_app/screens/trip_screen.dart';
import 'package:sky_weather_app/services/gps_service.dart';
import 'package:sky_weather_app/ui/weather/app_scene.dart';
import 'package:sky_weather_app/ui/weather/weather_background.dart';
import 'package:sky_weather_app/utils/theme.dart';

class _BenThanhGps implements GpsService {
  @override
  Future<GpsFix> locate() async =>
      const GpsFix(GpsStatus.ok, lat: 10.7704, lon: 106.6951);
  @override
  Future<bool> openAppSettings() async => false;
  @override
  Future<bool> openLocationSettings() async => false;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final s = Uri.base.queryParameters['s'] ?? 'trip_quick';
  final lp = LocationProvider();
  await lp.refreshPlaces();
  if (s != 'locations_empty') {
    for (final id in ['phuong-ben-thanh', 'phuong-thu-duc']) {
      lp.addSaved(id);
    }
  }
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => WeatherProvider(initialSettings: settings),
        ),
        ChangeNotifierProvider.value(value: lp),
        ChangeNotifierProvider(create: (_) => PlannerProvider()),
        ChangeNotifierProvider(create: (_) => SceneOverride()),
        ChangeNotifierProvider(create: (_) => PreferencesProvider()..load()),
        ChangeNotifierProvider(create: (_) => TripProvider()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        builder: (context, child) => AppSceneScope(child: child!),
        home: switch (s) {
          'trip' => TripScreen(gps: _BenThanhGps()),
          'map' => MapScreen(locations: lp),
          'compare' => CompareScreen(
            locations: lp,
            locationIds: const ['phuong-ben-thanh', 'phuong-thu-duc'],
          ),
          'locations' || 'locations_empty' => LocationsScreen(locations: lp),
          _ => TripScreen(gps: _BenThanhGps(), quickStart: true),
        },
      ),
    ),
  );
}
