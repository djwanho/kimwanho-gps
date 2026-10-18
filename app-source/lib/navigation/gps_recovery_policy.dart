/// 위치 스트림이 조용히 멈추는 경우의 자동 복구 간격.
///
/// 실시간 표시를 담당하는 Stream, 일회성 조회(poll), 스트림 재구독을
/// 별도로 판단하여 단발성 조회만 성공해도 스트림 고장을 숨기지 않습니다.
class GpsRecoveryPolicy {
  static const pollAfter = Duration(seconds: 8);
  static const restartAfter = Duration(seconds: 15);
  static const pollInterval = Duration(seconds: 8);
  static const restartInterval = Duration(seconds: 20);

  static bool shouldPoll({
    required Duration streamSilentFor,
    Duration? sinceLastPoll,
    required bool pollBusy,
  }) {
    return !pollBusy &&
        streamSilentFor >= pollAfter &&
        (sinceLastPoll == null || sinceLastPoll >= pollInterval);
  }

  static bool shouldRestart({
    required Duration streamSilentFor,
    Duration? sinceLastRestart,
    required bool restartBusy,
  }) {
    return !restartBusy &&
        streamSilentFor >= restartAfter &&
        (sinceLastRestart == null || sinceLastRestart >= restartInterval);
  }
}
