import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// 원본 Valhalla JSON 응답: 하나의 출발지-목적지 보행 경로.
class WalkingVoiceRoute {
  WalkingVoiceRoute({
    required this.points,
    required this.maneuvers,
    required this.totalMeters,
    required this.totalSeconds,
  });

  final List<LatLng> points;
  final List<WalkingManeuver> maneuvers;
  final int totalMeters;
  final int totalSeconds;

  /// Valhalla 기본 JSON은 1e-6 정밀도의 encoded polyline을 반환합니다.
  static WalkingVoiceRoute fromValhalla(Map<String, dynamic> json) {
    final trip = json['trip'] as Map<String, dynamic>;
    final legs = trip['legs'] as List<dynamic>;
    if (legs.length != 1) {
      throw const FormatException('한 개의 도보 구간만 지원합니다.');
    }
    final leg = legs.single as Map<String, dynamic>;
    final rawShape = leg['shape'];
    if (rawShape is! String || rawShape.length > 500000) {
      throw const FormatException('경로 좌표 데이터가 잘못됐거나 너무 큽니다.');
    }
    final points = decodePolyline6(rawShape);
    if (points.length > 30000) {
      throw const FormatException('경로 지점 수가 너무 많습니다.');
    }
    if (points.length < 2) {
      throw const FormatException('보행 경로 좌표가 없습니다.');
    }

    final distances = <double>[0.0];
    for (var i = 1; i < points.length; i++) {
      distances.add(distances.last + metersBetween(points[i - 1], points[i]));
    }

    final maneuvers = <WalkingManeuver>[];
    for (final raw in (leg['maneuvers'] as List<dynamic>? ?? [])) {
      final m = raw as Map<String, dynamic>;
      final rawIndex = m['begin_shape_index'];
      if (rawIndex is! num || !rawIndex.isFinite) continue;
      final shapeIndex = rawIndex.toInt();
      if (shapeIndex < 0 || shapeIndex >= points.length) continue;
      maneuvers.add(
        WalkingManeuver(
          type: (m['type'] as num).toInt(),
          shapeIndex: shapeIndex,
          metersFromStart: distances[shapeIndex],
        ),
      );
    }
    // Valhalla distance 단위: kilometers, time 단위: seconds.
    final summary =
        trip['summary'] as Map<String, dynamic>? ??
        leg['summary'] as Map<String, dynamic>? ??
        {};
    final rawLength = summary['length'];
    final rawDuration = summary['time'];
    final lengthKm = rawLength is num && rawLength.isFinite && rawLength >= 0
        ? rawLength.toDouble()
        : null;
    final durationSeconds =
        rawDuration is num && rawDuration.isFinite && rawDuration >= 0
        ? rawDuration.toDouble()
        : null;
    return WalkingVoiceRoute(
      points: points,
      maneuvers: maneuvers,
      totalMeters: lengthKm == null
          ? distances.last.round()
          : (lengthKm * 1000).round(),
      totalSeconds: durationSeconds?.round() ?? 0,
    );
  }

  /// 최신 GPS 측정값에 가장 가까운 경로선상 위치와 경로 진행 거리를 찾습니다.
  RouteMatch locate(LatLng current) {
    var bestLateral = double.infinity;
    var bestAlong = 0.0;
    var cumulative = 0.0;
    final latitudeFactor = 111195.0;
    final longitudeFactor =
        latitudeFactor * math.cos(current.latitude * math.pi / 180);

    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final ax = (a.longitude - current.longitude) * longitudeFactor;
      final ay = (a.latitude - current.latitude) * latitudeFactor;
      final bx = (b.longitude - current.longitude) * longitudeFactor;
      final by = (b.latitude - current.latitude) * latitudeFactor;
      final dx = bx - ax;
      final dy = by - ay;
      final denom = dx * dx + dy * dy;
      final fraction = denom < 0.000001
          ? 0.0
          : ((-ax * dx - ay * dy) / denom).clamp(0.0, 1.0).toDouble();
      final nearestX = ax + dx * fraction;
      final nearestY = ay + dy * fraction;
      final lateral = math.sqrt(nearestX * nearestX + nearestY * nearestY);
      final segmentLength = metersBetween(a, b);
      if (lateral < bestLateral) {
        bestLateral = lateral;
        bestAlong = cumulative + segmentLength * fraction;
      }
      cumulative += segmentLength;
    }
    return RouteMatch(alongMeters: bestAlong, lateralMeters: bestLateral);
  }
}

