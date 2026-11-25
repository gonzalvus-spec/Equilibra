import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/background_keys.dart';
import 'app_logger.dart';

/// Notificaciones locales de la alarma EQUILIBRA.
///
/// Ningún método propaga excepciones: las notificaciones son un extra de la
/// supervisión y un fallo del sistema de notificaciones (canal bloqueado,
/// plugin no disponible, `NOTIFICATIONS` revocado…) no debe interrumpir la
/// alarma, el servicio en primer plano ni el isolate de segundo plano.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String channelId = 'equilibra_alertas';
  static const String channelName = 'Equilibra';
  static const String channelDescription = 'Alertas de detección de golpes';
  static const int alarmNotificationId = 1;
  static const int serviceNotificationId = BackgroundKeys.serviceNotificationId;

  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _initialization;

  /// Inicializa el plugin una sola vez. Si falla, se libera la caché para que
  /// un intento posterior (por ejemplo, tras conceder el permiso) funcione.
  Future<void> initialize() async {
    final pending = _initialization;
    if (pending != null) return pending;
    final future = _initialize();
    _initialization = future;
    try {
      await future;
    } catch (_) {
      if (identical(_initialization, future)) _initialization = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        BackgroundKeys.channelId,
        BackgroundKeys.channelName,
        description: BackgroundKeys.channelDescription,
        importance: Importance.low,
      ),
    );
  }

  /// Comprueba y, si hace falta, solicita el permiso de notificaciones.
  ///
  /// Devuelve `false` en lugar de lanzar: la app funciona sin notificaciones.
  Future<bool> ensurePermission() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return true;
      if (await android.areNotificationsEnabled() ?? false) return true;
      return await android.requestNotificationsPermission() ?? false;
    } catch (error) {
      AppLogger.warn(
        LogTags.notificaciones,
        'No se pudo verificar el permiso de notificaciones: $error',
      );
      return false;
    }
  }

  /// Servicio discreto y persistente; no interrumpe al usuario.
  Future<void> showServiceNotification({
    required String title,
    required String message,
  }) async {
    try {
      await initialize();
      await _plugin.show(
        id: serviceNotificationId,
        title: title,
        body: message,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            BackgroundKeys.channelId,
            BackgroundKeys.channelName,
            channelDescription: BackgroundKeys.channelDescription,
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            playSound: false,
            enableVibration: false,
          ),
        ),
      );
    } catch (error, stack) {
      _logFailure('mostrar la notificación del servicio', error, stack);
    }
  }

  /// Alerta urgente: suena, vibra e intenta abrir la pantalla aunque esté bloqueada.
  Future<void> showFallAlert({
    required String title,
    required String message,
  }) async {
    try {
      await initialize();
      await _plugin.show(
        id: alarmNotificationId,
        title: title,
        body: message,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.alarm,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            enableVibration: true,
            playSound: true,
            fullScreenIntent: true,
            visibility: NotificationVisibility.public,
            autoCancel: false,
          ),
        ),
      );
    } catch (error, stack) {
      _logFailure('mostrar la alerta de caída', error, stack);
    }
  }

  Future<void> cancelFallAlert() async {
    try {
      await initialize();
      await _plugin.cancel(id: alarmNotificationId);
    } catch (error, stack) {
      _logFailure('cancelar la alerta de caída', error, stack);
    }
  }

  void _logFailure(String action, Object error, StackTrace stack) {
    AppLogger.error(
      LogTags.notificaciones,
      'No se pudo $action: $error',
      error,
      stack,
    );
    debugPrint('Equilibra: no se pudo $action: $error');
  }
}
