import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:reliquary_fe/services/auth_service.dart';

String _jwt(Map<String, dynamic> payload) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.${seg(payload)}.signature';
}

void main() {
  test('reads the exp claim from a token', () {
    final expiry = DateTime.utc(2026, 8, 13, 12);
    final token = _jwt({
      'username': 'alice',
      'exp': expiry.millisecondsSinceEpoch ~/ 1000,
    });

    expect(AuthService.tokenExpiry(token), expiry);
  });

  // A null expiry means "cannot tell", and must never be read as "expired" —
  // an opaque OIDC access token has no claims to read and still works.
  test('returns null when there is no readable expiry', () {
    final cases = <String, String>{
      'opaque token': 'gAAAAABm-not-a-jwt',
      'empty': '',
      'wrong segment count': 'a.b',
      'payload is not base64': 'header.!!!not-base64!!!.sig',
      'payload is not JSON': 'header.${base64Url.encode(utf8.encode('nope')).replaceAll('=', '')}.sig',
      'no exp claim': _jwt({'username': 'alice'}),
      'exp is not a number': _jwt({'exp': 'soon'}),
    };

    cases.forEach((name, token) {
      expect(AuthService.tokenExpiry(token), isNull, reason: name);
    });
  });

  test('a token issued by the backend is readable', () {
    // Shape the Go backend emits: username, role, source, ver, exp, iat.
    final exp = DateTime.utc(2026, 8, 16, 8, 37, 43);
    final token = _jwt({
      'username': 'admin',
      'role': 'admin',
      'source': 'password',
      'ver': 2,
      'exp': exp.millisecondsSinceEpoch ~/ 1000,
      'iat': exp.millisecondsSinceEpoch ~/ 1000 - 259200,
    });

    expect(AuthService.tokenExpiry(token), exp);
  });
}
