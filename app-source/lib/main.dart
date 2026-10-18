import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'navigation/direction_sector.dart';
import 'navigation/favorite_places.dart';
import 'navigation/save_favorite_dialog.dart';
import 'navigation/walking_guidance.dart';
import 'navigation/off_route_monitor.dart';
import 'navigation/gps_recovery_policy.dart';
import 'navigation/gps_input_parser.dart';

const _routeEndpoint = String.fromEnvironment(
  'ROUTE_ENDPOINT',
  defaultValue: 'https://valhalla1.openstreetmap.de/route',
);
const _appClientId = 'com.kimwanho.gpswalknavigator';
const _privacyPolicyUrl = String.fromEnvironment('PRIVACY_POLICY_URL');
const _pipChannel = MethodChannel('com.kimwanho.gpswalknavigator/pip');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WalkingNavigatorApp());
}

class WalkingNavigatorApp extends StatelessWidget {
  const WalkingNavigatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GPS 통합 도보 길안내',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1765D1)),
        useMaterial3: true,
      ),
      home: const WalkingHomePage(),
    );
  }
}

class WalkingHomePage extends StatefulWidget {
  const WalkingHomePage({super.key});

  @override
  State<WalkingHomePage> createState() => _WalkingHomePageState();
}

class _WalkingHomePageState extends State<WalkingHomePage>
    with WidgetsBindingObserver {
  final _destinationController =
      TextEditingController(text: '37.5665, 126.9780');
  final _geocoder = Geocoding();
  bool _resolvingDestination = false;
  int _destinationRequest = 0;
  String _destinationLabel = 'GPS 좌표';
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _locationSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  double? _compassHeading;
  DateTime? _compassTime;
  DateTime? _compassRenderTime;
  final FavoritePlacesStorage _favoriteStorage = FavoritePlacesStorage();
  List<FavoritePlace> _favorites = [];

  LatLng _destination = const LatLng(37.5665, 126.9780);
  Position? _position;
  String _status = '주소 또는 GPS 좌표를 입력하고 목적지 설정을 누르세요.';
  bool _locating = false;
  bool _routing = false;
  List<LatLng> _routePoints = [];
  int? _walkingMeters;
  int? _walkingSeconds;
  final FlutterTts _tts = FlutterTts();
  late final Future<void> _ttsSetup;
  WalkingVoiceRoute? _voiceRoute;
  WalkingGuidance? _guidance;
  bool _voiceOn = false;
  bool _fullScreenNavigation = false;
  bool _isInPip = false;
  bool _pipSupported = false;
  bool _foregroundLocation = false;
  Future<void> _locationModeOperation = Future<void>.value();
  bool _followGps = true;
  bool _startingNavigation = false;
  bool _rerouting = false;
  bool _rerouteFailed = false;
  int _navigationEpoch = 0;
  int _initialRouteEpoch = 0;
  final OffRouteMonitor _offRouteMonitor = OffRouteMonitor();
  int _directArrivalFixes = 0;
  RouteMatch? _lastRouteMatch;
  WalkingVoiceRoute? _lastMatchedRoute;
  DateTime? _lastMapMoveAt;
  DateTime? _lastGpsReceivedAt;
  Timer? _gpsHealthTicker;
  // 스트림과 단발성 위치 조회를 분리하여, 스트림 중단을 조용히 숨기지 않습니다.
  Future<void> _gpsStreamOperation = Future<void>.value();
  int _gpsStreamGeneration = 0;
  DateTime? _gpsStreamOpenedAt;
  DateTime? _lastGpsStreamFixAt;
  DateTime? _lastGpsPollAt;
  DateTime? _lastGpsRestartAt;
  bool _gpsPollBusy = false;
  bool _gpsRestartBusy = false;
  bool _gpsPermissionReady = false;
  int _gpsDiagnosticFixCount = 0;
  bool _ttsAvailable = true;
  int _speechEpoch = 0;
  String _voiceStatus = '음성안내를 시작하려면 도보 경로를 먼저 조회하세요.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ttsSetup = _configureTts();
    _startLocationUpdates();
    _gpsHealthTicker = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      // 이 타이머는 화면만 다시 그리는 것이 아니라 GPS 수신 중단을
      // 감지하여 현재 위치 조회 + 실시간 스트림 복구까지 실행합니다.
      if (!_isInPip) setState(() {});
      _checkGpsHealth();
    });
    _loadFavorites();
    _setupPictureInPicture();
  }

  Future<void> _setupPictureInPicture() async {
    if (!Platform.isAndroid) return;
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'pipModeChanged' && mounted) {
        final pip = call.arguments == true;
        setState(() => _isInPip = pip);
        if (pip) _centerOnCurrentLocation();
      }
    });
    try {
      final supported = await _pipChannel.invokeMethod<bool>('isSupported');
      final inPip = await _pipChannel.invokeMethod<bool>('isInPip');
      if (mounted) {
        setState(() {
          _pipSupported = supported ?? false;
          _isInPip = inPip ?? false;
        });
      }
    } catch (e) {
      debugPrint('PiP setup unavailable: $e');
    }
  }

  Future<void> _setPipNavigationActive(bool active) async {
    if (!Platform.isAndroid) return;
    try {
      await _pipChannel.invokeMethod<bool>('setNavigationActive', active);
    } catch (e) {
      debugPrint('PiP update failed: $e');
    }
  }

  Future<void> _enterPipWindow() async {
    if (!_voiceOn || !_fullScreenNavigation) return;
    try {
      final ok = await _pipChannel.invokeMethod<bool>('enterPip');
      if (ok != true && mounted) {
        _notify('작은 지도 창을 열 수 없습니다. 휴대폰의 PIP 권한을 확인하세요.');
      }
    } catch (e) {
      _notify('PIP 전환을 사용할 수 없습니다: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _gpsPermissionReady) {
      // 통화/다른 앱에서 돌아오면 오래된 지도 점을 두지 않습니다.
      unawaited(_pollGpsOnce(force: true));
      _checkGpsHealth();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navigationEpoch++;
    _initialRouteEpoch++;
    _gpsHealthTicker?.cancel();
    _gpsStreamGeneration++; // 종료 후 도착한 이전 스트림 이벤트 무효화.
    _locationSubscription?.cancel();
    _compassSubscription?.cancel();
    _tts.stop();
    unawaited(_setPipNavigationActive(false));
    _pipChannel.setMethodCallHandler(null);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _mapController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  void _notify(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  Future<void> _configureTts() async {
    try {
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.setAudioAttributesForNavigation();
    } catch (e) {
      _ttsAvailable = false;
      _notify('한국어 음성 엔진 초기화 실패: $e');
    }
  }

  Future<void> _speak(String message, {bool isTest = false}) async {
    final epoch = ++_speechEpoch;
    try {
      await _ttsSetup;
      if (!_ttsAvailable) {
        _notify('갤럭시의 한국어 TTS 음성을 설정한 후 다시 실행하세요.');
        return;
      }
      if (!mounted || epoch != _speechEpoch || (!isTest && !_voiceOn)) {
        return;
      }
      await _tts.stop();
      if (!mounted || epoch != _speechEpoch || (!isTest && !_voiceOn)) {
        return;
      }
      await _tts.speak(message, focus: true);
    } catch (e) {
      if (mounted && epoch == _speechEpoch) {
        _notify('음성 출력 실패: 갤럭시 TTS 한국어 음성 설정을 확인하세요. ($e)');
      }
    }
  }

  void _startCompass() {
    if (_compassSubscription != null) {
      return;
    }
    final stream = FlutterCompass.events;
    if (stream == null) {
      return; // 나침반이 없는 기기에서는 이동방향만 활용
    }
    _compassSubscription = stream.listen(
      (event) {
        final heading = event.heading;
        if (!mounted ||
            !_fullScreenNavigation ||
            !_voiceOn ||
            heading == null ||
            !heading.isFinite) {
          return;
        }
        final now = DateTime.now();
        // 잦은 센서 업데이트로 지도 전체를 계속 다시 그리지 않도록 제한.
        if (_compassRenderTime != null &&
            now.difference(_compassRenderTime!) <
                const Duration(milliseconds: 300)) {
          return;
        }
        _compassRenderTime = now;
        setState(() {
          _compassHeading = (heading % 360 + 360) % 360;
          _compassTime = now;
        });
      },
      onError: (Object error) {
        debugPrint('Compass unavailable: $error');
      },
    );
  }

  void _stopCompass() {
    _compassSubscription?.cancel();
    _compassSubscription = null;
    _compassHeading = null;
    _compassTime = null;
    _compassRenderTime = null;
  }

  double? get _currentDirectionDegrees {
    final position = _position;
    if (position == null) return null;
    // 보행 중 GPS 이동방향은 센서 방향보다 실제 진행방향에 가까움.
    if (position.speed >= 0.9 &&
        position.accuracy <= 60 &&
        position.heading.isFinite &&
        position.heading >= 0 &&
        position.heading < 360) {
      return position.heading;
    }
    // 멈춘 상태에서는 장치가 바라보는 방향 표시(자기북 기준).
    if (_compassHeading != null &&
        _compassTime != null &&
        DateTime.now().difference(_compassTime!) < const Duration(seconds: 5)) {
      return _compassHeading;
    }
    return null; // 방향 값을 모르는데 임의로 북쪽을 표시하지 않습니다.
  }

  Future<void> _loadFavorites() async {
    try {
      final list = await _favoriteStorage.load();
      if (mounted) setState(() => _favorites = list);
    } catch (error) {
      _notify('즐겨찾기를 불러오지 못했습니다: $error');
    }
  }

  Future<void> _persistFavorites(List<FavoritePlace> next) async {
    try {
      await _favoriteStorage.save(next);
      if (mounted) setState(() => _favorites = next);
    } catch (error) {
      _notify('즐겨찾기 저장 실패: $error');
    }
  }

  Future<void> _onMapLongPress(LatLng pressed) async {
    if (_fullScreenNavigation && _followGps) {
      setState(() => _followGps = false); // 선택 중 지도 자동 중앙이동 중지
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
            title: Text('즐겨찾기에 저장할 위치'),
            subtitle: Text('길게 누른 장소 또는 현재 GPS 위치를 선택하세요.'),
          ),
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: const Text('지도에서 누른 지점 저장'),
            subtitle: Text(
              '${pressed.latitude.toStringAsFixed(6)}, '
              '${pressed.longitude.toStringAsFixed(6)}',
            ),
            onTap: () => Navigator.pop(context, 'pressed'),
          ),
          ListTile(
            enabled: _position != null,
            leading: const Icon(Icons.my_location),
            title: const Text('내 현재 GPS 위치 저장'),
            subtitle: Text(_position == null
                ? 'GPS 신호를 먼저 확인하세요.'
                : '${_position!.latitude.toStringAsFixed(6)}, '
                    '${_position!.longitude.toStringAsFixed(6)}'),
            onTap: _position == null
                ? null
                : () => Navigator.pop(context, 'current'),
          ),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    final position = _position;
    final coords = choice == 'current' && position != null
        ? LatLng(position.latitude, position.longitude)
        : pressed;
    await _saveFavoriteAt(
      coords,
      suggestedName: choice == 'current' ? '현재 위치' : '지도 저장 위치',
    );
  }

  Future<void> _saveFavoriteAt(LatLng coords,
      {required String suggestedName}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => SaveFavoriteDialog(
        coords: coords,
        suggestedName: '$suggestedName ${_favorites.length + 1}',
      ),
    );
    if (!mounted || name == null) return;
    if (_favorites.length >= 200) {
      _notify('즐겨찾기는 최대 200개까지 저장할 수 있습니다.');
      return;
    }
    final place = FavoritePlace(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      latitude: coords.latitude,
      longitude: coords.longitude,
    );
    await _persistFavorites([..._favorites, place]);
    if (mounted && _favorites.any((x) => x.id == place.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('즐겨찾기 "$name"을 저장했습니다.')),
      );
    }
  }

  Future<void> _showFavorites() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * .55,
          child: Column(children: [
            const ListTile(
              title: Text('즐겨찾기'),
              subtitle: Text('장소를 선택하면 목적지로 지정하고 도보 경로를 조회합니다.'),
            ),
            Expanded(
              child: _favorites.isEmpty
                  ? const Center(
                      child: Text(
                      '저장된 장소가 없습니다.\n지도에서 꾹 눌러 저장해 보세요.',
                      textAlign: TextAlign.center,
                    ))
                  : ListView.builder(
                      itemCount: _favorites.length,
                      itemBuilder: (context, i) {
                        final place = _favorites[i];
                        return ListTile(
                          leading: const Icon(Icons.star, color: Colors.amber),
                          title: Text(place.name),
                          subtitle: Text(
                            '${place.latitude.toStringAsFixed(6)}, '
                            '${place.longitude.toStringAsFixed(6)}',
                          ),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _selectFavorite(place);
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '${place.name} 삭제',
                            onPressed: () async {
                              Navigator.pop(sheetContext);
                              final approved = await showDialog<bool>(
                                context: this.context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('즐겨찾기 삭제'),
                                  content: Text('"${place.name}"을 삭제하시겠습니까?'),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('취소'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('삭제'),
                                    ),
                                  ],
                                ),
                              );
                              if (approved == true && mounted) {
                                await _persistFavorites(_favorites
                                    .where((x) => x.id != place.id)
                                    .toList());
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _selectFavorite(FavoritePlace place) async {
    if (_routing) {
      _notify('경로 조회 중에는 목적지를 변경할 수 없습니다.');
      return;
    }
    final target = LatLng(place.latitude, place.longitude);
    _destinationController.text =
        '${place.latitude.toStringAsFixed(7)}, ${place.longitude.toStringAsFixed(7)}';
    _applyDestination(target, label: '즐겨찾기: ${place.name}');
    await _loadWalkingRoute();
    if (mounted && _voiceRoute != null) {
      _notify('저장된 장소까지의 도보 경로가 준비됐습니다. 음성안내를 시작하세요.');
    }
  }

  /// GPS 스트림 콜백은 예외를 바깥으로 전파하지 않습니다.
  /// 오프루트 감지와 실제 보행 경로 요청은 별도 비동기로 실행합니다.
  void _onPosition(Position p) {
    if (!mounted) return;
    if (!p.latitude.isFinite ||
        !p.longitude.isFinite ||
        p.latitude < -90 ||
        p.latitude > 90 ||
        p.longitude < -180 ||
        p.longitude > 180) {
      return;
    }
    try {
      // 먼저 도착한 최신 위치를 나중에 끝난 getCurrentPosition()의
      // 오래된 캐시 위치가 다시 덮어쓰지 않도록 막습니다.
      final previous = _position;
      if (previous != null &&
          p.timestamp.isBefore(
            previous.timestamp.subtract(const Duration(seconds: 2)),
          )) {
        debugPrint('[NAV-GPS] discarded out-of-order fix: ${p.timestamp}');
        return;
      }
      _lastGpsReceivedAt = DateTime.now();
      // 경로 매칭이나 회전 안내가 실패하더라도 파란 현재 위치 점은
      // 반드시 최신 GPS 좌표로 먼저 업데이트해야 합니다.
      setState(() => _position = p);
      if (_followGps && _fullScreenNavigation) {
        _centerOnCurrentLocation();
      }
      // 새 위치는 기록하되 보행 경로 선분 매칭은 GPS 1회당 한 번만 수행합니다.
      // 자동차 속도로 좌표가 바뀌어도 렌더링에서 같은 경로를 반복 계산하지 않습니다.
      final guide = _guidance;
      final navigating = _voiceOn && guide != null && _fullScreenNavigation;
      final point = LatLng(p.latitude, p.longitude);
      RouteMatch? match;
      if (navigating) {
        match = guide.route.locate(point);
        if (!match.lateralMeters.isFinite || !match.alongMeters.isFinite) {
          debugPrint('GPS route match invalid: ${match.lateralMeters}');
          return;
        }
      }
      _lastMatchedRoute = navigating ? guide.route : null;
      _lastRouteMatch = match;
      if (!navigating || _rerouting || match == null) {
        return;
      }
      _gpsDiagnosticFixCount++;
      if (_gpsDiagnosticFixCount % 15 == 0) {
        debugPrint('[NAV-GPS] speed=${p.speed.toStringAsFixed(1)}m/s '
            'accuracy=${p.accuracy.toStringAsFixed(1)}m '
            'deviation=${match.lateralMeters.toStringAsFixed(0)}m');
      }
      // 지름길로 목적지에 바로 도착한 경우 기존 경로선 위에 없더라도
      // 연속 2회 정확한 측정값으로 도착을 판단합니다.
      if (p.accuracy.isFinite &&
          p.accuracy <= 25 &&
          metersBetween(point, _destination) <= 20) {
        _directArrivalFixes++;
      } else {
        _directArrivalFixes = 0;
      }
      if (_directArrivalFixes >= 2) {
        _guidance = null;
        _offRouteMonitor.resetSession();
        _stopCompass();
        setState(() {
          _voiceOn = false;
          _voiceStatus = '목적지 근처에 도착했습니다. 주변을 확인하세요.';
        });
        unawaited(_setPipNavigationActive(false));
        unawaited(_setNavigationLocationMode(false));
        unawaited(_speak(
          '목적지 근처에 도착했습니다. 주변을 확인하세요.',
          isTest: true,
        ));
        return;
      }
      final shouldReroute = _offRouteMonitor.observe(
        lateralMeters: match.lateralMeters,
        accuracyMeters: p.accuracy,
        speedMetersPerSecond: p.speed,
        now: DateTime.now(),
      );
      if (shouldReroute) {
        debugPrint('[NAV-REROUTE] trigger '
            'deviation=${match.lateralMeters.toStringAsFixed(0)}m');
        unawaited(_rerouteFromPosition(p));
        return;
      }
      // 기존 경로에서 멀리 벗어난 동안 과거 회전 지시를 읽지 않습니다.
      // GPS 정확도 기준이 나쁘면 정상적인 안내도 잠시 건너뜁니다.
      if (!p.accuracy.isFinite ||
          p.accuracy > 35 ||
          match.lateralMeters > _offRouteMonitor.thresholdMeters) {
        return;
      }

      if (_rerouteFailed) {
        setState(() {
          _rerouteFailed = false;
          _voiceStatus = '기존 경로에 복귀했습니다. 안내를 계속합니다.';
        });
      }
      final message = guide.onGpsFix(
        point,
        accuracyMeters: p.accuracy,
        match: match,
      );
      if (!guide.active) {
        _offRouteMonitor.resetSession();
        _guidance = null;
        setState(() {
          _voiceOn = false;
          _voiceStatus = message ?? '목적지 근처에 도착했습니다.';
        });
        _stopCompass();
        unawaited(_setPipNavigationActive(false));
        unawaited(_setNavigationLocationMode(false));
        unawaited(_speak(
          message ?? '목적지 근처에 도착했습니다.',
          isTest: true,
        ));
        return;
      }
      if (message != null) {
        setState(() => _voiceStatus = message);
        unawaited(_speak(message));
      }
    } catch (error, stack) {
      debugPrint('GPS 안내 처리 오류: $error\n$stack');
      if (mounted) {
        setState(() => _voiceStatus = '일시적인 GPS 안내 오류입니다. 위치 확인을 계속합니다.');
      }
    }
  }

  void _stopVoice({bool updateStatus = true}) {
    _navigationEpoch++;
    _speechEpoch++;
    _offRouteMonitor.resetSession();
    _lastRouteMatch = null;
    _lastMatchedRoute = null;
    _directArrivalFixes = 0;
    _rerouting = false;
    _rerouteFailed = false;
    _stopCompass();
    _guidance = null;
    _voiceOn = false;
    unawaited(_setPipNavigationActive(false));
    unawaited(_setNavigationLocationMode(false));
    unawaited(_tts.stop().catchError((Object _) {}));
    if (mounted && updateStatus) {
      setState(() => _voiceStatus = '음성안내를 중지했습니다.');
    }
  }

  /// 현재 위치에서 기존 목적지로 요청하며, 실패해도 이전 경로와 지도를 유지합니다.
  Future<void> _rerouteFromPosition(Position location,
      {bool manual = false}) async {
    if (_rerouting || !_voiceOn || !_fullScreenNavigation || !mounted) {
      return;
    }
    if (!location.latitude.isFinite ||
        !location.longitude.isFinite ||
        location.latitude.abs() > 90 ||
        location.longitude.abs() > 180) {
      return;
    }
    if (!manual &&
        (!location.accuracy.isFinite ||
            location.accuracy < 0 ||
            location.accuracy > _offRouteMonitor.maxAccuracyMeters)) {
      return;
    }

    final epoch = _navigationEpoch;
    final destination = _destination;
    final startingPoint = LatLng(location.latitude, location.longitude);
    if (manual) _offRouteMonitor.markAttempt(DateTime.now());
    debugPrint('[NAV-REROUTE] start manual=$manual '
        'speed=${location.speed.toStringAsFixed(1)}m/s '
        'lat=${location.latitude.toStringAsFixed(6)} '
        'lon=${location.longitude.toStringAsFixed(6)}');

    setState(() {
      _rerouting = true;
      _rerouteFailed = false;
      _voiceStatus = '경로 재탐색 중...';
    });
    unawaited(_speak('경로를 벗어났습니다. 새로운 경로를 탐색합니다.'));
    try {
      final newRoute = await _fetchWalkingRoute(startingPoint, destination);
      if (!mounted ||
          epoch != _navigationEpoch ||
          !_voiceOn ||
          !_fullScreenNavigation) {
        return;
      }
      if (newRoute.maneuvers.isEmpty) {
        throw const FormatException('회전 안내 데이터가 없는 경로입니다.');
      }
      final updatedGuidance = WalkingGuidance(newRoute);
      setState(() {
        _routePoints = newRoute.points;
        _voiceRoute = newRoute;
        _guidance = updatedGuidance;
        _lastRouteMatch = null;
        _lastMatchedRoute = null;
        _walkingMeters = newRoute.totalMeters;
        _walkingSeconds = newRoute.totalSeconds;
        _voiceOn = true;
        _rerouteFailed = false;
        _voiceStatus = '새로운 경로로 안내를 시작합니다.';
        _status = '현재 GPS 위치에서 새 도보 경로를 찾았습니다.';
      });
      _offRouteMonitor.resetConsecutive();
      debugPrint('[NAV-REROUTE] success points=${newRoute.points.length}');
      // 새 경로의 첫 회전 안내는 다음 GPS 갱신 시 WalkingGuidance가 처리.
      unawaited(_speak('새로운 경로로 안내를 시작합니다.'));
    } catch (error, stack) {
      debugPrint('자동 경로 재탐색 실패: $error\n$stack');
      if (mounted && epoch == _navigationEpoch && _fullScreenNavigation) {
        setState(() {
          _rerouteFailed = true;
          _voiceStatus = '경로 재탐색에 실패했습니다. 다시 시도할 수 있습니다.';
          _status = '경로 재탐색 오류: $error';
        });
      }
      // 재탐색 실패 시 이전 경로/안내 세션을 보존합니다.
    } finally {
      if (mounted && epoch == _navigationEpoch) {
        setState(() => _rerouting = false);
      }
    }
  }

  void _retryReroute() {
    final p = _position;
    if (p == null ||
        _rerouting ||
        !p.accuracy.isFinite ||
        p.accuracy < 0 ||
        p.accuracy > 50) {
      _notify('GPS 위치 정확도를 확인한 뒤 다시 시도하세요.');
      return;
    }
    unawaited(_rerouteFromPosition(p, manual: true));
  }

  /// 안내 시작 시 GPS를 다시 확인하고, 필요하면 현 위치에서 경로를 재검색합니다.
  /// 음성안내 버튼을 누르면 같은 앱에서 지도 전체화면으로 전환합니다.
  Future<void> _beginVoiceNavigation() async {
    if (_startingNavigation || _routing) return;
    if (_voiceOn) {
      _endNavigation();
      return;
    }
    var route = _voiceRoute;
    if (route == null || route.points.length < 2 || route.maneuvers.isEmpty) {
      _notify('먼저 앱 안에 도보 경로를 표시하세요.');
      return;
    }
    setState(() => _startingNavigation = true);
    try {
      Position? current = _position;
      try {
        final fresh = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        if (!mounted) return;
        _onPosition(fresh);
        current = fresh;
      } catch (_) {
        // 실시간 GPS 스트림의 마지막 측정값으로 진행합니다.
      }
      if (!mounted) return;
      if (current == null) {
        _notify('현재 GPS 위치가 확인된 뒤 음성안내를 시작하세요.');
        return;
      }

      var livePosition = LatLng(current.latitude, current.longitude);
      final lateral = route.locate(livePosition).lateralMeters;
      if (current.accuracy <= 35 && lateral > 65) {
        _notify('현재 위치가 이전 경로와 달라 다시 검색하고 있습니다.');
        await _loadWalkingRoute();
        if (!mounted) return;
        route = _voiceRoute;
        if (route == null) {
          _notify('현재 위치에서 경로를 다시 계산하지 못했습니다.');
          return;
        }
        final latest = _position ?? current;
        livePosition = LatLng(latest.latitude, latest.longitude);
        current = latest;
      }

      final guidance = WalkingGuidance(route);
      final first = guidance.onGpsFix(
        livePosition,
        accuracyMeters: current.accuracy,
      );
      final remaining = navigationSnapshot(route, livePosition).remainingMeters;
      setState(() {
        _guidance = guidance.active ? guidance : null;
        _lastRouteMatch = null;
        _lastMatchedRoute = null;
        _voiceOn = guidance.active;
        _navigationEpoch++;
        _offRouteMonitor.resetSession();
        _directArrivalFixes = 0;
        _rerouteFailed = false;
        _rerouting = false;
        _fullScreenNavigation = true;
        _followGps = true;
        _voiceStatus = first ?? '현재 위치에서 안내를 시작했습니다.';
      });
      // 음성 안내 활성화 시 나침반을 연결하고 부채꼴 표시를 시작합니다.
      if (guidance.active) {
        _startCompass();
        // Start location foreground service while the activity is visible;
        // Android 14+ disallows starting a location FGS from the background.
        await _setNavigationLocationMode(true);
        if (mounted && _voiceOn && _fullScreenNavigation) {
          unawaited(_setPipNavigationActive(true));
        }
      }
      // 화면의 지도 위젯이 다시 연결된 이후 GPS를 화면 중앙으로 이동.
      _centerOnCurrentLocation();
      if (guidance.active) {
        _speak(
          first ??
              '현재 위치에서 도보 음성안내를 시작합니다. '
                  '목적지까지 경로를 따라 약 $remaining미터 남았습니다.',
        );
      } else {
        unawaited(_speak(first ?? '목적지 근처에 도착했습니다.', isTest: true));
      }
    } catch (error, stack) {
      debugPrint('음성안내 시작 실패: $error\n$stack');
      _notify('음성안내 시작에 실패했습니다. GPS와 경로를 다시 확인하세요.');
    } finally {
      if (mounted) setState(() => _startingNavigation = false);
    }
  }

  void _centerOnCurrentLocation({bool force = false}) {
    final now = DateTime.now();
    // 이동 중 지도 타일/카메라가 수십 번 연속 갱신되는 현상을 억제합니다.
    if (!force &&
        _lastMapMoveAt != null &&
        now.difference(_lastMapMoveAt!) < const Duration(milliseconds: 1000)) {
      return;
    }
    _lastMapMoveAt = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_fullScreenNavigation || !_followGps) return;
      final p = _position;
      if (p == null) return;
      try {
        final zoom = _mapController.camera.zoom;
        _mapController.move(
          LatLng(p.latitude, p.longitude),
          zoom.isFinite
              ? (p.speed.isFinite && p.speed >= 8 && zoom > 16.5 ? 16.5 : zoom)
              : 18,
        );
      } catch (error) {
        // 지도가 준비되지 않았거나 PiP 전환 중이면 다음 GPS 갱신에서 복구.
        debugPrint('[NAV-MAP] map move skipped: $error');
      }
    });
  }

  void _endNavigation() {
    _stopVoice();
    setState(() {
      _fullScreenNavigation = false;
      _followGps = true;
    });
  }

  void _toggleGpsFollow() {
    setState(() => _followGps = !_followGps);
    if (_followGps) _centerOnCurrentLocation(force: true);
  }

  void _testVoice() {
    _speak('안녕하세요. 김완호 GPS 도보 길안내 음성 테스트입니다.', isTest: true);
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _notify('위치 서비스가 꺼져 있습니다. 휴대폰에서 GPS를 켜주세요.');
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      _notify('현재 위치를 확인하려면 위치 권한이 필요합니다.');
      return false;
    }
    if (permission == LocationPermission.deniedForever) {
      _notify('앱 설정에서 위치 권한을 허용한 뒤 다시 실행하세요.');
      return false;
    }
    return true;
  }

  Future<void> _startLocationUpdates() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      if (!await _ensureLocationPermission()) return;
      _gpsPermissionReady = true;
      // GPS 스트림부터 구독합니다. 단발 조회가 느려져도 추적은 유지됩니다.
      await _replaceLocationStream(foreground: _foregroundLocation);
      if (!mounted) return;
      _notify('GPS 실시간 위치 추적이 연결됐습니다.');
      // 초기 좌표만 가져오고 끝내지 않고, 계속 스트림을 유지합니다.
      await _pollGpsOnce(force: true);
    } catch (e, stack) {
      debugPrint('[NAV-GPS] stream startup failed: $e\n$stack');
      _notify('GPS 연결 오류: 위치 권한과 위치 서비스를 확인하세요.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _replaceLocationStream({required bool foreground}) {
    // 화면 이동, 음성안내 시작, GPS 자동복구의 동시 요청을 순서대로 처리.
    final generation = ++_gpsStreamGeneration;
    final operation = _gpsStreamOperation.catchError((Object error) {
      debugPrint('[NAV-GPS] previous stream operation: $error');
    }).then((_) async {
      if (!mounted || generation != _gpsStreamGeneration) return;
      await _locationSubscription?.cancel();
      _locationSubscription = null;
      if (!mounted || generation != _gpsStreamGeneration) return;

      final LocationSettings settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              // 기존 5m 거리 필터로 인해 정지/저속 이동에서 위치가
              // 지나치게 늦게 갱신되는 현상을 피합니다.
              distanceFilter: 0,
              intervalDuration: const Duration(seconds: 2),
              foregroundNotificationConfig: foreground
                  ? const ForegroundNotificationConfig(
                      notificationTitle: '김완호 GPS 도보 길안내',
                      notificationText: '실시간 위치와 도보 안내를 사용합니다',
                      enableWakeLock: true,
                    )
                  : null,
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
            );
      _gpsStreamOpenedAt = DateTime.now();
      _lastGpsStreamFixAt = null;
      _locationSubscription = Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen(
        (position) {
          if (!mounted || generation != _gpsStreamGeneration) return;
          _lastGpsStreamFixAt = DateTime.now();
          _onPosition(position);
        },
        onError: (Object error) {
          if (!mounted || generation != _gpsStreamGeneration) return;
          debugPrint('[NAV-GPS] position stream error: $error');
          _notify('GPS 신호가 중단되어 자동으로 다시 연결하고 있습니다.');
          // onError 이후 스트림이 살아 있다고 가정하지 않습니다.
          unawaited(_restartGpsStream(reason: 'stream error'));
        },
        onDone: () {
          if (!mounted || generation != _gpsStreamGeneration) return;
          debugPrint('[NAV-GPS] position stream completed unexpectedly');
          unawaited(_restartGpsStream(reason: 'stream completed'));
        },
        cancelOnError: false,
      );
      debugPrint('[NAV-GPS] stream subscribed: foreground=$foreground '
          'generation=$generation');
    });
    _gpsStreamOperation = operation;
    return operation;
  }

  Future<void> _setNavigationLocationMode(bool active) {
    if (_foregroundLocation == active && _locationSubscription != null) {
      return _locationModeOperation;
    }
    _foregroundLocation = active;
    _locationModeOperation = _locationModeOperation.then((_) async {
      if (!mounted || !_gpsPermissionReady) return;
      try {
        await _replaceLocationStream(foreground: _foregroundLocation);
      } catch (error) {
        debugPrint('[NAV-GPS] foreground stream failed: $error');
        if (_foregroundLocation) {
          _foregroundLocation = false;
          _notify('백그라운드 위치 서비스를 시작하지 못했습니다. '
              '화면을 켠 상태로 안내해 주세요.');
        }
        try {
          await _replaceLocationStream(foreground: false);
        } catch (fallbackError) {
          debugPrint('[NAV-GPS] foreground fallback failed: $fallbackError');
        }
      }
    }).catchError((Object error) {
      debugPrint('[NAV-GPS] location mode update failed: $error');
    });
    return _locationModeOperation;
  }

  void _checkGpsHealth() {
    if (!mounted || !_gpsPermissionReady || _locating) return;
    final now = DateTime.now();
    final baseline = _lastGpsStreamFixAt ?? _gpsStreamOpenedAt;
    if (baseline == null) {
      unawaited(_restartGpsStream(reason: 'no stream'));
      return;
    }
    final silentFor = now.difference(baseline);
    if (GpsRecoveryPolicy.shouldPoll(
      streamSilentFor: silentFor,
      sinceLastPoll:
          _lastGpsPollAt == null ? null : now.difference(_lastGpsPollAt!),
      pollBusy: _gpsPollBusy,
    )) {
      unawaited(_pollGpsOnce());
    }
    if (GpsRecoveryPolicy.shouldRestart(
      streamSilentFor: silentFor,
      sinceLastRestart:
          _lastGpsRestartAt == null ? null : now.difference(_lastGpsRestartAt!),
      restartBusy: _gpsRestartBusy,
    )) {
      unawaited(
          _restartGpsStream(reason: 'stream silent ${silentFor.inSeconds}s'));
    }
  }

  Future<void> _pollGpsOnce({bool force = false}) async {
    if (_gpsPollBusy || !mounted || !_gpsPermissionReady) return;
    final now = DateTime.now();
    if (!force &&
        _lastGpsPollAt != null &&
        now.difference(_lastGpsPollAt!) < GpsRecoveryPolicy.pollInterval) {
      return;
    }
    _lastGpsPollAt = now;
    _gpsPollBusy = true;
    try {
      final current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 7),
        ),
      );
      if (mounted) _onPosition(current);
    } catch (error) {
      debugPrint('[NAV-GPS] fallback current position failed: $error');
    } finally {
      _gpsPollBusy = false;
    }
  }

  Future<void> _restartGpsStream({required String reason}) async {
    if (!mounted || !_gpsPermissionReady || _gpsRestartBusy) return;
    final now = DateTime.now();
    if (_lastGpsRestartAt != null &&
        now.difference(_lastGpsRestartAt!) <
            GpsRecoveryPolicy.restartInterval) {
      return;
    }
    _gpsRestartBusy = true;
    _lastGpsRestartAt = now;
    debugPrint('[NAV-GPS] recovering GPS stream: $reason');
    try {
      await _replaceLocationStream(foreground: _foregroundLocation);
    } catch (error) {
      debugPrint('[NAV-GPS] restart failed: $error');
      if (_foregroundLocation) {
        // 서비스 실행 권한/OS 제약으로 실패하면 화면 내 추적부터 복구.
        _foregroundLocation = false;
        try {
          await _replaceLocationStream(foreground: false);
        } catch (fallbackError) {
          debugPrint('[NAV-GPS] fallback restart failed: $fallbackError');
        }
      }
    } finally {
      _gpsRestartBusy = false;
    }
  }

  String get _gpsHealthText {
    final position = _position;
    final received = _lastGpsReceivedAt;
    if (position == null || received == null) return 'GPS 수신 대기 중';
    final elapsed = DateTime.now().difference(received).inSeconds;
    final accuracy = position.accuracy.isFinite
        ? '정확도 약 ${position.accuracy.round()}m'
        : '정확도 알 수 없음';
    final streamBaseline = _lastGpsStreamFixAt ?? _gpsStreamOpenedAt;
    final streamAge = streamBaseline == null
        ? null
        : DateTime.now().difference(streamBaseline).inSeconds;
    if (_gpsPermissionReady &&
        streamAge != null &&
        streamAge >= GpsRecoveryPolicy.pollAfter.inSeconds) {
      return 'GPS 실시간 연결 복구 중 · 최근 위치 $elapsed초 전 · $accuracy';
    }
    if (elapsed > 15) {
      return '최근 GPS $elapsed초 전 · $accuracy (수신 지연)';
    }
    return 'GPS $elapsed초 전 · $accuracy';
  }

  Future<void> _reconnectGps() async {
    if (_locating) return;
    _notify('GPS 연결을 다시 확인하고 있습니다.');
    await _startLocationUpdates();
    if (!mounted) return;
    _centerOnCurrentLocation(force: true);
  }

  Future<void> _pasteDestination() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      _notify('복사된 주소 또는 GPS 좌표가 없습니다.');
      return;
    }
    setState(() => _destinationController.text = text);
    _notify('붙여넣었습니다. 목적지 설정을 눌러 확인하세요.');
  }

  String _decodeGpsFile(Uint8List bytes) {
    if (bytes.length >= 2) {
      final le = bytes[0] == 0xFF && bytes[1] == 0xFE;
      final be = bytes[0] == 0xFE && bytes[1] == 0xFF;
      if (le || be) {
        final units = <int>[];
        for (var i = 2; i + 1 < bytes.length; i += 2) {
          units.add(le
              ? bytes[i] | (bytes[i + 1] << 8)
              : (bytes[i] << 8) | bytes[i + 1]);
        }
        return String.fromCharCodes(units);
      }
    }
    // UTF-8 BOM 포함 파일도 GPX XML 파서가 읽을 수 있도록 제거.
    final offset = bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF
        ? 3
        : 0;
    return utf8.decode(bytes.sublist(offset));
  }

  Future<void> _importGpsFile() async {
    if (_resolvingDestination || _routing) {
      _notify('진행 중인 작업을 완료한 뒤 GPS 파일을 선택하세요.');
      return;
    }
    _notify('파일 선택창에서 GPX 파일을 선택해 주세요.');
    try {
      // 갤럭시/안드로이드 파일 제공자는 .gpx 확장자의 MIME 타입을
      // 서로 다르게 보고하므로, 선택창에서는 형식 제한을 걸지 않습니다.
      final file = await FilePicker.pickFile(type: FileType.any);
      if (!mounted) return;
      if (file == null) {
        _notify('파일 선택이 취소되었습니다.');
        return;
      }

      final name = file.name.toLowerCase().trim();
      if (!['.gpx', '.csv', '.txt', '.xml'].any(name.endsWith)) {
        _notify('선택한 파일은 지원하지 않습니다: ${file.name} (GPX·CSV·TXT·XML 가능)');
        return;
      }

      _notify('${file.name} 파일을 읽고 있습니다...');
      const maxBytes = 10 * 1024 * 1024;
      final length = await file.length();
      if (length != null && length > maxBytes) {
        _notify('GPS 파일은 최대 10MB까지 지원합니다.');
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBytes) {
        _notify('GPS 파일은 최대 10MB까지 지원합니다.');
        return;
      }

      final points = GpsInputParser.parseFileText(_decodeGpsFile(bytes));
      if (!mounted) return;
      if (points.isEmpty) {
        _notify('GPX에 GPS 지점을 찾지 못했습니다. trkpt·wpt·rtept 위치가 있는지 확인하세요.');
        return;
      }
      _notify('${file.name}: GPS 지점 ${points.length}개를 찾았습니다.');
      final choice = await showDialog<LatLng>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('GPS 파일 인식 완료: ${file.name}'),
          content: Text(
            '총 ${points.length}개 GPS 지점을 확인했습니다.\n'
            '첫 지점 또는 마지막 지점을 목적지로 설정합니다.\n\n'
            '선택한 지점으로 도보 경로를 자동 조회합니다.\n'
            'GPX 전체 궤적을 그대로 안내하는 것은 아닙니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, points.first),
              child: const Text('첫 지점'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, points.last),
              child: const Text('마지막 지점'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == null) {
        _notify('GPS 파일의 목적지 선택을 취소했습니다.');
        return;
      }
      final coordinate =
          '${choice.latitude.toStringAsFixed(7)}, ${choice.longitude.toStringAsFixed(7)}';
      setState(() => _destinationController.text = coordinate);
      _applyDestination(choice, label: 'GPS 파일 ${file.name}');

      // 목적지 핀 등록 후 기존 내비게이션 경로 조회 흐름에 자동 연결합니다.
      // 경로 데이터가 도착하면 사용자가 '한국어 음성안내 시작'을 누를 수 있습니다.
      _notify('목적지 핀 표시 완료. 현재 GPS에서 도보 경로를 조회합니다.');
      await _loadWalkingRoute();
      if (!mounted) return;
      if (_voiceRoute != null) {
        _notify('GPS 파일에서 목적지를 설정하고 도보 경로를 표시했습니다. '
            '한국어 음성안내 시작을 누르세요.');
      }
    } on FormatException catch (e) {
      _notify('GPX 파일 형식 오류: ${e.message}');
      debugPrint('GPS parse failure: $e');
    } catch (e, stack) {
      _notify('파일을 열거나 경로를 연결하지 못했습니다: $e');
      debugPrint('GPS file import error: $e\n$stack');
    }
  }

  Future<void> _setDestination() async {
    if (_resolvingDestination) return;
    final input = _destinationController.text.trim();
    if (input.isEmpty) {
      _notify('주소나 GPS 좌표를 입력하세요.');
      return;
    }

    final coords = GpsInputParser.parse(input);
    if (coords != null) {
      _applyDestination(coords, label: 'GPS 좌표');
      return;
    }

    // 지원하지 않는 좌표 문자열을 주소로 검색하지 않습니다.
    if (RegExp(
      r'^(?:geo:|gps:|https?://|<|[NSEW]?[-+]?\d|(?:lat|lon|lng|latitude|longitude)\s*[:=])',
      caseSensitive: false,
    ).hasMatch(input)) {
      _notify(
          '좌표 형식을 확인하세요. 예: 37.5665, 126.9780 또는 37°33\'59.4"N 126°58\'40.8"E');
      return;
    }

    setState(() {
      _resolvingDestination = true;
      _status = '주소를 GPS 좌표로 변환하는 중입니다...';
    });
    final request = ++_destinationRequest;
    try {
      final results = await _geocoder
          .locationFromAddress(input)
          .timeout(const Duration(seconds: 15));
      if (!mounted || request != _destinationRequest) return;
      if (results.isEmpty) {
        _notify('주소 검색 결과가 없습니다. 도로명주소를 자세히 입력해 주세요.');
        return;
      }
      final first = results.first;
      final target = LatLng(first.latitude, first.longitude);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('주소 검색 결과 확인'),
          content: Text('입력한 주소: $input\n\n'
              '위도: ${target.latitude.toStringAsFixed(6)}\n'
              '경도: ${target.longitude.toStringAsFixed(6)}\n\n'
              '이 좌표를 목적지로 설정하시겠습니까?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('목적지 지정'),
            ),
          ],
        ),
      );
      if (!mounted || request != _destinationRequest) return;
      if (confirmed == true) {
        _applyDestination(target, label: input);
      } else {
        _notify('주소 검색을 취소했습니다. 목적지는 변경되지 않았습니다.');
      }
    } catch (_) {
      _notify('주소를 좌표로 변환하지 못했습니다. 인터넷 연결과 주소를 확인하거나 GPS 좌표를 입력하세요.');
    } finally {
      if (mounted && request == _destinationRequest) {
        setState(() => _resolvingDestination = false);
      }
    }
  }

  void _applyDestination(LatLng target, {required String label}) {
    if (!mounted) return;
    _stopVoice(updateStatus: false);
    _initialRouteEpoch++;
    setState(() {
      _fullScreenNavigation = false;
      _voiceRoute = null;
      _voiceStatus = '도보 경로 조회 후 음성안내를 시작할 수 있습니다.';
      _routePoints = [];
      _walkingMeters = null;
      _walkingSeconds = null;
      _destination = target;
      _destinationLabel = label;
      _status = '목적지: ${target.latitude.toStringAsFixed(6)}, '
          '${target.longitude.toStringAsFixed(6)}';
    });
    _mapController.move(target, 16);
  }

  /// 초기 경로 조회 및 자동 재탐색에서 동일한 Valhalla 요청·검증 로직 사용.
  /// 이 함수는 UI 상태를 변경하지 않습니다.
  Future<WalkingVoiceRoute> _fetchWalkingRoute(LatLng start, LatLng end) async {
    final uri = Uri.parse(_routeEndpoint);
    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'X-Client-Id': _appClientId,
          },
          body: jsonEncode({
            'locations': [
              {'lat': start.latitude, 'lon': start.longitude},
              {'lat': end.latitude, 'lon': end.longitude},
            ],
            'costing': 'pedestrian',
            'format': 'json',
            'directions_type': 'instructions',
            'language': 'en-US',
            'units': 'kilometers',
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      var message = '경로 서버 오류 (${response.statusCode})';
      try {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data is Map) {
          message = '${data['error'] ?? data['message'] ?? message}';
        }
      } catch (_) {
        // 서버가 HTML 등을 반환해도 오류 문구를 보여줍니다.
      }
      throw Exception(message);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('경로 서버 응답 형식이 올바르지 않습니다.');
    }
    final result = WalkingVoiceRoute.fromValhalla(decoded);
    if (result.points.length < 2) {
      throw const FormatException('경로 좌표가 없습니다.');
    }
    return result;
  }

  Future<void> _loadWalkingRoute() async {
    if (_routing || _rerouting) return;
    _stopVoice(updateStatus: false);
    final requestEpoch = ++_initialRouteEpoch;
    setState(() {
      _fullScreenNavigation = false;
      _voiceRoute = null;
      _voiceStatus = '경로를 조회하고 있습니다.';
    });
    var p = _position;
    if (p == null) {
      await _startLocationUpdates();
      p = _position;
    }
    if (!mounted || requestEpoch != _initialRouteEpoch) return;
    if (p == null) {
      _notify('GPS 현재 위치를 확인한 후 경로를 조회하세요.');
      return;
    }

    final destination = _destination;
    setState(() => _routing = true);
    try {
      final route = await _fetchWalkingRoute(
        LatLng(p.latitude, p.longitude),
        destination,
      );
      if (!mounted || requestEpoch != _initialRouteEpoch) return;
      setState(() {
        _voiceRoute = route;
        _routePoints = route.points;
        _walkingMeters = route.totalMeters;
        _walkingSeconds = route.totalSeconds;
        _voiceStatus = route.maneuvers.isEmpty
            ? '경로는 표시됐으나 회전 안내 정보가 없습니다.'
            : '음성안내 시작 버튼을 누르면 경로 회전 지점을 안내합니다.';
        _status = '보행 경로와 회전 안내 데이터를 조회했습니다.';
      });
      try {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(route.points),
            padding: const EdgeInsets.all(48),
          ),
        );
      } catch (_) {
        // 지도가 아직 렌더링되지 않았다면 자동 맞춤은 생략.
      }
    } catch (error, stack) {
      debugPrint('초기 도보 경로 조회 실패: $error\n$stack');
      if (mounted && requestEpoch == _initialRouteEpoch) {
        setState(() {
          _routePoints = [];
          _voiceRoute = null;
          _walkingMeters = null;
          _walkingSeconds = null;
          _voiceStatus = '경로 조회가 실패해 음성 길안내를 사용할 수 없습니다.';
          _status = '도보 경로 조회 실패: $error';
        });
      }
    } finally {
      if (mounted && requestEpoch == _initialRouteEpoch) {
        setState(() => _routing = false);
      }
    }
  }

  Future<void> _startWalkingNavigation() async {
    // Google Maps URLs: 출발점을 생략하면 지도 앱이 기기 위치를 사용합니다.
    // 구글 지도의 실제 길안내 동작은 설치 여부/OS/지역에 따라 달라집니다.
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${_destination.latitude},${_destination.longitude}',
      'travelmode': 'walking',
      'dir_action': 'navigate',
    });
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!ok) _notify('구글 지도 길찾기를 열지 못했습니다.');
    } catch (e) {
      _notify('도보 길찾기 실행 오류: $e');
    }
  }

  Future<void> _goToMyLocation() async {
    if (_position == null) {
      await _startLocationUpdates();
    }
    final p = _position;
    if (p != null) {
      _mapController.move(LatLng(p.latitude, p.longitude), 17);
    }
  }

  String get _distanceLabel {
    final p = _position;
    if (p == null) return '현재 위치 확인 중';
    final meters = Geolocator.distanceBetween(
      p.latitude,
      p.longitude,
      _destination.latitude,
      _destination.longitude,
    );
    if (meters < 1000) return '직선거리 ${meters.round()} m';
    return '직선거리 ${(meters / 1000).toStringAsFixed(2)} km';
  }

  Widget _buildMap(
    List<Polyline> routeLines,
    List<Marker> markers, {
    bool navigation = false,
    bool compact = false,
  }) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _position == null
                ? _destination
                : LatLng(_position!.latitude, _position!.longitude),
            initialZoom: navigation ? 18 : 15,
            onLongPress: compact ? null : (_, point) => _onMapLongPress(point),
            onMapReady: () {
              if (_fullScreenNavigation && _followGps) {
                _centerOnCurrentLocation();
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: _appClientId,
            ),
            if (navigation &&
                _voiceOn &&
                _position != null &&
                _currentDirectionDegrees != null)
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: directionSector(
                      LatLng(_position!.latitude, _position!.longitude),
                      _currentDirectionDegrees!,
                      radiusMeters: 42,
                      halfAngleDegrees: 28,
                    ),
                    color: const Color(0x662197F3),
                    borderColor: const Color(0x882197F3),
                    borderStrokeWidth: 1,
                  ),
                ],
              ),
            PolylineLayer(polylines: routeLines),
            MarkerLayer(markers: markers),
          ],
        ),
        Positioned(
          left: 8,
          bottom: navigation ? 92 : 6,
          child: GestureDetector(
            onTap: () => launchUrl(
              Uri.parse('https://www.openstreetmap.org/copyright'),
              mode: LaunchMode.externalApplication,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              color: Colors.white.withValues(alpha: 0.9),
              child: const Text(
                '© OpenStreetMap contributors',
                style: TextStyle(fontSize: 10),
              ),
            ),
          ),
        ),
        if (!navigation)
          Positioned(
            right: 12,
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: 'myLocation',
              tooltip: '현재 위치',
              onPressed: _goToMyLocation,
              child: const Icon(Icons.my_location),
            ),
          ),
      ],
    );
  }

  Widget _buildCompactPipNavigation(
    List<Polyline> routeLines,
    List<Marker> markers,
  ) {
    final current = _position;
    final route = _voiceRoute;
    final snapshot = current != null && route != null
        ? navigationSnapshot(route, LatLng(current.latitude, current.longitude),
            match: identical(route, _lastMatchedRoute) ? _lastRouteMatch : null)
        : null;
    final remaining = snapshot?.remainingMeters;
    final remainingText = remaining == null
        ? 'GPS 수신 중'
        : remaining >= 1000
            ? '${(remaining / 1000).toStringAsFixed(1)}km'
            : '${remaining}m';

    // Only the map and one short instruction remain in the small system PiP
    // surface. The Android system manages resizing, drag, close and expand.
    return Stack(
      children: [
        Positioned.fill(
          child: _buildMap(
            routeLines,
            markers,
            navigation: true,
            compact: true,
          ),
        ),
        Positioned(
          left: 3,
          right: 3,
          top: 3,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xE8173E72),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _rerouting
                  ? '경로 재탐색 중...'
                  : '${snapshot?.nextInstruction ?? '목적지 안내 중'} · $remainingText',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNavigationScreen(
    List<Polyline> routeLines,
    List<Marker> markers,
  ) {
    if (_isInPip) {
      return _buildCompactPipNavigation(routeLines, markers);
    }
    final p = _position;
    final route = _voiceRoute;
    final snapshot = (p == null || route == null)
        ? null
        : navigationSnapshot(route, LatLng(p.latitude, p.longitude),
            match:
                identical(route, _lastMatchedRoute) ? _lastRouteMatch : null);
    final remaining = snapshot?.remainingMeters;
    final distanceText = remaining == null
        ? 'GPS 위치 확인 중'
        : remaining >= 1000
            ? '${(remaining / 1000).toStringAsFixed(2)}km 남음'
            : '${remaining}m 남음';

    return Stack(
      children: [
        Positioned.fill(
          child: _buildMap(routeLines, markers, navigation: true),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
            child: Column(
              children: [
                Material(
                  elevation: 5,
                  color: const Color(0xFF173E72),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: _endNavigation,
                          tooltip: '기존 화면으로 돌아가기',
                          color: Colors.white,
                          icon: const Icon(Icons.arrow_back),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _rerouting
                                    ? '경로 재탐색 중...'
                                    : _rerouteFailed
                                        ? '재탐색 실패 · 다시 시도하세요'
                                        : (p != null &&
                                                p.accuracy.isFinite &&
                                                p.accuracy <= 35 &&
                                                route != null &&
                                                (identical(route,
                                                                _lastMatchedRoute) &&
                                                            _lastRouteMatch !=
                                                                null
                                                        ? _lastRouteMatch!
                                                            .lateralMeters
                                                        : route
                                                            .locate(LatLng(
                                                              p.latitude,
                                                              p.longitude,
                                                            ))
                                                            .lateralMeters) >
                                                    30)
                                            ? '경로 이탈 확인 중...'
                                            : (snapshot?.nextInstruction ??
                                                'GPS 위치를 확인하고 있습니다.'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$distanceText · ${_voiceOn ? "음성안내 중" : "음성안내 종료"}',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 13),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _gpsHealthText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        if (_pipSupported && _voiceOn) ...[
                          IconButton(
                            onPressed: _enterPipWindow,
                            tooltip: '작은 지도 창으로 전환',
                            color: Colors.white,
                            icon: const Icon(Icons.picture_in_picture_alt),
                          ),
                          const SizedBox(width: 4),
                        ],
                        const Icon(Icons.directions_walk, color: Colors.white),
                        const SizedBox(width: 10),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                Align(
                  alignment: Alignment.centerRight,
                  child: Column(
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'favoriteListNav',
                        tooltip: '즐겨찾기 목록',
                        onPressed: _showFavorites,
                        child: const Icon(Icons.star),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'gpsReconnect',
                        tooltip: 'GPS 위치 추적 다시 연결',
                        onPressed: _locating ? null : _reconnectGps,
                        child: const Icon(Icons.refresh),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'followPosition',
                        tooltip: _followGps ? '위치 자동 따라가기 끄기' : '현재 위치 따라가기',
                        onPressed: _toggleGpsFollow,
                        child: Icon(
                            _followGps ? Icons.gps_fixed : Icons.gps_not_fixed),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '목적지: $_destinationLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _voiceStatus,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (_rerouting) ...[
                          const SizedBox(height: 10),
                          const LinearProgressIndicator(),
                        ],
                        if (_rerouteFailed) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _retryReroute,
                            icon: const Icon(Icons.refresh),
                            label: const Text('현재 위치에서 경로 다시 탐색'),
                          ),
                        ],
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _endNavigation,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('안내 종료 · 입력 화면으로'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final routeLines = _routePoints.length >= 2
        ? <Polyline>[
            Polyline(
              points: _routePoints,
              color: const Color(0xFF1565C0),
              strokeWidth: 7,
            ),
          ]
        : <Polyline>[];
    final markers = <Marker>[
      Marker(
        point: _destination,
        width: 48,
        height: 48,
        child: const Icon(Icons.location_pin, color: Colors.red, size: 48),
      ),
      ..._favorites.map((place) => Marker(
            point: LatLng(place.latitude, place.longitude),
            width: 40,
            height: 40,
            child: IconButton(
              tooltip: place.name,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.star, color: Colors.amber, size: 32),
              onPressed: _showFavorites,
            ),
          )),
      if (_position != null)
        Marker(
          point: LatLng(_position!.latitude, _position!.longitude),
          width: 30,
          height: 30,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1976D2),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 4)
              ],
            ),
          ),
        ),
    ];

    return PopScope(
      canPop: !_fullScreenNavigation,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _fullScreenNavigation) _endNavigation();
      },
      child: Scaffold(
        appBar: _fullScreenNavigation
            ? null
            : AppBar(
                title: const Text('GPS 통합 도보 길안내'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.my_location),
                    tooltip: 'GPS 위치 다시 연결',
                    onPressed: _locating ? null : _reconnectGps,
                  ),
                  IconButton(
                    icon: const Icon(Icons.star_outline),
                    tooltip: '즐겨찾기 목록',
                    onPressed: _showFavorites,
                  ),
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    tooltip: '앱 정보 및 약관',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AppLegalPage()),
                    ),
                  ),
                ],
              ),
        body: _fullScreenNavigation
            ? _buildNavigationScreen(routeLines, markers)
            : SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _destinationController,
                            keyboardType: TextInputType.text,
                            textInputAction: TextInputAction.search,
                            maxLines: 2,
                            minLines: 1,
                            decoration: const InputDecoration(
                              labelText: '목적지 (주소 · GPS · 위도/경도)',
                              hintText: '서울시청 또는 37.5665, 126.9780',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.search),
                            ),
                            onSubmitted: (_) => _setDestination(),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '주소 / 37.5665,126.9780 / lat=37.5665 lon=126.9780 / '
                            '도분초(DMS) / GPX 좌표 문자열 지원',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _resolvingDestination
                                      ? null
                                      : _setDestination,
                                  icon: const Icon(Icons.place),
                                  label: Text(_resolvingDestination
                                      ? '주소 검색 중...'
                                      : '목적지 설정'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: _resolvingDestination
                                    ? null
                                    : _pasteDestination,
                                icon: const Icon(Icons.content_paste),
                                label: const Text('붙여넣기'),
                              ),
                            ],
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: (_resolvingDestination || _routing)
                                  ? null
                                  : _importGpsFile,
                              icon: const Icon(Icons.file_open),
                              label:
                                  const Text('GPS 파일 불러오기 (GPX · CSV · TXT)'),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text('선택: $_destinationLabel',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 4),
                          Text(_walkingMeters == null
                              ? _distanceLabel
                              : '도보 경로 ${(_walkingMeters! / 1000).toStringAsFixed(2)} km'
                                  '${_walkingSeconds == null ? '' : ' · 약 ${(_walkingSeconds! / 60).ceil()}분'}'),
                          const SizedBox(height: 3),
                          Text(_gpsHealthText,
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    Expanded(child: _buildMap(routeLines, markers)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton.icon(
                            onPressed: _routing ? null : _loadWalkingRoute,
                            icon: const Icon(Icons.route),
                            label:
                                Text(_routing ? '경로 조회 중...' : '앱 안에 도보 경로 표시'),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: (_startingNavigation || _routing)
                                      ? null
                                      : (_voiceOn || _voiceRoute != null)
                                          ? _beginVoiceNavigation
                                          : null,
                                  icon: Icon(_voiceOn
                                      ? Icons.volume_off
                                      : Icons.volume_up),
                                  label: Text(_startingNavigation
                                      ? '현재 GPS 확인 중...'
                                      : _voiceOn
                                          ? '음성안내 중지'
                                          : '한국어 음성안내 시작'),
                                ),
                              ),
                              IconButton(
                                tooltip: '음성 테스트',
                                onPressed: _testVoice,
                                icon: const Icon(Icons.record_voice_over),
                              ),
                            ],
                          ),
                          Text(_voiceStatus,
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 6),
                          OutlinedButton.icon(
                            onPressed: _startWalkingNavigation,
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('구글 지도에서 열기 (별도 앱)'),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _status,
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class AppLegalPage extends StatelessWidget {
  const AppLegalPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('앱 정보 및 법적 고지')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('좌표 도보 길안내',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('제작자: 김완호\n버전: 1.5.5\n© 2026 김완호. All rights reserved.'),
          const SizedBox(height: 16),
          const Text('이용 시 유의사항',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text('지도와 경로 데이터는 실제 도로 상태와 다를 수 있습니다. '
              '이동 중 화면을 계속 보지 말고 주변 안전표지, 통행 제한 및 현장 안내를 우선하세요. '
              '경로 제공이 중단되거나 정확하지 않을 수 있습니다.'),
          const SizedBox(height: 16),
          const Text('위치정보 및 개인정보 안내',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text('앱 사용 중 GPS 위치 접근 권한을 요청합니다. 보행 경로 조회를 누르면 '
              '현재 위치와 목적지 좌표가 경로조회 서버 및 외부 경로 제공자에 전달됩니다. '
              '앱의 즐겨찾기에 직접 저장한 장소 이름과 GPS 좌표는 휴대폰 내부에 저장됩니다. 이동 기록은 저장하지 않습니다. '
              '다만 실제 서버 운영자의 로그·보관 및 제공사 처리 방식은 '
              '배포 전에 확인해 별도 개인정보 처리방침에 명시해야 합니다. '
              '실제 개인정보 처리방침은 앱 배포 전에 작성·게시되어야 합니다.'),
          const SizedBox(height: 16),
          const Text('지도 데이터 및 오픈소스',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text('지도와 경로 데이터는 OpenStreetMap 기여자에게 권리가 있으며, '
              '보행 경로 계산에는 FOSSGIS가 운영하는 공개 Valhalla 데모 서버를 사용합니다. '
              '공개 서버에는 가용성 보장이 없고 사용량 제한이 적용될 수 있으므로 '
              '공개 배포 전에는 운영자가 직접 관리하는 지도·경로 서비스를 연결해야 합니다.'),
          const SizedBox(height: 12),
          const Text('주소 검색은 Android의 기기 지오코딩 서비스를 이용하며 '
              '네트워크 연결 및 제공자의 서버 처리가 발생할 수 있습니다. '
              '검색 결과는 실제 주소와 다를 수 있으므로 좌표를 확인하세요.'),
          const SizedBox(height: 12),
          const Text('한국어 음성은 갤럭시의 TTS 기능을 사용하며, '
              '보행 경로가 정상적으로 조회된 경우에만 회전 지점을 안내합니다. '
              '이 버전은 앱이 화면에 표시될 때만 위치를 추적합니다. '
              'GPS 오차 및 경로 서버 상태에 따라 안내가 부정확할 수 있습니다.'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: '좌표 도보 길안내',
              applicationVersion: '1.5.4',
              applicationLegalese: '© 2026 김완호',
            ),
            icon: const Icon(Icons.description_outlined),
            label: const Text('오픈소스 라이선스 보기'),
          ),
          const SizedBox(height: 12),
          if (_privacyPolicyUrl.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(_privacyPolicyUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.privacy_tip_outlined),
              label: const Text('개인정보 처리방침 확인'),
            )
          else
            const Text('테스트 배포 전 개인정보 처리방침 URL을 등록해야 합니다.',
                style: TextStyle(color: Colors.deepOrange)),
        ],
      ),
    );
  }
}
