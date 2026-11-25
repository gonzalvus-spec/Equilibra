import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_constants.dart';
import '../models/alarm_status.dart';
import '../models/bluetooth_status.dart';
import '../models/device_info.dart';
import '../models/equilibra_event.dart';
import '../models/geo_point.dart';
import '../models/operation_result.dart';
import '../services/app_initializer.dart';
import '../services/app_logger.dart';
import '../services/bluetooth_failure.dart';
import '../services/bluetooth_preferences.dart';
import '../services/bluetooth_service.dart';
import '../services/firebase_service.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';

class BridgeController extends ChangeNotifier {
  BridgeController({
    required FirebaseService firebaseService,
    required NotificationService notificationService,
    BluetoothService? bluetoothService,
    BluetoothPreferences? bluetoothPreferences,
    LocationService? locationService,
  }) : _firebase = firebaseService,
       _notifications = notificationService,
       _bluetooth = bluetoothService ?? BluetoothService(),
       _bluetoothPreferences = bluetoothPreferences ?? BluetoothPreferences(),
       _location = locationService ?? LocationService() {
    _lineSubscription = _bluetooth.lines.listen(_handleLine);
    _connectionSubscription = _bluetooth.connectionStates.listen(
      _handleConnection,
    );
    _listenToDiscovery();
  }

  final FirebaseService _firebase;
  final NotificationService _notifications;
  final BluetoothService _bluetooth;
  final BluetoothPreferences _bluetoothPreferences;
  final LocationService _location;
  final StreamController<EquilibraEvent> _events =
      StreamController<EquilibraEvent>.broadcast();
  final Set<String> _discoveredAddresses = <String>{};

  late final StreamSubscription<String> _lineSubscription;
  late final StreamSubscription<BluetoothStatus> _connectionSubscription;
  late final StreamSubscription<DeviceInfo> _discoverySubscription;
  late final StreamSubscription<bool> _discoveryStateSubscription;
  StreamSubscription<Object?>? _offRequestSubscription;
  DateTime? _ignoreActivatedUntil;
  bool _handlingOffRequest = false;
  bool _initialized = false;
  bool _offRequestPending = false;

  AlarmStatus _alarmStatus = AlarmStatus.deactivated;
  BluetoothStatus _bluetoothStatus = BluetoothStatus.disconnected;
  DeviceInfo? _device;
  List<DeviceInfo> _devices = const [];
  GeoPoint? _locationPoint;
  bool _busy = false;
  bool _scanning = false;
  bool _disposed = false;

  AlarmStatus get alarmStatus => _alarmStatus;
  BluetoothStatus get bluetoothStatus => _bluetoothStatus;
  DeviceInfo? get device => _device;
  List<DeviceInfo> get devices => _devices;
  List<DeviceInfo> get pairedDevices =>
      _devices.where((device) => device.isPaired).toList(growable: false);
  List<DeviceInfo> get foundDevices =>
      _devices.where((device) => !device.isPaired).toList(growable: false);
  GeoPoint? get locationPoint => _locationPoint;
  bool get isBusy => _busy;
  bool get isScanning => _scanning;
  bool get isConnected => _bluetoothStatus.isConnected;
  Stream<EquilibraEvent> get events => _events.stream;

  Future<bool> isBluetoothEnabled() async {
    try {
      return await _bluetooth.isEnabled();
    } on BluetoothFailure catch (error) {
      AppLogger.error(
        LogTags.bluetooth,
        'No se pudo consultar el adaptador: ${error.message}',
      );
      return false;
    }
  }

  Future<OperationResult> enableBluetooth() async {
    AppLogger.info(LogTags.bluetooth, 'Solicitando encender Bluetooth…');
    try {
      final enabled = await _bluetooth.enable();
      if (!enabled) {
        return const OperationResult.failure('El Bluetooth sigue apagado.');
      }
      AppLogger.ok(LogTags.bluetooth, 'Bluetooth encendido por el usuario.');
      return const OperationResult.success('Bluetooth encendido.');
    } on BluetoothFailure catch (error) {
      AppLogger.error(
        LogTags.bluetooth,
        'No se pudo encender Bluetooth: ${error.message}',
      );
      return OperationResult.failure(error.message);
    }
  }

