import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_mode.dart';

class ModePreferences {
  ModePreferences([SharedPreferences? preferences])
    : _preferences = preferences;

  static const String key = 'operation_mode';
  static const String _legacyKey = 'app_mode';
  static const String savedModeKey = 'saved_mode';
  static const String activeSessionKey = 'has_active_session';

  final SharedPreferences? _preferences;

  Future<SharedPreferences> get _instance async =>
      _preferences ?? SharedPreferences.getInstance();

  /// Modo guardado leído de forma **sincrónica** desde la caché de
  /// `shared_preferences`.
  ///
  /// `main()` precarga la instancia antes del primer frame, así que al abrir la
  /// app no hace falta un `await` ni un estado intermedio: el modo inicial se
  /// conoce antes de construir `EquilibraApp`.
  AppMode? get cachedMode {
    final preferences = _preferences;
    if (preferences == null) return null;
    return _decode(preferences);
  }

  Future<AppMode?> load() async => _decode(await _instance);

  static AppMode? _decode(SharedPreferences preferences) {
    final saved = preferences.getString(savedModeKey);
    if (saved == 'puente') return AppMode.bridge;
    if (saved == 'monitor') return AppMode.monitor;
    return AppMode.fromStorage(
      preferences.getString(key) ?? preferences.getString(_legacyKey),
    );
  }

  Future<void> save(AppMode mode) async {
    final preferences = await _instance;
    await preferences.setString(
      savedModeKey,
      mode == AppMode.bridge ? 'puente' : 'monitor',
    );
    await preferences.setString(key, mode.storageValue);
    // El isolate del servicio lee esta clave al reiniciarse.
    await preferences.setString(_legacyKey, mode.storageValue);
  }

  Future<void> clear() async {
    final preferences = await _instance;
    await preferences.remove(savedModeKey);
    await preferences.remove(key);
    await preferences.remove(_legacyKey);
  }

  bool? get cachedHasActiveSession => _preferences?.getBool(activeSessionKey);

  Future<bool> loadHasActiveSession() async {
    final preferences = await _instance;
    return preferences.getBool(activeSessionKey) ?? false;
  }

  Future<void> saveHasActiveSession(bool active) async {
    final preferences = await _instance;
    await preferences.setBool(activeSessionKey, active);
  }
}
