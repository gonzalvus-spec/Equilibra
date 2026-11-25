import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/background_keys.dart';
import '../models/app_mode.dart';
import 'app_initializer.dart';
import 'app_logger.dart';
import 'background_runtime.dart';

/// Fachada para configurar, iniciar y detener el servicio persistente.
///
/// Ningún método propaga excepciones nativas: en Android 14+/MagicOS el
/// sistema puede rechazar el servicio en primer plano con
/// `ForegroundServiceStartNotAllowedException` (expuesta en Dart como
/// [PlatformException]) y la app debe seguir operando en primer plano.
class BackgroundService {
  BackgroundService({FlutterBackgroundService? service, FirebaseAuth? auth})
    : _service = service ?? FlutterBackgroundService(),
      _authOverride = auth;

  final FlutterBackgroundService _service;
  final FirebaseAuth? _authOverride;
  FirebaseAuth? _auth;

  Stream<Map<String, dynamic>?> on(String event) {
    try {
      return _service.on(event);
    } catch (error) {
      debugPrint('Equilibra: no se pudo escuchar "$event": $error');
      return const Stream<Map<String, dynamic>?>.empty();
    }
  }

  /// Configura el servicio sin iniciarlo.
  ///
  /// Por defecto usa sólo `dataSync`, que no requiere permisos en runtime, de
  /// modo que el `startForeground` inicial nunca falle en Android 14+/MagicOS.
  /// `location` se añade únicamente cuando el usuario ya concedió el permiso.
  Future<void> configure({bool includeLocation = false}) async {
    AppLogger.info(
      LogTags.bgService,
      'Configurando servicio (ubicación: $includeLocation).',
    );
    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: backgroundOnStart,
          autoStart: false,
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: BackgroundKeys.channelId,
          initialNotificationTitle: 'Equilibra',
          initialNotificationContent: 'Preparando servicio…',
          foregroundServiceNotificationId: BackgroundKeys.serviceNotificationId,
          // Debe ser un subconjunto de android:foregroundServiceType del
          // manifiesto.
          foregroundServiceTypes: includeLocation
              ? const [
                  AndroidForegroundType.location,
                  AndroidForegroundType.dataSync,
                ]
              : const [AndroidForegroundType.dataSync],
        ),
        iosConfiguration: IosConfiguration(autoStart: false),
      );
      AppLogger.ok(LogTags.bgService, 'Servicio configurado correctamente.');
    } on PlatformException catch (error, stack) {
      AppLogger.error(
        LogTags.bgService,
        'Android rechazó configure() (${error.code}): ${error.message}',
        error,
        stack,
      );
      debugPrint(
        'Equilibra: Android rechazó configure() '
        '(${error.code}): ${error.message}',
      );
    } catch (error, stack) {
      AppLogger.error(
        LogTags.bgService,
        'No se pudo configurar el servicio: $error',
        error,
        stack,
      );
      debugPrint('Equilibra: no se pudo configurar el servicio: $error');
    }
  }

  Future<bool> _locationGranted() async {
    try {
      final permission = await Geolocator.checkPermission();
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  /// Sincroniza el modo y el usuario activos con el isolate de segundo plano.
  ///
  /// Nunca propaga excepciones: un fallo del sistema al iniciar el servicio
  /// (por ejemplo, FGS no permitido en segundo plano) no debe tumbar la app.
  Future<void> start(
    AppMode mode, {
    String? deviceAddress,
    String? terminalId,
  }) async {
    AppLogger.info(
      LogTags.bgService,
      'start(${mode.label}) solicitado; comprobando usuario y permisos.',
    );
    try {
      // Firebase debe existir antes de tocar `FirebaseAuth.instance`.
      await AppInitializer.requireFirebaseReady();
      final auth = _auth ??= _authOverride ?? FirebaseAuth.instance;
      final uid = auth.currentUser?.uid;
      if (uid == null) {
        AppLogger.warn(
          LogTags.bgService,
          'No hay usuario autenticado; no se inicia el servicio.',
        );
        return;
      }
      // Se guarda el usuario aquí (y no al abrir la app) porque sólo hace
      // falta para que el isolate pueda reanudarse si el sistema lo reinicia.
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('background_uid', uid);
        if (mode == AppMode.monitor) {
          // Una restauración del servicio en Modo Monitor nunca debe heredar
          // la dirección RFCOMM utilizada por un puente anterior.
          await preferences.remove('bluetooth_device_address');
        }
      } catch (_) {
        // Preferencias no disponibles: el servicio recibe el uid por evento.
      }
      // `start` se llama después de `AppPermissions.requestAll()`: el permiso
      // de ubicación ya está concedido, así que el tipo `location` es seguro.
      final includeLocation =
          mode == AppMode.bridge && await _locationGranted();
      await configure(includeLocation: includeLocation);
      if (!await _service.isRunning()) {
        final started = await _service.startService();
        if (!started) {
          AppLogger.warn(
            LogTags.bgService,
            'startService() devolvió false; el servicio sigue detenido.',
          );
          return;
        }
        AppLogger.ok(LogTags.bgService, 'startService() aceptado por Android.');
      } else {
        AppLogger.info(LogTags.bgService, 'El servicio ya estaba en marcha.');
      }
      _service.invoke(BackgroundKeys.configure, {
        BackgroundKeys.mode: mode.storageValue,
        BackgroundKeys.uid: uid,
        BackgroundKeys.deviceAddress: mode == AppMode.bridge
            ? deviceAddress
            : null,
        BackgroundKeys.terminalId: terminalId,
      });
      AppLogger.ok(
        LogTags.bgService,
        'Configuración enviada al isolate; arranque confirmado.',
      );
    } on PlatformException catch (error, stack) {
      AppLogger.error(
        LogTags.bgService,
        'Android restringió el servicio (ForegroundServiceStartNotAllowed / '
        '${error.code}): ${error.message}',
        error,
        stack,
      );
      debugPrint(
        'Equilibra: Android restringió el servicio '
        '(${error.code}): ${error.message}',
      );
    } catch (error, stack) {
      AppLogger.error(
        LogTags.bgService,
        'No se pudo iniciar el servicio: $error',
        error,
        stack,
      );
      debugPrint('Equilibra: no se pudo iniciar el servicio: $error');
    }
  }

  Future<void> stop() async {
    try {
      if (await _service.isRunning()) {
        _service.invoke(BackgroundKeys.stopService);
        AppLogger.info(LogTags.bgService, 'Orden de detención enviada.');
      }
    } on PlatformException catch (error) {
      debugPrint('Equilibra: no se pudo detener el servicio (${error.code})');
    } catch (error) {
      debugPrint('Equilibra: no se pudo detener el servicio: $error');
    }
  }

  /// Notifica al isolate que el Bluetooth se desconectó desde la interfaz.
  void notifyBridgeDisconnected() {
    try {
      _service.invoke(BackgroundKeys.disconnectBridge);
    } catch (error) {
      debugPrint('Equilibra: no se pudo notificar la desconexión: $error');
    }
  }
}
