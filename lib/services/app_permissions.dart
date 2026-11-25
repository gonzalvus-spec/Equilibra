import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import 'app_logger.dart';

/// Solicita los permisos necesarios en orden, antes de iniciar el servicio.
///
/// Sólo pide permisos estándar de **primer plano** (notificaciones, ubicación
/// mientras se usa la app y Bluetooth scan/connect). En Android 11+ y MagicOS
/// pedir `ACCESS_BACKGROUND_LOCATION` en el mismo lote hace que el diálogo se
/// ignore o quede colgado, así que esa variante se deja fuera del arranque.
///
/// [requestAll] nunca lanza: devuelve un [PermissionReport] para que un
/// diálogo bloqueado o un permiso denegado jamás impida entrar al módulo.
///
/// Puntos críticos de Android:
/// - `BluetoothAdapter.isEnabled()` exige `BLUETOOTH_CONNECT` desde Android 12.
///   Llamarlo antes de concederlo provoca una `SecurityException` **nativa** en
///   el hilo principal que cierra el proceso. Por eso aquí siempre se piden los
///   permisos de Bluetooth antes de consultar el adaptador.
/// - Sólo puede haber un diálogo de permisos del sistema a la vez. Las
///   peticiones concurrentes se comparten con [_inFlight] para que dos
///   llamadas simultáneas no se anulen entre sí.
class AppPermissions {
  const AppPermissions({
    this.bluetooth,
    this.deviceInfo,
    this.platform,
    this.timeout = const Duration(seconds: 60),
  });

  final FlutterClassicBluetooth? bluetooth;
  final DeviceInfoPlugin? deviceInfo;
  final TargetPlatform? platform;

  /// Límite para el lote completo. Es amplio a propósito: el usuario puede
  /// tardar en responder a los diálogos del sistema y abortar antes mostraría
  /// un error mientras el diálogo sigue abierto.
  final Duration timeout;

  static const Set<BtcPermission> _bluetoothScopes = {
    BtcPermission.scan,
    BtcPermission.connect,
  };

  /// Petición en curso compartida entre llamadas concurrentes.
  static Future<PermissionReport>? _inFlight;

  TargetPlatform get _platform => platform ?? defaultTargetPlatform;

  /// Pide notificaciones, ubicación y Bluetooth según lo que necesite [mode].
  ///
  /// El monitor remoto sólo necesita notificaciones; el puente necesita además
  /// ubicación (GPS del ESP32) y Bluetooth (RFCOMM). Pedir de más en el monitor
  /// abre diálogos innecesarios y amplía el riesgo de fallos del sistema.
  Future<PermissionReport> requestAll({
    bool notifications = true,
    bool location = true,
    bool bluetooth = true,
  }) {
    final pending = _inFlight;
    if (pending != null) {
      AppLogger.info(
        LogTags.permisos,
        'Ya hay una solicitud de permisos en curso; se reutiliza.',
      );
      return pending;
    }
    final future = _requestAll(
      notifications: notifications,
      location: location,
      bluetooth: bluetooth,
    ).whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<PermissionReport> _requestAll({
    required bool notifications,
    required bool location,
    required bool bluetooth,
  }) async {
    final failures = <String>[];

    Future<void> attempt(Future<void> Function() step) async {
      try {
        await step();
      } on PermissionFailure catch (error) {
        failures.add(error.message);
      }
    }

    try {
      await (() async {
        if (notifications) await attempt(_requestNotifications);
        if (location) await attempt(_requestLocation);
        if (bluetooth) await attempt(_requestBluetooth);
      })().timeout(timeout);
    } on TimeoutException {
      AppLogger.error(
        LogTags.permisos,
        'El sistema no respondió a los permisos en ${timeout.inSeconds} s.',
      );
      failures.add(
        'El sistema no respondió a los permisos. Puedes concederlos desde '
        'Ajustes de la app.',
      );
    } catch (error, stack) {
      AppLogger.error(
        LogTags.permisos,
        'No se pudieron verificar los permisos del sistema.',
        error,
        stack,
      );
      failures.add('No se pudieron verificar los permisos del sistema.');
    }

    if (failures.isEmpty) {
      AppLogger.ok(LogTags.permisos, 'Todos los permisos concedidos.');
      return const PermissionReport.granted();
    }
    final message = failures.first;
    AppLogger.warn(LogTags.permisos, 'Permisos incompletos: $message');
    return PermissionReport.denied(message);
  }

  Future<void> _requestNotifications() async {
    if (kIsWeb || _platform != TargetPlatform.android) return;

    int? sdkInt;
    try {
      final info = await (deviceInfo ?? DeviceInfoPlugin()).androidInfo.timeout(
        const Duration(seconds: 5),
      );
      sdkInt = info.version.sdkInt;
    } catch (error) {
      AppLogger.warn(
        LogTags.permisos,
        'No se pudo leer la versión de Android: $error',
      );
    }
    if (sdkInt != null && sdkInt < 33) {
      AppLogger.info(
        LogTags.permisos,
        'Permiso notificaciones: no requerido (Android < 13).',
      );
      return;
    }

    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      AppLogger.warn(
        LogTags.permisos,
        'Permiso notificaciones: plugin no disponible en esta plataforma.',
      );
      return;
    }
    if (await android.areNotificationsEnabled() ?? false) {
      AppLogger.ok(LogTags.permisos, 'Permiso notificaciones: concedido.');
      return;
    }
    final granted = await android.requestNotificationsPermission();
    if (granted != true) {
      AppLogger.warn(LogTags.permisos, 'Permiso notificaciones: denegado.');
      throw const PermissionFailure(
        'Concede el permiso de notificaciones para recibir las alertas.',
      );
    }
    AppLogger.ok(LogTags.permisos, 'Permiso notificaciones: concedido.');
  }

