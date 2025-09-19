// lib/screens/home_screen.dart (updated)
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
              'lat': data['lat'] ?? 0.0,
              'lng': data['lng'] ?? 0.0,
              'radius': data['radius'] ?? 100.0,
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
    // Cancel existing timer if any
    _locationTimer?.cancel();

    // Update location every 10 seconds (for real-time database)
    _locationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _updateUserLocation();
    });
  }

  void _startFirestoreLocationStorage() {
    // Cancel existing timer if any
    _firestoreLocationTimer?.cancel();

    // Store location in Firestore every 30 minutes
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
          // Only update if moved more than 10 meters
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

      // Always update real-time database (every 10 seconds)
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

      // Update safety status
      _updateSafetyStatus();
    } catch (e) {
      print('Location update error: $e');
    }
  }

  void _updateSafetyStatus() {
    if (currentLocation == null || safeZones.isEmpty) return;

    double nearestDist = double.infinity;
    bool inSafeZone = false;

    // Check if user is in any safe zone
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

      // Track nearest safe zone
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
      // Calculate safety score based on distance to nearest safe zone
      const double maxDist = 5000.0; // 5km maximum distance
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

      // Store location history in Firestore every 30 minutes
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
    const R = 6371000; // Earth's radius in meters
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
        appBar: AppBar(
          title: const Text('Tourist Safety'),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Tourist Safety',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.blue[800],
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Safety Status Card
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Safety Score',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: safetyScore > 80
                            ? Colors.green
                            : safetyScore > 60
                            ? Colors.orange
                            : Colors.red,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        alertStatus,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: safetyScore / 100,
                  backgroundColor: Colors.grey[300],
                  valueColor: AlwaysStoppedAnimation<Color>(
                    safetyScore > 80
                        ? Colors.green
                        : safetyScore > 60
                        ? Colors.orange
                        : Colors.red,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  minHeight: 10,
                ),
                const SizedBox(height: 8),
                Text(
                  '${safetyScore.toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // Map Section
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withOpacity(0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: FlutterMap(
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
                          userAgentPackageName:
                              'com.example.tourist_safety_app',
                        ),
                        // Safe zones bubbles - sized to cover radius
                        MarkerLayer(
                          markers: safeZones.map((zone) {
                            final lat = zone['lat']?.toDouble() ?? 0.0;
                            final lng = zone['lng']?.toDouble() ?? 0.0;
                            final radius = zone['radius']?.toDouble() ?? 100.0;

                            // Calculate pixel size based on radius (1 meter ≈ 0.000009 degrees)
                            // Convert radius to degrees and then to pixels
                            final double radiusInDegrees = radius * 0.000009;
                            final double pixelSize =
                                radiusInDegrees *
                                100000; // Scale factor for visibility

                            return Marker(
                              point: LatLng(lat, lng),
                              width: pixelSize.clamp(
                                40.0,
                                300.0,
                              ), // Clamp between 40-300 pixels
                              height: pixelSize.clamp(40.0, 300.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.3),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.green,
                                    width: 2,
                                  ),
                                ),
                                child: Center(
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: const BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.safety_check,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
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
                                  color: _isPanicActive
                                      ? Colors.red
                                      : Colors.red,
                                  size: 30,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 16,
                  right: 32,
                  child: FloatingActionButton(
                    onPressed: _updateUserLocation,
                    mini: true,
                    backgroundColor: Colors.white,
                    child: Icon(Icons.my_location, color: Colors.blue[800]),
                  ),
                ),
              ],
            ),
          ),

          // Action Buttons
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Family Tracking Card
          Container(
            margin: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.blue.withOpacity(0.2)),
            ),
            child: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FamilyScreen()),
                );
              },
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
