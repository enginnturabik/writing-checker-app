import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../models/history_entry.dart';

/// Settings and saved checks, kept on the device.
///
/// The API key lives in the platform keystore (Keychain / EncryptedSharedPrefs)
/// rather than in the settings file. Everything else is plain JSON in the app
/// support directory. On web, where that directory does not exist, storage
/// degrades to memory for the session instead of failing.
class LocalStore {
  // Defaults are already the hardened ones on every platform in v11: Android
  // encrypts the preference store, iOS and macOS use the Keychain.
  LocalStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  static const _keyApiKey = 'anthropic_api_key';
  static const _keySessionToken = 'device_session_token';
  static const _settingsFile = 'settings.json';
  static const _historyFile = 'history.json';

  final FlutterSecureStorage _secure;

  Directory? _dir;
  final Map<String, String> _memory = {};

  Future<Directory?> _directory() async {
    if (kIsWeb) return null;
    if (_dir != null) return _dir;
    try {
      _dir = await getApplicationSupportDirectory();
      await _dir!.create(recursive: true);
      return _dir;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _read(String name) async {
    final dir = await _directory();
    if (dir == null) return _memory[name];
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String name, String contents) async {
    final dir = await _directory();
    if (dir == null) {
      _memory[name] = contents;
      return;
    }
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(contents, flush: true);
  }

  // --- API key -------------------------------------------------------------

  Future<String?> readApiKey() async {
    try {
      return await _secure.read(key: _keyApiKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeApiKey(String key) async {
    try {
      await _secure.write(key: _keyApiKey, value: key);
    } catch (_) {
      // A locked or unavailable keystore should not take the app down; the
      // user simply has to re-enter the key next launch.
    }
  }

  Future<void> deleteApiKey() async {
    try {
      await _secure.delete(key: _keyApiKey);
    } catch (_) {}
  }

  // --- Device session ------------------------------------------------------

  /// The device token is a bearer credential for the balance, so it belongs in
  /// the keystore alongside the API key rather than in the settings file.
  Future<String?> readSessionToken() async {
    try {
      return await _secure.read(key: _keySessionToken);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeSessionToken(String token) async {
    try {
      await _secure.write(key: _keySessionToken, value: token);
    } catch (_) {}
  }

  /// Forgets the device token, so the next launch registers as a new device.
  Future<void> clearSessionToken() async {
    try {
      await _secure.delete(key: _keySessionToken);
    } catch (_) {}
  }

  // --- Settings ------------------------------------------------------------

  Future<Map<String, dynamic>> readSettings() async {
    final raw = await _read(_settingsFile);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Future<void> writeSettings(Map<String, dynamic> settings) =>
      _write(_settingsFile, jsonEncode(settings));

  // --- History -------------------------------------------------------------

  Future<List<HistoryEntry>> readHistory() async {
    final raw = await _read(_historyFile);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => HistoryEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      // A corrupt history file must not block the app from starting.
      return [];
    }
  }

  Future<void> writeHistory(List<HistoryEntry> entries) => _write(
        _historyFile,
        jsonEncode(entries.map((e) => e.toJson()).toList()),
      );
}