  Future<void> _requestLocation() async {
    if (kIsWeb ||
        (_platform != TargetPlatform.android &&
            _platform != TargetPlatform.iOS)) {
      return;
    }
    // `requestPermission()` solicita únicamente ubicación en primer plano
    // (`whileInUse`). Nunca se vuelve a pedir para pasar a segundo plano en
    // este lote.
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      AppLogger.warn(
        LogTags.permisos,
        'Permiso ubicación: bloqueado permanentemente.',
      );
      throw const PermissionFailure(
        'Activa el permiso de ubicación desde los ajustes de la aplicación.',
      );
    }
    if (permission == LocationPermission.denied) {
      AppLogger.warn(LogTags.permisos, 'Permiso ubicación: denegado.');
      throw const PermissionFailure(
        'Concede el permiso de ubicación para registrar las caídas.',
      );
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      AppLogger.warn(LogTags.permisos, 'Permiso ubicación: servicio apagado.');
      throw const PermissionFailure('Activa la ubicación del teléfono.');
    }
    AppLogger.ok(
      LogTags.permisos,
      'Permiso ubicación: concedido (${permission.name}).',
    );
  }

  Future<void> _requestBluetooth() async {
    if (kIsWeb || _platform != TargetPlatform.android) return;
    final api = bluetooth ?? FlutterClassicBluetooth();

    // 1) Permisos ANTES de tocar el adaptador. En Android 12+ `isEnabled()`
    //    lanza SecurityException nativa sin BLUETOOTH_CONNECT y esa excepción
    //    en el hilo principal cierra la app.
    var status = await api.checkPermissions(permissions: _bluetoothScopes);
    if (status == BtcPermissionStatus.denied) {
      status = await api.requestPermissions(permissions: _bluetoothScopes);
    }
    if (status == BtcPermissionStatus.permanentlyDenied) {
      AppLogger.warn(
        LogTags.permisos,
        'Permiso Bluetooth: bloqueado permanentemente.',
      );
      throw const PermissionFailure(
        'Activa los permisos de Bluetooth desde los ajustes de la aplicación.',
      );
    }
    if (status != BtcPermissionStatus.granted &&
        status != BtcPermissionStatus.notRequired) {
      AppLogger.warn(LogTags.permisos, 'Permiso Bluetooth: denegado.');
      throw const PermissionFailure(
        'Concede los permisos de Bluetooth para buscar y conectar el ESP32.',
      );
    }

    // 2) Con los permisos ya concedidos, consultar el adaptador es seguro.
    if (!await api.isSupported()) {
      AppLogger.warn(LogTags.permisos, 'Bluetooth clásico: no soportado.');
      throw const PermissionFailure(
        'Este teléfono no admite Bluetooth clásico.',
      );
    }
    if (!await api.isEnabled()) {
      AppLogger.warn(LogTags.permisos, 'Bluetooth clásico: adaptador apagado.');
      throw const PermissionFailure('Activa Bluetooth para continuar.');
    }
    AppLogger.ok(
      LogTags.permisos,
      'Permisos Bluetooth concedidos y adaptador disponible.',
    );
  }
}

/// Resultado de [AppPermissions.requestAll].
class PermissionReport {
  const PermissionReport.granted() : granted = true, message = null;

  const PermissionReport.denied(this.message) : granted = false;

  final bool granted;
  final String? message;
}

class PermissionFailure implements Exception {
  const PermissionFailure(this.message);

  final String message;
}
