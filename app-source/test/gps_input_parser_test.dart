import 'package:flutter_test/flutter_test.dart';
import 'package:walk_pin_navigator/navigation/gps_input_parser.dart';

void main() {
  test('십진수 위도/경도와 공백으로 구분한 GPS 입력', () {
    final comma = GpsInputParser.parse('37.5665, 126.9780')!;
    expect(comma.latitude, closeTo(37.5665, 0.0000001));
    expect(comma.longitude, closeTo(126.9780, 0.0000001));
    expect(GpsInputParser.parse('37.5665 126.9780')!.longitude, 126.978);
  });

  test('순서가 뒤바뀐 라벨 GPS 자료도 올바르게 해석', () {
    final p = GpsInputParser.parse('lon=126.9780 lat=37.5665')!;
    expect(p.latitude, 37.5665);
    expect(p.longitude, 126.978);
    expect(
      GpsInputParser.parse('위도: 37.5665 경도: 126.9780')!.longitude,
      126.978,
    );
  });

  test('드론의 도분초 좌표를 십진수로 변환', () {
    final p = GpsInputParser.parse(r"""37°33'59.4"N 126°58'40.8"E""")!;
    expect(p.latitude, closeTo(37.5665, 0.0000001));
    expect(p.longitude, closeTo(126.9780, 0.0000001));
    final reversed = GpsInputParser.parse(r"""126°58'40.8"E 37°33'59.4"N""")!;
    expect(reversed.latitude, closeTo(37.5665, 0.0000001));
  });

  test('방향 표기가 있는 GPS와 서경/남위', () {
    expect(GpsInputParser.parse('N37.5665 E126.9780')!.latitude, 37.5665);
    final p = GpsInputParser.parse('12.5°S, 75.25°W')!;
    expect(p.latitude, -12.5);
    expect(p.longitude, -75.25);
  });

  test('Google Maps 좌표 링크, Android geo URI', () {
    expect(
      GpsInputParser.parse(
        'https://www.google.com/maps/search/?api=1&query=37.5665%2C126.978',
      )!.latitude,
      37.5665,
    );
    expect(
      GpsInputParser.parse('geo:37.5665,126.978;u=20')!.longitude,
      126.978,
    );
  });

  test('GPX 첫 지점 및 CSV/TXT 파일 지점 목록', () {
    final gpx =
        '<gpx><wpt lat="37.5665" lon="126.9780"/>'
        '<wpt lat="37.5670" lon="126.9790"/></gpx>';
    final points = GpsInputParser.parseFileText(gpx);
    expect(points.length, 2);
    expect(points.last.latitude, 37.567);
    expect(
      GpsInputParser.parseFileText(
        'timestamp,latitude,longitude\n123,37.5665,126.978\n124,37.567,126.979'
            .replaceAll(r'\n', '\n'),
      ).length,
      2,
    );
    expect(
      GpsInputParser.parseFileText(
        '37.5665,126.978\n37.567,126.979'.replaceAll(r'\n', '\n'),
      ).length,
      2,
    );
  });

  test('일반 한국 주소, 잘못된 좌표는 좌표로 인식하지 않음', () {
    expect(GpsInputParser.parse('서울특별시 중구 세종대로 110'), isNull);
    expect(GpsInputParser.parse('91, 126.978'), isNull);
    expect(GpsInputParser.parse(r"""37°61'00"N 126°58'00"E"""), isNull);
  });
}
