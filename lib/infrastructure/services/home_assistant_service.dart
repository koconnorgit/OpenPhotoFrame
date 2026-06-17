import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Result of a Home Assistant state fetch.
///
/// Either [value] is non-null (success) or [error] describes what went wrong.
/// Used by the settings "test connection" button to give actionable feedback;
/// the slideshow only cares about [value].
class HomeAssistantResult {
  final String? value; // Formatted state, e.g. "21.3°C"
  final String? error; // Human-readable error, null on success

  const HomeAssistantResult.success(this.value) : error = null;
  const HomeAssistantResult.failure(this.error) : value = null;

  bool get isSuccess => error == null;
}

/// Fetches a sensor value (e.g. local temperature) from Home Assistant via its
/// REST API.
///
/// Calls `GET {baseUrl}/api/states/{entityId}` with a long-lived access token in
/// the `Authorization: Bearer` header and returns the entity's state formatted
/// with its unit of measurement (e.g. `"21.3°C"`).
///
/// See: https://developers.home-assistant.io/docs/api/rest/
class HomeAssistantService {
  final _log = Logger('HomeAssistantService');
  final http.Client _client = http.Client();

  /// Fetch [entityId]'s current state, formatted with its unit.
  ///
  /// Returns a [HomeAssistantResult] so callers that want diagnostics (the
  /// settings test button) can show why a fetch failed. The slideshow uses the
  /// thinner [getTemperature] wrapper which just yields the value or null.
  Future<HomeAssistantResult> fetchState({
    required String baseUrl,
    required String token,
    required String entityId,
  }) async {
    final url = baseUrl.trim();
    final tok = token.trim();
    final entity = entityId.trim();

    if (url.isEmpty || tok.isEmpty || entity.isEmpty) {
      return const HomeAssistantResult.failure('Not configured');
    }

    try {
      // Strip any trailing slashes so we don't produce "...//api/...".
      final normalized = url.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$normalized/api/states/$entity');

      final response = await _client.get(uri, headers: {
        'Authorization': 'Bearer $tok',
        'Content-Type': 'application/json',
      }).timeout(const Duration(seconds: 5));

      if (response.statusCode == 401) {
        _log.warning('Home Assistant auth failed (401)');
        return const HomeAssistantResult.failure('Invalid access token (401)');
      }
      if (response.statusCode == 404) {
        _log.warning('Home Assistant entity not found: $entity');
        return HomeAssistantResult.failure('Entity not found: $entity');
      }
      if (response.statusCode != 200) {
        _log.warning('Home Assistant request failed: HTTP ${response.statusCode}');
        return HomeAssistantResult.failure('HTTP ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final state = json['state']?.toString();
      if (state == null ||
          state.isEmpty ||
          state == 'unavailable' ||
          state == 'unknown') {
        return const HomeAssistantResult.failure('Sensor unavailable');
      }

      final attributes = json['attributes'] as Map<String, dynamic>?;
      final unit = attributes?['unit_of_measurement']?.toString();

      // Tidy numeric readings to one decimal; leave non-numeric states as-is.
      final numeric = double.tryParse(state);
      final display = numeric != null ? _formatNumber(numeric) : state;
      final formatted =
          (unit != null && unit.isNotEmpty) ? '$display$unit' : display;

      _log.fine('Home Assistant $entity → $formatted');
      return HomeAssistantResult.success(formatted);
    } catch (e) {
      _log.warning('Home Assistant fetch error: $e');
      return HomeAssistantResult.failure('Connection failed');
    }
  }

  /// Convenience wrapper for the slideshow: returns the formatted value or null.
  Future<String?> getTemperature({
    required String baseUrl,
    required String token,
    required String entityId,
  }) async {
    final result = await fetchState(
      baseUrl: baseUrl,
      token: token,
      entityId: entityId,
    );
    return result.value;
  }

  /// One decimal place, with a trailing ".0" dropped (e.g. 21.0 → "21").
  String _formatNumber(double value) {
    final s = value.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  void dispose() {
    _client.close();
  }
}
