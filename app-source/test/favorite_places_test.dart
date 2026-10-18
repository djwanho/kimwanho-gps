import 'package:flutter_test/flutter_test.dart';
import 'package:walk_pin_navigator/navigation/favorite_places.dart';

void main() {
  test('favorite serializes and deserializes without coordinate swap', () {
    const place = FavoritePlace(
      id: 'a1',
      name: '촬영 장소',
      latitude: 37.5665,
      longitude: 126.978,
    );
    final restored = FavoritePlace.fromJson(place.toJson())!;
    expect(restored.name, '촬영 장소');
    expect(restored.latitude, 37.5665);
    expect(restored.longitude, 126.978);
  });

  test('invalid coordinates are discarded', () {
    expect(
        FavoritePlace.fromJson({
          'id': 'x',
          'name': '잘못된 좌표',
          'latitude': 200,
          'longitude': 126.978,
        }),
        isNull);
  });
}
