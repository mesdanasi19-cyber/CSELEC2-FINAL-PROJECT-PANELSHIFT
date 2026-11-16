import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preloads a short page-turn sound and reuses a small pool of players.
///
/// The sound is deliberately independent of reader navigation. The curl widget
/// calls [play] only after its PageController leaves a settled page index, so
/// panel stepping/zooming never reaches this controller.
class PageTurnSoundController {
  static const String _defaultAsset = 'audio/page_turn.mp3';
  static const String _enabledKey = 'reader.pageSound.enabled';
  static const String _volumeKey = 'reader.pageSound.volume';
  static const String _customPathKey = 'reader.pageSound.customPath';
  static const int _maxCustomSoundBytes = 8 * 1024 * 1024;

  bool _enabled = true;
  double _volume = 0.46;
  String? _customPath;
  SharedPreferences? _preferences;
  AudioPool? _pool;
  Future<void>? _initialization;
  bool _disposed = false;
  bool _ready = false;

  bool get enabled => _enabled;
  double get volume => _volume;
  String? get customSoundName {
    final String? path = _customPath;
    return path == null ? null : path.split(Platform.pathSeparator).last;
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      _enabled = _preferences?.getBool(_enabledKey) ?? true;
      _volume = (_preferences?.getDouble(_volumeKey) ?? 0.46)
          .clamp(0.0, 1.0)
          .toDouble();
      _customPath = _preferences?.getString(_customPathKey);
    } catch (error, stackTrace) {
      // Audio must never prevent the comic reader from opening.
      _preferences = null;
      debugPrint('Could not load page-sound preferences: $error\n$stackTrace');
    }

    final String? savedPath = _customPath;
    if (savedPath != null) {
      try {
        if (await File(savedPath).exists()) {
          await _replacePool(DeviceFileSource(savedPath));
          if (_pool != null) {
            _ready = true;
            return;
          }
        }
      } catch (error, stackTrace) {
        debugPrint('Could not restore custom page sound: $error\n$stackTrace');
      }
      _customPath = null;
      try {
        await _preferences?.remove(_customPathKey);
      } catch (_) {
        // Preferences are optional; use the bundled sound for this session.
      }
    }

