import 'dart:io';

import 'package:mysql_dart/mysql_dart.dart';

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

/// MySQL has a JSON type from 5.7 on; MariaDB maps JSON to LONGTEXT.
Future<bool> serverHasJsonType(MySQLConnection conn) =>
    _mysqlAtLeast(conn, [5, 7]);

/// DATETIME(6) and TIME(6) keep fractions of a second from MySQL 5.6.4 on.
Future<bool> serverHasFractionalSeconds(MySQLConnection conn) =>
    _mysqlAtLeast(conn, [5, 6, 4]);

/// True on MariaDB (10+ has both features) or MySQL [minimum] and later.
Future<bool> _mysqlAtLeast(MySQLConnection conn, List<int> minimum) async {
  final result = await conn.execute('SELECT VERSION() AS v');
  final version = result.rows.first.colByName('v')!;
  if (version.contains('MariaDB')) return true;
  final parts = version
      .split(RegExp(r'[.-]'))
      .take(minimum.length)
      .map(int.parse)
      .toList();
  for (var i = 0; i < minimum.length; i++) {
    if (parts[i] != minimum[i]) return parts[i] > minimum[i];
  }
  return true;
}

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
