import 'package:flutter_test/flutter_test.dart';
import 'package:walk_pin_navigator/navigation/off_route_monitor.dart';

void main() {
  final now = DateTime(2026, 10, 15, 9);

  test('경로 이탈 30m 이상 연속 3회일 때만 재탐색', () {
    final monitor = OffRouteMonitor();
    expect(
      monitor.observe(lateralMeters: 50, accuracyMeters: 8, now: now),
      false,
    );
    expect(
      monitor.observe(
        lateralMeters: 42,
        accuracyMeters: 8,
        now: now.add(const Duration(seconds: 1)),
      ),
      false,
    );
    expect(
      monitor.observe(
        lateralMeters: 45,
        accuracyMeters: 8,
        now: now.add(const Duration(seconds: 2)),
      ),
      true,
    );
  });

  test('경로에 복귀하면 연속 횟수가 초기화', () {
    final monitor = OffRouteMonitor();
    monitor.observe(lateralMeters: 50, accuracyMeters: 8, now: now);
    monitor.observe(lateralMeters: 9, accuracyMeters: 8, now: now);
    expect(
      monitor.observe(
        lateralMeters: 55,
        accuracyMeters: 8,
        now: now.add(const Duration(seconds: 1)),
      ),
      false,
    );
    expect(monitor.consecutiveFixes, 1);
  });

  test('GPS 부정확한 좌표는 이탈 판정에서 제외', () {
    final monitor = OffRouteMonitor();
    monitor.observe(lateralMeters: 60, accuracyMeters: 8, now: now);
    monitor.observe(lateralMeters: 60, accuracyMeters: 100, now: now);
    expect(monitor.consecutiveFixes, 0);
    expect(
      monitor.observe(lateralMeters: double.nan, accuracyMeters: 8, now: now),
      false,
    );
    expect(
      monitor.observe(
        lateralMeters: 60,
        accuracyMeters: double.infinity,
        now: now,
      ),
      false,
    );
  });

  test('재탐색 실패 후에도 15초 동안 요청을 제한하고 재시도', () {
    final monitor = OffRouteMonitor();
    for (var i = 0; i < 3; i++) {
      final result = monitor.observe(
        lateralMeters: 80,
        accuracyMeters: 5,
        now: now.add(Duration(seconds: i)),
      );
      expect(result, i == 2);
    }
    for (var i = 3; i < 8; i++) {
      expect(
        monitor.observe(
          lateralMeters: 80,
          accuracyMeters: 5,
          now: now.add(Duration(seconds: i)),
        ),
        false,
      );
    }
    expect(
      monitor.observe(
        lateralMeters: 80,
        accuracyMeters: 5,
        now: now.add(const Duration(seconds: 17)),
      ),
      true,
    );
  });

  test('자동차 이동 중 큰 경로 이탈은 정확한 GPS 2회로 재탐색', () {
    final monitor = OffRouteMonitor();
    expect(
      monitor.observe(
        lateralMeters: 130,
        accuracyMeters: 7,
        speedMetersPerSecond: 14,
        now: now,
      ),
      false,
    );
    expect(
      monitor.observe(
        lateralMeters: 240,
        accuracyMeters: 8,
        speedMetersPerSecond: 14,
        now: now.add(const Duration(seconds: 2)),
      ),
      true,
    );
  });

  test('고속 이동이라도 GPS 정확도가 나쁘면 재탐색하지 않음', () {
    final monitor = OffRouteMonitor();
    for (var i = 0; i < 5; i++) {
      expect(
        monitor.observe(
          lateralMeters: 160,
          accuracyMeters: 90,
          speedMetersPerSecond: 17,
          now: now.add(Duration(seconds: i)),
        ),
        false,
      );
    }
  });

  test('새 내비게이션 시작 시 세션 초기화', () {
    final monitor = OffRouteMonitor();
    for (var i = 0; i < 3; i++) {
      monitor.observe(
        lateralMeters: 40,
        accuracyMeters: 5,
        now: now.add(Duration(seconds: i)),
      );
    }
    monitor.resetSession();
    expect(monitor.consecutiveFixes, 0);
    for (var i = 0; i < 3; i++) {
      expect(
        monitor.observe(
          lateralMeters: 40,
          accuracyMeters: 5,
          now: now.add(Duration(seconds: 3 + i)),
        ),
        i == 2,
      );
    }
  });
}
