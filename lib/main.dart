import 'dart:async';

import 'package:flutter/material.dart';

import 'home/home_screen.dart';
import 'home/home_theme.dart';
import 'services/comic_cache_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Orphan cleanup is pure disk I/O. Started before the first frame it competes
  // with the library's cover reads on slow flash storage, so it waits until the
  // UI has settled.
  unawaited(
    Future<void>.delayed(const Duration(seconds: 4))
        .then<void>((_) => ComicCacheService.instance.purgeOrphans())
        .catchError((Object error, StackTrace st) {
          debugPrint('PanelShift cache cleanup failed: $error');
        }),
  );
  // The saved theme is read before the first frame so the app never flashes
  // the default colors first. SharedPreferences is a single small file.
  final AppThemeSettings theme = await AppThemeController.loadSaved();
  runApp(PanelShiftApp(initialTheme: theme));
}

class PanelShiftApp extends StatefulWidget {
  const PanelShiftApp({
    super.key,
    this.initialTheme = AppThemeSettings.defaults,
  });

  final AppThemeSettings initialTheme;

  @override
  State<PanelShiftApp> createState() => _PanelShiftAppState();
}

class _PanelShiftAppState extends State<PanelShiftApp> {
  late final AppThemeController _theme = AppThemeController(
    widget.initialTheme,
  );

  // Built once and handed to the builder as its `child`: a theme change
  // rebuilds MaterialApp only, and the screen's State is never replaced.
  late final Widget _home = ComicProcessorScreen(
    title: 'PanelShift Core Engine',
    themeController: _theme,
  );

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppThemeSettings>(
      valueListenable: _theme,
      child: _home,
      builder: (BuildContext context, AppThemeSettings settings, Widget? home) {
        return MaterialApp(
          title: 'PanelShift Core',
          theme: settings.toThemeData(),
          home: home,
        );
      },
    );
  }
}
