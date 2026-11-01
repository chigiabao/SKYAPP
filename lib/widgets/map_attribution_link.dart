import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/map_tiles.dart';

class MapAttributionLink extends StatelessWidget {
  const MapAttributionLink({super.key, required this.text, this.style});

  final String text;
  final TextStyle? style;

  Future<void> _openLicense(BuildContext context) async {
    try {
      if (await launchUrl(
        Uri.parse(kMapTileLicenseUrl),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Keep the license address accessible if the device has no browser.
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Giấy phép bản đồ'),
        content: SelectableText('$text\n$kMapTileLicenseUrl'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(44, 44),
      alignment: Alignment.centerLeft,
      foregroundColor: style?.color,
    ),
    onPressed: () => _openLicense(context),
    child: Text(
      text,
      style: style?.copyWith(decoration: TextDecoration.underline),
    ),
  );
}
