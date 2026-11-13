import 'dart:convert';

import 'package:http/http.dart' as http;

const _defaultApiBaseUrl =
    'https://device-demo-production.up.railway.app/api/v1';

class StaffApiException implements Exception {
  const StaffApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class StaffApi {
  StaffApi({http.Client? client})
    : _client = client ?? http.Client(),
      _baseUrl = const String.fromEnvironment(
        'STAFF_API_BASE_URL',
        defaultValue: _defaultApiBaseUrl,
      );

  final http.Client _client;
  final String _baseUrl;

  Future<Map<String, dynamic>> login(String username, String password) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/staff/app/login/'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> session(String token) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/staff/app/session/'),
      headers: _authHeaders(token),
    );
    return _decode(response);
  }

  Future<List<Map<String, dynamic>>> notifications(String token) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/staff/app/notifications/'),
      headers: _authHeaders(token),
    );
    final payload = _decode(response);
    final values = payload['notifications'];
    if (values is! List) {
      throw const StaffApiException('The staff inbox response was invalid.');
    }
    return values.whereType<Map>().map((item) {
      return item.map((key, value) => MapEntry(key.toString(), value));
    }).toList();
  }

  Future<void> savePushSubscription(
    String token,
    Map<String, dynamic> subscription,
  ) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/staff/app/push-subscriptions/'),
      headers: {..._authHeaders(token), 'Content-Type': 'application/json'},
      body: jsonEncode({'subscription': subscription}),
    );
    _decode(response);
  }

  Future<void> removePushSubscription(String token, String endpoint) async {
    final response = await _client.delete(
      Uri.parse('$_baseUrl/staff/app/push-subscriptions/'),
      headers: {..._authHeaders(token), 'Content-Type': 'application/json'},
      body: jsonEncode({'endpoint': endpoint}),
    );
    _decode(response);
  }

  Future<void> logout(String token) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/staff/app/logout/'),
      headers: _authHeaders(token),
    );
    _decode(response);
  }

  Map<String, String> _authHeaders(String token) => {
    'Authorization': 'Bearer $token',
  };

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException();
      }
      payload = decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      throw const StaffApiException(
        'The staff service returned an invalid response.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StaffApiException(
        payload['error']?.toString() ??
            'The staff service could not complete the request.',
      );
    }
    return payload;
  }
}
