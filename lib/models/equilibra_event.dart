/// Eventos asíncronos que la UI debe presentar como alertas.
enum EquilibraEventType { alarmActivated, alarmDeactivated, connectionLost }

/// Evento emitido por el controlador cuando el ESP32 cambia de estado
/// sin que medie una acción del usuario.
class EquilibraEvent {
  const EquilibraEvent({
    required this.type,
    required this.title,
    required this.message,
  });

  final EquilibraEventType type;
  final String title;
  final String message;
}
