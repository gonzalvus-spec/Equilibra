import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_constants.dart';
import 'core/app_theme.dart';
import 'screens/auth_screen.dart';
import 'services/app_initializer.dart';
import 'services/app_logger.dart';

/// Arranque mínimo que precarga sólo el estado local de la sesión.
///
/// Esto permite decidir el primer frame sin mostrar brevemente el formulario y,
/// además, conocer el modo guardado (`ModePreferences.cachedMode`) de forma
/// sincrónica al abrir la sesión: la app no pinta la selección de modo para
/// luego saltar al módulo elegido.
///
/// Firebase se precalienta en segundo plano (sin bloquear el primer frame) y
/// el resto de plugins se inicializa dentro de la app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Registrados antes de cualquier `await`: un fallo en la precarga también
  // debe quedar en el historial en lugar de abortar el arranque.
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.error(
      LogTags.boot,
      'Error no capturado de Flutter: ${details.exceptionAsString()}',
      details.exception,
      details.stack,
    );
    FlutterError.presentError(details);
    debugPrint('Equilibra: FlutterError: ${details.exceptionAsString()}');
  };

  // Errores de Dart fuera del ciclo de Flutter (Futures unawaited, callbacks
  // nativos, isolate): devolver `true` evita que el runtime termine la app.
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLogger.error(
      LogTags.boot,
      'Error no capturado (Dart/nativo): $error',
      error,
      stack,
    );
    debugPrint('Equilibra: error no capturado: $error');
    debugPrint('Equilibra: stack trace: $stack');
    return true;
  };

  // Firebase arranca en paralelo y sin `await`: en Android de gama de entrada
  // o con red lenta puede tardar varios segundos y no debe retrasar el primer
  // frame ni el formulario de inicio de sesión. `AppInitializer` se encarga de
  // los reintentos y comparte la campaña con el resto de la app.
  unawaited(AppInitializer.ensureFirebaseReady());

  SharedPreferences? preferences;
  try {
    preferences = await SharedPreferences.getInstance();
  } catch (error, stack) {
    // Sin caché se puede seguir: `ModePreferences` vuelve a intentarlo y, si
    // tampoco responde, la app abre la selección de modo.
    AppLogger.error(
      LogTags.boot,
      'No se pudieron precargar las preferencias locales.',
      error,
      stack,
    );
  }

  AppLogger.info(LogTags.boot, 'Iniciando main(): bindings de Flutter listos.');

  runApp(
    MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: AuthScreen(preferences: preferences),
    ),
  );
}
