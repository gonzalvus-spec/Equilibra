import 'dart:async';

import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';

import '../models/bluetooth_status.dart';
import '../models/device_info.dart';
import 'app_logger.dart';
import 'bluetooth_failure.dart';

/// Comunicación serial Bluetooth clásico (SPP/RFCOMM) con el ESP32.
///
/// Regla de oro de Android 12+: ningún método del adaptador (`isEnabled`,
/// `isDiscovering`, `bondedDevices`, `startDiscovery`…) puede invocarse antes de
/// tener `BLUETOOTH_CONNECT`/`BLUETOOTH_SCAN`. El plugin los ejecuta en el hilo
/// principal sin capturar `SecurityException`, y una excepción nativa ahí
/// termina el proceso completo (la app "se cierra sola"). Por eso esta clase
/// siempre consulta/pidé los permisos **antes** de tocar el adaptador.
class BluetoothService {
  BluetoothService({FlutterClassicBluetooth? bluetooth})
    : _bluetooth = bluetooth ?? FlutterClassicBluetooth();

  static const Set<BtcPermission> connectScopes = {BtcPermission.connect};
  static const Set<BtcPermission> discoveryScopes = {
    BtcPermission.scan,
    BtcPermission.connect,
  };

  final FlutterClassicBluetooth _bluetooth;
  final StreamController<String> _lines = StreamController<String>.broadcast();
  final StreamController<BluetoothStatus> _states =
      StreamController<BluetoothStatus>.broadcast();

  BtcConnection? _connection;
  StreamSubscription<String>? _lineSubscription;
  StreamSubscription<BtcConnectionState>? _stateSubscription;
  bool _disposed = false;

  Stream<String> get lines => _lines.stream;
  Stream<BluetoothStatus> get connectionStates => _states.stream;
  Stream<DeviceInfo> get discoveryResults => _bluetooth.discoveryResults.map(
    (device) => DeviceInfo(
      name: device.displayName == device.address ? '' : device.displayName,
      address: device.address,
      isPaired: device.bondState == BtcBondState.bonded,
      rssi: device.rssi,
    ),
  );
  Stream<bool> get discoveryStates => _bluetooth.discoveryState;

  static bool _isUsable(BtcPermissionStatus status) =>
      status == BtcPermissionStatus.granted ||
      status == BtcPermissionStatus.notRequired;

  /// Estado actual de [scopes] sin mostrar ningún diálogo del sistema.
  Future<bool> hasPermissions({
    Set<BtcPermission> scopes = connectScopes,
  }) async {
    try {
      return _isUsable(await _bluetooth.checkPermissions(permissions: scopes));
    } catch (_) {
      return false;
    }
  }

  /// Garantiza [scopes] antes de llamar al adaptador nativo.
  ///
  /// Sólo pide el diálogo si el permiso aún puede solicitarse; si Android ya no
  /// volverá a preguntar, devuelve un error de dominio en lugar de esperar un
  /// diálogo que nunca aparece.
  Future<void> _ensurePermissions(
    Set<BtcPermission> scopes,
    String denialMessage,
  ) async {
    try {
      var status = await _bluetooth.checkPermissions(permissions: scopes);
      if (_isUsable(status)) return;
      if (status == BtcPermissionStatus.permanentlyDenied) {
        throw BluetoothFailure(
          '$denialMessage Actívalos desde los ajustes de la aplicación.',
        );
      }
      status = await _bluetooth.requestPermissions(permissions: scopes);
      if (_isUsable(status)) return;
      throw BluetoothFailure(denialMessage);
    } on BluetoothFailure {
      rethrow;
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    } catch (error) {
      throw BluetoothFailure('No se pudieron verificar los permisos: $error');
    }
  }

  Future<bool> isEnabled() async {
    await _ensurePermissions(
      connectScopes,
      'Concede el permiso de Bluetooth para comprobar el adaptador.',
    );
    try {
      return await _bluetooth.isEnabled();
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    } catch (error) {
      throw BluetoothFailure('No se pudo comprobar Bluetooth: $error');
    }
  }

  Future<bool> enable() async {
    // `enableBluetooth()` del plugin lee `adapter.isEnabled` antes de pedir
    // permiso: sin BLUETOOTH_CONNECT eso es una SecurityException nativa.
    await _ensurePermissions(
      connectScopes,
      'Concede el permiso de Bluetooth para encenderlo.',
    );
    try {
      return await _bluetooth.enableBluetooth();
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    } catch (error) {
      throw BluetoothFailure('No se pudo encender Bluetooth: $error');
    }
  }

  /// Comprueba soporte, adaptador y permiso de conexión a equipos emparejados.
  Future<void> prepare() async {
    try {
      await _ensurePermissions(
        connectScopes,
        'Concede el permiso de Bluetooth para continuar.',
      );
      if (!await _bluetooth.isSupported()) {
        throw const BluetoothFailure(
          'Este dispositivo no admite Bluetooth clásico.',
        );
      }
      if (!await _bluetooth.isEnabled()) {
        throw const BluetoothFailure('Activa Bluetooth para continuar.');
      }
    } on BluetoothFailure {
      rethrow;
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    } catch (error) {
      throw BluetoothFailure('No se pudo preparar Bluetooth: $error');
    }
  }

