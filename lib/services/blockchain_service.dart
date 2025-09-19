import 'dart:convert';
import 'dart:math'; // Add this import for Random
import 'package:flutter/services.dart';
import 'package:web3dart/web3dart.dart';
import 'package:http/http.dart' as http;
import 'package:encrypt/encrypt.dart' as encrypt_pkg;
import 'package:crypto/crypto.dart';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';

class BlockchainService {
  static final BlockchainService _instance = BlockchainService._internal();
  factory BlockchainService() => _instance;
  BlockchainService._internal();

  final String _infuraUrl =
      'https://sepolia.infura.io/v3/YOUR_INFURA_PROJECT_ID';
  final String _contractAddress = 'YOUR_CONTRACT_ADDRESS';
  late Web3Client _client;
  late DeployedContract _contract;
  late ContractAbi _abi;
  late ContractFunction _storeHashFunction;
  late ContractFunction _getHashFunction;

  final encrypt_pkg.Encrypter _encrypter = encrypt_pkg.Encrypter(
    encrypt_pkg.AES(encrypt_pkg.Key.fromSecureRandom(32)),
  );
  encrypt_pkg.IV? _iv;

  final Random random = Random(); // Add this line

  Future<void> initialize() async {
    _client = Web3Client(_infuraUrl, http.Client());

    // Load ABI
    final abiJson = await rootBundle.loadString('assets/abi.json');
    final abi = jsonDecode(abiJson);
    _abi = ContractAbi.fromJson(abi, 'CredentialsStorage');

    _contract = DeployedContract(
      _abi,
      EthereumAddress.fromHex(_contractAddress),
    );

    _storeHashFunction = _contract.function('storeHash');
    _getHashFunction = _contract.function('getHash');
  }

  Future<Uint8List> generateUserPrivateKey() async {
    // Generate new private key for each user
    final privateKey = EthPrivateKey.createRandom(random);
    return privateKey.privateKey; // Fixed: returns hex string
  }

  String _generateEncryptionKey(String userId) {
    // Deterministic key from user ID + salt
    final bytes = utf8.encode('blockchain_salt_$userId');
    final digest = sha256.convert(bytes);
    return base64Encode(digest.bytes);
  }

  Future<Map<String, dynamic>> encryptCredentials(
    Map<String, dynamic> credentials,
    String userId,
  ) async {
    final encryptionKey = _generateEncryptionKey(userId);
    final key = encrypt_pkg.Key.fromBase64(encryptionKey);
    _iv = encrypt_pkg.IV.fromSecureRandom(16);

    final jsonStr = jsonEncode(credentials);
    final encrypter = encrypt_pkg.Encrypter(encrypt_pkg.AES(key));
    final encrypted = encrypter.encrypt(jsonStr, iv: _iv!);

    final hash = sha256.convert(utf8.encode(encrypted.base64)).toString();

    return {
      'encrypted_data': encrypted.base64,
      'iv': _iv!.base64,
      'hash': hash,
      'encryption_key': encryptionKey,
    };
  }

  Future<void> storeCredentialsOnBlockchain(
    String hash,
    String userPrivateKey,
  ) async {
    try {
      final credentialsEth = EthPrivateKey.fromHex(userPrivateKey);
      final address = await credentialsEth.extractAddress();

      await _client.sendTransaction(
        credentialsEth,
        Transaction.callContract(
          contract: _contract,
          function: _storeHashFunction,
          parameters: [hash],
        ),
        chainId: 11155111, // Sepolia
      );

      print('Credentials hash stored on blockchain for: $address');
    } catch (e) {
      print('Blockchain storage error: $e');
      rethrow;
    }
  }

  Future<String?> getOnChainHash(String userAddress) async {
    try {
      final address = EthereumAddress.fromHex(userAddress);
      final result = await _client.call(
        contract: _contract,
        function: _getHashFunction,
        params: [address],
      );

      if (result.isNotEmpty) {
        return result.first.toString();
      }
      return null;
    } catch (e) {
      print('Error fetching on-chain hash: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> decryptCredentials(
    String encryptedData,
    String ivBase64,
    String encryptionKey,
    String userId,
  ) async {
    try {
      final key = encrypt_pkg.Key.fromBase64(encryptionKey);
      final iv = encrypt_pkg.IV.fromBase64(ivBase64);
      final encrypter = encrypt_pkg.Encrypter(encrypt_pkg.AES(key));

      final decrypted = encrypter.decrypt64(encryptedData, iv: iv);
      return jsonDecode(decrypted) as Map<String, dynamic>;
    } catch (e) {
      print('Decryption error: $e');
      return null;
    }
  }

  Future<bool> verifyCredentialIntegrity(
    String storedHash,
    String userAddress,
  ) async {
    try {
      final onChainHash = await getOnChainHash(userAddress);
      return onChainHash == storedHash;
    } catch (e) {
      print('Verification error: $e');
      return false;
    }
  }
}