  /// Refleja una alarma detectada por el isolate del servicio.
  void markAlarmActivated() {
    if (_alarmStatus.isActivated) return;
    _alarmStatus = AlarmStatus.activated;
    _notify();
  }

  void _listenToDiscovery() {
    _discoverySubscription = _bluetooth.discoveryResults.listen((device) {
      _discoveredAddresses.add(device.address);
      AppLogger.info(
        LogTags.bluetooth,
        'Dispositivo encontrado: ${device.displayName} (${device.address})'
        '${device.isPaired ? ' · emparejado' : ''}.',
      );
      _mergeDevice(device);
      _sortDevices();
      _notify();
    });
    _discoveryStateSubscription = _bluetooth.discoveryStates.listen((value) {
      _scanning = value;
      AppLogger.info(
        LogTags.bluetooth,
        value ? 'Escaneo Bluetooth iniciado.' : 'Escaneo Bluetooth finalizado.',
      );
      _notify();
    });
  }

  Future<OperationResult> initialize() async {
    if (_initialized) return const OperationResult.success('Módulo listo.');
    _initialized = true;
    AppLogger.info(LogTags.bluetooth, 'Inicializando el módulo Bluetooth…');
    await AppInitializer.ensureFirebaseReady();
    await _firebase.keepDeviceSynced();
    await _offRequestSubscription?.cancel();
    _offRequestSubscription = _firebase.watchOffRequests().listen(
      (value) {
        _offRequestPending = value == true;
        if (_offRequestPending) unawaited(_handleRemoteOffRequest());
      },
      onError: (Object error) => AppLogger.warn(
        LogTags.firebase,
        'Fallo en el listener de comandos/off_request: $error',
      ),
    );
    // Sólo se crean los canales: el permiso de notificaciones lo gestiona
    // `EquilibraApp` una única vez. Pedirlo aquí abría un segundo diálogo en
    // paralelo al lote de permisos del sistema y Android descartaba uno de los
    // dos (con el riesgo nativo que eso implica).
    try {
      await _notifications.initialize();
    } catch (error) {
      AppLogger.warn(
        LogTags.notificaciones,
        'No se pudieron preparar los canales de notificación: $error',
      );
    }
    final savedAddress = await _bluetoothPreferences.loadAddress();
    AppLogger.info(
      LogTags.bluetooth,
      'Última dirección guardada: ${savedAddress ?? 'ninguna'}.',
    );
    return refreshDevices(preferredAddress: savedAddress);
  }

