// Community tiles are for public, non-commercial, moderate-traffic use.
// Configure a licensed provider before a commercial/high-traffic deployment.
const kMapTileUrl = String.fromEnvironment(
  'MAP_TILE_URL',
  defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
);
const kMapTileFallbackUrl = String.fromEnvironment(
  'MAP_TILE_FALLBACK_URL',
  defaultValue: 'https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
);
const kMapTileUserAgent = 'com.skyweather.app';
const kMapTileLicenseUrl = String.fromEnvironment(
  'MAP_TILE_LICENSE_URL',
  defaultValue: 'https://www.openstreetmap.org/copyright',
);
const kMapTileAttribution = String.fromEnvironment(
  'MAP_TILE_ATTRIBUTION',
  defaultValue: '© OpenStreetMap contributors · HOT · OpenStreetMap France',
);