  /// Obtiene los dispositivos emparejados en el sistema.
  Future<List<DeviceInfo>> pairedDevices() async {
    // El handler nativo pediría el permiso por su cuenta y, en el isolate del
    // servicio (sin Activity), devolvería un error difícil de diagnosticar.
    await _ensurePermissions(
      connectScopes,
      'Concede el permiso de Bluetooth para leer los equipos emparejados.',
    );
    try {
      final devices = await _bluetooth.getPairedDevices();
      return devices
          .map(
            (device) => DeviceInfo(
              name: device.displayName,
              address: device.address,
              isPaired: true,
              rssi: device.rssi,
            ),
          )
          .toList(growable: false);
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    } catch (error) {
      throw BluetoothFailure('No se pudieron leer los dispositivos: $error');
    }
  }

  /// Prepara permisos y requisitos específicos del descubrimiento activo.
  Future<void> prepareDiscovery() async {
    await _ensurePermissions(
      discoveryScopes,
      'Concede el permiso para buscar dispositivos cercanos.',
    );
    await prepare();
    try {
      if (await _bluetooth.isLocationServiceRequired() &&
          !await _bluetooth.isLocationServiceEnabled()) {
        throw const BluetoothFailure(
          'Activa la ubicación del teléfono para buscar equipos Bluetooth.',
        );
      }
    } on BluetoothFailure {
      rethrow;
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    }
  }

  Future<void> startDiscovery() async {
    await prepareDiscovery();
    try {
      await _bluetooth.startDiscovery();
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    }
  }

  /// Detiene el escaneo sin pedir permisos: se usa también durante el cierre,
  /// donde un diálogo del sistema no tendría sentido.
  Future<void> stopDiscovery() async {
    if (!await hasPermissions(scopes: discoveryScopes)) return;
    try {
      if (await _bluetooth.isDiscovering()) await _bluetooth.stopDiscovery();
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    }
  }

  Future<void> pair(DeviceInfo device) async {
    if (device.isPaired) return;
    await _ensurePermissions(
      connectScopes,
      'Concede el permiso de Bluetooth para emparejar el dispositivo.',
    );
    try {
      final paired = await _bluetooth.bondDevice(device.address);
      if (!paired) {
        throw const BluetoothFailure('No se pudo emparejar el dispositivo.');
      }
    } on BluetoothFailure {
      rethrow;
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    }
  }

  /// Abre el socket RFCOMM/SPP y comienza a reconstruir mensajes por línea.
  Future<void> connect(DeviceInfo device) async {
    await _ensurePermissions(
      connectScopes,
      'Concede el permiso de Bluetooth para conectar el ESP32.',
    );
    await disconnect();
    _emitState(BluetoothStatus.connecting);

    try {
      final connection = await _bluetooth.connect(
        address: device.address,
        timeout: const Duration(seconds: 12),
      );
      _connection = connection;
      _lineSubscription = connection.input.lines().listen(
        (line) => _lines.add(line.trim()),
        onError: _lines.addError,
      );
      _stateSubscription = connection.stateStream.listen((state) {
        final status = switch (state.name) {
          'connected' => BluetoothStatus.connected,
          'connecting' => BluetoothStatus.connecting,
          _ => BluetoothStatus.disconnected,
        };
        _emitState(status);
      });
      _emitState(BluetoothStatus.connected);
    } on BtcException catch (error) {
      _emitState(BluetoothStatus.disconnected);
      throw BluetoothFailure(error.message);
    } catch (error) {
      _emitState(BluetoothStatus.disconnected);
      throw BluetoothFailure('No se pudo conectar con el dispositivo: $error');
    }
  }

  Future<void> disconnect() async {
    await _lineSubscription?.cancel();
    await _stateSubscription?.cancel();
    _lineSubscription = null;
    _stateSubscription = null;

    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection.close();
      } finally {
        connection.dispose();
      }
    }
    _emitState(BluetoothStatus.disconnected);
  }

  /// Envía un comando terminado exactamente en LF por el enlace serial.
  Future<void> sendCommand(String command) async {
    final connection = _connection;
    if (connection == null || !connection.isConnected) {
      throw const BluetoothFailure('Conecta el ESP32 primero.');
    }
    try {
      await connection.output.writeLine(command, newline: '\n');
    } on BtcException catch (error) {
      throw BluetoothFailure(error.message);
    } catch (error) {
      throw BluetoothFailure('No se pudo enviar el comando: $error');
    }
  }

  void _emitState(BluetoothStatus state) {
    if (!_disposed) _states.add(state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await stopDiscovery();
    } catch (error) {
      AppLogger.warn(
        LogTags.bluetooth,
        'No se pudo detener el escaneo durante el cierre: $error',
      );
    }
    try {
      await disconnect();
    } catch (error) {
      AppLogger.warn(
        LogTags.bluetooth,
        'No se pudo cerrar el socket durante el cierre: $error',
      );
    }
    _disposed = true;
    await _lines.close();
    await _states.close();
  }
}
