import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walk_pin_navigator/navigation/walking_guidance.dart';

void main() {
  final route = WalkingVoiceRoute(
    points: const [
      LatLng(37.0, 127.0),
      LatLng(37.0005, 127.0),
      LatLng(37.001, 127.0),
    ],
    maneuvers: const [
      WalkingManeuver(type: 10, shapeIndex: 1, metersFromStart: 55.6),
    ],
    totalMeters: 111,
    totalSeconds: 90,
  );

  test('전체화면 안내는 현재 GPS 기준 남은 거리와 회전 지점을 표시', () {
    final status = navigationSnapshot(route, const LatLng(37.0, 127.0));
    expect(status.remainingMeters, closeTo(111, 1));
    expect(status.nextInstruction, contains('우회전'));
    expect(status.offRoute, isFalse);
  });

  test('경로 밖에 있으면 안내 화면에 이탈 경고 표시', () {
    final status = navigationSnapshot(route, const LatLng(37.002, 127.01));
    expect(status.offRoute, isTrue);
    expect(status.nextInstruction, contains('경로에서 벗어났습니다'));
  });

  test('GPS 한 번 매칭한 결과를 화면에서 재사용해도 결과 동일', () {
    const current = LatLng(37.0005, 127.00001);
    final match = route.locate(current);
    final computed = navigationSnapshot(route, current);
    final cached = navigationSnapshot(route, current, match: match);
    expect(cached.remainingMeters, computed.remainingMeters);
    expect(cached.nextInstruction, computed.nextInstruction);
    expect(cached.offRoute, computed.offRoute);
  });

  test('현재 GPS 이동에 따라 남은 거리가 감소', () {
    final before = navigationSnapshot(route, const LatLng(37.0, 127.0));
    final after = navigationSnapshot(route, const LatLng(37.0005, 127.0));
    expect(after.remainingMeters, lessThan(before.remainingMeters));
  });
}
