import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// Error de dominio: Firebase Core no quedó listo tras los reintentos.
///
/// [AppInitializer.ensureFirebaseReady] nunca lo lanza; lo usa
/// [AppInitializer.requireFirebaseReady] en flujos que no pueden continuar sin
/// Authentication o Realtime Database (por ejemplo, iniciar sesión).
class FirebaseInitializationException implements Exception {
  const FirebaseInitializationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Inicialización diferida, posterior al primer frame.
///
/// Sólo se encarga de Firebase Core, necesario para Authentication y Realtime
/// Database. Ningún plugin de notificaciones, ubicación, Bluetooth o servicio
/// en primer plano se configura aquí: eso ocurre únicamente cuando el usuario
/// elige Modo Puente o Modo Monitor (ver `BackgroundService.start` y
/// `AppPermissions`).
class AppInitializer {
  const AppInitializer();

  /// Límite de espera por intento.
  ///
  /// Antes eran 6 s, insuficiente en Android de gama de entrada (primer
  /// arranque, Google Play Services frío) o con conexión lenta.
  static const Duration attemptTimeout = Duration(seconds: 15);

  /// Intentos por campaña: el inicial y un reintento si el canal nativo falla.
  static const int maxAttempts = 2;

  /// Pausa entre intentos para no saturar el canal de plataforma.
  static const Duration retryDelay = Duration(seconds: 1);

  /// Margen máximo que un flujo interactivo (botón "Iniciar sesión") espera
  /// una campaña en curso antes de devolver un error claro y reutilizable.
  static const Duration interactiveTimeout = Duration(seconds: 20);

  static Future<void>? _firebase;

  /// Operación nativa en curso. Evita invocar `Firebase.initializeApp()` dos
  /// veces mientras la primera sigue viva en el canal de plataforma.
  static Future<void>? _pendingApp;

  /// Indica si Firebase Core ya está disponible sin lanzar excepciones.
  static bool get isReady {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Usuario local sin lanzar si Firebase aún no está inicializado.
  static User? safeCurrentUser() {
    try {
      if (!isReady) return null;
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// Inicializa Firebase Core una sola vez por campaña.
  ///
  /// - Es idempotente y *single-flight*: todas las llamadas concurrentes
  ///   comparten la misma campaña de inicialización.
  /// - Nunca propaga excepciones: un arranque lento no debe romper la UI.
  /// - Si la campaña termina sin éxito libera la caché para que un intento
  ///   posterior (iniciar sesión, reabrir un módulo) pueda reintentar.
  static Future<void> ensureFirebaseReady() {
    if (isReady) return Future<void>.value();
    return _firebase ??= _initFirebase();
  }

  /// Alias conservado para llamadas existentes.
  static Future<void> ensureFirebase() => ensureFirebaseReady();

  /// Igual que [ensureFirebaseReady], pero lanza
  /// [FirebaseInitializationException] si Firebase sigue sin estar listo.
  ///
  /// Debe esperarse antes de tocar `FirebaseAuth.instance`,
  /// `FirebaseDatabase.instance`, `FirebaseDatabase.instanceFor` o
  /// `Firebase.app()` en flujos que no pueden continuar sin ellos.
  static Future<void> requireFirebaseReady({
    Duration timeout = interactiveTimeout,
  }) async {
    try {
      await ensureFirebaseReady().timeout(timeout);
    } on TimeoutException {
      AppLogger.warn(
        LogTags.boot,
        'Firebase Core sigue inicializándose tras ${timeout.inSeconds} s; '
        'se devuelve el control al usuario para reintentar.',
      );
    }
    if (!isReady) {
      throw const FirebaseInitializationException(
        'Firebase todavía no está disponible. Revisa tu conexión a internet '
        'e inténtalo de nuevo.',
      );
    }
  }

  static Future<void> _initFirebase() async {
    final stopwatch = Stopwatch()..start();
    try {
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (isReady) break;

        AppLogger.info(
          LogTags.boot,
          'Inicializando Firebase Core (intento $attempt/$maxAttempts, '
          'límite ${attemptTimeout.inSeconds} s)…',
        );
        try {
          await _initializeDefaultApp().timeout(attemptTimeout);
        } on TimeoutException {
          // El canal nativo puede terminar después del límite local. No se
          // descarta la operación: el siguiente intento la reutiliza y le da
          // margen extra en lugar de invocarla de nuevo.
          AppLogger.warn(
            LogTags.boot,
            'Firebase Core aún no responde tras ${attemptTimeout.inSeconds} s '
            '(intento $attempt/$maxAttempts); se amplía la espera.',
          );
        } catch (error, stack) {
          AppLogger.warn(
            LogTags.boot,
            'Fallo al inicializar Firebase Core '
            '(intento $attempt/$maxAttempts): $error. Se reintentará.',
          );
          debugPrint('Equilibra: fallo al inicializar Firebase: $error');
          debugPrintStack(stackTrace: stack);
        }

        if (isReady) {
          AppLogger.ok(
            LogTags.boot,
            'Firebase Core inicializado correctamente '
            '(${stopwatch.elapsed.inSeconds} s).',
          );
          return;
        }
        if (attempt < maxAttempts) await Future<void>.delayed(retryDelay);
      }

      AppLogger.error(
        LogTags.boot,
        'Firebase Core no se pudo inicializar tras $maxAttempts intentos '
        '(${stopwatch.elapsed.inSeconds} s). Se reintentará al iniciar sesión '
        'o al reabrir un módulo.',
      );
    } finally {
      // Permite que la próxima llamada (login, reintento manual) inicie una
      // campaña nueva si esta no consiguió inicializar Firebase.
      if (!isReady) _firebase = null;
    }
  }

  /// Envuelve `Firebase.initializeApp()` para no duplicar la llamada nativa
  /// mientras la primera sigue pendiente.
  static Future<void> _initializeDefaultApp() {
    if (isReady) return Future<void>.value();

    final pending = _pendingApp;
    if (pending != null) return pending;

    final operation = Firebase.initializeApp();
    _pendingApp = operation;
    operation.then(
      (_) {
        if (identical(_pendingApp, operation)) _pendingApp = null;
      },
      onError: (_) {
        if (identical(_pendingApp, operation)) _pendingApp = null;
      },
    );
    return operation;
  }
}
