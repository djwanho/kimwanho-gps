import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walk_pin_navigator/navigation/walking_guidance.dart';

String _encodePolyline6(List<LatLng> points) {
  var prevLat = 0;
  var prevLng = 0;
  final out = StringBuffer();
  void writeNumber(int value) {
    var n = value < 0 ? ~(value << 1) : value << 1;
    while (n >= 0x20) {
      out.writeCharCode(((n & 0x1f) | 0x20) + 63);
      n >>= 5;
    }
    out.writeCharCode(n + 63);
  }

  for (final p in points) {
    final lat = (p.latitude * 1000000).round();
    final lon = (p.longitude * 1000000).round();
    writeNumber(lat - prevLat);
    writeNumber(lon - prevLng);
    prevLat = lat;
    prevLng = lon;
  }
  return out.toString();
}

void main() {
  final pts = <LatLng>[
    const LatLng(37.5665, 126.9780),
    const LatLng(37.5669, 126.9780),
    const LatLng(37.5669, 126.9784),
  ];

  test('Polyline6 디코딩은 위도 경도 순서를 유지함', () {
    final actual = decodePolyline6(_encodePolyline6(pts));
    expect(actual.length, pts.length);
    expect(actual[1].latitude, closeTo(37.5669, 0.000001));
    expect(actual[2].longitude, closeTo(126.9784, 0.000001));
  });

  test('Valhalla 보행 경로와 안내 지점 파싱', () {
    final route = WalkingVoiceRoute.fromValhalla({
      'trip': {
        'summary': {'length': 0.08, 'time': 65.0},
        'legs': [
          {
            'shape': _encodePolyline6(pts),
            'maneuvers': [
              {'type': 1, 'begin_shape_index': 0},
              {'type': 10, 'begin_shape_index': 1},
              {'type': 4, 'begin_shape_index': 2},
            ],
          },
        ],
      },
    });
    expect(route.points.length, 3);
    expect(route.totalMeters, 80);
    expect(route.totalSeconds, 65);
    expect(route.maneuvers[1].koreanCommand, '우회전하세요');

    final guidance = WalkingGuidance(route);
    final first = guidance.onGpsFix(
      pts.first,
      accuracyMeters: 8,
      now: DateTime(2026, 10, 12),
    );
    expect(first, contains('우회전'));
    expect(
      guidance.onGpsFix(
        pts.first,
        accuracyMeters: 8,
        now: DateTime(2026, 10, 12),
      ),
      isNull,
    );

    // 목적지에서는 연속 2회 유효한 GPS 값이 들어와야 도착 알림.
    expect(guidance.onGpsFix(pts.last, accuracyMeters: 6), isNull);
    expect(guidance.onGpsFix(pts.last, accuracyMeters: 6), contains('도착'));
    expect(guidance.active, isFalse);
  });

  test('GPS 정확도가 낮을 때 잘못된 음성 안내를 하지 않음', () {
    final route = WalkingVoiceRoute(
      points: pts,
      maneuvers: [
        const WalkingManeuver(type: 10, shapeIndex: 1, metersFromStart: 40),
      ],
      totalMeters: 80,
      totalSeconds: 60,
    );
    final guidance = WalkingGuidance(route);
    expect(guidance.onGpsFix(pts.first, accuracyMeters: 100), isNull);
  });

  test('손상된 Polyline은 오류가 발생함', () {
    expect(() => decodePolyline6('_'), throwsFormatException);
  });
}
