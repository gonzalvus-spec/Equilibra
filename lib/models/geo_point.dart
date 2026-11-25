class GeoPoint {
  const GeoPoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  Map<String, Object> toJson() => {'lat': latitude, 'lng': longitude};

  static GeoPoint? fromJson(Object? value) {
    if (value is! Map) return null;
    final lat = value['lat'];
    final lng = value['lng'];
    if (lat is! num || lng is! num) return null;
    return GeoPoint(latitude: lat.toDouble(), longitude: lng.toDouble());
  }
}
