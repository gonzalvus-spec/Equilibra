import 'package:equilibra/services/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AppLogger.printToConsole = false;
    AppLogger.clear();
  });

  test('conserva como máximo 300 registros, más recientes primero', () {
    for (var i = 0; i < 305; i++) {
      AppLogger.info(LogTags.boot, 'evento $i');
    }

    final entries = AppLogger.instance.entries.value;
    expect(entries, hasLength(AppLogger.maxEntries));
    expect(entries.first.message, 'evento 304');
    expect(entries.last.message, 'evento 5');
  });

  test('formatea hora, nivel y detalle técnico al copiar todo', () {
    AppLogger.error(
      LogTags.firebase,
      'Fallo de escritura',
      'permission-denied',
    );

    final text = AppLogger.allText;
    expect(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} ').hasMatch(text), isTrue);
    expect(text, contains('ERROR'));
    expect(text, contains('[FIREBASE] Fallo de escritura'));
    expect(text, contains('error: permission-denied'));
  });

  test('limpia el historial', () {
    AppLogger.ok(LogTags.modo, 'Listo');
    AppLogger.clear();

    expect(AppLogger.instance.entries.value, isEmpty);
    expect(AppLogger.allText, isEmpty);
  });
}