    try {
      await _replaceBundledPool();
    } catch (error, stackTrace) {
      // Keep the reader functional even if the platform audio backend fails.
      debugPrint('Could not preload bundled page sound: $error\n$stackTrace');
    } finally {
      // Do not play with defaults before saved settings/custom source have
      // finished loading. A very early turn is simply silent, never delayed.
      _ready = true;
    }
  }

  Future<AudioPool> _createPool(Source source) {
    return AudioPool.create(
      source: source,
      minPlayers: 1,
      maxPlayers: 2,
      // AudioPool preloads and reuses players; mediaPlayer mode also provides
      // normal completion/recycling across Android, iOS and desktop platforms.
      playerMode: PlayerMode.mediaPlayer,
    );
  }

  Future<void> _replacePool(Source source) async {
    final AudioPool candidate = await _createPool(source);
    if (_disposed) {
      await candidate.dispose();
      return;
    }

    final AudioPool? previous = _pool;
    _pool = candidate;
    if (previous != null) {
      try {
        await previous.dispose();
      } catch (error) {
        debugPrint('Could not dispose previous page-sound pool: $error');
      }
    }
  }

  Future<void> _replaceBundledPool() async {
    final AudioPool candidate = await AudioPool.createFromAsset(
      path: _defaultAsset,
      minPlayers: 1,
      maxPlayers: 2,
      playerMode: PlayerMode.mediaPlayer,
    );
    if (_disposed) {
      await candidate.dispose();
      return;
    }

    final AudioPool? previous = _pool;
    _pool = candidate;
    if (previous != null) {
      try {
        await previous.dispose();
      } catch (error) {
        debugPrint('Could not dispose previous page-sound pool: $error');
      }
    }
  }

  /// Fire-and-forget by design: never make a pointer or page animation await
  /// audio I/O. The audio source is already loaded into the pool at this point.
  void play() {
    final AudioPool? pool = _pool;
    if (_disposed || !_ready || !_enabled || pool == null) return;
    unawaited(_startPool(pool, _volume));
  }

  Future<void> _startPool(AudioPool pool, double volume) async {
    try {
      await pool.start(volume: volume);
    } catch (error, stackTrace) {
      debugPrint('Page-turn sound playback failed: $error\n$stackTrace');
    }
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    if (_disposed) return;
    _enabled = value;
    try {
      await _preferences?.setBool(_enabledKey, value);
    } catch (error) {
      debugPrint('Could not persist page-sound enabled state: $error');
    }
  }

  Future<void> setVolume(double value) async {
    await initialize();
    if (_disposed) return;
    _volume = value.clamp(0.0, 1.0).toDouble();
    try {
      await _preferences?.setDouble(_volumeKey, _volume);
    } catch (error) {
      debugPrint('Could not persist page-sound volume: $error');
    }
  }

  /// Lets the user import WAV, MP3 or M4A audio. The selected file is copied
  /// into app-private storage so it remains available after a restart and is
  /// not tied to a temporary picker/cache URI.
  /// Lets the user import WAV, MP3 or M4A audio. The selected file is copied
  /// into app-private storage so it remains available after a restart and is
  /// not tied to a temporary picker/cache URI.
  Future<String?> importCustomSound() async {
    await initialize();
    if (_disposed) return null;

    final dynamic result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['wav', 'mp3', 'm4a'],
    );

    if (result == null) return null;

    final PlatformFile picked;
    if (result is List) {
      if (result.isEmpty) return null;
      picked = result.first as PlatformFile;
    } else {
      final files = result.files;
      if (files.isEmpty) return null;
      picked = files.single;
    }

    final String name = picked.name;
    final int extensionSeparator = name.lastIndexOf('.');
    if (extensionSeparator <= 0 || extensionSeparator == name.length - 1) {
      throw const FormatException('Choose a WAV, MP3 or M4A audio file.');
    }
    final String extension = name.substring(extensionSeparator + 1).toLowerCase();
    if (!const <String>{'wav', 'mp3', 'm4a'}.contains(extension)) {
      throw const FormatException('Choose a WAV, MP3 or M4A audio file.');
    }

    // Safely retrieve file size with null safety fallback
    final int fileSize = (await picked.length()) ?? 0;
    if (fileSize <= 0 || fileSize > _maxCustomSoundBytes) {
      throw const FormatException('The page sound must be between 1 byte and 8 MB.');
    }

    final List<int> bytes;
    if (picked.path != null) {
      bytes = await File(picked.path!).readAsBytes();
    } else {
      throw const FormatException('The selected audio file could not be read.');
    }
    if (bytes.isEmpty || bytes.length > _maxCustomSoundBytes) {
      throw const FormatException('The selected audio file is empty or larger than 8 MB.');
    }

    final Directory supportDirectory = await getApplicationSupportDirectory();
    final Directory soundDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}page_sounds',
    );
    await soundDirectory.create(recursive: true);

    final String storedName =
        'page_turn_${DateTime.now().microsecondsSinceEpoch}.$extension';
    final File storedFile = File(
      '${soundDirectory.path}${Platform.pathSeparator}$storedName',
    );
    await storedFile.writeAsBytes(bytes, flush: true);

    try {
      // Build and preload the replacement before swapping out the current pool.
      await _replacePool(DeviceFileSource(storedFile.path));
      if (_pool == null) {
        throw StateError('The custom page sound could not be initialized.');
      }
      final String? previousPath = _customPath;
      _customPath = storedFile.path;
      try {
        await _preferences?.setString(_customPathKey, storedFile.path);
      } catch (error) {
        // The imported sound remains active for this session even when the
        // platform preference store is temporarily unavailable.
        debugPrint('Could not persist custom page-sound path: $error');
      }
      if (previousPath != null && previousPath != storedFile.path) {
        unawaited(_deleteFileQuietly(previousPath));
      }
      return storedName;
    } catch (_) {
      await _deleteFileQuietly(storedFile.path);
      rethrow;
    }
  }

  /// Switches back to the tiny bundled default and removes the copied override.
  Future<void> useBundledSound() async {
    await initialize();
    if (_disposed) return;
    await _replaceBundledPool();
    final String? previousPath = _customPath;
    _customPath = null;
    try {
      await _preferences?.remove(_customPathKey);
    } catch (error) {
      debugPrint('Could not clear custom page-sound preference: $error');
    }
    if (previousPath != null) unawaited(_deleteFileQuietly(previousPath));
  }

  Future<void> _deleteFileQuietly(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Could not remove old page sound: $error');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final AudioPool? pool = _pool;
    _pool = null;
    if (pool != null) await pool.dispose();
  }
}