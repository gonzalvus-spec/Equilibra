/// Estado actual de la alarma reportado por el ESP32.
enum AlarmStatus {
  activated,
  deactivated;

  bool get isActivated => this == AlarmStatus.activated;

  String get label => switch (this) {
    AlarmStatus.activated => 'ACTIVADA',
    AlarmStatus.deactivated => 'DESACTIVADA',
  };

  String get description => switch (this) {
    AlarmStatus.activated => 'Verifica a la persona de inmediato.',
    AlarmStatus.deactivated => 'Monitoreando posibles golpes.',
  };
}
