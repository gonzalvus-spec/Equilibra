/// Error de Bluetooth clásico explicado para la interfaz.
class BluetoothFailure implements Exception {
  const BluetoothFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
