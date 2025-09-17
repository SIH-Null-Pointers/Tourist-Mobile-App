import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:location/location.dart';
import 'package:url_launcher/url_launcher.dart';

class PanicScreen extends StatefulWidget {
  const PanicScreen({super.key});

  @override
  State<PanicScreen> createState() => _PanicScreenState();
}

class _PanicScreenState extends State<PanicScreen> {
  bool _isLoading = false;
  bool _alertSent = false;
  String _statusMessage = '';
  String? _activeAlertId;
  final Location _locationService = Location();

  @override
  void initState() {
    super.initState();
    _triggerPanicAlert();
  }

  Future<void> _triggerPanicAlert() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Triggering emergency alert...';
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error: User not authenticated';
      });
      return;
    }

    try {
      // Get current location
      Map<String, dynamic>? coordinates = await _getCurrentLocation();

      // Get user profile data
      Map<String, dynamic>? userProfile = await _getUserProfile(user.uid);

      if (userProfile == null) {
        setState(() {
          _isLoading = false;
          _statusMessage = 'Error: Could not load user profile';
        });
        return;
      }

      // Create alert document
      DocumentReference alertDoc =
          await FirebaseFirestore.instance.collection('panic_alerts').add({
        'userId': user.uid,
        'alertActive': true,
        'timestamp': FieldValue.serverTimestamp(),
        'location': coordinates ??
            {
              'latitude': 0.0,
              'longitude': 0.0,
              'error': true, // consistent typing: bool flag
            },
        'userInfo': {
          'name': userProfile['name'] ?? 'Unknown',
          'nationality': userProfile['nationality'] ?? 'Unknown',
          'passport': userProfile['passport'] ?? 'Unknown',
          'id': userProfile['id'] ?? 'Unknown',
          'trip_start': userProfile['trip_start'] ?? 'Unknown',
          'trip_end': userProfile['trip_end'] ?? 'Unknown',
        },
        'message': 'A user has used the panic button',
        'alertType': 'panic',
        'status': 'pending', // pending, acknowledged, resolved
        'adminResponse': null,
      });

      setState(() {
        _isLoading = false;
        _alertSent = true;
        _activeAlertId = alertDoc.id;
        _statusMessage = 'Emergency alert sent successfully!';
      });

      // Also log to panic_logs
      await FirebaseFirestore.instance.collection('panic_logs').add({
        'userId': user.uid,
        'timestamp': FieldValue.serverTimestamp(),
        'triggered': true,
        'alertId': alertDoc.id,
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error sending alert: ${e.toString()}';
      });

      // Fallback to phone call
      _fallbackToPhoneCall();
    }
  }

  Future<Map<String, dynamic>?> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _locationService.requestService();
        if (!serviceEnabled) return null;
      }

      PermissionStatus permissionGranted =
          await _locationService.hasPermission();
      if (permissionGranted == PermissionStatus.denied) {
        permissionGranted = await _locationService.requestPermission();
        if (permissionGranted != PermissionStatus.granted) return null;
      }

      final locationData = await _locationService.getLocation();
      return {
        'latitude': locationData.latitude ?? 0.0,
        'longitude': locationData.longitude ?? 0.0,
      };
    } catch (e) {
      debugPrint('Location error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getUserProfile(String userId) async {
    try {
      DocumentSnapshot userDoc =
          await FirebaseFirestore.instance.collection('users').doc(userId).get();

      if (userDoc.exists) {
        return userDoc.data() as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      debugPrint('Profile fetch error: $e');
      return null;
    }
  }

  Future<void> _fallbackToPhoneCall() async {
    final Uri phoneUri = Uri(scheme: 'tel', path: '112');
    try {
      await launchUrl(phoneUri, mode: LaunchMode.externalNonBrowserApplication);
      setState(() {
        _statusMessage = 'Alert failed - calling emergency services...';
      });
    } catch (e) {
      setState(() {
        _statusMessage =
            'All emergency methods failed. Please call 112 manually.';
      });
    }
  }

  Future<void> _cancelAlert() async {
    if (_activeAlertId == null) return;

    setState(() => _isLoading = true);

    try {
      await FirebaseFirestore.instance
          .collection('panic_alerts')
          .doc(_activeAlertId)
          .update({
        'alertActive': false,
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancelledBy': 'user',
      });

      setState(() {
        _isLoading = false;
        _alertSent = false;
        _statusMessage = 'Alert cancelled successfully';
      });

      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.pop(context);
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = 'Error cancelling alert: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final red700 = Colors.red.shade700;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Emergency Alert',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: red700,
        foregroundColor: Colors.white,
        elevation: 5,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.red.shade50, Colors.white],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Status icon
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _alertSent
                          ? Colors.green.withOpacity(0.3)
                          : Colors.red.withOpacity(0.3),
                      blurRadius: 15,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: _isLoading
                    ? const CircularProgressIndicator(
                        color: Colors.red,
                        strokeWidth: 3,
                      )
                    : Icon(
                        _alertSent ? Icons.check_circle : Icons.warning,
                        size: 100,
                        color: _alertSent ? Colors.green : Colors.red,
                      ),
              ),
              const SizedBox(height: 30),

              // Title
              Text(
                _alertSent ? 'EMERGENCY ALERT SENT' : 'EMERGENCY ALERT',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: _alertSent ? Colors.green : Colors.red,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),

              // Status message
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  _statusMessage.isNotEmpty
                      ? _statusMessage
                      : 'Sending your location and details to emergency services...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 30),

              // When alert sent
              if (_alertSent) ...[
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.green.withOpacity(0.2)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.notifications_active, color: Colors.green),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Admin has been notified of your emergency',
                          style: TextStyle(color: Colors.green),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _cancelAlert,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel Alert'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                  ),
                ),
              ]
              // When preparing alert
              else if (!_isLoading) ...[
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.red.withOpacity(0.2)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.location_on, color: Colors.red),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Preparing to share your location with authorities',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.pop(context),
        backgroundColor: Colors.grey,
        foregroundColor: Colors.white,
        child: const Icon(Icons.arrow_back),
      ),
    );
  }
}
