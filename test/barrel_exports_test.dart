import 'package:mysql_dart/mysql_client.dart' as legacy;
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

void main() {
  test('mysql_dart and mysql_client export identical exception types', () {
    expect(MySQLException, same(legacy.MySQLException));
    expect(MySQLServerException, same(legacy.MySQLServerException));
    expect(MySQLClientException, same(legacy.MySQLClientException));
    expect(MySQLProtocolException, same(legacy.MySQLProtocolException));
  });

  test('exported exception types work in typed on-catch clauses', () {
    MySQLServerException? caughtServer;
    try {
      throw const MySQLServerException('Duplicate entry', 1062);
    } on MySQLServerException catch (e) {
      caughtServer = e;
    }
    expect(caughtServer, isA<legacy.MySQLServerException>());
    expect(caughtServer, isA<MySQLException>());
    expect(caughtServer, isA<legacy.MySQLException>());
    expect(caughtServer.errorCode, 1062);
    expect(caughtServer.message, 'Duplicate entry');

    MySQLClientException? caughtClient;
    try {
      throw const MySQLClientException('Column index is out of range');
    } on MySQLClientException catch (e) {
      caughtClient = e;
    }
    expect(caughtClient, isA<legacy.MySQLClientException>());
    expect(caughtClient, isA<MySQLException>());
    expect(caughtClient.message, 'Column index is out of range');

    MySQLProtocolException? caughtProtocol;
    try {
      throw const MySQLProtocolException('Received empty MySQL packet payload');
    } on MySQLProtocolException catch (e) {
      caughtProtocol = e;
    }
    expect(caughtProtocol, isA<legacy.MySQLProtocolException>());
    expect(caughtProtocol, isA<MySQLClientException>());
    expect(caughtProtocol, isA<MySQLException>());
    expect(caughtProtocol.message, 'Received empty MySQL packet payload');

    final caughtAsBase = <MySQLException>[];
    for (final error in const <Object>[
      MySQLServerException('Access denied', 1045),
      MySQLClientException('Connection closed'),
      MySQLProtocolException('Truncated packet'),
    ]) {
      try {
        Error.throwWithStackTrace(error, StackTrace.current);
      } on legacy.MySQLException catch (e) {
        caughtAsBase.add(e);
      }
    }
    expect(caughtAsBase, hasLength(3));
  });

  test('real client exceptions are catchable from barrel imports alone',
      () async {
    final pool = MySQLConnectionPool(
      host: '127.0.0.1',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      maxConnections: 1,
    );

    MySQLClientException? caught;
    try {
      await pool.execute('SELECT 1', null, true);
    } on MySQLClientException catch (e) {
      caught = e;
    }
    expect(caught, isNotNull);
    expect(caught, isA<legacy.MySQLClientException>());
    expect(caught, isA<MySQLException>());
  });
}
