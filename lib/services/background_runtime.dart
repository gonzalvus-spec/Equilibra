import 'dart:async';
import 'dart:ui';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_constants.dart';
import '../core/background_keys.dart';
import '../models/app_mode.dart';
import '../models/device_info.dart';
import '../models/geo_point.dart';
import '../models/log_entry.dart';
import '../models/remote_device_state.dart';
import 'app_initializer.dart';
import 'app_logger.dart';
import 'bluetooth_failure.dart';
import 'bluetooth_service.dart';
import 'notification_service.dart';

int _runtimeGeneration = 0;
_BackgroundWorker? _isolateWorker;
final List<StreamSubscription<dynamic>> _runtimeSubscriptions = [];

/// Reenvía un registro al isolate principal, que es dueño del historial visible.
void _log(
  ServiceInstance service,
  LogLevel level,
  String tag,
  String message, [
  Object? error,
]) {
  try {
    service.invoke(BackgroundKeys.log, {
      BackgroundKeys.logLevel: level.label,
      BackgroundKeys.logTag: tag,
      BackgroundKeys.logMessage: message,
      BackgroundKeys.logError: error?.toString(),
    });
  } catch (_) {
    // Registrar nunca debe interrumpir el servicio en segundo plano.
  }
}

/// Punto de entrada del isolate del servicio en primer plano.
@pragma('vm:entry-point')
Future<void> backgroundOnStart(ServiceInstance service) async {
  final generation = ++_runtimeGeneration;
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  final previousSubscriptions = List.of(_runtimeSubscriptions);
  _runtimeSubscriptions.clear();
  for (final subscription in previousSubscriptions) {
    await subscription.cancel();
  }
  await _isolateWorker?.stop();
  if (generation != _runtimeGeneration) return;

  final notifications = NotificationService();
  var activeWorker = _BackgroundWorker(
    service: service,
    notifications: notifications,
  );
  _isolateWorker = activeWorker;
  var explicitConfigurationReceived = false;
  var lastConfiguration = '';
  var configurationQueue = Future<void>.value();

  void scheduleConfiguration(Map<String, dynamic>? args) {
    if (args == null || generation != _runtimeGeneration) return;
    final signature =
        '${args[BackgroundKeys.mode]}|${args[BackgroundKeys.uid]}|'
        '${args[BackgroundKeys.deviceAddress]}|${args[BackgroundKeys.terminalId]}';
    configurationQueue = configurationQueue
        .then((_) async {
          if (generation != _runtimeGeneration ||
              signature == lastConfiguration) {
            return;
          }
          await activeWorker.stop();
          if (generation != _runtimeGeneration) return;
          activeWorker = _BackgroundWorker(
            service: service,
            notifications: notifications,
          );
          _isolateWorker = activeWorker;
          lastConfiguration = signature;
          await activeWorker.start(args);
        })
        .catchError((Object error) {
          _log(
            service,
            LogLevel.error,
            LogTags.bgService,
            'No se pudo aplicar la configuración del worker.',
            error,
          );
        });
  }

  // Los listeners se registran antes de cualquier `await`: si Firebase o el
  // plugin de notificaciones tarda, el servicio ya puede atender la orden de
  // detenerse o de reconfigurarse en lugar de perderla.
  _runtimeSubscriptions.add(
    service.on(BackgroundKeys.stopService).listen((_) async {
      try {
        await activeWorker.stop();
      } catch (error) {
        _log(
          service,
          LogLevel.warn,
          LogTags.bgService,
          'Fallo al detener el worker.',
          error,
        );
      } finally {
        await service.stopSelf();
      }
    }),
  );
  _runtimeSubscriptions.add(
    service.on(BackgroundKeys.disconnectBridge).listen((_) {
      unawaited(activeWorker.disconnectBridge());
    }),
  );

  _runtimeSubscriptions.add(
    service.on(BackgroundKeys.configure).listen((args) {
      explicitConfigurationReceived = true;
      try {
        scheduleConfiguration(args);
      } catch (error) {
        // Una configuración defectuosa nunca debe tumbar el isolate.
        _log(
          service,
          LogLevel.error,
          LogTags.bgService,
          'No se pudo reconfigurar el worker del servicio.',
          error,
        );
      }
    }),
  );

  if (service is AndroidServiceInstance) {
    _runtimeSubscriptions.add(
      service
          .on('setAsForeground')
          .listen((_) => service.setAsForegroundService()),
    );
    _runtimeSubscriptions.add(
      service
          .on('setAsBackground')
          .listen((_) => service.setAsBackgroundService()),
    );
  }

  _log(
    service,
    LogLevel.ok,
    LogTags.bgService,
    'Isolate del servicio iniciado.',
  );

  try {
    await AppInitializer.ensureFirebaseReady();
    await notifications.initialize();
  } catch (error) {
    _log(
      service,
      LogLevel.warn,
      LogTags.bgService,
      'Inicialización parcial del servicio (Firebase/notificaciones).',
      error,
    );
  }

  SharedPreferences? preferences;
  try {
    preferences = await SharedPreferences.getInstance();
    await preferences.reload();
  } catch (error) {
    _log(
      service,
      LogLevel.warn,
      LogTags.bgService,
      'No se pudieron leer las preferencias del servicio.',
      error,
    );
  }

  final savedMode = AppMode.fromStorage(preferences?.getString('app_mode'));
  final uid = preferences?.getString('background_uid');
  if (savedMode == null || uid == null || explicitConfigurationReceived) return;

  try {
    scheduleConfiguration({
      BackgroundKeys.mode: savedMode.storageValue,
      BackgroundKeys.uid: uid,
      BackgroundKeys.deviceAddress: savedMode == AppMode.bridge
          ? preferences?.getString('bluetooth_device_address')
          : null,
      BackgroundKeys.terminalId: preferences?.getString('terminal_id'),
    });
    await configurationQueue;
  } catch (error) {
    _log(
      service,
      LogLevel.error,
      LogTags.bgService,
      'No se pudo reanudar el worker tras reiniciar el servicio.',
      error,
    );
  }
}