/// GPS 현재 위치를 기준으로 전체화면 안내판에 표시할 경로 상태.
/// 실제 도로 경로상의 진행 거리로 계산하며, 목적지 직선거리와 다릅니다.
class NavigationSnapshot {
  const NavigationSnapshot({
    required this.remainingMeters,
    required this.nextInstruction,
    required this.offRoute,
  });

  final int remainingMeters;
  final String nextInstruction;
  final bool offRoute;
}

NavigationSnapshot navigationSnapshot(
  WalkingVoiceRoute route,
  LatLng position, {
  RouteMatch? match,
}) {
  final matched = match ?? route.locate(position);
  final remaining = math
      .max(0, route.totalMeters - matched.alongMeters)
      .round();
  if (matched.lateralMeters > 60) {
    return NavigationSnapshot(
      remainingMeters: remaining,
      nextInstruction: '경로에서 벗어났습니다. 경로를 다시 조회하세요.',
      offRoute: true,
    );
  }
  for (final m in route.maneuvers) {
    final command = m.koreanCommand;
    if (command == null) continue;
    final toTurn = m.metersFromStart - matched.alongMeters;
    if (toTurn < -12) continue;
    final description = toTurn <= 15
        ? '곧 $command'
        : '약 ${(toTurn / 10).round() * 10}미터 앞에서 $command';
    return NavigationSnapshot(
      remainingMeters: remaining,
      nextInstruction: description,
      offRoute: false,
    );
  }
  return NavigationSnapshot(
    remainingMeters: remaining,
    nextInstruction: '경로를 따라 계속 이동하세요.',
    offRoute: false,
  );
}

class RouteMatch {
  const RouteMatch({required this.alongMeters, required this.lateralMeters});
  final double alongMeters;
  final double lateralMeters;
}

class WalkingManeuver {
  const WalkingManeuver({
    required this.type,
    required this.shapeIndex,
    required this.metersFromStart,
  });
  final int type;
  final int shapeIndex;
  final double metersFromStart;

  /// Valhalla numeric maneuver types:
  /// https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/
  String? get koreanCommand {
    switch (type) {
      case 9:
        return '완만하게 우회전하세요';
      case 10:
        return '우회전하세요';
      case 11:
        return '급하게 우회전하세요';
      case 12:
      case 13:
        return '유턴하세요';
      case 14:
        return '급하게 좌회전하세요';
      case 15:
        return '좌회전하세요';
      case 16:
        return '완만하게 좌회전하세요';
      case 17:
        return '진입로를 따라 직진하세요';
      case 18:
      case 20:
      case 23:
      case 37:
        return '오른쪽 길로 진행하세요';
      case 19:
      case 21:
      case 24:
      case 38:
        return '왼쪽 길로 진행하세요';
      case 25:
        return '합류 도로로 진행하세요';
      case 26:
        return '회전교차로로 진입하세요';
      case 27:
        return '회전교차로에서 빠져나오세요';
      case 28:
        return '여객선 승선 지점으로 이동하세요';
      case 29:
        return '여객선에서 내리세요';
      case 39:
        return '엘리베이터를 이용하세요';
      case 40:
        return '계단을 이용하세요';
      case 41:
        return '에스컬레이터를 이용하세요';
      case 42:
        return '건물 안으로 들어가세요';
      case 43:
        return '건물 밖으로 나가세요';
      default:
        return null;
    }
  }
}

/// UI 및 음성 합성과 독립적으로 GPS 갱신 1회당 최대 1개의 문구만 반환.
class WalkingGuidance {
  WalkingGuidance(this.route);

  final WalkingVoiceRoute route;
  final Set<int> _announced = {};
  double _progressMeters = 0;
  int _offRouteFixes = 0;
  int _arrivalFixes = 0;
  DateTime? _lastOffRouteWarning;
  bool active = true;
  double _lastDistanceAnnouncementAt = 0;

