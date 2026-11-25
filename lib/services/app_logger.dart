import 'package:flutter/foundation.dart';

import '../models/log_entry.dart';

/// Etiquetas usadas por los flujos críticos de la aplicación.
abstract final class LogTags {
  static const String boot = 'BOOT';
  static const String auth = 'AUTH';
  static const String modo = 'MODO';
  static const String permisos = 'PERMISOS';
  static const String firebase = 'FIREBASE';
  static const String bgService = 'BG_SERVICE';
  static const String bluetooth = 'BLUETOOTH';
  static const String gps = 'GPS';
  static const String notificaciones = 'NOTIFICACIONES';
}

/// Historial interno en memoria de los últimos [AppLogger.maxEntries] eventos.
///
/// Es un singleton y expone un [ValueNotifier] para que el visor de registros
/// se actualice en vivo sin depender de Firebase ni del servicio en segundo
/// plano. Nunca lanza excepciones: registrar un evento jamás debe alterar el
/// flujo que lo originó.
class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  static const int maxEntries = 300;

  /// Eco en consola; se puede desactivar en pruebas para evitar ruido.
  static bool printToConsole = true;

  /// Los registros más recientes aparecen primero.
  final ValueNotifier<List<LogEntry>> entries = ValueNotifier<List<LogEntry>>(
    const <LogEntry>[],
  );

  static void info(String tag, String message) =>
      instance._add(LogLevel.info, tag, message);

  static void ok(String tag, String message) =>
      instance._add(LogLevel.ok, tag, message);

  static void warn(String tag, String message) =>
      instance._add(LogLevel.warn, tag, message);

  static void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) => instance._add(
    LogLevel.error,
    tag,
    message,
    error: error,
    stackTrace: stackTrace,
  );

  /// Texto completo del historial, listo para el portapapeles.
  static String get allText =>
      instance.entries.value.map((entry) => entry.formatted).join('\n');

  static void clear() => instance.entries.value = const <LogEntry>[];

  /// Registra un evento reenviado desde el isolate del servicio en primer
  /// plano (los isolates no comparten memoria con este singleton).
  void addFromIsolate(
    LogLevel level,
    String tag,
    String message, [
    String? error,
  ]) => _add(level, tag, message, error: error);

  void _add(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    final next = <LogEntry>[entry, ...entries.value];
    if (next.length > maxEntries) {
      next.removeRange(maxEntries, next.length);
    }
    entries.value = List<LogEntry>.unmodifiable(next);
    if (printToConsole) {
      debugPrint(
        '[EQB:${entry.level.label}][$tag] $message${error == null ? '' : ' · $error'}',
      );
    }
  }
}
