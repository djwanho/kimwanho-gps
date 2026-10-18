import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walk_pin_navigator/navigation/walking_guidance.dart';

void main() {
  test('경로 지점이 아니라 선분과 가까우면 이탈 아님', () {
    final route = WalkingVoiceRoute(
      points: const [LatLng(37.0, 127.0), LatLng(37.001, 127.0)],
      maneuvers: const [],
      totalMeters: 111,
      totalSeconds: 90,
    );
    // 긴 구간 중간은 모든 끝점에서 멀지만 경로 선분에서는 0m 근처.
    final match = route.locate(const LatLng(37.0005, 127.0));
    expect(match.lateralMeters, lessThan(1));
    final differentStreet = route.locate(const LatLng(37.0005, 127.0006));
    expect(differentStreet.lateralMeters, greaterThan(30));
  });
}
