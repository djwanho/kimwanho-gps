import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

/// 공통 GPS 좌표 입력 포맷을 오프라인으로 읽습니다.
/// null인 경우 주소 검색이 필요한 입력으로 처리할 수 있습니다.
class GpsInputParser {
  static const _number = r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)';

  static LatLng? parse(String text) {
    final input = text.trim();
    if (input.isEmpty) return null;

    // GPX의 첫 번째 waypoint/trackpoint/routepoint를 목적지로 취급합니다.
    final gpxTag = RegExp(
      r'<(?:[A-Za-z][\w.-]*:)?(?:wpt|trkpt|rtept)\b[^>]*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(input);
    if (gpxTag != null) {
      final tag = gpxTag.group(0)!;
      final lat = RegExp(
        r'''(?:^|\s)lat\s*=\s*["'](''' + _number + r''')["']''',
        caseSensitive: false,
      ).firstMatch(tag);
      final lon = RegExp(
        r'''(?:^|\s)lon\s*=\s*["'](''' + _number + r''')["']''',
        caseSensitive: false,
      ).firstMatch(tag);
      if (lat != null && lon != null) {
        return _coordinate(lat.group(1), lon.group(1));
      }
      return null;
    }

    // GPS 텍스트 로그, DJI 자료: lat=, lng=, 위도: 등.
    final lat = RegExp(
      r'(?:^|[\s,;])(?:latitude|lat|위도)\s*[:=]\s*(' + _number + r')',
      caseSensitive: false,
    ).firstMatch(input);
    final lon = RegExp(
      r'(?:^|[\s,;])(?:longitude|long|lng|lon|경도)\s*[:=]\s*(' + _number + r')',
      caseSensitive: false,
    ).firstMatch(input);
    if (lat != null && lon != null) {
      return _coordinate(lat.group(1), lon.group(1));
    }

    // GPS: 37.5665, 126.9780 같은 로그 표기.
    if (input.toLowerCase().startsWith('gps:')) {
      return _decimalPair(input.substring(4));
    }

    // geo:37.5665,126.9780 형태의 Android 위치 URI.
    if (input.toLowerCase().startsWith('geo:')) {
      return _decimalPair(input.substring(4).split(';').first);
    }

    // 구글 지도의 좌표 링크.
    if (input.startsWith('https://') || input.startsWith('http://')) {
      final uri = Uri.tryParse(input);
      if (uri == null) return null;
      for (final key in ['q', 'query', 'destination', 'll']) {
        final candidate = uri.queryParameters[key];
        if (candidate != null) {
          final parsed = _decimalPair(candidate);
          if (parsed != null) return parsed;
        }
      }
      final pathCoord = RegExp(
        r'@(' + _number + r'),(' + _number + r')',
      ).firstMatch(uri.path);
      if (pathCoord != null) {
        return _coordinate(pathCoord.group(1), pathCoord.group(2));
      }
      return null;
    }

    // 도분초 DMS: 37°33'59.4"N 126°58'40.8"E
    final dms = RegExp(
      r'''([NSEW])?\s*(\d{1,3})\s*[°º]\s*(\d{1,2})\s*['′’]\s*(\d+(?:\.\d+)?)\s*(?:["″”])?\s*([NSEW])?''',
      caseSensitive: false,
    ).allMatches(input).toList();
    if (dms.length == 2) {
      final first = _dms(dms[0]), second = _dms(dms[1]);
      if (first == null || second == null) return null;
      final aDir = _direction(dms[0]);
      final bDir = _direction(dms[1]);
      if (aDir == null && bDir == null) {
        return _coordinateValues(first, second);
      }
      final aLat = aDir == 'N' || aDir == 'S';
      final aLon = aDir == 'E' || aDir == 'W';
      final bLat = bDir == 'N' || bDir == 'S';
      final bLon = bDir == 'E' || bDir == 'W';
      if (aLat && bLon) return _coordinateValues(first, second);
      if (aLon && bLat) return _coordinateValues(second, first);
      if (aLat && bDir == null) return _coordinateValues(first, second);
      if (aDir == null && bLon) return _coordinateValues(first, second);
      if (aLon && bDir == null) return _coordinateValues(second, first);
      if (aDir == null && bLat) return _coordinateValues(second, first);
      return null;
    }

    // 십진수: 37.5665,126.9780 / 37.5665 126.9780 / 37.5665;126.9780
    final plain = _decimalPair(input);
    if (plain != null) return plain;

    // 드론 좌표: N37.5665 E126.9780 / 37.5665°N 126.9780°E
    final prefixed = RegExp(
      r'^\s*([NS])\s*(' +
          _number +
          r')\s*[,;/\s]+\s*([EW])\s*(' +
          _number +
          r')\s*$',
      caseSensitive: false,
    ).firstMatch(input);
    if (prefixed != null) {
      final latitude = double.tryParse(prefixed.group(2)!);
      final longitude = double.tryParse(prefixed.group(4)!);
      if (latitude == null || longitude == null) return null;
      return _coordinateValues(
        prefixed.group(1)!.toUpperCase() == 'S'
            ? -latitude.abs()
            : latitude.abs(),
        prefixed.group(3)!.toUpperCase() == 'W'
            ? -longitude.abs()
            : longitude.abs(),
      );
    }
    final suffixed = RegExp(
      r'^\s*(' +
          _number +
          r')\s*°?\s*([NS])\s*[,;/\s]+\s*(' +
          _number +
          r')\s*°?\s*([EW])\s*$',
      caseSensitive: false,
    ).firstMatch(input);
    if (suffixed != null) {
      final latitude = double.tryParse(suffixed.group(1)!);
      final longitude = double.tryParse(suffixed.group(3)!);
      if (latitude == null || longitude == null) return null;
      return _coordinateValues(
        suffixed.group(2)!.toUpperCase() == 'S'
            ? -latitude.abs()
            : latitude.abs(),
        suffixed.group(4)!.toUpperCase() == 'W'
            ? -longitude.abs()
            : longitude.abs(),
      );
    }
    return null;
  }

  /// GPX/간단한 CSV/TXT에서 GPS 지점들을 읽습니다.
  /// GPX의 경로를 그대로 탐색하는 기능은 아닙니다.
  static List<LatLng> parseFileText(String text) {
    final result = <LatLng>[];

    // GPX는 XML 문서입니다. 접두사(gpx:trkpt), 기본 namespace,
    // 속성 순서가 다른 장비 출력물도 처리하도록 XML로 파싱합니다.
    if (text.trimLeft().startsWith('<')) {
      late final XmlDocument document;
      try {
        document = XmlDocument.parse(text);
      } on XmlException {
        throw const FormatException('GPX XML 문서가 손상되었거나 유효하지 않습니다.');
      }
      if (document.rootElement.localName.toLowerCase() != 'gpx') {
        throw const FormatException('GPX 파일이 아닙니다. XML 최상위 요소를 확인하세요.');
      }
      for (final element in document.descendantElements) {
        final kind = element.localName.toLowerCase();
        if (kind != 'wpt' && kind != 'trkpt' && kind != 'rtept') continue;
        String? latitude, longitude;
        for (final attribute in element.attributes) {
          final name = attribute.name.local.toLowerCase();
          if (name == 'lat') latitude = attribute.value;
          if (name == 'lon') longitude = attribute.value;
        }
        final point = _coordinate(latitude, longitude);
        if (point != null) result.add(point);
        // 앱은 첫/마지막 지점만 목적지로 사용하므로
        // 한 파일당 허용할 지점 수에 안전 상한을 둡니다.
        if (result.length >= 100000) break;
      }
      return result;
    }

    final lines = text.split(RegExp(r'\r?\n')).take(5000).toList();
    if (lines.length > 1) {
      final headers = lines.first
          .toLowerCase()
          .split(',')
          .map(
            (field) => field.trim().replaceAll('"', ''),
          )
          .toList();
      final latIdx = headers.indexWhere(
        (field) => ['lat', 'latitude', '위도'].contains(field),
      );
      final lonIdx = headers.indexWhere(
        (field) => ['lon', 'lng', 'long', 'longitude', '경도'].contains(field),
      );
      if (latIdx >= 0 && lonIdx >= 0) {
        for (final row in lines.skip(1)) {
          final fields = row.split(',');
          if (fields.length <= latIdx || fields.length <= lonIdx) continue;
          final point = _coordinate(
            fields[latIdx].trim().replaceAll('"', ''),
            fields[lonIdx].trim().replaceAll('"', ''),
          );
          if (point != null) result.add(point);
        }
        if (result.isNotEmpty) return result;
      }
    }
    for (final line in lines) {
      final point = parse(line);
      if (point != null) result.add(point);
    }
    return result;
  }

  static String? _direction(RegExpMatch match) =>
      (match.group(1) ?? match.group(5))?.toUpperCase();

  static double? _dms(RegExpMatch match) {
    final degrees = double.tryParse(match.group(2)!);
    final minutes = double.tryParse(match.group(3)!);
    final seconds = double.tryParse(match.group(4)!);
    if (degrees == null ||
        minutes == null ||
        seconds == null ||
        minutes >= 60 ||
        seconds >= 60) {
      return null;
    }
    final dir = _direction(match);
    final signed = degrees + minutes / 60 + seconds / 3600;
    return dir == 'S' || dir == 'W' ? -signed : signed;
  }

  static LatLng? _decimalPair(String text) {
    final match = RegExp(
      r'^\s*(' + _number + r')\s*(?:[,;]|\s+)\s*(' + _number + r')\s*$',
    ).firstMatch(text);
    if (match == null) return null;
    return _coordinate(match.group(1), match.group(2));
  }

  static LatLng? _coordinate(String? lat, String? lon) {
    return _coordinateValues(
      double.tryParse(lat ?? '') ?? double.nan,
      double.tryParse(lon ?? '') ?? double.nan,
    );
  }

  static LatLng? _coordinateValues(double latitude, double longitude) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }
    return LatLng(latitude, longitude);
  }
}
