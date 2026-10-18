import 'package:flutter_test/flutter_test.dart';
import 'package:walk_pin_navigator/navigation/gps_recovery_policy.dart';

void main() {
  group('GPS 실시간 위치 복구', () {
    test('수신이 정상인 동안에는 일회성 조회와 재연결을 하지 않음', () {
      expect(
          GpsRecoveryPolicy.shouldPoll(
            streamSilentFor: const Duration(seconds: 4),
            pollBusy: false,
          ),
          isFalse);
      expect(
          GpsRecoveryPolicy.shouldRestart(
            streamSilentFor: const Duration(seconds: 4),
            restartBusy: false,
          ),
          isFalse);
    });

    test('8초 동안 스트림이 멈추면 위치를 다시 조회함', () {
      expect(
          GpsRecoveryPolicy.shouldPoll(
            streamSilentFor: const Duration(seconds: 8),
            pollBusy: false,
          ),
          isTrue);
    });

    test('15초 이상 스트림 수신이 없으면 재구독함', () {
      expect(
          GpsRecoveryPolicy.shouldRestart(
            streamSilentFor: const Duration(seconds: 15),
            restartBusy: false,
          ),
          isTrue);
    });

    test('동시에 여러 GPS 조회를 진행하지 않음', () {
      expect(
          GpsRecoveryPolicy.shouldPoll(
            streamSilentFor: const Duration(seconds: 25),
            pollBusy: true,
          ),
          isFalse);
      expect(
          GpsRecoveryPolicy.shouldRestart(
            streamSilentFor: const Duration(seconds: 25),
            restartBusy: true,
          ),
          isFalse);
    });

    test('연속 재연결/조회는 최소 간격을 지킴', () {
      expect(
          GpsRecoveryPolicy.shouldPoll(
            streamSilentFor: const Duration(seconds: 30),
            sinceLastPoll: const Duration(seconds: 2),
            pollBusy: false,
          ),
          isFalse);
      expect(
          GpsRecoveryPolicy.shouldRestart(
            streamSilentFor: const Duration(seconds: 30),
            sinceLastRestart: const Duration(seconds: 12),
            restartBusy: false,
          ),
          isFalse);
      expect(
          GpsRecoveryPolicy.shouldRestart(
            streamSilentFor: const Duration(seconds: 30),
            sinceLastRestart: const Duration(seconds: 20),
            restartBusy: false,
          ),
          isTrue);
    });

    test('일회성 GPS 조회 후에도 스트림 복구 여부는 별도로 판단함', () {
      expect(
          GpsRecoveryPolicy.shouldRestart(
            streamSilentFor: const Duration(seconds: 22),
            restartBusy: false,
          ),
          isTrue);
    });
  });
}
