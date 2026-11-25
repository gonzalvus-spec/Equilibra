class TerminalInfo {
  const TerminalInfo({
    required this.id,
    required this.name,
    required this.role,
    required this.online,
    required this.revoked,
    this.activeSession = false,
    this.lastHeartbeat,
  });

  final String id;
  final String name;
  final String role;
  final bool online;
  final bool revoked;
  final bool activeSession;
  final DateTime? lastHeartbeat;

  String get roleLabel => switch (role) {
    'puente' => 'Estación',
    'monitor' => 'Remoto',
    _ => 'Sin rol',
  };

  bool get hasRole => role == 'puente' || role == 'monitor';

  bool get isOrphaned {
    final heartbeat = lastHeartbeat;
    return !online &&
        !activeSession &&
        heartbeat != null &&
        DateTime.now().difference(heartbeat) > const Duration(minutes: 3);
  }

  static TerminalInfo? fromEntry(String id, Object? value) {
    if (value is! Map) return null;
    final rawHeartbeat = value['last_seen'] ?? value['ultimo_latido'];
    return TerminalInfo(
      id: id,
      name: value['nombre']?.toString() ?? 'Teléfono',
      role: value['rol']?.toString() ?? '',
      online: value['online'] == true,
      revoked: value['revocado'] == true,
      activeSession: value['sesion_activa'] == true,
      lastHeartbeat: rawHeartbeat is num
          ? DateTime.fromMillisecondsSinceEpoch(rawHeartbeat.toInt())
          : null,
    );
  }
}
