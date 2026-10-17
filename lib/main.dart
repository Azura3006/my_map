import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:polyline_codec/polyline_codec.dart';

void main() {
  runApp(const MyMapApp());
}

// ---------------------------------------------------------------------------
// Màu sắc dùng chung
// ---------------------------------------------------------------------------
class AppColors {
  static const primary = Color(0xFF00796B); // teal đậm
  static const primaryDark = Color(0xFF004D40);
  static const route = Color(0xFF1A73E8); // xanh dương kiểu Google
  static const danger = Color(0xFFD93025);
  static const ink = Color(0xFF202124);
  static const inkSoft = Color(0xFF5F6368);
}

class MyMapApp extends StatelessWidget {
  const MyMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MyMap',
      theme: ThemeData(
        colorSchemeSeed: AppColors.primary,
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<double> _mapRotation = ValueNotifier<double>(0);

  StreamSubscription<html.Geoposition>? _gpsSubscription;

  LatLng? _currentLocation;
  LatLng? _selectedLocation;
  LatLng? _lastRouteStart;
  LatLng? _navigationDestination;

  List<LatLng> _routePoints = [];
  List<dynamic> _searchResults = [];
  List<dynamic> _maneuvers = [];

  int _currentManeuverIndex = 0;
  double? _routeDistance;
  double? _routeDuration;
  double? _currentHeading;

  bool _isUpdatingRoute = false;
  bool _isNavigating = false;
  bool _isLoadingRoute = false;
  bool _mapReady = false;

  String _travelMode = 'motor_scooter';
  bool _avoidFerry = true;

  // Vị trí GPS nằm ở 75% chiều cao bản đồ (thấp hơn tâm màn hình)
  // để nhìn được nhiều đường phía trước hơn.
  static const double _gpsScreenYRatio = 0.75;

  // Mức zoom khi dẫn đường. Tăng số này để phóng to hơn (tối đa ~19).
  static const double _navigationZoom = 18.5;

  @override
  void dispose() {
    _gpsSubscription?.cancel();
    _searchController.dispose();
    _mapController.dispose();
    _mapRotation.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Tiện ích định dạng
  // -------------------------------------------------------------------------
  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${meters.round()} m';
  }

  String _formatDuration(double seconds) {
    final totalMinutes = math.max(1, (seconds / 60).ceil());
    if (totalMinutes < 60) return '$totalMinutes phút';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    return m == 0 ? '$h giờ' : '$h giờ $m phút';
  }

  String _formatArrival(double seconds) {
    final t = DateTime.now().add(Duration(seconds: seconds.round()));
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  // -------------------------------------------------------------------------
  // Logic: tìm kiếm / tuyến đường / GPS (giữ nguyên)
  // -------------------------------------------------------------------------
  Future<void> _searchPlace() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': query,
          'format': 'jsonv2',
          'limit': '5',
          'countrycodes': 'vn',
          'viewbox': '106.35,11.15,107.05,10.55',
          'bounded': '0',
        },
      );

      final response = await http.get(
        uri,
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode != 200) {
        debugPrint('Lỗi tìm kiếm: ${response.statusCode}');
        _showMessage('Lỗi tìm kiếm (mã ${response.statusCode}).');
        return;
      }

      final results = jsonDecode(response.body) as List<dynamic>;
      if (!mounted) return;

