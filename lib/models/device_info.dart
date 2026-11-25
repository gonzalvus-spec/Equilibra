/// Dispositivo Bluetooth clásico emparejado o encontrado cerca del teléfono.
class DeviceInfo {
  const DeviceInfo({
    required this.name,
    required this.address,
    this.isPaired = false,
    this.rssi,
  });

  final String name;
  final String address;
  final bool isPaired;
  final int? rssi;

  String get displayName => name.trim().isEmpty ? address : name;

  DeviceInfo merge(DeviceInfo other) => DeviceInfo(
    name: other.name.trim().isNotEmpty ? other.name : name,
    address: address,
    isPaired: isPaired || other.isPaired,
    rssi: other.rssi ?? rssi,
  );

  @override
  bool operator ==(Object other) =>
      other is DeviceInfo && other.address == address;

  @override
  int get hashCode => address.hashCode;
}
