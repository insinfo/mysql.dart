import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

void main() {
  test('createConnection rejects invalid auto-prepared cache capacity',
      () async {
    await expectLater(
      MySQLConnection.createConnection(
        host: '127.0.0.1',
        port: 3306,
        userName: 'dart',
        password: 'dart',
        autoPreparedStatementCacheCapacity: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('pool rejects invalid auto-prepared cache capacity', () {
    expect(
      () => MySQLConnectionPool(
        host: '127.0.0.1',
        port: 3306,
        userName: 'dart',
        password: 'dart',
        maxConnections: 1,
        autoPreparedStatementCacheCapacity: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('pool still rejects pooled streaming shortcut', () async {
    final pool = MySQLConnectionPool(
      host: '127.0.0.1',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      maxConnections: 1,
    );

    await expectLater(
      pool.execute('SELECT 1', null, true),
      throwsA(isA<MySQLClientException>()),
    );
  });
}
