/// Estado del enlace Bluetooth clásico con el módulo EQUILIBRA.
enum BluetoothStatus {
  disconnected,
  connecting,
  connected;

  bool get isConnected => this == BluetoothStatus.connected;

  String get label => switch (this) {
    BluetoothStatus.disconnected => 'DESCONECTADO',
    BluetoothStatus.connecting => 'CONECTANDO',
    BluetoothStatus.connected => 'CONECTADO',
  };
}