  String? onGpsFix(
    LatLng current, {
    required double accuracyMeters,
    DateTime? now,
    RouteMatch? match,
  }) {
    if (!active || !accuracyMeters.isFinite || accuracyMeters > 35) return null;
    final time = now ?? DateTime.now();
    final located = match ?? route.locate(current);

    if (located.lateralMeters > 55) {
      _offRouteFixes++;
      _arrivalFixes = 0;
      if (_offRouteFixes >= 3 &&
          (_lastOffRouteWarning == null ||
              time.difference(_lastOffRouteWarning!).inSeconds >= 90)) {
        _lastOffRouteWarning = time;
        return '경로에서 벗어났습니다. 지도를 확인하고 경로를 다시 조회하세요.';
      }
      return null;
    }

    _offRouteFixes = 0;
    _progressMeters = math.max(_progressMeters, located.alongMeters);

    // GPS 오차나 목적지와 평행한 길 때문에 잘못된 도착 판정을 피함.
    final toDestination = metersBetween(current, route.points.last);
    final closeToFinish =
        toDestination <= 20 &&
        _progressMeters >= route.locate(route.points.last).alongMeters - 55;
    _arrivalFixes = closeToFinish ? _arrivalFixes + 1 : 0;
    if (_arrivalFixes >= 2) {
      active = false;
      return '목적지 근처에 도착했습니다. 주변을 확인하세요.';
    }

    for (var i = 0; i < route.maneuvers.length; i++) {
      final maneuver = route.maneuvers[i];
      final command = maneuver.koreanCommand;
      if (command == null || _announced.contains(i)) continue;
      final remaining = maneuver.metersFromStart - _progressMeters;
      if (remaining < -12) {
        _announced.add(i);
        continue;
      }
      if (remaining <= 45) {
        _announced.add(i);
        if (remaining <= 15) return '곧 $command';
        final rounded = (remaining / 10).round() * 10;
        return '약 $rounded미터 앞에서 $command';
      }
      // 경로상 다음 지점들은 미래 지점이므로 여기서 중단합니다.
      break;
    }
    // 길이 긴 도보 구간에서는 이용자가 음성안내 작동을 확인할 수 있도록
    // 실제 경로 진행거리 기준으로 가끔 남은 거리를 읽어줍니다.
    if (route.totalMeters > 200 &&
        _progressMeters - _lastDistanceAnnouncementAt >= 150) {
      _lastDistanceAnnouncementAt = _progressMeters;
      final remaining = (route.totalMeters - _progressMeters)
          .clamp(0.0, route.totalMeters.toDouble())
          .round();
      return '경로를 따라 계속 이동하세요. 목적지까지 약 $remaining미터 남았습니다.';
    }
    return null;
  }
}

List<LatLng> decodePolyline6(String polyline) {
  var index = 0;
  var latitude = 0;
  var longitude = 0;
  final points = <LatLng>[];

  int readSigned() {
    var value = 0;
    var shift = 0;
    while (true) {
      if (index >= polyline.length || shift > 35) {
        throw const FormatException('손상된 경로 좌표입니다.');
      }
      final byte = polyline.codeUnitAt(index++) - 63;
      if (byte < 0 || byte > 63) {
        throw const FormatException('경로 좌표 형식이 올바르지 않습니다.');
      }
      value |= (byte & 0x1f) << shift;
      shift += 5;
      if (byte < 0x20) break;
    }
    return (value & 1) != 0 ? ~(value >> 1) : value >> 1;
  }

  while (index < polyline.length) {
    latitude += readSigned();
    longitude += readSigned();
    points.add(LatLng(latitude / 1000000, longitude / 1000000));
  }
  return points;
}

double metersBetween(LatLng a, LatLng b) {
  const earthRadiusMeters = 6371008.8;
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final dlat = (b.latitude - a.latitude) * math.pi / 180;
  final dlon = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.sin(dlat / 2) * math.sin(dlat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) * math.sin(dlon / 2);
  return earthRadiusMeters * 2 * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}
