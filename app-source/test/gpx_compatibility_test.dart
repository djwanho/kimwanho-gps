import 'package:flutter_test/flutter_test.dart';
import 'package:walk_pin_navigator/navigation/gps_input_parser.dart';

void main() {
  test('GPX 1.1 기본 네임스페이스 + 이동 트랙 지점', () {
    final sample = '''<?xml version="1.0" encoding="utf-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="test">
  <trk><name>walk</name><trkseg>
    <trkpt lon="126.9780" lat="37.5665"><ele>35.0</ele></trkpt>
    <trkpt lat="37.5667" lon="126.9783" />
  </trkseg></trk>
</gpx>''';
    final points = GpsInputParser.parseFileText(sample);
    expect(points.length, 2);
    expect(points.first.latitude, 37.5665);
    expect(points.last.longitude, 126.9783);
  });

  test('GPX 1.1 접두사가 붙은 웨이포인트, 경로, 이동 트랙', () {
    final sample = '''<?xml version="1.0"?>
<g:gpx xmlns:g="http://www.topografix.com/GPX/1/1" version="1.1">
  <g:wpt lon="126.9780" lat="37.5665" />
  <g:rte><g:rtept lon="126.9781" lat="37.5666"/></g:rte>
  <g:trk><g:trkseg><g:trkpt lat="37.5667" lon="126.9782" /></g:trkseg></g:trk>
</g:gpx>''';
    final points = GpsInputParser.parseFileText(sample);
    expect(points.length, 3);
    expect(points.first.latitude, 37.5665);
    expect(points.last.latitude, 37.5667);
  });

  test('GPX 좌표가 없는 경우 빈 목록', () {
    expect(
      GpsInputParser.parseFileText(
        '<gpx><metadata><name>Only metadata</name></metadata></gpx>',
      ),
      isEmpty,
    );
  });

  test('비정상 GPX 구조는 오류 원인을 알 수 있게 함', () {
    expect(
      () => GpsInputParser.parseFileText('<gpx><trkpt></gpx>'),
      throwsA(isA<FormatException>()),
    );
  });

  test('기존 CSV 입력의 호환성 유지', () {
    final points = GpsInputParser.parseFileText(
      'latitude,longitude\n37.5665,126.978\n37.567,126.979',
    );
    expect(points.length, 2);
    expect(points.last.longitude, 126.979);
  });
}
