import 'package:shared_preferences/shared_preferences.dart';

class BluetoothPreferences {
  static const _addressKey = 'bluetooth_device_address';

  Future<String?> loadAddress() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_addressKey);
  }

  Future<void> saveAddress(String address) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_addressKey, address);
  }

  Future<void> clearAddress() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_addressKey);
  }
}
