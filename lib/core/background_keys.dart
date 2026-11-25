/// Claves compartidas entre el isolate principal y el servicio en segundo plano.
abstract final class BackgroundKeys {
  static const String mode = 'mode';
  static const String uid = 'uid';
  static const String deviceAddress = 'device_address';
  static const String deviceName = 'device_name';
  static const String terminalId = 'terminal_id';

  static const String configure = 'configure';
  static const String disconnectBridge = 'disconnect_bridge';
  static const String stopService = 'stopService';

  static const String state = 'background_state';
  static const String alarm = 'background_alarm';
  static const String line = 'background_line';
  static const String error = 'background_error';
  static const String log = 'background_log';

  static const String logLevel = 'log_level';
  static const String logTag = 'log_tag';
  static const String logMessage = 'log_message';
  static const String logError = 'log_error';

  static const String channelId = 'equilibra_servicio';
  static const String channelName = 'Servicio Equilibra';
  static const String channelDescription =
      'Mantenimiento del puente y supervisión remota en segundo plano';
  static const int serviceNotificationId = 778;
}
