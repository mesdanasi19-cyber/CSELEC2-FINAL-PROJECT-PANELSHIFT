import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ==========================================
/// 0. App theme (seed color + brightness)
/// ==========================================

/// One selectable seed color. [monochrome] renders the whole Material scheme in
/// neutral greys (used by "Monochrome Slate").
@immutable
class AppThemePreset {
  const AppThemePreset(this.name, this.argb, {this.monochrome = false});

  final String name;

  /// 0xAARRGGBB. This int is what gets persisted.
  final int argb;
  final bool monochrome;

  Color get color => Color(argb);
}

class AppThemePresets {
  const AppThemePresets._();

  static const AppThemePreset deepPurple = AppThemePreset(
    'Deep Purple',
    0xFF673AB7,
  );
  static const AppThemePreset crimson = AppThemePreset('Crimson', 0xFFC62828);
  static const AppThemePreset cobalt = AppThemePreset(
    'Cobalt Blue',
    0xFF0047AB,
  );
  static const AppThemePreset emerald = AppThemePreset('Emerald', 0xFF2E9E6B);
  static const AppThemePreset amber = AppThemePreset('Amber', 0xFFFFB300);
  static const AppThemePreset rose = AppThemePreset('Rose', 0xFFF06292);
  static const AppThemePreset slate = AppThemePreset(
    'Monochrome Slate',
    0xFF607D8B,
    monochrome: true,
  );

  static const List<AppThemePreset> all = <AppThemePreset>[
    deepPurple,
    crimson,
    cobalt,
    emerald,
    amber,
    rose,
    slate,
  ];

  /// The preset saved as [argb], or Deep Purple for anything unknown.
  static AppThemePreset byArgb(int? argb) {
    for (final AppThemePreset preset in all) {
      if (preset.argb == argb) return preset;
    }
    return deepPurple;
  }
}

/// Immutable theme choice: seed color + dark/light.
@immutable
class AppThemeSettings {
  const AppThemeSettings({required this.preset, required this.brightness});

  static const AppThemeSettings defaults = AppThemeSettings(
    preset: AppThemePresets.deepPurple,
    brightness: Brightness.dark,
  );

  final AppThemePreset preset;
  final Brightness brightness;

  ThemeData toThemeData() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: preset.color,
      brightness: brightness,
      dynamicSchemeVariant: preset.monochrome
          ? DynamicSchemeVariant.monochrome
          : DynamicSchemeVariant.tonalSpot,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppThemeSettings &&
      other.preset.argb == preset.argb &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(preset.argb, brightness);
}

/// Holds the live theme at the app root. Library code only ever calls
/// [select]; `PanelShiftApp` listens and rebuilds the [MaterialApp] with the
/// new [ThemeData], so the screen below keeps its State (scroll position,
/// search, selection, pre-indexer queue).
class AppThemeController extends ValueNotifier<AppThemeSettings> {
  AppThemeController([AppThemeSettings initial = AppThemeSettings.defaults])
    : super(initial);

  static const String seedKey = 'panelshift.themeSeed.v1';
  static const String brightnessKey = 'panelshift.themeBrightness.v1';

  static Future<AppThemeSettings> loadSaved() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return AppThemeSettings(
        preset: AppThemePresets.byArgb(prefs.getInt(seedKey)),
        brightness: prefs.getString(brightnessKey) == Brightness.light.name
            ? Brightness.light
            : Brightness.dark,
      );
    } catch (e) {
      debugPrint('PanelShift: could not load theme: $e');
      return AppThemeSettings.defaults;
    }
  }

  void select({AppThemePreset? preset, Brightness? brightness}) {
    final AppThemeSettings next = AppThemeSettings(
      preset: preset ?? value.preset,
      brightness: brightness ?? value.brightness,
    );
    if (next == value) return;
    value = next;
    unawaited(_save(next));
  }

  Future<void> _save(AppThemeSettings settings) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(seedKey, settings.preset.argb);
      await prefs.setString(brightnessKey, settings.brightness.name);
    } catch (e) {
      debugPrint('PanelShift: could not save theme: $e');
    }
  }
}

/// Compact theme chooser. Choices apply immediately (live preview) and are
/// persisted by [AppThemeController]; the dialog just listens to it.
class ThemeDialog extends StatelessWidget {
  const ThemeDialog({required this.controller});

  final AppThemeController controller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Theme'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 320,
        child: ValueListenableBuilder<AppThemeSettings>(
          valueListenable: controller,
          builder: (BuildContext context, AppThemeSettings settings, _) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Color', style: text.labelLarge),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 8,
                    children: [
                      for (final AppThemePreset preset in AppThemePresets.all)
                        _ThemeSwatch(
                          preset: preset,
                          selected: preset.argb == settings.preset.argb,
                          onTap: () => controller.select(preset: preset),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('Mode', style: text.labelLarge),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<Brightness>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<Brightness>>[
                        ButtonSegment<Brightness>(
                          value: Brightness.dark,
                          icon: Icon(Icons.dark_mode_outlined),
                          label: Text('Dark'),
                        ),
                        ButtonSegment<Brightness>(
                          value: Brightness.light,
                          icon: Icon(Icons.light_mode_outlined),
                          label: Text('Light'),
                        ),
                      ],
                      selected: <Brightness>{settings.brightness},
                      onSelectionChanged: (Set<Brightness> selection) =>
                          controller.select(brightness: selection.first),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Bookshelf wood follows the mode: walnut in dark, oak in '
                    'light.',
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final AppThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = preset.color;
    final Color onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;

    return SizedBox(
      width: 72,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: selected
                      ? Icon(Icons.check, size: 20, color: onColor)
                      : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                preset.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(fontSize: 10.5, height: 1.15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
