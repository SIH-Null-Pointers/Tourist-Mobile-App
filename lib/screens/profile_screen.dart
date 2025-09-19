import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/blockchain_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _userData;
  bool _isVerifying = false;
  String _verificationStatus = 'Checking...';
  final BlockchainService _blockchainService = BlockchainService();

  @override
  void initState() {
    super.initState();
    _blockchainService.initialize();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      if (doc.exists && mounted) {
        final data = doc.data()!;
        setState(() => _userData = data);

        // Verify blockchain integrity
        if (data['blockchain_address'] != null &&
            data['blockchain_hash'] != null) {
          await _verifyBlockchainIntegrity(
            data['blockchain_address'],
            data['blockchain_hash'],
          );
        }
      }
    }
  }

  Future<void> _verifyBlockchainIntegrity(
    String address,
    String storedHash,
  ) async {
    setState(() {
      _isVerifying = true;
      _verificationStatus = 'Verifying on blockchain...';
    });

    try {
      final isValid = await _blockchainService.verifyCredentialIntegrity(
        storedHash,
        address,
      );

      if (mounted) {
        setState(() {
          _verificationStatus = isValid ? '✅ Verified' : '❌ Tampered';
          _isVerifying = false;
        });

        // Log verification check
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await FirebaseFirestore.instance.collection('blockchain_logs').add({
            'userId': user.uid,
            'action': 'integrity_check',
            'blockchain_address': address,
            'is_valid': isValid,
            'timestamp': FieldValue.serverTimestamp(),
            'network': 'sepolia',
          });
        }

        if (!isValid) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Warning: Profile data may have been tampered with!',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _verificationStatus = 'Verification failed';
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _reverify() async {
    if (_userData?['blockchain_address'] != null &&
        _userData?['blockchain_hash'] != null) {
      await _verifyBlockchainIntegrity(
        _userData!['blockchain_address'],
        _userData!['blockchain_hash'],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_userData == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isVerified = _userData!['is_verified'] == true;
    final name = _userData!['name'] ?? 'Unknown';
    final nationality = _userData!['nationality'] ?? 'Unknown';
    final passport = _userData!['passport'] ?? 'Unknown';
    final tripStart = _userData!['trip_start'] ?? 'Unknown';
    final tripEnd = _userData!['trip_end'] ?? 'Unknown';
    final id = _userData!['id'] ?? 'Unknown';
    final blockchainAddress = _userData!['blockchain_address'] ?? 'Not set';
    final verificationTimestamp =
        _userData!['verification_timestamp'] as Timestamp?;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Digital ID Card',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.blue[800],
        foregroundColor: Colors.white,
        elevation: 5,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reverify,
            tooltip: 'Re-verify',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue[50]!, Colors.grey[100]!],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.all(20),
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
                  child: Padding(
                    padding: const EdgeInsets.all(25),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'TOURIST DIGITAL ID',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          height: 100,
                          width: 100,
                          decoration: BoxDecoration(
                            color: Colors.blue[100],
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isVerified ? Colors.green : Colors.orange,
                              width: 3,
                            ),
                          ),
                          child: Icon(
                            isVerified ? Icons.verified : Icons.warning,
                            color: isVerified ? Colors.green : Colors.orange,
                            size: 50,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _buildInfoRow('Name', name),
                        _buildInfoRow('Nationality', nationality),
                        _buildInfoRow('Passport', passport),
                        _buildInfoRow('Trip Start', tripStart),
                        _buildInfoRow('Trip End', tripEnd),
                        _buildInfoRow('ID', id),
                        const SizedBox(height: 15),
                        _buildBlockchainInfo(),
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(15),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Column(
                            children: [
                              QrImageView(
                                data:
                                    'Tourist ID: $id\nBlockchain: ${blockchainAddress.substring(0, 10)}...',
                                size: 150,
                                backgroundColor: Colors.white,
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _isVerifying
                                        ? Icons.hourglass_empty
                                        : (isVerified
                                              ? Icons.verified
                                              : Icons.error),
                                    color: _isVerifying
                                        ? Colors.blue
                                        : (isVerified
                                              ? Colors.green
                                              : Colors.red),
                                    size: 16,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    _verificationStatus,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _isVerifying
                                          ? Colors.blue
                                          : (isVerified
                                                ? Colors.green
                                                : Colors.red),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 15),
                        Row(
                          children: [
                            const Icon(
                              Icons.security,
                              color: Colors.green,
                              size: 16,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                'Blockchain-secured: Tamper-proof & Valid till trip end',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                        if (verificationTimestamp != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Last verified: ${_formatTimestamp(verificationTimestamp)}',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => _shareId(),
                        icon: const Icon(Icons.share),
                        label: const Text('Share ID'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue[800],
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        onPressed: _showDecryptedData,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('View Encrypted Data'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green[600],
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.blueGrey,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockchainInfo() {
    final blockchainAddress =
        _userData!['blockchain_address']?.toString() ?? 'Not set';
    String displayAddress;

    if (blockchainAddress == 'Not set') {
      displayAddress = 'Not set';
    } else if (blockchainAddress.length > 20) {
      displayAddress = '${blockchainAddress.substring(0, 20)}...';
    } else {
      displayAddress = blockchainAddress;
    }

    return Column(
      children: [
        _buildInfoRow('Blockchain Address', displayAddress),
        const SizedBox(height: 10),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.block, color: Colors.green, size: 16),
            ),
            const SizedBox(width: 8),
            const Text(
              'Secured by Ethereum Blockchain',
              style: TextStyle(
                fontSize: 12,
                color: Colors.green,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatTimestamp(Timestamp timestamp) {
    final date = timestamp.toDate();
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _shareId() async {
    // Implement sharing logic
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ID sharing functionality to be implemented'),
      ),
    );
  }

  Future<void> _showDecryptedData() async {
    if (_userData?['encrypted_data'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No encrypted data available')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Decrypted Credentials'),
        content: FutureBuilder<Map<String, dynamic>?>(
          future: _blockchainService.decryptCredentials(
            _userData!['encrypted_data'],
            _userData!['iv'],
            _userData!['encryption_key'],
            _userData!['userId'] ?? FirebaseAuth.instance.currentUser!.uid,
          ),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const CircularProgressIndicator();
            }
            if (snapshot.hasData && snapshot.data != null) {
              final data = snapshot.data!;
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: data.entries
                      .map(
                        (entry) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text('${entry.key}: ${entry.value}'),
                        ),
                      )
                      .toList(),
                ),
              );
            }
            return const Text('Failed to decrypt data');
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
