/// GPS 경로 이탈 재탐색 트리거.
/// 연속 유효 측정 및 쿨다운을 통해 GPS 오차/요청 폭주를 방지합니다.
class OffRouteMonitor {
  OffRouteMonitor({
    this.thresholdMeters = 30,
    this.maxAccuracyMeters = 35,
    this.requiredFixes = 3,
    this.cooldown = const Duration(seconds: 15),
  }) : assert(requiredFixes > 0);

  final double thresholdMeters;
  final double maxAccuracyMeters;
  final int requiredFixes;
  final Duration cooldown;
  int _consecutive = 0;
  DateTime? _lastAttempt;

  int get consecutiveFixes => _consecutive;

  bool observe({
    required double lateralMeters,
    required double accuracyMeters,
    required DateTime now,
    double? speedMetersPerSecond,
  }) {
    if (!lateralMeters.isFinite ||
        !accuracyMeters.isFinite ||
        accuracyMeters < 0 ||
        accuracyMeters > maxAccuracyMeters) {
      _consecutive = 0;
      return false;
    }
    if (lateralMeters <= thresholdMeters) {
      _consecutive = 0;
      return false;
    }
    _consecutive += 1;
    // 차량 등 빠른 이동에서 경로 밖 100m 이상으로 멀어진 상황은
    // GPS 정확도가 충분할 때 연속 2회로 조기 재탐색합니다.
    // 일반 보행에서는 기존 3회 조건을 유지합니다.
    final rapidDeviation = speedMetersPerSecond != null &&
        speedMetersPerSecond.isFinite &&
        speedMetersPerSecond >= 8.0 &&
        lateralMeters >= 100.0 &&
        lateralMeters - accuracyMeters >= 70.0;
    final needed = rapidDeviation ? 2 : requiredFixes;
    if (_consecutive < needed) return false;
    if (_lastAttempt != null && now.difference(_lastAttempt!) < cooldown) {
      return false;
    }
    markAttempt(now);
    return true;
  }

  void markAttempt(DateTime now) {
    _lastAttempt = now;
    _consecutive = 0;
  }

  /// 성공/실패 뒤에도 쿨다운은 유지하여 불필요한 연속 요청을 막습니다.
  void resetConsecutive() => _consecutive = 0;

  void resetSession() {
    _consecutive = 0;
    _lastAttempt = null;
  }
}
