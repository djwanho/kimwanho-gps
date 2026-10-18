import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walk_pin_navigator/navigation/direction_sector.dart';

void main() {
  test('heading 0 degrees points the sector northward', () {
    const center = LatLng(37.5665, 126.9780);
    final sector = directionSector(center, 0);
    expect(sector.length, 18);
    expect(sector.first.latitude, center.latitude);
    expect(sector[9].latitude, greaterThan(center.latitude));
  });

  test('heading 90 degrees points the sector eastward', () {
    const center = LatLng(37.5665, 126.9780);
    final sector = directionSector(center, 90);
    expect(sector[9].longitude, greaterThan(center.longitude));
  });

  test('invalid headings do not create misleading sectors', () {
    expect(directionSector(const LatLng(0, 0), double.nan), isEmpty);
  });
}