class _BackgroundWorker {
  _BackgroundWorker({required this.service, required this.notifications});

  final ServiceInstance service;
  final NotificationService notifications;

  BluetoothService? _bluetooth;
  DatabaseReference? _device;
  DatabaseReference? _terminal;
  StreamSubscription<String>? _lines;
  StreamSubscription<RemoteDeviceState>? _states;
  StreamSubscription<Object?>? _offRequests;
  Timer? _heartbeat;
  Timer? _terminalHeartbeat;
  Timer? _reconnect;
  AppMode? _mode;
  String? _address;
  bool _alarmEmitted = false;
  bool _connecting = false;
  bool _stopped = false;
  bool _started = false;
  bool _handlingOffRequest = false;
  bool _offRequestPending = false;
  bool? _lastAlarmState;
  DateTime? _ignoreActivatedUntil;

  Future<void> start(Map<String, dynamic>? args) async {
    if (args == null || _started) return;
    final mode = AppMode.fromStorage(args[BackgroundKeys.mode] as String?);
    final uid = args[BackgroundKeys.uid] as String?;
    if (mode == null || uid == null) return;

    _started = true;
    _mode = mode;
    _address = mode == AppMode.bridge
        ? args[BackgroundKeys.deviceAddress] as String?
        : null;
    _stopped = false;
    _log(
      service,
      LogLevel.info,
      LogTags.bgService,
      'Worker iniciado en modo ${mode.label}; dirección ${_address ?? 'sin guardar'}.',
    );

    await AppInitializer.requireFirebaseReady();
    _device = FirebaseDatabase.instance.ref(
      'usuarios/$uid/${AppConstants.firebaseDevicePath}',
    );
    await _device!.keepSynced(true);
    final terminalId =
        args[BackgroundKeys.terminalId] as String? ??
        (await SharedPreferences.getInstance()).getString('terminal_id');
    if (terminalId != null) {
      _terminal = FirebaseDatabase.instance.ref(
        'usuarios/$uid/terminales/$terminalId',
      );
      await _terminal!.onDisconnect().update({
        'online': false,
        'sesion_activa': false,
        'last_seen': ServerValue.timestamp,
        'ultimo_latido': ServerValue.timestamp,
      });
      await _sendTerminalHeartbeat();
      _terminalHeartbeat = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_sendTerminalHeartbeat()),
      );
    }

    await notifications.ensurePermission();
    final title = mode == AppMode.bridge
        ? 'Equilibra Puente activo'
        : 'Equilibra Monitor activo';
    final message = mode == AppMode.bridge
        ? 'Monitoreando equipo'
        : 'Supervisando alarmas remotas';
    await notifications.showServiceNotification(title: title, message: message);
    _log(
      service,
      LogLevel.ok,
      LogTags.bgService,
      'Notificación del servicio en primer plano publicada.',
    );

    if (mode == AppMode.bridge) {
      await _startBridge();
    } else {
      await _startMonitor();
    }
  }

  Future<void> _startBridge() async {
    await _lines?.cancel();
    await _offRequests?.cancel();
    _heartbeat?.cancel();
    _reconnect?.cancel();
    final bluetooth = BluetoothService();
    _bluetooth = bluetooth;
    _lines = bluetooth.lines.listen(_handleLine);
    _offRequests = _device
        ?.child('comandos/off_request')
        .onValue
        .map((event) => event.snapshot.value)
        .distinct()
        .listen((value) {
          _offRequestPending = value == true;
          if (_offRequestPending) unawaited(_handleOffRequest());
        });
    // La estación queda visible de inmediato. Ni la conexión RFCOMM ni el GPS
    // forman parte del camino crítico de presencia remota.
    unawaited(_publishBridgePresence());
    unawaited(
      _device
              ?.child('estado/puente_en_linea')
              .onDisconnect()
              .set(false)
              .catchError((_) {}) ??
          Future<void>.value(),
    );
    unawaited(_connectBridge());
    unawaited(_refreshBridgeLocation());
    _heartbeat = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_sendHeartbeat()),
    );
    _reconnect = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_connectBridge()),
    );
  }

  Future<void> _sendTerminalHeartbeat() async {
    final terminal = _terminal;
    if (terminal == null || _stopped) return;
    try {
      await terminal.update({
        'online': true,
        'sesion_activa': true,
        'last_seen': ServerValue.timestamp,
        'ultimo_latido': ServerValue.timestamp,
      });
    } catch (_) {
      // El siguiente ciclo reintentará la presencia.
    }
  }

  Future<void> _connectBridge() async {
    final bluetooth = _bluetooth;
    if (bluetooth == null || _stopped || _connecting) return;
    _connecting = true;
    try {
      var saved = _address?.trim();
      if (saved == null || saved.isEmpty) {
        saved = (await SharedPreferences.getInstance())
            .getString('bluetooth_device_address')
            ?.trim();
      }
      if (saved == null || saved.isEmpty || _stopped) return;
      _address = saved;
      _log(
        service,
        LogLevel.info,
        LogTags.bgService,
        'Reconectando el puente Bluetooth desde segundo plano…',
      );
      await bluetooth.prepare();
      final paired = await bluetooth.pairedDevices();
      final device =
          paired.where((item) => item.address == saved).firstOrNull ??
          DeviceInfo(name: '', address: saved, isPaired: true);
      try {
        await bluetooth.connect(device);
        if (_offRequestPending) unawaited(_handleOffRequest());
        _log(
          service,
          LogLevel.ok,
          LogTags.bgService,
          'Puente Bluetooth conectado en segundo plano (${device.address}).',
        );
      } on BluetoothFailure catch (error) {
        // El socket puede estar ocupado durante el traspaso entre isolates.
        _log(
          service,
          LogLevel.warn,
          LogTags.bgService,
          'Socket ocupado al traspasar el puente al isolate.',
          error,
        );
      }
    } catch (error) {
      // Se reintentará en el siguiente ciclo.
      _log(
        service,
        LogLevel.warn,
        LogTags.bgService,
        'Fallo al conectar en segundo plano; se reintentará.',
        error,
      );
    } finally {
      _connecting = false;
    }
  }

  Future<void> _sendHeartbeat() async {
    if (_device == null || _stopped) return;
    await _publishBridgePresence();
    if (_stopped) return;
    await _refreshBridgeLocation();
  }

  Future<void> _publishBridgePresence() async {
    final device = _device;
    if (device == null || _stopped) return;
    try {
      await device.update({
        'estado/puente_en_linea': true,
        'estado/ultimo_latido': ServerValue.timestamp,
      });
      _log(
        service,
        LogLevel.info,
        LogTags.firebase,
        'Presencia inmediata del puente publicada por el servicio.',
      );
      service.invoke(BackgroundKeys.state, {'active': _alarmEmitted});
    } catch (error) {
      // Sin conexión de red el servicio sigue activo.
      _log(
        service,
        LogLevel.warn,
        LogTags.firebase,
        'No se pudo publicar el latido del servicio.',
        error,
      );
    }
  }

  Future<void> _refreshBridgeLocation() async {
    final device = _device;
    if (device == null || _stopped) return;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (_stopped) return;
      final point = GeoPoint(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      await device.child('ubicacion').set(point.toJson());
      _log(
        service,
        LogLevel.info,
        LogTags.firebase,
        'Ubicación del puente actualizada por el servicio.',
      );
    } catch (error) {
      // La ubicación es secundaria y nunca invalida la presencia publicada.
      _log(
        service,
        LogLevel.warn,
        LogTags.firebase,
        'No se pudo actualizar la ubicación del servicio.',
        error,
      );
    }
  }

  Future<void> _handleLine(String rawLine) async {
    if (rawLine.trim().toUpperCase() != 'ACTIVADA') return;
    final ignoreUntil = _ignoreActivatedUntil;
    if (ignoreUntil != null && DateTime.now().isBefore(ignoreUntil)) {
      _log(
        service,
        LogLevel.info,
        LogTags.bgService,
        'Trama ACTIVADA residual ignorada durante el cooldown de OFF.',
      );
      return;
    }
    _log(
      service,
      LogLevel.warn,
      LogTags.bgService,
      'Trama ACTIVADA recibida por el servicio en primer plano.',
    );
    service.invoke(BackgroundKeys.line, {'line': 'ACTIVADA'});
    if (_alarmEmitted) return;
    _alarmEmitted = true;
    await _device?.child('estado/alarma_activa').set(true);
    await notifications.showFallAlert(
      title: '¡Alarma activada!',
      message: 'Se detectó una caída o impacto.',
    );
    service.invoke(BackgroundKeys.alarm, {'alarm': true});
  }

  Future<void> _startMonitor() async {
    final device = _device;
    if (device == null) return;
    await _states?.cancel();
    RemoteDeviceState? previous;
    _states = device.onValue
        .map((event) => RemoteDeviceState.fromJson(event.snapshot.value))
        .listen(
          (state) {
            if (previous != null && _sameRemoteState(previous!, state)) return;
            previous = state;
            if (_lastAlarmState != state.alarmActive) {
              _lastAlarmState = state.alarmActive;
              _log(
                service,
                state.alarmActive ? LogLevel.warn : LogLevel.info,
                LogTags.firebase,
                'Cambio de alarma remota leído por el servicio: '
                '${state.alarmActive}.',
              );
            }
            service.invoke(BackgroundKeys.state, {
              'active': state.alarmActive,
              'bridge_online': state.bridgeOnline,
              'last_heartbeat': state.lastHeartbeat?.millisecondsSinceEpoch,
              'latitude': state.location?.latitude,
              'longitude': state.location?.longitude,
            });
            if (state.alarmActive && !_alarmEmitted) {
              _alarmEmitted = true;
              unawaited(
                notifications.showFallAlert(
                  title: '¡Alarma activada!',
                  message: 'Se detectó una caída o impacto.',
                ),
              );
              service.invoke(BackgroundKeys.alarm, {'alarm': true});
            } else if (!state.alarmActive) {
              _alarmEmitted = false;
              unawaited(notifications.cancelFallAlert());
            }
          },
          onError: (Object error) {
            _log(
              service,
              LogLevel.error,
              LogTags.firebase,
              'Error en el listener remoto del servicio.',
              error,
            );
            service.invoke(BackgroundKeys.error, {'message': error.toString()});
          },
        );
  }

  Future<void> _handleOffRequest() async {
    if (_mode != AppMode.bridge ||
        _handlingOffRequest ||
        _stopped ||
        _bluetooth == null) {
      return;
    }
    _handlingOffRequest = true;
    try {
      await _bluetooth!.sendCommand(AppConstants.bluetoothOffCommand);
      _ignoreActivatedUntil = DateTime.now().add(const Duration(seconds: 2));
      await _device?.update({
        'estado/alarma_activa': false,
        'comandos/off_request': null,
      });
      _alarmEmitted = false;
      _offRequestPending = false;
      await notifications.cancelFallAlert();
      _log(
        service,
        LogLevel.ok,
        LogTags.firebase,
        'OFF confirmado y alarma/off_request actualizados atómicamente.',
      );
    } catch (error) {
      // Si este isolate no es dueño del socket, la UI procesará la misma orden.
      // La petición queda pendiente para un reintento posterior.
      _log(
        service,
        LogLevel.warn,
        LogTags.bluetooth,
        'El worker no pudo procesar todavía la orden OFF.',
        error,
      );
    } finally {
      _handlingOffRequest = false;
    }
  }

  Future<void> disconnectBridge() async {
    if (_mode != AppMode.bridge) return;
    _log(
      service,
      LogLevel.info,
      LogTags.bgService,
      'Desconectando el puente por orden de la interfaz…',
    );
    final bluetooth = _bluetooth;
    _bluetooth = null;
    if (bluetooth == null) return;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    await _lines?.cancel();
    await _offRequests?.cancel();
    try {
      await bluetooth.disconnect();
    } catch (_) {
      // El socket ya puede estar cerrado.
    }
    await bluetooth.dispose();
    final device = _device;
    try {
      await device?.child('estado/puente_en_linea').set(false);
    } catch (_) {
      // El cierre no depende de la red.
    }
  }

  Future<void> stop() async {
    if (!_started) {
      _stopped = true;
      return;
    }
    _stopped = true;
    _log(service, LogLevel.info, LogTags.bgService, 'Deteniendo el worker.');
    _heartbeat?.cancel();
    _terminalHeartbeat?.cancel();
    _reconnect?.cancel();
    await _lines?.cancel();
    await _states?.cancel();
    await _offRequests?.cancel();
    _lines = null;
    _states = null;
    _offRequests = null;
    _heartbeat = null;
    _terminalHeartbeat = null;
    _reconnect = null;
    final bluetooth = _bluetooth;
    _bluetooth = null;
    if (bluetooth != null) {
      try {
        await bluetooth.disconnect();
      } catch (_) {
        // El adaptador pudo apagarse durante el cierre.
      }
      await bluetooth.dispose();
    }
    try {
      await _terminal?.onDisconnect().cancel();
      if (_mode == AppMode.bridge) {
        await _device?.child('estado/puente_en_linea').onDisconnect().cancel();
        await _device?.child('estado/puente_en_linea').set(false);
      }
    } catch (_) {
      // La desconexión configurada cubrirá un cierre sin red.
    }
    _device = null;
    _terminal = null;
    _address = null;
    _mode = null;
    _lastAlarmState = null;
    _started = false;
  }
}

bool _sameRemoteState(RemoteDeviceState previous, RemoteDeviceState next) =>
    previous.alarmActive == next.alarmActive &&
    previous.bridgeOnline == next.bridgeOnline &&
    previous.lastHeartbeat == next.lastHeartbeat &&
    previous.location?.latitude == next.location?.latitude &&
    previous.location?.longitude == next.location?.longitude;
