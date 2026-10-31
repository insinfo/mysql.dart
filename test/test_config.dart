import 'dart:io';

String get mysqlTestHost => Platform.environment['MYSQL_HOST'] ?? 'localhost';

int get mysqlTestPort =>
    int.tryParse(Platform.environment['MYSQL_PORT'] ?? '') ?? 3306;

String get mysqlTestUser => Platform.environment['MYSQL_USER'] ?? 'dart';

String get mysqlTestPassword =>
    Platform.environment['MYSQL_PASSWORD'] ?? 'dart';

String get mysqlTestDatabase =>
    Platform.environment['MYSQL_DATABASE'] ?? 'banco_teste';

bool _testCaLoaded = false;

/// With TLS the server certificate is verified, so the suite trusts the CA
/// in MYSQL_CA_CERT (the one that signed the test server's certificate).
bool get mysqlTestSecure {
  final secure =
      _parseBool(Platform.environment['MYSQL_SECURE'], defaultValue: true);
  if (secure && !_testCaLoaded) {
    _testCaLoaded = true;
    final ca = Platform.environment['MYSQL_CA_CERT'];
    if (ca != null && ca.isNotEmpty) {
      SecurityContext.defaultContext.setTrustedCertificates(ca);
    }
  }
  return secure;
}

String? get mysqlTestCaCert => Platform.environment['MYSQL_CA_CERT'];

String? get mysqlRestartCommand =>
    Platform.environment['MYSQL_RESTART_COMMAND'];

bool _parseBool(String? value, {required bool defaultValue}) {
  if (value == null || value.isEmpty) {
    return defaultValue;
  }

  switch (value.toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'y':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'n':
    case 'off':
      return false;
    default:
      return defaultValue;
  }
}
