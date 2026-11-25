import 'geo_point.dart';

class RemoteDeviceState {
  const RemoteDeviceState({
    required this.alarmActive,
    required this.bridgeOnline,
    this.location,
    this.lastHeartbeat,
  });

  const RemoteDeviceState.initial()
    : alarmActive = false,
      bridgeOnline = false,
      location = null,
      lastHeartbeat = null;

  final bool alarmActive;
  final bool bridgeOnline;
  final GeoPoint? location;
  final DateTime? lastHeartbeat;

  bool get hasFreshBridge {
    final heartbeat = lastHeartbeat;
    return bridgeOnline &&
        heartbeat != null &&
        DateTime.now().difference(heartbeat).abs() <
            const Duration(seconds: 75);
  }

  static RemoteDeviceState fromJson(Object? value) {
    if (value is! Map) return const RemoteDeviceState.initial();
    final state = value['estado'];
    final stateMap = state is Map ? state : const <Object?, Object?>{};
    final rawHeartbeat = stateMap['ultimo_latido'];
    return RemoteDeviceState(
      alarmActive: stateMap['alarma_activa'] == true,
      bridgeOnline: stateMap['puente_en_linea'] == true,
      location: GeoPoint.fromJson(value['ubicacion']),
      lastHeartbeat: rawHeartbeat is num
          ? DateTime.fromMillisecondsSinceEpoch(rawHeartbeat.toInt())
          : null,
    );
  }
}
