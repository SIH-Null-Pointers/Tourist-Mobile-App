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
  final Random random = Random();
  Timer? _timer;
  Timer? _locationTimer;
  Timer? _firestoreLocationTimer;
  Timer? _safetyTimer;
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
      if (mounted) {
        _updateSafetyStatus();
      }
    });

    // Get initial location and start updates
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
              'lat': data['lat']?.toDouble() ?? 0.0,
              'lng': data['lng']?.toDouble() ?? 0.0,
              'radius': data['radius']?.toDouble() ?? 100.0,
            };
          }).toList();
        });
        print('Loaded ${safeZones.length} safe zones');
      }
    } catch (e) {
      debugPrint('Error loading safe zones: $e');
      if (mounted) {
        setState(() {
          safeZones = [];
        });
      }
    }
  }

  Future<void> _initializeLocation() async {
    try {
      print('Initializing location...');

      // Request permissions and service
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _locationService.requestService();
        if (!serviceEnabled) {
          print('Location service not enabled');
          _handleLocationFailure();
          return;
        }
      }

      PermissionStatus permissionGranted = await _locationService
          .hasPermission();
      if (permissionGranted == PermissionStatus.denied) {
        permissionGranted = await _locationService.requestPermission();
        if (permissionGranted != PermissionStatus.granted) {
          print('Location permission denied');
          _handleLocationFailure();
          return;
        }
      }

      // Get location
      print('Getting initial location...');
      final locationData = await _locationService.getLocation();

      if (!mounted) return;

      final lat = locationData.latitude ?? 20.5937;
      final lng = locationData.longitude ?? 78.9629;

      print('Location obtained: $lat, $lng');

      setState(() {
        currentLocation = LatLng(lat, lng);
        _isLoading = false;
        _locationInitialized = true;
      });

      // Initial database update
      await _updateUserLocation();

      // Store initial location in Firestore
      await _storeLocationInFirestore();

      // Update safety status
      _updateSafetyStatus();

      // Start location updates after initial load
      _startLocationUpdates();
      _startFirestoreLocationStorage();
    } catch (e) {
      print('Location initialization error: $e');
      _handleLocationFailure();
    }
  }

  void _handleLocationFailure() {
    if (!mounted) return;

    setState(() {
      currentLocation = const LatLng(20.5937, 78.9629); // India default
      _isLoading = false;
      _locationInitialized = true;
    });

    // Still update database with fallback location
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateUserLocation();
      _storeLocationInFirestore();
      _updateSafetyStatus();

      // Start location updates even with fallback
      _startLocationUpdates();
      _startFirestoreLocationStorage();
    });
  }

  void _startLocationUpdates() {
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _updateUserLocation();
    });
  }

  void _startFirestoreLocationStorage() {
    _firestoreLocationTimer?.cancel();
    _firestoreLocationTimer = Timer.periodic(const Duration(minutes: 30), (
      timer,
    ) {
      _storeLocationInFirestore();
    });
  }

  Future<void> _updateUserLocation() async {
    try {
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled) return;

      PermissionStatus permissionGranted = await _locationService
          .hasPermission();
      if (permissionGranted != PermissionStatus.granted) return;

      final locationData = await _locationService.getLocation();
      final newLocation = LatLng(
        locationData.latitude ?? currentLocation?.latitude ?? 20.5937,
        locationData.longitude ?? currentLocation?.longitude ?? 78.9629,
      );

      if (!mounted) return;

      // Update UI only if location changed significantly
      if (currentLocation != null) {
        final distance = _calculateDistance(
          currentLocation!.latitude,
          currentLocation!.longitude,
          newLocation.latitude,
          newLocation.longitude,
        );

        if (distance > 10) {
          setState(() {
            currentLocation = newLocation;
          });

          if (_mapIsReady) {
            _mapController.move(newLocation, 13.0);
          }
        }
      } else {
        setState(() {
          currentLocation = newLocation;
        });
      }

      // Always update real-time database
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
          'Real-time location updated: ${newLocation.latitude}, ${newLocation.longitude}',
        );
      }

      _updateSafetyStatus();
    } catch (e) {
      print('Location update error: $e');
    }
  }

  void _updateSafetyStatus() {
    if (currentLocation == null || safeZones.isEmpty) return;

    double nearestDist = double.infinity;
    bool inSafeZone = false;

    for (var zone in safeZones) {
      final lat = zone['lat']?.toDouble() ?? 0.0;
      final lng = zone['lng']?.toDouble() ?? 0.0;
      final radius = zone['radius']?.toDouble() ?? 100.0;

      final dist = _calculateDistance(
        currentLocation!.latitude,
        currentLocation!.longitude,
        lat,
        lng,
      );

      if (dist <= radius) {
        inSafeZone = true;
        break;
      }

      if (dist < nearestDist) {
        nearestDist = dist;
      }
    }

    double score;
    String status;

    if (inSafeZone) {
      score = 100.0;
      status = 'Safe';
    } else if (nearestDist == double.infinity) {
      score = 0.0;
      status = 'No Safe Zones Nearby';
    } else {
      const double maxDist = 5000.0;
      score = ((maxDist - nearestDist) / maxDist * 100).clamp(0.0, 100.0);

      if (nearestDist < 200) {
        status = 'Safe';
      } else if (nearestDist < 500) {
        status = 'Moderate';
      } else if (nearestDist < 1000) {
        status = 'Caution';
      } else {
        status = 'Danger - Reach Safe Zone';
        score = score.clamp(0.0, 20.0);
      }
    }

    if (mounted) {
      setState(() {
        safetyScore = score;
        alertStatus = status;
      });
    }
  }

  Future<void> _storeLocationInFirestore() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || currentLocation == null) return;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('location_history')
          .add({
            'latitude': currentLocation!.latitude,
            'longitude': currentLocation!.longitude,
            'timestamp': FieldValue.serverTimestamp(),
            'safetyScore': safetyScore,
            'status': alertStatus,
            'createdAt': DateTime.now().toIso8601String(),
          });

      print(
        'Location stored in Firestore: ${currentLocation!.latitude}, ${currentLocation!.longitude}',
      );
    } catch (e) {
      print('Firestore location storage error: $e');
    }
  }

  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const R = 6371000;
    final phi1 = _deg2rad(lat1);
    final phi2 = _deg2rad(lat2);
    final deltaPhi = _deg2rad(lat2 - lat1);
    final deltaLambda = _deg2rad(lon2 - lon1);

    final a =
        sin(deltaPhi / 2) * sin(deltaPhi / 2) +
        cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _deg2rad(double degrees) {
    return degrees * pi / 180;
  }

  Future<void> _checkPanicStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      print('No authenticated user found');
      return;
    }

    print('Checking panic status for user: ${user.uid}');

    try {
      final snapshot = await FirebaseDatabase.instance
          .ref('panic_alerts/${user.uid}')
          .get();

      print('Panic snapshot exists: ${snapshot.exists}');

      if (snapshot.exists) {
        final data = snapshot.value as Map<dynamic, dynamic>?;
        if (data != null && data['alertActive'] == true) {
          if (mounted) {
            setState(() {
              _isPanicActive = true;
            });
          }
        }
      }
    } catch (e) {
      print('Error checking panic status: $e');
    }
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
    if (_isLoading || !_locationInitialized) {
      return Scaffold(
        backgroundColor: Colors.grey[50],
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
              ),
              const SizedBox(height: 20),
              Text(
                'Getting your location...',
                style: TextStyle(color: Colors.grey[600], fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'Tourist Safety',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none, size: 24),
            onPressed: () {},
          ),
        ],
      ),
      body: Stack(
        children: [
          // Map background
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: currentLocation!,
              initialZoom: 13.0,
              onMapReady: () {
                setState(() {
                  _mapIsReady = true;
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'com.example.tourist_safety_app',
              ),
              // Safe zones
              CircleLayer(
                circles: safeZones.map((zone) {
                  return CircleMarker(
                    point: LatLng(zone['lat'], zone['lng']),
                    color: Colors.green.withOpacity(0.15),
                    borderColor: Colors.green.withOpacity(0.7),
                    borderStrokeWidth: 2,
                    useRadiusInMeter: true,
                    radius: zone['radius'],
                  );
                }).toList(),
              ),
              // Current location marker
              MarkerLayer(
                markers: [
                  Marker(
                    point: currentLocation!,
                    width: 50,
                    height: 50,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _isPanicActive
                            ? Colors.red.withOpacity(0.2)
                            : const Color(0xFF6366F1).withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.location_pin,
                        color: _isPanicActive
                            ? Colors.red
                            : const Color(0xFF6366F1),
                        size: 36,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Gradient overlay at top
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.4), Colors.transparent],
                ),
              ),
            ),
          ),

          // Main content
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: kToolbarHeight + 16),

                // Safety Status Card
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'SAFETY STATUS',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[600],
                                letterSpacing: 0.5,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: _getStatusColor().withOpacity(0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                alertStatus.toUpperCase(),
                                style: TextStyle(
                                  color: _getStatusColor(),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${safetyScore.toStringAsFixed(0)}%',
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF1F2937),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Safety Score',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 60,
                              height: 60,
                              child: Stack(
                                children: [
                                  CircularProgressIndicator(
                                    value: safetyScore / 100,
                                    backgroundColor: Colors.grey[200],
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      _getStatusColor(),
                                    ),
                                    strokeWidth: 6,
                                  ),
                                  Center(
                                    child: Icon(
                                      safetyScore > 80
                                          ? Icons.verified
                                          : safetyScore > 60
                                          ? Icons.warning_amber_rounded
                                          : Icons.dangerous,
                                      color: _getStatusColor(),
                                      size: 24,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const Spacer(),

                // Bottom action section
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        offset: const Offset(0, -5),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Action buttons
                      Row(
                        children: [
                          Expanded(
                            child: _buildActionButton(
                              icon: Icons.warning_amber_rounded,
                              label: 'Panic',
                              color: _isPanicActive ? Colors.grey : Colors.red,
                              onTap: _isPanicActive
                                  ? null
                                  : () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => const PanicScreen(),
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildActionButton(
                              icon: Icons.person_outline,
                              label: 'Profile',
                              color: const Color(0xFF6366F1),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const ProfileScreen(),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildActionButton(
                              icon: Icons.my_location,
                              label: 'Locate',
                              color: const Color(0xFF10B981),
                              onTap: _updateUserLocation,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // Family tracking card
                      InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const FamilyScreen(),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFFE2E8F0),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF6366F1,
                                  ).withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.group,
                                  color: Color(0xFF6366F1),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Family Tracking',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF1F2937),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'View family members and their safety status',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_ios_rounded,
                                color: Color(0xFF94A3B8),
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return Material(
      borderRadius: BorderRadius.circular(12),
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: onTap == null ? Colors.grey[300] : color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                color: onTap == null ? Colors.grey[500] : color,
                size: 24,
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: onTap == null ? Colors.grey[500] : color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getStatusColor() {
    if (safetyScore > 80) return const Color(0xFF10B981);
    if (safetyScore > 60) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }
}
