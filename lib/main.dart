import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'config/api_config.dart';
import 'models/app_settings.dart';
import 'providers/account_provider.dart';
import 'providers/location_provider.dart';
import 'providers/planner_provider.dart';
import 'providers/preferences_provider.dart';
import 'providers/trip_provider.dart';
import 'providers/weather_provider.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/app_version.dart';
import 'services/background_check.dart';
import 'services/home_widget_service.dart';
import 'services/notification_service.dart';
import 'ui/weather/app_scene.dart';
import 'ui/weather/weather_background.dart';
import 'utils/theme.dart';
import 'widgets/replay_banner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Doc cai dat truoc frame dau de khong bi nhay giao dien sang/toi
  final settings = await AppSettings.load();
  // URL may chu nguoi dung tu dat (Cai dat > Nang cao), neu co.
  await ApiConfig.loadBaseUrl();
  // Phien ban that (package_info_plus) cho Cai dat / phan hoi.
  await AppVersion.load();

  runApp(SkyWeatherApp(initialSettings: settings));
}

class SkyWeatherApp extends StatelessWidget {
  final AppSettings? initialSettings;

  const SkyWeatherApp({super.key, this.initialSettings});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (context) =>
              WeatherProvider(initialSettings: initialSettings),
        ),
        // Dia diem da luu, vi tri hien tai, du lieu ban do.
        // WeatherProvider tai truoc trang ke ben theo thu tu trang Home.
        ChangeNotifierProvider(
          create: (context) {
            final lp = LocationProvider();
            context.read<WeatherProvider>().pageIds = () => [
              for (final p in lp.pages) p.locationId,
            ];
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
          create: (context) => PreferencesProvider()..load(),
        ),
        // Canh bao khi di chuyen (nhom 6); lich su chuyen di chi tren may.
        ChangeNotifierProvider(
          create: (context) => TripProvider(
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
      child: Consumer<WeatherProvider>(
        builder: (context, provider, child) {
          return MaterialApp(
            title: 'Sky Weather',
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: AccountProvider.messengerKey,

            // Theme configuration
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: provider.themeMode,

            // Mau thanh trang thai/dieu huong theo giao dien dang ap dung
            // (ke ca che do "Theo hệ thống")
            builder: (context, child) {
              final isDark = Theme.of(context).brightness == Brightness.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: isDark
                    ? SystemUiOverlayStyle.light.copyWith(
                        statusBarColor: Colors.transparent,
                        systemNavigationBarColor: const Color(0xFF1A1A2E),
                      )
                    : SystemUiOverlayStyle.dark.copyWith(
                        statusBarColor: Colors.transparent,
                        systemNavigationBarColor: Colors.grey[50],
                      ),
                // Canh nen tinh MOT lan cho ca app; banner "ĐANG XEM LẠI"
                // tren moi man hinh.
                // Co chu / tuong phan cao / giam chuyen dong trong app.
                child: MediaQuery(
                  data: context.watch<PreferencesProvider>().applyTo(
                    MediaQuery.of(context),
                  ),
                  child: AppSceneScope(child: ReplayBannerHost(child: child!)),
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
