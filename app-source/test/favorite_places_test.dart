import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:walk_pin_navigator/navigation/favorite_places.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      isNull,
    );
  });

  test('favorites persist across storage instances and deletion', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    const place = FavoritePlace(
      id: 'persisted-1',
      name: '다시 여는 장소',
      latitude: 37.5665,
      longitude: 126.978,
    );

    await FavoritePlacesStorage().save([place]);
    final afterRelaunch = await FavoritePlacesStorage().load();

    expect(afterRelaunch, hasLength(1));
    expect(afterRelaunch.single.id, place.id);
    expect(afterRelaunch.single.name, place.name);
    expect(afterRelaunch.single.latitude, place.latitude);
    expect(afterRelaunch.single.longitude, place.longitude);

    await FavoritePlacesStorage().save([]);
    expect(await FavoritePlacesStorage().load(), isEmpty);
  });
}
