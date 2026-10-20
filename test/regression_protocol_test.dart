// Regression tests for 3.0.1: errors inside a result set, client-side
// parameter failures, query timeouts, named-parameter parsing, UNSIGNED
// integers, _bin text columns, transactional() and close() after the server
// ended the session.

import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

Future<MySQLConnection> _open() async {
  final connection = await MySQLConnection.createConnection(
    host: mysqlTestHost,
    port: mysqlTestPort,
    userName: mysqlTestUser,
    password: mysqlTestPassword,
    databaseName: mysqlTestDatabase,
    secure: mysqlTestSecure,
  );
  await connection.connect();
  return connection;
}

Future<Map<String, dynamic>> _row(MySQLConnection c, String sql,
        [Object? params]) async =>
    (await c.execute(sql, params)).rows.single.typedAssoc();

void main() {
  late MySQLConnection conn;

  setUp(() async => conn = await _open());
  tearDown(() async {
    try {
      await conn.close();
    } catch (_) {}
  });

  test('an error after some rows keeps the connection open', () async {
    const failing = 'select g.n, (select 1 union select 2 from dual '
        'where g.n > 1) as x from (select 1 as n union select 2) g';
    await expectLater(conn.execute(failing), throwsA(isA<MySQLServerException>()));
    expect((await _row(conn, 'select 1 as v'))['v'], 1);
    // Prepared (binary) path.
    await expectLater(conn.execute('$failing where ? = ?', [1, 1]),
        throwsA(isA<MySQLServerException>()));
    expect((await _row(conn, 'select ? as v', [2]))['v'], 2);
  });

  test('a parameter the client rejects does not leave the connection busy',
      () async {
    await expectLater(
        conn.execute('select ? as v', [Object()]),
        throwsA(isA<MySQLClientException>()));
    expect((await _row(conn, 'select 3 as v'))['v'], 3);
  });

  test('Map, List, Set and BigInt parameters', () async {
    final row = await _row(conn, 'select ? as m, ? as l, ? as s, ? as b', [
      {'a': 1},
      [1, 2],
      {'x'},
      BigInt.parse('18446744073709551615'),
    ]);
    expect(row['m'], '{"a":1}');
    expect(row['l'], '[1,2]');
    expect(row['s'], '["x"]');
    expect(row['b'], '18446744073709551615');
    // Through a BLOB column: MySQL 9 reports a bare `select ?` with the
    // connection charset (text), MariaDB as binary.
    await conn.execute('create temporary table reg_blob (v blob)');
    await conn.execute(
        'insert into reg_blob values (?)', [Uint8List.fromList([0, 1, 255])]);
    final bytes = await _row(conn, 'select v from reg_blob');
    expect(bytes['v'], [0, 1, 255]);
  });

  test('a query timeout interrupts the statement and frees the connection',
      () async {
    final watch = Stopwatch()..start();
    await expectLater(
        conn.execute('select sleep(5) as s', null, false,
            const Duration(milliseconds: 300)),
        throwsA(isA<MySQLClientException>()));
    expect((await _row(conn, 'select 4 as v'))['v'], 4);
    expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
  });

  test('named parameters skip strings, identifiers and comments', () async {
    expect(
        await _row(conn, r"select 'it\'s :x' as a, :y as b -- :z", {'y': 1}),
        {'a': "it's :x", 'b': 1});
    expect(await _row(conn, "select 1 as `a:b`, :y as b /* :q */", {'y': 2}),
        {'a:b': 1, 'b': 2});
    expect(await _row(conn, "select 'o''k :x' as a, :y as b", {'y': 3}),
        {'a': "o'k :x", 'b': 3});
  });

  test('UNSIGNED integers and _bin text columns', () async {
    await conn.execute('drop table if exists mysql_dart_regression_types');
    await conn.execute('create table mysql_dart_regression_types ('
        'tu tinyint unsigned, su smallint unsigned, iu int unsigned, '
        'bu bigint unsigned, tb text collate utf8mb4_bin)');
    try {
      await conn.execute('insert into mysql_dart_regression_types values '
          "(200, 60000, 4000000000, 18446744073709551615, 'ção')");
      final text =
          await _row(conn, 'select * from mysql_dart_regression_types');
      final binary = await _row(
          conn, 'select * from mysql_dart_regression_types where 1 = ?', [1]);
      for (final row in [text, binary]) {
        expect(row['tu'], 200);
        expect(row['su'], 60000);
        expect(row['iu'], 4000000000);
        expect(row['bu'], BigInt.parse('18446744073709551615'));
        expect(row['tb'], 'ção');
      }
    } finally {
      await conn.execute('drop table mysql_dart_regression_types');
    }
  });

  test('transactional() always clears its state and keeps the first error',
      () async {
    await expectLater(
        conn.transactional((c) async {
          await c.execute('select 1');
          throw StateError('boom');
        }),
        throwsStateError);
    final row = await conn.transactional(
        (c) async => (await c.execute('select 5 as v')).rows.single.typedAssoc());
    expect(row['v'], 5);
  });

  test('close() completes after the server killed the session', () async {
    final victim = await _open();
    final id = (await _row(victim, 'select connection_id() as id'))['id'];
    await conn.execute('KILL $id');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await expectLater(victim.execute('select 1'),
        throwsA(isA<MySQLClientException>()));
    // It used to wait forever flushing the destroyed socket.
    await victim.close().timeout(const Duration(seconds: 5));
    expect(victim.connected, isFalse);
  });
}
