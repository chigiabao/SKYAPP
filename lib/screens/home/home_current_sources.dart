import '../../models/weather/current_weather.dart';
import '../../utils/forecast_format.dart';

String? currentReferenceLabel(CurrentWeather current, String field) {
  final reference = current.fieldSources[field];
  if (reference == null) return null;
  final provider = switch (reference.source) {
    'open_meteo' => 'Open-Meteo',
    'open_meteo_cams' => 'Open-Meteo / CAMS',
    _ => 'nguồn ngoài',
  };
  return 'Tham khảo: $provider · ${ForecastFormat.dateTime(reference.timestamp)}';
}
