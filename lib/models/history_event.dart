class HistoryEvent {
  const HistoryEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    this.latitude,
    this.longitude,
  });

  final String id;
  final String type;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;

  String get label => switch (type) {
    'caida_impacto' => 'Caída o impacto',
    'desactivada_remota' => 'Desactivación remota',
    'desactivada_fisica' => 'Alarma desactivada',
    _ => 'Evento',
  };

  static HistoryEvent? fromEntry(String id, Object? value) {
    if (value is! Map) return null;
    final timestamp = value['timestamp'];
    if (timestamp is! num) return null;
    final lat = value['lat'];
    final lng = value['lng'];
    return HistoryEvent(
      id: id,
      type: value['tipo']?.toString() ?? 'evento',
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp.toInt()),
      latitude: lat is num ? lat.toDouble() : null,
      longitude: lng is num ? lng.toDouble() : null,
    );
  }
}
