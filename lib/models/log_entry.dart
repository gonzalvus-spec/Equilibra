import 'package:intl/intl.dart';

/// Nivel de severidad de un registro interno.
enum LogLevel {
  info('INFO'),
  ok('OK'),
  warn('WARN'),
  error('ERROR');

  const LogLevel(this.label);

  final String label;
}

/// Registro inmutable del historial interno de EQUILIBRA.
class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  /// Hora exacta con milisegundos, tal como se muestra en el visor.
  String get timeLabel =>
      DateFormat('HH:mm:ss.SSS').format(timestamp.toLocal());

  /// Representación de una línea, usada al copiar todo el historial.
  String get formatted {
    final buffer = StringBuffer(
      '$timeLabel ${level.label.padRight(5)} [$tag] $message',
    );
    if (error != null) buffer.write(' | error: $error');
    if (stackTrace != null) buffer.write(' | stack: $stackTrace');
    return buffer.toString();
  }
}
