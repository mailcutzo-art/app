import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'catalog_home.dart';

void main() => runApp(const CatalogApp());

/// Lets any catalog page flip between light and dark.
class ThemeModeScope extends InheritedWidget {
  const ThemeModeScope({super.key, required this.mode, required this.toggle, required super.child});

  final ThemeMode mode;
  final VoidCallback toggle;

  static ThemeModeScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeModeScope>()!;

  @override
  bool updateShouldNotify(ThemeModeScope oldWidget) => oldWidget.mode != mode;
}

class CatalogApp extends StatefulWidget {
  const CatalogApp({super.key, this.initialMode = ThemeMode.light, this.home});

  final ThemeMode initialMode;

  /// Overrides the start page (used by golden tests).
  final Widget? home;

  @override
  State<CatalogApp> createState() => _CatalogAppState();
}

class _CatalogAppState extends State<CatalogApp> {
  late ThemeMode _mode = widget.initialMode;

  @override
  Widget build(BuildContext context) {
    return ThemeModeScope(
      mode: _mode,
      toggle: () => setState(() {
        _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
      }),
      child: MaterialApp(
        title: 'Quiz design system',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _mode,
        home: widget.home ?? const CatalogHome(),
      ),
    );
  }
}
