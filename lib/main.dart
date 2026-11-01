import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'config/api_config.dart';
import 'models/app_settings.dart';
import 'background/background_check.dart';
import 'providers/account_provider.dart';
import 'providers/home_widget_updater.dart';
import 'providers/location_provider.dart';
import 'providers/planner_provider.dart';
import 'providers/preferences_provider.dart';
import 'providers/trip_provider.dart';
import 'providers/weather_provider.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/api_service.dart';
import 'services/app_settings_store.dart';
import 'services/app_version.dart';
import 'services/notification_service.dart';
import 'ui/weather/app_scene.dart';
import 'ui/weather/design_tokens.dart';
import 'ui/weather/weather_background.dart';
import 'utils/safe_focus_policy.dart';
import 'utils/theme.dart';
import 'widgets/replay_banner.dart';

/// Ghi log loi khong bat duoc (khong lam sap app).
void _logUncaught(String source, Object error, StackTrace? stack) {
  developer.log(
    'Uncaught error ($source)',
    name: 'sky_weather',
    error: error,
    stackTrace: stack,
  );
  debugPrint('[$source] $error');
}

Future<void> main() async {
  // Bat loi toan cuc: loi framework, loi nen tang/async, loi trong zone.
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _logUncaught('flutter', details.exception, details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _logUncaught('platform', error, stack);
      return true;
    };

    // Doc cai dat truoc frame dau de khong bi nhay giao dien sang/toi
    final settings = await AppSettingsStore.load();
    final preferences = PreferencesProvider();
    await preferences.load();
    // URL may chu nguoi dung tu dat (Cai dat > Nang cao), neu co.
    await ApiConfig.loadBaseUrl();
    // Phien ban that (package_info_plus) cho Cai dat / phan hoi.
    await AppVersion.load();

    runApp(SkyWeatherApp(initialSettings: settings, preferences: preferences));
  }, (error, stack) => _logUncaught('zone', error, stack));
}

final FocusTraversalPolicy _focusPolicy = SafeReadingOrderTraversalPolicy();

class SkyWeatherApp extends StatelessWidget {
  final AppSettings? initialSettings;

  /// Da [PreferencesProvider.load] truoc runApp; null -> tao moi va tai sau.
  final PreferencesProvider? preferences;

  const SkyWeatherApp({super.key, this.initialSettings, this.preferences});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Mot ApiService (mot http.Client) dung chung cho cac provider; dong
        // khi app dong.
        Provider<WeatherRepository>(
          create: (context) => ApiService(),
          dispose: (_, api) => api.close(),
        ),
        ChangeNotifierProvider(
          create: (context) => WeatherProvider(
            apiService: context.read<WeatherRepository>(),
            initialSettings: initialSettings,
          )..attachLifecycle(),
        ),
        // Dia diem da luu, vi tri hien tai, du lieu ban do.
        // WeatherProvider tai truoc trang ke ben theo thu tu trang Home.
        ChangeNotifierProvider(
          create: (context) {
            final lp = LocationProvider(
              apiService: context.read<WeatherRepository>(),
            );
            final wp = context.read<WeatherProvider>();
            wp.pageIds = () => [for (final p in lp.pages) p.locationId];
            wp.placeFor = lp.knownPlace;
            return lp;
          },
        ),
        // Canh bao + goi y hoat dong (tinh tren thiet bi).
        // Thong bao he thong chi tren Android; xin quyen khi nguoi dung bat.
        ChangeNotifierProvider(
          create: (context) {
            final p = PlannerProvider(
              notifications: NotificationService.platform(),
              onBackgroundChanged: setBackgroundCheck,
            )..attachLifecycle();
            p.load().then((_) {
              p.recordAppOpen();
              p.syncBackground();
            });
            return p;
          },
        ),
        // Gia lap canh thoi tiet (man hinh "Giả lập thời tiết", chi debug).
        ChangeNotifierProvider(create: (context) => SceneOverride()),
        // Don vi, chi so trang chu, tro nang (nhom 8).
        ChangeNotifierProvider(
          create: (context) => (preferences ?? PreferencesProvider())..load(),
        ),
        // Canh bao khi di chuyen (nhom 6); lich su chuyen di chi tren may.
        ChangeNotifierProvider(
          create: (context) => TripProvider(
            api: context.read<WeatherRepository>(),
            units: () => context.read<PreferencesProvider>().units,
            alertSettings: () => context.read<PlannerProvider>().settings,
          )..load(),
        ),
        // Widget man hinh chinh (Android; iOS chi luu du lieu; web bo qua).
        Provider<HomeWidgetUpdater>(
          lazy: false,
          create: (context) => HomeWidgetUpdater(
            context.read<WeatherProvider>(),
            context.read<LocationProvider>(),
            units: () => context.read<PreferencesProvider>().units,
          ),
          dispose: (_, u) => u.dispose(),
        ),
        // Tai khoan tuy chon + dong bo (nhom 9).
        ChangeNotifierProvider(
          create: (context) => AccountProvider()
            ..attach(
              context.read<LocationProvider>(),
              context.read<WeatherProvider>(),
              context.read<PlannerProvider>(),
              prefs: context.read<PreferencesProvider>(),
            ),
        ),
      ],
      // Giao dien Sang/Toi theo he thong (khong con lua chon trong app).
      child: Builder(
        builder: (context) {
          return MaterialApp(
            title: 'Sky Weather',
            debugShowCheckedModeBanner: false,
            navigatorKey: AccountProvider.navigatorKey,

            // Theme configuration
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: ThemeMode.system,

            // Mau thanh trang thai/dieu huong theo giao dien dang ap dung
            // (ke ca che do "Theo hệ thống")
            builder: (context, child) {
              final isDark = Theme.of(context).brightness == Brightness.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: isDark
                    ? SystemUiOverlayStyle.light.copyWith(
                        statusBarColor: Colors.transparent,
                        systemNavigationBarColor: Colors.transparent,
                      )
                    : SystemUiOverlayStyle.dark.copyWith(
                        statusBarColor: Colors.transparent,
                        systemNavigationBarColor:
                            SystemColors.groupedBackground,
                      ),
                // Canh nen tinh MOT lan cho ca app; banner "ĐANG XEM LẠI"
                // tren moi man hinh.
                // Co chu / tuong phan cao / giam chuyen dong trong app.
                child: MediaQuery(
                  data: context.watch<PreferencesProvider>().applyTo(
                    MediaQuery.of(context),
                  ),
                  // Thu tu focus an toan: khong do kich thuoc nut chua
                  // layout khi cua so web nhan focus (xem chinh sach).
                  child: FocusTraversalGroup(
                    policy: _focusPolicy,
                    child: AppSceneScope(
                      child: ReplayBannerHost(child: child!),
                    ),
                  ),
                ),
              );
            },

            // Home screen
            // Lan dau: huong dan 3 buoc phu len man chinh (bo qua duoc).
            home: OnboardingGate(
              child: HomeScreen(locations: context.read<LocationProvider>()),
            ),
          );
        },
      ),
    );
  }
}
