import 'package:flutter/widgets.dart';

/// Clears text-field focus after backing out of a route, so the restored screen
/// doesn't reopen the software keyboard.
class KeyboardFocusObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }
}