      if (results.isEmpty) _showMessage('Không tìm thấy địa điểm phù hợp.');
      setState(() => _searchResults = results);
    } catch (e) {
      debugPrint('Lỗi khi tìm địa điểm: $e');
    }
  }

  IconData _getManeuverIcon(dynamic maneuver) {
    final instruction =
        (maneuver['instruction'] ?? '').toString().toLowerCase();

    if (instruction.contains('quay đầu')) return Icons.u_turn_left;
    if (instruction.contains('rẽ trái')) return Icons.turn_left;
    if (instruction.contains('rẽ phải')) return Icons.turn_right;
    if (instruction.contains('vòng xuyến') ||
        instruction.contains('vòng xoay')) {
      return Icons.roundabout_left;
    }
    if (instruction.contains('đi thẳng') ||
        instruction.contains('giữ thẳng')) {
      return Icons.straight;
    }
    if (instruction.contains('đã tới nơi') ||
        instruction.contains('bạn đã tới nơi')) {
      return Icons.flag;
    }
    return Icons.navigation;
  }

  Future<bool> _getRoute(
    LatLng destination, {
    LatLng? startLocation,
    bool isRetry = false,
  }) async {
    final start = startLocation ?? _currentLocation;
    if (start == null) {
      debugPrint('Chưa có GPS. Hãy lấy vị trí hiện tại trước.');
      return false;
    }

    if (mounted && !_isNavigating) setState(() => _isLoadingRoute = true);

    try {
      _navigationDestination = destination;
      final response = await http.post(
        Uri.parse('https://valhalla1.openstreetmap.de/route'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'locations': [
            {'lat': start.latitude, 'lon': start.longitude},
            {'lat': destination.latitude, 'lon': destination.longitude},
          ],
          'costing': _travelMode,
          'costing_options': {
            _travelMode: {
              // use_ferry: 0 = tránh phà, 1 = ưu tiên phà
              'use_ferry': _avoidFerry ? 0 : 0.5,
              // Xe máy không được đi cao tốc ở Việt Nam.
              if (_travelMode == 'motor_scooter') 'exclude_highways': true,
            },
          },
          'units': 'kilometers',
          'format': 'json',
          'shape_format': 'polyline6',
          'language': 'vi-VN',
          'directions_type': 'instructions',
        }),
      ).timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        debugPrint('Lỗi Valhalla: ${response.statusCode}');
        debugPrint(response.body);

        // Lấy thông báo lỗi từ server (nếu có) để hiện cho người dùng.
        String reason = 'mã lỗi ${response.statusCode}';
        int? errorCode;
        try {
          final err = jsonDecode(response.body) as Map<String, dynamic>;
          if (err['error'] != null) reason = err['error'].toString();
          errorCode = (err['error_code'] as num?)?.toInt();
        } catch (_) {}

        // Lỗi 154: tuyến vượt giới hạn khoảng cách của server.
        // Tự thử lại bằng chế độ ô tô (giới hạn thường cao hơn xe máy).
        if (errorCode == 154 && !isRetry && _travelMode == 'motor_scooter') {
          if (mounted) setState(() => _travelMode = 'auto');
          _showMessage(
              'Tuyến quá dài cho chế độ xe máy, đang chuyển sang tuyến ô tô. '
              'Lưu ý: tuyến này có thể đi qua cao tốc mà xe máy không được vào.');
          return _getRoute(
            destination,
            startLocation: startLocation,
            isRetry: true,
          );
        }

        if (!_isNavigating) {
          final tooFar = errorCode == 154;
          _showMessage(tooFar
              ? 'Tuyến đường quá dài so với giới hạn của máy chủ miễn phí (tối đa khoảng 200 km). Hãy chọn điểm đến gần hơn.'
              : 'Không tìm được tuyến đường: $reason');
        }
        return false;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final trip = data['trip'] as Map<String, dynamic>?;
      final legs = trip?['legs'] as List<dynamic>? ?? [];
      if (legs.isEmpty) {
        debugPrint('Valhalla không trả về chặng đường.');
        return false;
      }

      final leg = legs.first as Map<String, dynamic>;
      final shape = leg['shape'] as String?;
      if (shape == null || shape.isEmpty) {
        debugPrint('Không có shape tuyến đường.');
        return false;
      }

      final decoded = PolylineCodec.decode(shape, precision: 6);
      final points = decoded
          .map((point) => LatLng(
                (point[0] as num).toDouble(),
                (point[1] as num).toDouble(),
              ))
          .toList();

      if (points.isEmpty) {
        debugPrint('Không giải mã được tuyến đường.');
        return false;
      }

      final summary = trip!['summary'] as Map<String, dynamic>;
      final distanceMeters = (summary['length'] as num).toDouble() * 1000;
      final durationSeconds = (summary['time'] as num).toDouble();
      final maneuvers = leg['maneuvers'] as List<dynamic>? ?? [];

      if (!mounted) return false;
      setState(() {
        _routePoints = points;
        _routeDistance = distanceMeters;
        _routeDuration = durationSeconds;
        _maneuvers = maneuvers;
        _currentManeuverIndex = 0;
      });

      // Chỉ fit toàn tuyến khi chưa dẫn đường. Khi đang dẫn đường giữ khung GPS.
      if (!_isNavigating && _mapReady) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            // chừa chỗ cho thanh tìm kiếm (trên) và bảng thông tin (dưới)
            padding: const EdgeInsets.fromLTRB(40, 170, 40, 260),
          ),
        );
      }

      _lastRouteStart = start;
      return true;
    } catch (e) {
      debugPrint('Lỗi khi lấy tuyến đường: $e');
      if (!_isNavigating) {
        _showMessage(e is TimeoutException
            ? 'Máy chủ tuyến đường phản hồi quá lâu. Vui lòng thử lại.'
            : 'Lỗi khi lấy tuyến đường: $e');
      }
      return false;
    } finally {
      if (mounted && _isLoadingRoute) {
        setState(() => _isLoadingRoute = false);
      }
    }
  }

  Future<LatLng?> _readBrowserPosition() async {
    try {
      final position =
          await html.window.navigator.geolocation.getCurrentPosition(
        enableHighAccuracy: true,
        timeout: const Duration(seconds: 10),
        maximumAge: const Duration(seconds: 5),
      );
      final latitude = position.coords?.latitude;
      final longitude = position.coords?.longitude;
      if (latitude == null || longitude == null) return null;

      return LatLng(latitude.toDouble(), longitude.toDouble());
    } catch (e) {
      debugPrint('Không thể lấy vị trí: $e');
      return null;
    }
  }

  Future<void> _getCurrentLocation() async {
    final position = await _readBrowserPosition();
    if (position == null || !mounted) return;

    setState(() => _currentLocation = position);

    if (_mapReady) {
      if (_isNavigating) {
        _moveCameraWithLocationBelowCenter(
          position,
          zoom: _navigationZoom,
          heading: _currentHeading,
        );
      } else {
        _mapController.move(position, 17);
      }
    }
  }

  // Đặt camera sao cho vị trí GPS nằm thấp hơn tâm màn hình,
  // và bản đồ xoay theo hướng di chuyển (heading-up như Google Maps).
  void _moveCameraWithLocationBelowCenter(
    LatLng location, {
    double? zoom,
    double? heading,
  }) {
    if (!_mapReady) return;

    final targetZoom = zoom ?? _mapController.camera.zoom;
    final rotation =
        heading != null ? -heading : _mapController.camera.rotation;

    _mapController.moveAndRotate(location, targetZoom, rotation);

    final camera = _mapController.camera;
    final size = camera.nonRotatedSize;

    final targetScreenPoint =
        Offset(size.width / 2, size.height * _gpsScreenYRatio);
    final targetLatLng = camera.screenOffsetToLatLng(targetScreenPoint);

    final latitudeShift = location.latitude - targetLatLng.latitude;
    final longitudeShift = location.longitude - targetLatLng.longitude;

    _mapController.moveAndRotate(
      LatLng(
        camera.center.latitude + latitudeShift,
        camera.center.longitude + longitudeShift,
      ),
      targetZoom,
      rotation,
    );
  }

  double _smoothHeading(double? previous, double next) {
    if (previous == null) return next;
    final diff = ((next - previous + 540) % 360) - 180;
    return (previous + diff * 0.3 + 360) % 360;
  }

  double? _initialRouteBearing(LatLng from) {
    if (_routePoints.length < 2) return null;
    for (final p in _routePoints) {
      final d = Geolocator.distanceBetween(
        from.latitude,
        from.longitude,
        p.latitude,
        p.longitude,
      );
      if (d >= 15) {
        final b = Geolocator.bearingBetween(
          from.latitude,
          from.longitude,
          p.latitude,
          p.longitude,
        );
        return (b + 360) % 360;
      }
    }
    return null;
  }

  Future<void> _startGpsTracking() async {
    try {
      await _gpsSubscription?.cancel();

      _gpsSubscription =
          html.window.navigator.geolocation.watchPosition().listen(
        (html.Geoposition position) {
          final latitude = position.coords?.latitude;
          final longitude = position.coords?.longitude;
          if (latitude == null || longitude == null) return;

          final newPosition = LatLng(
            latitude.toDouble(),
            longitude.toDouble(),
          );

          final reportedHeading = position.coords?.heading;
          double? heading =
              reportedHeading != null && reportedHeading.isFinite
                  ? reportedHeading.toDouble()
                  : null;

          final previousLocation = _currentLocation;
          if (heading == null && previousLocation != null) {
            final movedMeters = Geolocator.distanceBetween(
              previousLocation.latitude,
              previousLocation.longitude,
              newPosition.latitude,
              newPosition.longitude,
            );
            if (movedMeters >= 2) {
              heading = Geolocator.bearingBetween(
                previousLocation.latitude,
                previousLocation.longitude,
                newPosition.latitude,
                newPosition.longitude,
              );
              heading = (heading + 360) % 360;
            }
          }

          if (heading != null && heading.isFinite) {
            _currentHeading = _smoothHeading(_currentHeading, heading);
          }

          if (!mounted) return;
          setState(() => _currentLocation = newPosition);

          if (_isNavigating) {
            _moveCameraWithLocationBelowCenter(
              newPosition,
              heading: _currentHeading,
            );
          }

          final destination = _navigationDestination;
          final lastStart = _lastRouteStart;
          if (destination != null && lastStart != null && !_isUpdatingRoute) {
            final movedMeters = Geolocator.distanceBetween(
              lastStart.latitude,
              lastStart.longitude,
              newPosition.latitude,
              newPosition.longitude,
            );

            if (movedMeters >= 30) {
              _isUpdatingRoute = true;
              _getRoute(destination).whenComplete(() {
                _isUpdatingRoute = false;
              });
            }
          }
        },
        onError: (Object error) {
          debugPrint('Lỗi theo dõi GPS: $error');
        },
      );
    } catch (e) {
      debugPrint('Không thể bắt đầu theo dõi GPS: $e');
    }
  }

  bool _isStarting = false;

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _startNavigation() async {
    if (_isStarting || _isNavigating) return;

    if (_selectedLocation == null) {
      _showMessage('Vui lòng chọn điểm đến trước.');
      return;
    }

    _isStarting = true;
    try {
      // Đọc GPS mới; nếu thất bại thì dùng vị trí gần nhất đã biết.
      final position = await _readBrowserPosition() ?? _currentLocation;
      if (position == null) {
        _showMessage(
            'Không lấy được vị trí GPS. Hãy cho phép truy cập vị trí và thử lại.');
        return;
      }
      if (!mounted) return;

      // Tính tuyến trước, chỉ vào chế độ dẫn đường khi có tuyến hợp lệ.
      final ok = await _getRoute(
        _selectedLocation!,
        startLocation: position,
      );
      if (!mounted) return;
      if (!ok && _routePoints.isEmpty) {
        _showMessage('Không lấy được tuyến đường. Vui lòng thử lại sau vài giây.');
        return;
      }

      setState(() {
        _currentLocation = position;
        _isNavigating = true;
        _navigationDestination = _selectedLocation;
        _currentManeuverIndex = 0;
      });

      _currentHeading ??= _initialRouteBearing(position);
      _moveCameraWithLocationBelowCenter(
        position,
        zoom: _navigationZoom,
        heading: _currentHeading,
      );
      await _startGpsTracking();
    } catch (e) {
      debugPrint('Lỗi khi bắt đầu dẫn đường: $e');
      _showMessage('Không thể bắt đầu dẫn đường: $e');
    } finally {
      _isStarting = false;
    }
  }

  void _stopNavigation() {
    setState(() {
      _isNavigating = false;
      _navigationDestination = null;
      _currentManeuverIndex = 0;
    });
    _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _isUpdatingRoute = false;

    if (_mapReady) _mapController.rotate(0);
    _currentHeading = null;
  }

  void _clearRoute() {
    _stopNavigation();
    setState(() {
      _routePoints = [];
      _routeDistance = null;
      _routeDuration = null;
      _selectedLocation = null;
      _maneuvers = [];
      _lastRouteStart = null;
    });
  }

  void _selectResult(dynamic result) {
    final latitude = double.parse(result['lat'].toString());
    final longitude = double.parse(result['lon'].toString());
    final destination = LatLng(latitude, longitude);

    setState(() {
      _selectedLocation = destination;
      _searchResults = [];
      _routePoints = [];
      _routeDistance = null;
      _routeDuration = null;
      _maneuvers = [];
      _lastRouteStart = null;
    });

    if (_mapReady) _mapController.move(destination, 15);
    _getRoute(destination);
    FocusScope.of(context).unfocus();
  }

  void _toggleAvoidFerry() {
    setState(() => _avoidFerry = !_avoidFerry);
    if (_selectedLocation != null) _getRoute(_selectedLocation!);
  }

  void _changeMode(String mode) {
    if (_travelMode == mode) return;
    setState(() => _travelMode = mode);
    if (_selectedLocation != null) _getRoute(_selectedLocation!);
  }

  // -------------------------------------------------------------------------
  // UI: các thành phần nhỏ
  // -------------------------------------------------------------------------
  List<BoxShadow> get _softShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.18),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ];

  Widget _buildSearchBar() {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: _softShadow,
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.search, color: AppColors.primary),
            onPressed: _searchPlace,
          ),
          Expanded(
            child: TextField(
              controller: _searchController,
              onSubmitted: (_) => _searchPlace(),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 16, color: AppColors.ink),
              decoration: const InputDecoration(
                hintText: 'Tìm địa điểm...',
                hintStyle: TextStyle(color: AppColors.inkSoft),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox(width: 12);
              return IconButton(
                icon: const Icon(Icons.close, color: AppColors.inkSoft),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchResults = []);
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _modeChip(String label, IconData icon, String mode) {
    final selected = _travelMode == mode;
    return GestureDetector(
      onTap: () => _changeMode(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: _softShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? Colors.white : AppColors.inkSoft,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleChip(String label, IconData icon, bool value, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: value ? AppColors.primary.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: value ? AppColors.primary : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: _softShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.check : icon,
              size: 18,
              color: value ? AppColors.primary : AppColors.inkSoft,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: value ? AppColors.primary : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: _softShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        shrinkWrap: true,
        itemCount: _searchResults.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, indent: 64, endIndent: 16),
        itemBuilder: (context, index) {
          final result = _searchResults[index];
          final parts = result['display_name'].toString().split(', ');
          final title = parts.first;
          final subtitle = parts.length > 1 ? parts.skip(1).join(', ') : '';
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: AppColors.primary.withValues(alpha: 0.12),
              child: const Icon(Icons.place, color: AppColors.primary),
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: subtitle.isEmpty
                ? null
                : Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _selectResult(result),
          );
        },
        ),
      ),
    );
  }

  Widget _buildManeuverBanner() {
    final index = _currentManeuverIndex.clamp(0, _maneuvers.length - 1);
    final maneuver = _maneuvers[index];
    final instruction =
        (maneuver['instruction'] ?? 'Tiếp tục đi').toString();
    final meters = ((maneuver['length'] as num?)?.toDouble() ?? 0) * 1000;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: _softShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(
              _getManeuverIcon(maneuver),
              size: 40,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatDistance(meters),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  instruction,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
    Color? iconColor,
    Color background = Colors.white,
  }) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        boxShadow: _softShadow,
      ),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: iconColor ?? AppColors.primary, size: 26),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildCompass() {
    return ValueListenableBuilder<double>(
      valueListenable: _mapRotation,
      builder: (context, rotation, _) {
        if (rotation.abs() < 0.5) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: _softShadow,
            ),
            child: IconButton(
              tooltip: 'Hướng bắc',
              onPressed: () => _mapController.rotate(0),
              icon: Transform.rotate(
                angle: rotation * math.pi / 180,
                child: const Icon(
                  Icons.navigation,
                  color: AppColors.danger,
                  size: 28,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAttribution() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        '© OpenStreetMap contributors',
        style: TextStyle(fontSize: 10, color: AppColors.inkSoft),
      ),
    );
  }

  Widget _buildRoutePanel() {
    final distance = _routeDistance!;
    final duration = _routeDuration!;
    final modeIcon = _travelMode == 'motor_scooter'
        ? Icons.two_wheeler
        : Icons.directions_car;

    if (_isNavigating) {
      // Thanh gọn khi đang dẫn đường
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: _softShadow,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatDuration(duration),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                  Text(
                    '${_formatDistance(distance)} · Đến lúc ${_formatArrival(duration)}',
                    style: const TextStyle(color: AppColors.inkSoft),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _stopNavigation,
              icon: const Icon(Icons.close),
              label: const Text('Thoát'),
            ),
          ],
        ),
      );
    }

    // Bảng thông tin đầy đủ trước khi bắt đầu
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: _softShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(modeIcon, color: AppColors.primary, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDuration(duration),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                    Text(
                      '${_formatDistance(distance)} · Đến lúc ${_formatArrival(duration)}',
                      style: const TextStyle(color: AppColors.inkSoft),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: AppColors.inkSoft),
                onPressed: _clearRoute,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: _startNavigation,
                icon: const Icon(Icons.navigation),
                label: const Text(
                  'Bắt đầu',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentLocationMarker() {
    if (_isNavigating) {
      // Mũi tên dẫn đường (bản đồ đã xoay nên mũi tên luôn chỉ lên trên)
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: _softShadow,
        ),
        child: const Center(
          child: Icon(Icons.navigation, color: AppColors.route, size: 50),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.route.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: AppColors.route,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: _softShadow,
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // build
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final hasRoute = _routeDistance != null && _routeDuration != null;

    return Scaffold(
      body: Stack(
        children: [
          // ---------------- Bản đồ toàn màn hình ----------------
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(10.762622, 106.660172),
              initialZoom: 12,
              onPositionChanged: (camera, hasGesture) {
                final r = camera.rotation;
                if ((r - _mapRotation.value).abs() < 0.1) return;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _mapRotation.value = r;
                });
              },
              onMapReady: () {
                _mapReady = true;
                if (_currentLocation != null) {
                  if (_isNavigating) {
                    _moveCameraWithLocationBelowCenter(
                      _currentLocation!,
                      zoom: _navigationZoom,
                      heading: _currentHeading,
                    );
                  } else {
                    _mapController.move(_currentLocation!, 15);
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.my_map',
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 7,
                      color: AppColors.route,
                      borderStrokeWidth: 2.5,
                      borderColor: Colors.white,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                  ],
                ),
              if (_selectedLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _selectedLocation!,
                      width: 50,
                      height: 50,
                      alignment: Alignment.topCenter, // mũi ghim chạm đúng điểm
                      rotate: true,
                      child: const Icon(
                        Icons.location_pin,
                        color: AppColors.danger,
                        size: 48,
                      ),
                    ),
                  ],
                ),
              if (_currentLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentLocation!,
                      width: _isNavigating ? 88 : 64,
                      height: _isNavigating ? 88 : 64,
                      rotate: true,
                      child: _buildCurrentLocationMarker(),
                    ),
                  ],
                ),
            ],
          ),

          // ---------------- Lớp phía trên cùng ----------------
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_isNavigating && _maneuvers.isNotEmpty)
                    _buildManeuverBanner()
                  else if (!_isNavigating) ...[
                    _buildSearchBar(),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            _modeChip(
                                'Xe máy', Icons.two_wheeler, 'motor_scooter'),
                            const SizedBox(width: 10),
                            _modeChip('Ô tô', Icons.directions_car, 'auto'),
                            const SizedBox(width: 10),
                            _toggleChip('Tránh phà', Icons.directions_boat,
                                _avoidFerry, _toggleAvoidFerry),
                            const SizedBox(width: 12),
                            if (_isLoadingRoute)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.5),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (_searchResults.isNotEmpty) _buildSearchResults(),
                  ],
                ],
              ),
            ),
          ),

          // ---------------- Lớp phía dưới: nút + bảng thông tin ----------------
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _buildAttribution(),
                        const Spacer(),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildCompass(),
                            _roundButton(
                              icon: Icons.my_location,
                              tooltip: 'Vị trí của tôi',
                              onPressed: _getCurrentLocation,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (hasRoute)
                    Padding(
                      padding: _isNavigating
                          ? const EdgeInsets.fromLTRB(16, 0, 16, 12)
                          : EdgeInsets.zero,
                      child: _buildRoutePanel(),
                    )
                  else
                    const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}