  Future<OperationResult> refreshDevices({String? preferredAddress}) async {
    if (_busy) return const OperationResult.failure('Espera un momento.');
    _setBusy(true);
    try {
      await _bluetooth.prepare();
      final paired = await _bluetooth.pairedDevices();
      for (final device in paired) {
        _mergeDevice(device);
      }
      _sortDevices();
      final address = preferredAddress ?? _device?.address;
      _device =
          _findDevice(address) ??
          _findRecommended() ??
          (_devices.isEmpty ? null : _devices.first);
      _notify();
      AppLogger.info(
        LogTags.bluetooth,
        'Equipos emparejados: ${paired.length}; seleccionado: '
        '${_device?.address ?? 'ninguno'}.',
      );
      if (_device == null) {
        return const OperationResult.failure(
          'No hay equipos guardados. Inicia una búsqueda.',
        );
      }
      return OperationResult.success(
        'Se encontraron ${paired.length} equipos emparejados.',
      );
    } on BluetoothFailure catch (error) {
      AppLogger.error(
        LogTags.bluetooth,
        'Fallo al listar equipos: ${error.message}',
      );
      return OperationResult.failure(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<OperationResult> startDiscovery() async {
    AppLogger.info(LogTags.bluetooth, 'Iniciando escaneo de dispositivos…');
    try {
      await _bluetooth.startDiscovery();
      _scanning = true;
      _notify();
      final paired = await _bluetooth.pairedDevices();
      for (final device in paired) {
        _mergeDevice(device);
      }
      _sortDevices();
      _notify();
      AppLogger.ok(LogTags.bluetooth, 'Escaneo en curso.');
      return const OperationResult.success('Buscando equipos cercanos…');
    } on BluetoothFailure catch (error) {
      _scanning = false;
      _notify();
      AppLogger.error(
        LogTags.bluetooth,
        'No se pudo iniciar el escaneo: ${error.message}',
      );
      return OperationResult.failure(error.message);
    }
  }

  Future<OperationResult> stopDiscovery() async {
    try {
      await _bluetooth.stopDiscovery();
      _scanning = false;
      _notify();
      AppLogger.info(LogTags.bluetooth, 'Escaneo detenido.');
      return const OperationResult.success('Búsqueda detenida.');
    } on BluetoothFailure catch (error) {
      AppLogger.error(
        LogTags.bluetooth,
        'No se pudo detener el escaneo: ${error.message}',
      );
      return OperationResult.failure(error.message);
    }
  }

  Future<OperationResult> connect() async {
    var selected = _device;
    if (selected == null) {
      final result = await refreshDevices();
      if (!result.success) return result;
      selected = _device;
    }
    if (selected == null) {
      return const OperationResult.failure('Selecciona un dispositivo.');
    }
    return connectTo(selected);
  }

  Future<OperationResult> connectTo(DeviceInfo device) async {
    AppLogger.info(
      LogTags.bluetooth,
      'Intentando conexión SPP/RFCOMM con ${device.displayName} '
      '(${device.address})…',
    );
    if (isConnected) await disconnect();
    _setBusy(true);
    try {
      if (_scanning) await _bluetooth.stopDiscovery();
      var selected = device;
      if (!selected.isPaired) {
        AppLogger.info(
          LogTags.bluetooth,
          'Emparejando ${device.address} antes de conectar…',
        );
        await _bluetooth.pair(selected);
        AppLogger.ok(
          LogTags.bluetooth,
          'Emparejamiento listo: ${device.address}.',
        );
        selected = DeviceInfo(
          name: selected.name,
          address: selected.address,
          isPaired: true,
          rssi: selected.rssi,
        );
      }
      await _bluetooth.connect(selected);
      _device = selected;
      _mergeDevice(selected);
      _sortDevices();
      await _bluetoothPreferences.saveAddress(selected.address);
      _notify();
      AppLogger.ok(
        LogTags.bluetooth,
        'Conectado por RFCOMM a ${selected.address}.',
      );
      return OperationResult.success('Puente conectado.');
    } on BluetoothFailure catch (error) {
      AppLogger.error(
        LogTags.bluetooth,
        'Fallo de conexión con ${device.address}: ${error.message}',
      );
      return OperationResult.failure(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> selectDevice(DeviceInfo device) async {
    if (isConnected) await disconnect();
    _device = device;
    await _bluetoothPreferences.saveAddress(device.address);
    _notify();
  }

  DeviceInfo? _findDevice(String? address) {
    if (address == null) return null;
    for (final device in _devices) {
      if (device.address == address) return device;
    }
    return null;
  }

  DeviceInfo? _findRecommended() {
    for (final device in _devices) {
      if (device.name.trim().toLowerCase() ==
          AppConstants.bluetoothName.toLowerCase()) {
        return device;
      }
    }
    return null;
  }

  void _mergeDevice(DeviceInfo next) {
    final devices = [..._devices];
    final index = devices.indexWhere((item) => item.address == next.address);
    if (index < 0) {
      devices.add(next);
    } else {
      devices[index] = devices[index].merge(next);
      if (_device?.address == next.address) _device = devices[index];
    }
    _devices = devices;
  }

  void _sortDevices() {
    final devices = [..._devices];
    devices.sort((a, b) {
      final aRecommended =
          a.name.trim().toLowerCase() ==
          AppConstants.bluetoothName.toLowerCase();
      final bRecommended =
          b.name.trim().toLowerCase() ==
          AppConstants.bluetoothName.toLowerCase();
      if (aRecommended != bRecommended) return aRecommended ? -1 : 1;
      if (a.isPaired != b.isPaired) return a.isPaired ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    _devices = List.unmodifiable(devices);
  }

  Future<OperationResult> disconnect() async {
    _setBusy(true);
    try {
      await _bluetooth.disconnect();
      AppLogger.ok(LogTags.bluetooth, 'Puente Bluetooth desconectado.');
      return const OperationResult.success('Puente desconectado.');
    } on BluetoothFailure catch (error) {
      AppLogger.error(
        LogTags.bluetooth,
        'Fallo al desconectar: ${error.message}',
      );
      return OperationResult.failure(error.message);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> prepareForSignOut() async {
    if (_scanning) {
      try {
        await _bluetooth.stopDiscovery();
      } catch (_) {
        // El cierre continúa si el adaptador dejó de responder.
      }
    }
    if (isConnected) await disconnect();
  }

  Future<OperationResult> deactivateAlarm() async {
    if (!isConnected) {
      return const OperationResult.failure('Conecta el dispositivo primero.');
    }
    try {
      AppLogger.warn(
        LogTags.bluetooth,
        'Enviando orden ${AppConstants.bluetoothOffCommand} al ESP32…',
      );
      await _bluetooth.sendCommand(AppConstants.bluetoothOffCommand);
      AppLogger.ok(
        LogTags.bluetooth,
        'Orden ${AppConstants.bluetoothOffCommand} enviada al ESP32.',
      );
      return const OperationResult.success('Orden enviada.');
    } on BluetoothFailure catch (error) {
      AppLogger.error(
        LogTags.bluetooth,
        'No se pudo enviar ${AppConstants.bluetoothOffCommand}: ${error.message}',
      );
      return OperationResult.failure(error.message);
    }
  }

  Future<void> _handleLine(String rawLine) async {
    final line = rawLine.trim().toUpperCase();
    if (line == 'ACTIVADA') {
      final ignoreUntil = _ignoreActivatedUntil;
      if (ignoreUntil != null && DateTime.now().isBefore(ignoreUntil)) {
        AppLogger.info(
          LogTags.bluetooth,
          'Trama ACTIVADA residual ignorada durante el cooldown de OFF.',
        );
        return;
      }
      AppLogger.warn(LogTags.bluetooth, 'Trama recibida del ESP32: ACTIVADA.');
      _alarmStatus = AlarmStatus.activated;
      _notify();
      const event = EquilibraEvent(
        type: EquilibraEventType.alarmActivated,
        title: '¡Alarma activada!',
        message: 'Se detectó una caída o impacto.',
      );
      _events.add(event);
      unawaited(
        _notifications.showFallAlert(
          title: event.title,
          message: event.message,
        ),
      );
      final point = await _readLocation();
      try {
        await _firebase.reportAlarm(point);
        AppLogger.ok(
          LogTags.firebase,
          'Alarma y ubicación publicadas en Firebase Realtime Database.',
        );
      } catch (error, stack) {
        AppLogger.error(
          LogTags.firebase,
          'No se pudo publicar la alarma en Firebase.',
          error,
          stack,
        );
      }
      return;
    }
    if (line != 'DESACTIVADA') {
      AppLogger.info(LogTags.bluetooth, 'Trama ignorada: $line');
      return;
    }
    AppLogger.ok(LogTags.bluetooth, 'Trama recibida del ESP32: DESACTIVADA.');
    _alarmStatus = AlarmStatus.deactivated;
    _notify();
    unawaited(_notifications.cancelFallAlert());
    try {
      await _firebase.reportDeactivated(
        remote: false,
        location: _locationPoint,
      );
      AppLogger.ok(LogTags.firebase, 'Desactivación publicada en Firebase.');
    } catch (error, stack) {
      AppLogger.error(
        LogTags.firebase,
        'No se pudo publicar la desactivación; se sincronizará en el latido.',
        error,
        stack,
      );
    }
  }

  void _handleConnection(BluetoothStatus status) {
    if (_bluetoothStatus == status) return;
    _bluetoothStatus = status;
    AppLogger.info(
      LogTags.bluetooth,
      'Estado de conexión Bluetooth: ${status.label}.',
    );
    _notify();
    if (status.isConnected) {
      if (_offRequestPending) unawaited(_handleRemoteOffRequest());
    }
  }

  Future<void> _handleRemoteOffRequest() async {
    if (_handlingOffRequest || _disposed || !isConnected) return;
    _handlingOffRequest = true;
    try {
      AppLogger.warn(
        LogTags.bluetooth,
        'Orden remota recibida; enviando OFF al ESP32…',
      );
      await _bluetooth.sendCommand(AppConstants.bluetoothOffCommand);
      _ignoreActivatedUntil = DateTime.now().add(const Duration(seconds: 2));
      await _firebase.completeRemoteOff(_locationPoint);
      _offRequestPending = false;
      _alarmStatus = AlarmStatus.deactivated;
      _notify();
      unawaited(_notifications.cancelFallAlert());
      AppLogger.ok(
        LogTags.firebase,
        'OFF confirmado y alarma/off_request actualizados atómicamente.',
      );
    } catch (error, stack) {
      // La petición permanece en true para que el dueño efectivo del socket o
      // el siguiente intento pueda procesarla.
      AppLogger.error(
        LogTags.bluetooth,
        'No se pudo completar la orden remota OFF.',
        error,
        stack,
      );
    } finally {
      _handlingOffRequest = false;
    }
  }

  Future<GeoPoint?> _readLocation() async {
    try {
      _locationPoint = await _location.current();
      AppLogger.info(
        LogTags.gps,
        'Ubicación obtenida: ${_locationPoint!.latitude.toStringAsFixed(5)}, '
        '${_locationPoint!.longitude.toStringAsFixed(5)}.',
      );
      _notify();
      return _locationPoint;
    } on LocationFailure catch (error) {
      AppLogger.warn(LogTags.gps, 'Ubicación no disponible: ${error.message}');
      _events.add(
        EquilibraEvent(
          type: EquilibraEventType.connectionLost,
          title: 'Ubicación no disponible',
          message: error.message,
        ),
      );
      return _locationPoint;
    } catch (error, stack) {
      // Un timeout del GPS o un error de plataforma nunca debe propagarse a
      // los latidos ni a la trama Bluetooth.
      AppLogger.warn(LogTags.gps, 'Fallo inesperado al leer GPS: $error');
      AppLogger.error(
        LogTags.gps,
        'Detalle del fallo de ubicación.',
        error,
        stack,
      );
      return _locationPoint;
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // El widget puede intentar disponer el controlador que es propiedad de
    // EquilibraApp durante el cambio de modo o el cierre de sesión.
    if (_disposed) return;
    _disposed = true;
    unawaited(_offRequestSubscription?.cancel());
    unawaited(_lineSubscription.cancel());
    unawaited(_connectionSubscription.cancel());
    unawaited(_discoverySubscription.cancel());
    unawaited(_discoveryStateSubscription.cancel());
    unawaited(_events.close());
    unawaited(_bluetooth.dispose());
    super.dispose();
  }
}
