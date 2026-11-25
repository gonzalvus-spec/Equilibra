import 'package:geolocator/geolocator.dart';

import '../models/geo_point.dart';

class LocationFailure implements Exception {
  const LocationFailure(this.message);

  final String message;
}

class LocationService {
  /// Devuelve la posición actual traduciendo cualquier error del plugin
  /// (permiso, GPS apagado, timeout del proveedor, canal nativo) a
  /// [LocationFailure], para que nunca escape como excepción genérica a un
  /// `unawaited` de latidos o de la trama Bluetooth.
  Future<GeoPoint> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const LocationFailure('Activa la ubicación del teléfono.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const LocationFailure('Concede el permiso de ubicación.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      return GeoPoint(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } on LocationFailure {
      rethrow;
    } catch (error) {
      throw LocationFailure('No se pudo obtener la ubicación: $error');
    }
  }
}
