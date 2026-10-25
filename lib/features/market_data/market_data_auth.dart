import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Per-installation authentication for the hosted market-data backend.
/// iOS stores the token in Keychain; web uses flutter_secure_storage's web backend
/// and therefore requires HTTPS (or localhost during development).
class MarketDataAuth {
  MarketDataAuth._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _tokenKey = 'trading_memory_market_data_device_token';

  static Future<String?> readToken() => _storage.read(key: _tokenKey);

  static Future<bool> hasToken() async => (await readToken())?.isNotEmpty ?? false;

  static Future<void> enroll({required String baseUrl, required String pairingCode}) async {
    final code = pairingCode.trim();
    if (code.isEmpty) throw const FormatException('Enter the server pairing code.');
    final response = await http.post(
      Uri.parse('$baseUrl/api/device/enroll'),
      headers: const {'Accept': 'application/json', 'Content-Type': 'application/json'},
      body: jsonEncode({'pairing_code': code}),
    ).timeout(const Duration(seconds: 20));
    dynamic decoded;
    try { decoded = jsonDecode(response.body); } on FormatException {
      throw StateError('The server returned an invalid enrollment response (HTTP ${response.statusCode}).');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map ? decoded['detail']?.toString() : null;
      throw StateError(detail ?? 'Device pairing failed (HTTP ${response.statusCode}).');
    }
    if (decoded is! Map || decoded['device_token'] is! String || (decoded['device_token'] as String).isEmpty) {
      throw const FormatException('The server did not return a device token.');
    }
    await _storage.write(key: _tokenKey, value: decoded['device_token'] as String);
  }

  static Future<void> clear() => _storage.delete(key: _tokenKey);
}
