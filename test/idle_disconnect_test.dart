// A connection the server closed for being idle (wait_timeout): the next
// commands fail with an error the caller can catch, and nothing else fails
// in the background (a write to the closed connection was an uncaught
// "Connection reset by peer" on Linux). The pool replaces the connection.

import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('commands on a connection closed by wait_timeout fail cleanly',
      () async {
    final connection = await MySQLConnection.createConnection(
      host: mysqlTestHost,
      port: mysqlTestPort,
      userName: mysqlTestUser,
      password: mysqlTestPassword,
      databaseName: mysqlTestDatabase,
      secure: mysqlTestSecure,
    );
    await connection.connect();
    await connection.execute('set session wait_timeout = 1');
    await Future<void>.delayed(const Duration(seconds: 3));

    await expectLater(connection.execute('select 1'), throwsA(anything));
    await expectLater(connection.execute('select 2'), throwsA(anything));
    expect(connection.connected, isFalse);
    try {
      await connection.close();
    } catch (_) {
      // Closing an already closed connection may report the reset.
    }
  });

  test('the pool replaces a connection closed by wait_timeout', () async {
    final pool = MySQLConnectionPool(
      host: mysqlTestHost,
      port: mysqlTestPort,
      userName: mysqlTestUser,
      password: mysqlTestPassword,
      databaseName: mysqlTestDatabase,
      secure: mysqlTestSecure,
      maxConnections: 1,
    );
    try {
      await pool.execute('set session wait_timeout = 1');
      await Future<void>.delayed(const Duration(seconds: 3));

      // The first command may fail on the closed connection; the pool then
      // opens a new one.
      try {
        await pool.execute('select 1');
      } catch (_) {}
      final result = await pool.execute('select 1 as one');
      expect(result.rows.single.colAt(0).toString(), '1');
    } finally {
      await pool.close();
    }
  });
}
