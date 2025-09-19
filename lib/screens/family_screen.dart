// lib/screens/family_screen.dart (updated)
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';

class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key});

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  List<Map<String, dynamic>> _familyMembers = [];
  bool _isLoading = true;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadFamilyMembers();
  }

  Future<void> _loadFamilyMembers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'User not authenticated';
      });
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data()!;
        final familyMember = data['familyMember'];

        List<Map<String, dynamic>> members = [];

        if (familyMember != null && familyMember is Map<String, dynamic>) {
          // since it's a single map, put it into a list
          members.add({
            ...familyMember,
            'safetyScore': 100.0,
            'status': 'Safe',
            'lastUpdated': DateTime.now().millisecondsSinceEpoch,
          });
        }
        if (mounted) {
          setState(() {
            _familyMembers = members;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading family members: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load family members: ${e.toString()}';
        });
      }
    }
  }

  Future<Map<String, dynamic>> _getFamilyMemberSafetyData(
    Map<String, dynamic> member,
  ) async {
    try {
      // Try to find a user with matching details
      QuerySnapshot querySnapshot;

      // Try to find by ID number first
      if (member['idNumber'] != null) {
        querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .where('idNumber', isEqualTo: member['idNumber'])
            .limit(1)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final memberId = querySnapshot.docs.first.id;
          return await _getSafetyDataFromRealtimeDB(memberId);
        }
      }

      // If not found by ID, try by name
      if (member['name'] != null) {
        querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .where('name', isEqualTo: member['name'])
            .limit(1)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final memberId = querySnapshot.docs.first.id;
          return await _getSafetyDataFromRealtimeDB(memberId);
        }
      }
    } catch (e) {
      debugPrint('Error getting safety data: $e');
    }

    // Return default safe values if no data found
    return {
      'safetyScore': 100.0,
      'status': 'Safe',
      'latitude': null,
      'longitude': null,
      'timestamp': null,
    };
  }

  Future<Map<String, dynamic>> _getSafetyDataFromRealtimeDB(
    String memberId,
  ) async {
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref('users/$memberId')
          .get();

      if (snapshot.exists) {
        final data = snapshot.value as Map<dynamic, dynamic>;
        return {
          'safetyScore': data['safetyScore']?.toDouble() ?? 100.0,
          'status': data['status'] ?? 'Safe',
          'latitude': data['latitude']?.toDouble(),
          'longitude': data['longitude']?.toDouble(),
          'timestamp': data['timestamp'],
        };
      }
    } catch (e) {
      debugPrint('Error getting realtime safety data: $e');
    }

    return {
      'safetyScore': 100.0,
      'status': 'Safe',
      'latitude': null,
      'longitude': null,
      'timestamp': null,
    };
  }

  Color _getSafetyColor(double score) {
    if (score > 80) return Colors.green;
    if (score > 60) return Colors.orange;
    return Colors.red;
  }

  String _getSafetyStatus(double score) {
    if (score > 80) return 'Safe';
    if (score > 60) return 'Moderate';
    if (score > 40) return 'Caution';
    return 'Danger';
  }

  Widget _buildMemberCard(Map<String, dynamic> member) {
    final safetyScore = member['safetyScore'] ?? 100.0;
    final status = member['status'] ?? _getSafetyStatus(safetyScore);
    final bloodGroup = member['bloodGroup'] ?? 'Not specified';
    final idNumber = member['idNumber'] ?? 'N/A';
    final idType = member['idType'] ?? 'N/A';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.blue[100],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.person, color: Colors.blue[800], size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member['name'] ?? 'Unknown',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'ID: $idNumber',
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _getSafetyColor(safetyScore).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _getSafetyColor(safetyScore),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: _getSafetyColor(safetyScore),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
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
                        'Blood Group: $bloodGroup',
                        style: const TextStyle(fontSize: 14),
                      ),
                      Text(
                        'ID Type: $idType',
                        style: const TextStyle(fontSize: 14),
                      ),
                      Text(
                        'Nationality: ${member['nationality'] ?? 'N/A'}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
                Column(
                  children: [
                    Text(
                      '${safetyScore.toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: _getSafetyColor(safetyScore),
                      ),
                    ),
                    const Text(
                      'Safety Score',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: safetyScore / 100,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(
                _getSafetyColor(safetyScore),
              ),
              borderRadius: BorderRadius.circular(10),
              minHeight: 8,
            ),
            if (member['lastUpdated'] != null) ...[
              const SizedBox(height: 8),
              Text(
                'Last updated: ${_formatTimestamp(member['lastUpdated'])}',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp == null) return 'Unknown';

    try {
      if (timestamp is int) {
        final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
        return '${date.hour}:${date.minute.toString().padLeft(2, '0')}';
      } else if (timestamp is String) {
        return timestamp;
      }
    } catch (e) {
      debugPrint('Error formatting timestamp: $e');
    }

    return 'Recent';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Family Members'),
          backgroundColor: Colors.blue[800],
          foregroundColor: Colors.white,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Family Members'),
          backgroundColor: Colors.blue[800],
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
              const SizedBox(height: 16),
              Text(
                _errorMessage,
                style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _loadFamilyMembers,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Family Members',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.blue[800],
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFamilyMembers,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _familyMembers.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.group, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    'No family members found',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Add family members in your profile',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadFamilyMembers,
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _familyMembers.length,
                itemBuilder: (context, index) {
                  return _buildMemberCard(_familyMembers[index]);
                },
              ),
            ),
    );
  }
}
