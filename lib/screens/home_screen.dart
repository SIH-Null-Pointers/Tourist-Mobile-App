// lib/screens/home_screen.dart (final fixed version)

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'panic_screen.dart';
import 'profile_screen.dart';
import 'family_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  double safetyScore = 85.0;
  String alertStatus = 'Safe';
  bool _isPanicActive = false;
  Timer? _timer;
  Timer? _locationTimer;
  Timer? _firestoreLocationTimer;
  LatLng? currentLocation;
  final Location _locationService = Location();
  final MapController _mapController = MapController();
  bool _isLoading = true;
  StreamSubscription<DatabaseEvent>? _panicListener;
  bool _mapIsReady = false;
  late List<Map<String, dynamic>> safeZones = [];
  bool _locationInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadSafeZones();
    _checkPanicStatus();
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) _updateSafetyStatus();
    });
    _initializeLocation();
  }

  Future<void> _loadSafeZones() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('safe_zones')
          .get();
      if (mounted) {
        setState(() {
          safeZones = snapshot.docs.map((doc) {
            final data = doc.data();
            return {
              'id': doc.id,
              'lat': (data['lat'] as num?)?.toDouble() ?? 0.0,
              'lng': (data['lng'] as num?)?.toDouble() ?? 0.0,
              'radius': (data['radius'] as num?)?.toDouble() ?? 500.0,
            };
          }).toList();
        });
      }
    } catch (e) {
      if (mounted) setState(() => safeZones = []);
    }
  }

  Future<void> _initializeLocation() async {
    try {
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled)
        serviceEnabled = await _locationService.requestService();
      if (!serviceEnabled) return _handleLocationFailure();

      PermissionStatus permission = await _locationService.hasPermission();
      if (permission == PermissionStatus.denied) {
        permission = await _locationService.requestPermission();
        if (permission != PermissionStatus.granted)
          return _handleLocationFailure();
      }

      final locationData = await _locationService.getLocation();
      final lat = locationData.latitude ?? 20.5937;
      final lng = locationData.longitude ?? 78.9629;

      if (!mounted) return;

      setState(() {
        currentLocation = LatLng(lat, lng);
        _isLoading = false;
        _locationInitialized = true;
      });

      await _updateUserLocation();
      await _storeLocationInFirestore();
      _updateSafetyStatus();

      _startLocationUpdates();
      _startFirestoreLocationStorage();
    } catch (e) {
      _handleLocationFailure();
    }
  }

  void _handleLocationFailure() {
    if (!mounted) return;
    setState(() {
      currentLocation = const LatLng(20.5937, 78.9629);
      _isLoading = false;
      _locationInitialized = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _updateUserLocation();
      await _storeLocationInFirestore();
      _updateSafetyStatus();
      _startLocationUpdates();
      _startFirestoreLocationStorage();
    });
  }

  void _startLocationUpdates() {
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _updateUserLocation(),
    );
  }

  void _startFirestoreLocationStorage() {
    _firestoreLocationTimer?.cancel();
    _firestoreLocationTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _storeLocationInFirestore(),
    );
  }

  Future<void> _updateUserLocation() async {
    try {
      final locationData = await _locationService.getLocation();
      final newLocation = LatLng(
        locationData.latitude ?? currentLocation?.latitude ?? 20.5937,
        locationData.longitude ?? currentLocation?.longitude ?? 78.9629,
      );

      if (currentLocation != null) {
        final distance = _calculateDistance(
          currentLocation!.latitude,
          currentLocation!.longitude,
          newLocation.latitude,
          newLocation.longitude,
        );
        if (distance > 10) {
          setState(() => currentLocation = newLocation);
          if (_mapIsReady) _mapController.move(newLocation, 13.0);
        }
      } else {
        setState(() => currentLocation = newLocation);
      }

      // First update safety score based on new location
      _updateSafetyStatus();

      // Then push to Realtime Database with latest safetyScore
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseDatabase.instance.ref('users/${user.uid}').update({
          'latitude': newLocation.latitude,
          'longitude': newLocation.longitude,
          'timestamp': ServerValue.timestamp,
          'safetyScore': safetyScore,
          'status': alertStatus,
        });
        print(
          'RTDB updated: lat=${newLocation.latitude}, lng=${newLocation.longitude}, score=$safetyScore',
        );
      }
    } catch (e) {
      debugPrint('Location update error: $e');
    }
  }

  Future<void> _storeLocationInFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && currentLocation != null) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('location_history')
          .add({
            'latitude': currentLocation!.latitude,
            'longitude': currentLocation!.longitude,
            'timestamp': FieldValue.serverTimestamp(),
          });
    }
  }

  double _degreesToRadians(double degrees) => degrees * pi / 180;

  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000; // meters
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  void _updateSafetyStatus() {
    if (currentLocation == null) return;

    if (safeZones.isEmpty) {
      safetyScore = 0.0;
    } else {
      double minDistance = double.infinity;
      double nearestRadius = 500.0;

      for (var zone in safeZones) {
        final double zoneLat = zone['lat'] as double;
        final double zoneLng = zone['lng'] as double;
        final double zoneRadius = zone['radius'] as double;

        final dist = _calculateDistance(
          currentLocation!.latitude,
          currentLocation!.longitude,
          zoneLat,
          zoneLng,
        );

        if (dist < minDistance) {
          minDistance = dist;
          nearestRadius = zoneRadius;
        }
      }

      safetyScore = minDistance > nearestRadius
          ? 0.0
          : 100 * (1 - minDistance / nearestRadius);
    }

    alertStatus = safetyScore > 50 ? 'Safe' : 'Alert';

    if (mounted) setState(() {});

    // Update safetyScore in Firestore user document
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'safetyScore': safetyScore})
          .catchError((e) => debugPrint('Firestore update error: $e'));
    }
  }

  Future<void> _checkPanicStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _panicListener = FirebaseDatabase.instance
        .ref('panic_alerts/${user.uid}')
        .onValue
        .listen((event) {
          final data = event.snapshot.value as Map<dynamic, dynamic>?;
          final active = data?['alertActive'] == true;
          if (mounted) setState(() => _isPanicActive = active);
        });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _locationTimer?.cancel();
    _firestoreLocationTimer?.cancel();
    _panicListener?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || currentLocation == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: currentLocation!,
              initialZoom: 13.0,
              onMapReady: () => _mapIsReady = true,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
              ),
              CircleLayer(
                circles: safeZones.map((zone) {
                  return CircleMarker(
                    point: LatLng(zone['lat'] as double, zone['lng'] as double),
                    radius: zone['radius'] as double,
                    useRadiusInMeter: true,
                    color: Colors.green.withOpacity(0.3),
                    borderColor: Colors.green,
                    borderStrokeWidth: 2,
                  );
                }).toList(),
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: currentLocation!,
                    width: 50,
                    height: 50,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _isPanicActive
                            ? Colors.red.withOpacity(0.3)
                            : Colors.blue.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.location_on,
                        color: _isPanicActive ? Colors.red : Colors.red,
                        size: 30,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            top: 50,
            left: 16,
            right: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Safety Score: ${safetyScore.toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      alertStatus,
                      style: TextStyle(
                        fontSize: 18,
                        color: alertStatus == 'Safe'
                            ? Colors.green
                            : Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 16,
            right: 32,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white,
              onPressed: _updateUserLocation,
              child: Icon(Icons.my_location, color: Colors.blue[800]),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _isPanicActive
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PanicScreen(),
                          ),
                        ),
                  icon: const Icon(Icons.warning, size: 20),
                  label: const Text('Panic'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isPanicActive ? Colors.grey : Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  ),
                  icon: const Icon(Icons.person, size: 20),
                  label: const Text('Profile'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[800],
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.blue.withOpacity(0.2)),
            ),
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FamilyScreen()),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.group,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Family Tracking',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.blue,
                          ),
                        ),
                        Text(
                          'View all family members and their safety status',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.blueGrey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.blue, size: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
