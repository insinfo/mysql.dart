// Concurrent callers of one MySQLConnection: commands wait for their turn
// instead of failing with "connection is busy", and commands from outside a
// transactional() callback wait for it to end instead of running inside it.

import 'dart:async';

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

Future<List<String>> _names(MySQLConnection c) async => [
      for (final row
          in (await c.execute('select name from mysql_dart_queue order by id'))
              .rows)
        row.colByName('name')!,
    ];

void main() {
  late MySQLConnection conn;

  setUp(() async {
    conn = await _open();
    await conn.execute('drop table if exists mysql_dart_queue');
    await conn.execute('create table mysql_dart_queue '
        '(id int auto_increment primary key, name varchar(20)) engine=InnoDB');
  });
  tearDown(() async {
    try {
      await conn.execute('drop table if exists mysql_dart_queue');
      await conn.close();
    } catch (_) {}
  });

  test('concurrent commands run one at a time, in call order', () async {
    final results = await Future.wait([
      for (var i = 0; i < 40; i++)
        i.isEven
            ? conn.execute('select $i as v')
            : conn.execute('select :v as v', {'v': i}),
    ]);
    for (var i = 0; i < 40; i++) {
      expect(results[i].rows.single.typedColByName<int>('v'), i);
    }

    final order = <int>[];
    await Future.wait([
      for (var i = 0; i < 10; i++)
        conn
            .execute("insert into mysql_dart_queue (name) values ('n$i')")
            .then((_) => order.add(i)),
    ]);
    expect(order, List.generate(10, (i) => i));
    expect(await _names(conn), List.generate(10, (i) => 'n$i'));
  });

  test('prepare, prepared execute and deallocate wait for their turn',
      () async {
    final statements = await Future.wait([
      for (var i = 0; i < 5; i++) conn.prepare('select ? + $i as v'),
    ]);
    final results = await Future.wait([
      for (var i = 0; i < 5; i++) statements[i].execute([10]),
      conn.execute('select 99 as v'),
    ]);
    for (var i = 0; i < 5; i++) {
      expect(results[i].rows.single.typedColByName<int>('v'), 10 + i);
    }
    expect(results[5].rows.single.typedColByName<int>('v'), 99);
    await Future.wait([for (final s in statements) s.deallocate()]);
    expect((await conn.execute('select 1 as v')).rows.single.colAt(0), '1');
  });

  test('a command waits until an iterable result set is fully read', () async {
    final iterable = await conn.execute(
        'select 1 as v union all select 2 union all select 3', null, true);
    final next = conn.execute('select 42 as v');
    final rows = await iterable.rowsStream.map((r) => r.colAt(0)).toList();
    expect(rows, ['1', '2', '3']);
    expect((await next).rows.single.colAt(0), '42');
  });

  test('a command from outside waits for the transaction and stays outside it',
      () async {
    final entered = Completer<void>();
    final transaction = conn.transactional((c) async {
      await c.execute("insert into mysql_dart_queue (name) values ('tx')");
      entered.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      throw StateError('roll back');
    });
    await entered.future;
    // Issued while the transaction is open: it must neither fail ("busy")
    // nor be rolled back with the transaction.
    final outside =
        conn.execute("insert into mysql_dart_queue (name) values ('outside')");
    await expectLater(transaction, throwsStateError);
    await outside;
    expect(await _names(conn), ['outside']);
  });

  test('a read from outside sees the transaction only after the commit',
      () async {
    final entered = Completer<void>();
    var committed = false;
    final transaction = conn.transactional((c) async {
      await c.execute("insert into mysql_dart_queue (name) values ('a')");
      entered.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      committed = true;
    });
    await entered.future;
    final names = await _names(conn);
    expect(committed, isTrue);
    expect(names, ['a']);
    await transaction;
  });

  test('concurrent commands inside the callback run in the transaction',
      () async {
    await expectLater(conn.transactional((c) async {
      await Future.wait([
        for (var i = 0; i < 8; i++)
          c.execute("insert into mysql_dart_queue (name) values ('t$i')"),
      ]);
      expect(await _names(c), hasLength(8));
      throw StateError('roll back');
    }), throwsStateError);
    expect(await _names(conn), isEmpty);
  });

  test('concurrent transactions run one after the other', () async {
    final log = <String>[];
    await Future.wait([
      for (var i = 0; i < 4; i++)
        conn.transactional((c) async {
          log.add('begin $i');
          await c.execute("insert into mysql_dart_queue (name) values ('x$i')");
          await Future<void>.delayed(const Duration(milliseconds: 20));
          log.add('end $i');
        }),
    ]);
    expect(log, [
      for (var i = 0; i < 4; i++) ...['begin $i', 'end $i'],
    ]);
    expect(await _names(conn), ['x0', 'x1', 'x2', 'x3']);
  });

  test('queueConcurrentCalls: false fails fast, as in 3.0.0', () async {
    final strict = await MySQLConnection.createConnection(
      host: mysqlTestHost,
      port: mysqlTestPort,
      userName: mysqlTestUser,
      password: mysqlTestPassword,
      databaseName: mysqlTestDatabase,
      secure: mysqlTestSecure,
      queueConcurrentCalls: false,
    );
    await strict.connect();
    addTearDown(strict.close);

    final first = strict.execute('select sleep(0.2)');
    await expectLater(
        strict.execute('select 1'),
        throwsA(isA<MySQLClientException>()
            .having((e) => e.toString(), 'message', contains('busy'))));
    await first;

    final transaction = strict.transactional(
        (c) => Future<void>.delayed(const Duration(milliseconds: 50)));
    await expectLater(
        strict.transactional((c) async {}),
        throwsA(isA<MySQLClientException>().having((e) => e.toString(),
            'message', contains('Already in transaction'))));
    await transaction;
  });

  test('transactional() inside its own callback is rejected', () async {
    await expectLater(
        conn.transactional((c) => c.transactional((_) async => 1)),
        throwsA(isA<MySQLClientException>().having((e) => e.toString(),
            'message', contains('Already in transaction'))));
    expect((await conn.execute('select 1 as v')).rows.single.colAt(0), '1');
  });
}
