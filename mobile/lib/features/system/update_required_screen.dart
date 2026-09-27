import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shown instead of everything else when this build is older than the
/// server's `min_build` (or the server answered 426).
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key});

  Future<void> _openStore(BuildContext context) async {
    final package = (await PackageInfo.fromPlatform()).packageName;
    final market = Uri.parse('market://details?id=$package');
    final web = Uri.https('play.google.com', '/store/apps/details', {'id': package});
    final opened = await _launch(market) || await _launch(web);
    if (!opened && context.mounted) {
      showAppToast(context, 'Open the Play Store and update Quiz Arena.', icon: AppIcons.alert);
    }
  }

  static Future<bool> _launch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // No app can open it (e.g. no Play Store on this device).
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: EmptyState(
              icon: AppIcons.rocket,
              tone: PastelTone.lime,
              title: 'Time for an update',
              message:
                  'This version of Quiz Arena is no longer supported. Update to keep playing '
                  'with everyone else.',
              actionLabel: 'Update on Play Store',
              onAction: () => _openStore(context),
            ),
          ),
        ),
      ),
    );
  }
}
