import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../core/app_constants.dart';
import '../models/geo_point.dart';
import '../models/history_event.dart';
import '../models/remote_device_state.dart';
import 'app_logger.dart';

class FirebaseService {
  FirebaseService({required this.uid, this.database});

  final FirebaseDatabase? database;
  final String uid;
  FirebaseDatabase? _resolvedDatabase;
  Stream<RemoteDeviceState>? _deviceStream;
  Stream<Object?>? _offRequestStream;

  /// La base de datos se resuelve de forma diferida: el constructor no puede
  /// tocar `Firebase.app()` antes de `ensureFirebaseReady()`.
  FirebaseDatabase get _db =>
      database ??
      (_resolvedDatabase ??= FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: AppConstants.databaseUrl,
      ));

  DatabaseReference get _device =>
      _db.ref('usuarios/$uid/${AppConstants.firebaseDevicePath}');

  /// Comparte un único listener nativo por instancia y descarta snapshots que
  /// no modifican realmente el estado. La app conserva una sola instancia por
  /// sesión de usuario.
  Stream<RemoteDeviceState> watchDevice() => _deviceStream ??= _device.onValue
      .map((event) => RemoteDeviceState.fromJson(event.snapshot.value))
      .distinct(_sameDeviceState)
      .map((state) {
        AppLogger.info(
          LogTags.firebase,
          'Lectura de estado: alarma_activa=${state.alarmActive}, '
          'puente_en_linea=${state.bridgeOnline}.',
        );
        return state;
      })
      .asBroadcastStream();

  Stream<Object?> watchOffRequests() => _offRequestStream ??= _device
      .child('comandos/off_request')
      .onValue
      .map((event) => event.snapshot.value)
      .distinct()
      .asBroadcastStream();

  /// Mantiene en caché local el nodo del equipo para que los comandos remotos
  /// lleguen al listener sin depender de una lectura periódica.
  Future<void> keepDeviceSynced() => _device.keepSynced(true);

  Stream<List<HistoryEvent>> watchHistory() => _device
      .child('historial')
      .orderByChild('timestamp')
      .limitToLast(100)
      .onValue
      .map((event) {
        final value = event.snapshot.value;
        if (value is! Map) return const <HistoryEvent>[];
        final events = <HistoryEvent>[];
        for (final entry in value.entries) {
          final item = HistoryEvent.fromEntry(
            entry.key.toString(),
            entry.value,
          );
          if (item != null) events.add(item);
        }
        events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        return events;
      });

  Future<void> reportAlarm(GeoPoint? location) async {
    final updates = <String, Object?>{
      'estado/alarma_activa': true,
      'estado/puente_en_linea': true,
      'estado/ultimo_latido': ServerValue.timestamp,
    };
    if (location != null) updates['ubicacion'] = location.toJson();
    AppLogger.warn(
      LogTags.firebase,
      'Escribiendo alarma activa en usuarios/{uid}/${AppConstants.firebaseDevicePath}.',
    );
    await _device.update(updates);
    await addHistory('caida_impacto', location);
    AppLogger.ok(LogTags.firebase, 'Alarma e historial guardados en Firebase.');
  }

  Future<void> reportDeactivated({
    required bool remote,
    GeoPoint? location,
  }) async {
    await _device.child('estado/alarma_activa').set(false);
    await addHistory(
      remote ? 'desactivada_remota' : 'desactivada_fisica',
      location,
    );
  }

  Future<void> requestRemoteOff(GeoPoint? location) async {
    AppLogger.warn(
      LogTags.firebase,
      'Escribiendo comandos/off_request para apagar el ESP32…',
    );
    // El monitor sólo solicita. El puente es quien confirma alarma=false
    // después de entregar OFF al ESP32.
    await _device.child('comandos/off_request').set(true);
    AppLogger.ok(LogTags.firebase, 'Orden remota registrada en Firebase.');
  }

  /// Confirma en una sola escritura multipath el apagado y el consumo de la
  /// orden. Sólo debe llamarse después de enviar OFF por RFCOMM.
  Future<void> completeRemoteOff(GeoPoint? location) async {
    await _device.update({
      'estado/alarma_activa': false,
      'comandos/off_request': null,
    });
    await addHistory('desactivada_remota', location);
  }

  Future<void> heartbeat(GeoPoint? location) async {
    final updates = <String, Object?>{
      'estado/puente_en_linea': true,
      'estado/ultimo_latido': ServerValue.timestamp,
    };
    if (location != null) updates['ubicacion'] = location.toJson();
    await _device.update(updates);
    AppLogger.info(
      LogTags.firebase,
      'Latido GPS publicado (latido: ${location == null ? 'sin coords' : 'con coords'}).',
    );
  }

  /// Publica la disponibilidad del puente sin depender de GPS u otros
  /// periféricos. Se usa al entrar en Modo Estación y antes de cada lectura de
  /// ubicación para que los monitores reciban la presencia inmediatamente.
  Future<void> setBridgeOnline() async {
    await _device.update({
      'estado/puente_en_linea': true,
      'estado/ultimo_latido': ServerValue.timestamp,
    });
    AppLogger.info(
      LogTags.firebase,
      'Presencia inmediata del puente publicada.',
    );
  }

  /// Actualiza únicamente las coordenadas. La presencia ya se publicó antes,
  /// por lo que un GPS lento no retrasa el estado visible en Modo Monitor.
  Future<void> updateBridgeLocation(GeoPoint location) =>
      _device.child('ubicacion').set(location.toJson());

  Future<void> setBridgeOffline() async {
    await _device.child('estado/puente_en_linea').set(false);
    AppLogger.info(
      LogTags.firebase,
      'Puente marcado como offline en Firebase.',
    );
  }

  Future<void> configureDisconnectPresence() async {
    await _device.child('estado/puente_en_linea').onDisconnect().set(false);
  }

  Future<void> addHistory(String type, GeoPoint? location) {
    final data = <String, Object?>{
      'tipo': type,
      'timestamp': ServerValue.timestamp,
    };
    if (location != null) {
      data['lat'] = location.latitude;
      data['lng'] = location.longitude;
    }
    return _device.child('historial').push().set(data);
  }
}

bool _sameDeviceState(RemoteDeviceState previous, RemoteDeviceState next) =>
    previous.alarmActive == next.alarmActive &&
    previous.bridgeOnline == next.bridgeOnline &&
    previous.lastHeartbeat == next.lastHeartbeat &&
    previous.location?.latitude == next.location?.latitude &&
    previous.location?.longitude == next.location?.longitude;
