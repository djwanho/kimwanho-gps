import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class FavoritePlace {
  const FavoritePlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
      };

  static FavoritePlace? fromJson(Object? data) {
    if (data is! Map) return null;
    final id = data['id'];
    final name = data['name'];
    final lat = data['latitude'];
    final lng = data['longitude'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        lat is! num ||
        lng is! num) {
      return null;
    }
    final latitude = lat.toDouble();
    final longitude = lng.toDouble();
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }
    return FavoritePlace(
        id: id, name: name, latitude: latitude, longitude: longitude);
  }
}

class FavoritePlacesStorage {
  static const key = 'kimwanho.gps.favorite_places.v1';
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<List<FavoritePlace>> load() async {
    final raw = await _prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded
        .map(FavoritePlace.fromJson)
        .whereType<FavoritePlace>()
        .take(200)
        .toList();
  }

  Future<void> save(List<FavoritePlace> places) async {
    if (places.length > 200) {
      throw ArgumentError('Maximum of 200 favorite places.');
    }
    await _prefs.setString(
      key,
      jsonEncode(places.map((place) => place.toJson()).toList()),
    );
  }
}
