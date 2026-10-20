// Errors and recovery: server errors inside result sets, query timeouts,
// cancelled streams, connections killed by the server (with commands in
// flight and queued behind them), the auto-prepared statement cache,
// deallocated statements, and concurrency edge cases on one connection and
// on the pool.

import 'dart:async';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _table = 'cov_recovery';

/// A statement that fails after its first row (the subquery returns more
/// than one row only for the second row).
const _errorAfterRows = 'select g.n, (select 1 union select 2 from dual '
    'where g.n > 1) as x from (select 1 as n union select 2) g';

Future<MySQLConnection> _open({
  int autoPreparedStatementCacheCapacity = 32,
}) async {
  final connection = await MySQLConnection.createConnection(
    host: mysqlTestHost,
    port: mysqlTestPort,
    userName: mysqlTestUser,
    password: mysqlTestPassword,
    databaseName: mysqlTestDatabase,
    secure: mysqlTestSecure,
    autoPreparedStatementCacheCapacity: autoPreparedStatementCacheCapacity,
  );
  await connection.connect();
  return connection;
}

MySQLConnectionPool _pool(int maxConnections) => MySQLConnectionPool(
      host: mysqlTestHost,
      port: mysqlTestPort,
      userName: mysqlTestUser,
      password: mysqlTestPassword,
      databaseName: mysqlTestDatabase,
      secure: mysqlTestSecure,
      maxConnections: maxConnections,
    );

Future<int> _value(Future<IResultSet> result) async =>
    int.parse((await result).rows.single.colAt(0).toString());

Future<int> _threadId(MySQLConnection c) =>
    _value(c.execute('select connection_id() as id'));

/// Commands of every kind; each must return its own [i].
Future<int> _echo(MySQLConnection c, int i) {
  switch (i % 4) {
    case 0:
      return _value(c.execute('select $i as v'));
    case 1:
      return _value(c.execute('select cast(? as signed) as v', [i]));
    case 2:
      return _value(c.execute('select cast(:v as signed) as v', {'v': i}));
    default:
      return c.execute('select $i as v', null, true).then((rs) =>
          rs.rowsStream.map((r) => int.parse(r.colAt(0) as String)).single);
  }
}

final _closed = throwsA(isA<Exception>());

/// Ten rows (0..9) without a table.
const _digits = '(select 0 n union all select 1 union all select 2 '
    'union all select 3 union all select 4 union all select 5 '
    'union all select 6 union all select 7 union all select 8 '
    'union all select 9)';

void main() {
  late MySQLConnection conn;
  late MySQLConnection admin;

  Future<void> kill(MySQLConnection victim, {int? id}) async {
    await admin.execute('KILL ${id ?? await _threadId(victim)}');
  }

  setUpAll(() async => admin = await _open());
  tearDownAll(() => admin.close());

  setUp(() async {
    conn = await _open();
    await conn.execute('drop table if exists $_table');
    await conn.execute('create table $_table '
        '(id int auto_increment primary key, name varchar(20)) engine=InnoDB');
  });
  tearDown(() async {
    await admin.execute('drop table if exists $_table');
    try {
      await conn.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
  });

  Future<List<String>> names(MySQLConnection c) async => [
        for (final row
            in (await c.execute('select name from $_table order by id')).rows)
          row.colAt(0) as String,
      ];

  group('server error inside a result set', () {
    test('iterable text stream gets the error, the connection stays usable',
        () async {
      final rs = await conn.execute(_errorAfterRows, null, true);
      final rows = <String>[];
      await expectLater(
          rs.rowsStream.map((r) => r.colAt(0) as String).forEach(rows.add),
          throwsA(isA<MySQLServerException>()));
      expect(rows, ['1']);
      expect(await _echo(conn, 4), 4);
      expect(conn.connected, isTrue);
    });

    test('iterable prepared stream gets the error', () async {
      final stmt = await conn.prepare('$_errorAfterRows where ? = 1', true);
      for (var i = 0; i < 2; i++) {
        final rs = await stmt.execute([1]);
        await expectLater(
            rs.rowsStream.toList(), throwsA(isA<MySQLServerException>()));
        expect(await _echo(conn, i), i);
      }
      await stmt.deallocate();
    });

    test('commands queued behind a failing result set get their own replies',
        () async {
      final failing = conn.execute(_errorAfterRows);
      final queued = [for (var i = 0; i < 8; i++) _echo(conn, i)];
      await expectLater(failing, throwsA(isA<MySQLServerException>()));
      expect(await Future.wait(queued), List.generate(8, (i) => i));
    });
  });

  group('query timeout', () {
    test('prepared statement (auto-prepared) timeout frees the connection',
        () async {
      final watch = Stopwatch()..start();
      await expectLater(
          conn.execute('select sleep(?) as s', [5], false,
              const Duration(milliseconds: 300)),
          throwsA(isA<MySQLClientException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(await _echo(conn, 1), 1);
      expect(await _echo(conn, 2), 2);
    });

    test('commands queued behind a timed-out query get their own replies',
        () async {
      final slow = conn.execute('select sleep(5) as s', null, false,
          const Duration(milliseconds: 300));
      final queued = [for (var i = 0; i < 6; i++) _echo(conn, i)];
      await expectLater(slow, throwsA(isA<MySQLClientException>()));
      expect(await Future.wait(queued), List.generate(6, (i) => i));
    });

    test('a timeout inside transactional rolls the transaction back', () async {
      await expectLater(conn.transactional((c) async {
        await c.execute("insert into $_table (name) values ('tx')");
        await c.execute(
            'select sleep(5)', null, false, const Duration(milliseconds: 300));
      }), throwsA(isA<MySQLClientException>()));
      expect(await names(conn), isEmpty);
      expect(await _echo(conn, 3), 3);
    });
  });

  group('pausing and cancelling an iterable stream', () {
    test('mid-way closes the connection; queued commands fail, not hang',
        () async {
      final rs = await conn.execute(
          'select a.n + b.n * 10 + c.n * 100 + d.n * 1000 + e.n * 10000 as v '
          'from $_digits a, $_digits b, $_digits c, $_digits d, $_digits e',
          null,
          true);
      final queued = conn.execute('select 1 as v');
      final first = await rs.rowsStream.take(3).toList();
      expect(first, hasLength(3));
      // Documented: the rest of the result cannot be skipped, so the
      // connection is closed.
      await expectLater(queued.timeout(const Duration(seconds: 5)),
          throwsA(isA<MySQLClientException>()));
      expect(conn.connected, isFalse);
      await expectLater(conn.execute('select 2'), _closed);
      await conn.close().timeout(const Duration(seconds: 5));
    });

    test('after the last row keeps the connection', () async {
      final rs =
          await conn.execute('select 1 as v union all select 2', null, true);
      final queued = conn.execute('select 3 as v');
      expect(await rs.rowsStream.map((r) => r.colAt(0)).toList(), ['1', '2']);
      expect((await queued).rows.single.colAt(0), '3');
      expect(conn.connected, isTrue);
    });

    test('a paused stream keeps queued commands waiting', () async {
      final rs = await conn.execute(
          'select 1 as v union all select 2 union all select 3', null, true);
      final queued = _echo(conn, 9);
      final rows = <String>[];
      final sub = rs.rowsStream.listen((r) => rows.add(r.colAt(0) as String));
      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sub.resume();
      await sub.asFuture<void>();
      expect(rows, ['1', '2', '3']);
      // The socket was paused with the last rows still buffered: it used to
      // stay paused, and the queued command waited forever.
      expect(await queued.timeout(const Duration(seconds: 5)), 9);
    });

    test('an await for loop with an async body, then the next command',
        () async {
      for (final iterable in [
        () => conn.execute(
            'select a.n + b.n * 10 as v from $_digits a, $_digits b',
            null,
            true),
        () => conn.execute(
            'select a.n + b.n * 10 + ? as v from $_digits a, $_digits b',
            [0],
            true),
      ]) {
        final rs = await iterable();
        final queued = _echo(conn, 3);
        var count = 0;
        await for (final _ in rs.rowsStream) {
          // The loop pauses the stream while its body waits.
          await Future<void>.delayed(Duration.zero);
          count++;
        }
        expect(count, 100);
        expect(await queued.timeout(const Duration(seconds: 5)), 3);
        expect(await _echo(conn, 4).timeout(const Duration(seconds: 5)), 4);
      }
    });
  });

  group('connection killed by the server', () {
    test('while idle: commands fail, close() completes', () async {
      await kill(conn);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await expectLater(conn.execute('select 1'), _closed);
      await expectLater(conn.execute('select ?', [1]), _closed);
      await expectLater(conn.prepare('select 1'), _closed);
      await conn.close().timeout(const Duration(seconds: 5));
    });

    test('mid-query: the running and the queued commands fail, not hang',
        () async {
      final id = await _threadId(conn);
      final running = conn.execute('select sleep(5)');
      final queued = [
        for (var i = 0; i < 4; i++)
          _echo(conn, i).then<Object?>((v) => v, onError: (Object e) => e),
      ];
      final runningResult =
          running.then<Object?>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await kill(conn, id: id);
      expect(await runningResult.timeout(const Duration(seconds: 3)),
          isA<Exception>());
      for (final q in queued) {
        expect(await q.timeout(const Duration(seconds: 3)), isA<Exception>());
      }
      expect(conn.connected, isFalse);
      await conn.close().timeout(const Duration(seconds: 5));
    });

    test('mid-query through a prepared statement', () async {
      final id = await _threadId(conn);
      final stmt = await conn.prepare('select sleep(?)');
      final running =
          stmt.execute([5]).then<Object?>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await kill(conn, id: id);
      expect(
          await running.timeout(const Duration(seconds: 3)), isA<Exception>());
      await conn.close().timeout(const Duration(seconds: 5));
    });

    test('mid-stream: the iterable stream gets an error', () async {
      final id = await _threadId(conn);
      // Rows big enough to be sent one by one, one every 300 ms.
      final rs = await conn.execute(
          "select repeat('x', 100000) as v, sleep(0.3) from $_digits a",
          null,
          true);
      var received = 0;
      final done = rs.rowsStream
          .forEach((_) => received++)
          .then<Object?>((_) => 'done', onError: (Object e) => e);
      final queued =
          _echo(conn, 1).then<Object?>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await kill(conn, id: id);
      expect(await done.timeout(const Duration(seconds: 3)), isA<Exception>());
      expect(received, inInclusiveRange(1, 9));
      expect(
          await queued.timeout(const Duration(seconds: 3)), isA<Exception>());
      await conn.close().timeout(const Duration(seconds: 5));
    });

    test(
        'inside transactional: the transaction and the callers waiting for '
        'it fail, not hang', () async {
      final id = await _threadId(conn);
      final entered = Completer<void>();
      final transaction = conn.transactional((c) async {
        await c.execute("insert into $_table (name) values ('tx')");
        entered.complete();
        await c.execute('select sleep(5)');
      }).then<Object?>((v) => v, onError: (Object e) => e);
      await entered.future;
      final outside = [
        for (var i = 0; i < 3; i++)
          _echo(conn, i).then<Object?>((v) => v, onError: (Object e) => e),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await kill(conn, id: id);
      expect(await transaction.timeout(const Duration(seconds: 3)),
          isA<Exception>());
      for (final o in outside) {
        expect(await o.timeout(const Duration(seconds: 3)), isA<Exception>());
      }
      // The transaction was not committed.
      expect(await names(admin), isEmpty);
    });
  });

  group('auto-prepared statement cache', () {
    test('a capacity of 1 evicts on every new query and keeps results right',
        () async {
      final small = await _open(autoPreparedStatementCacheCapacity: 1);
      addTearDown(small.close);
      Future<int> statusCount(String name) async {
        final r = await small.execute("show session status like '$name'");
        return int.parse(r.rows.single.colAt(1) as String);
      }

      final closesBefore = await statusCount('Com_stmt_close');
      const queries = [
        'select cast(? as signed) as a',
        'select cast(? as signed) + 0 as b',
        'select concat(?, \'\') as c',
      ];
      for (var i = 0; i < 30; i++) {
        final q = queries[i % 3];
        // Parameter types change between runs of the same statement.
        final Object param = i.isEven ? i : '$i';
        final r = await small.execute(q, [param]);
        expect(r.rows.single.colAt(0), '$i');
      }
      // Iterable and plain runs of one query are separate cache entries.
      for (var i = 0; i < 4; i++) {
        final r = await small.execute(queries[0], [i], i.isOdd);
        expect(await r.rowsStream.map((row) => row.colAt(0)).single, '$i');
      }
      final stats = small.autoPreparedStatementCacheStats;
      expect(stats.cachedStatements, 1);
      expect(stats.evictions, greaterThanOrEqualTo(30));
      // The evicted statements were closed on the server.
      expect(await statusCount('Com_stmt_close') - closesBefore,
          greaterThanOrEqualTo(stats.evictions - 1));
      expect(await _echo(small, 1), 1);
    });

    test('capacity 2 with alternating queries hits the cache', () async {
      final small = await _open(autoPreparedStatementCacheCapacity: 2);
      addTearDown(small.close);
      for (var i = 0; i < 20; i++) {
        final r = await small.execute(
            i.isEven ? 'select cast(? as signed) as a' : 'select ? as b', [i]);
        expect(r.rows.single.colAt(0), '$i');
      }
      final stats = small.autoPreparedStatementCacheStats;
      expect(stats.misses, 2);
      expect(stats.hits, 18);
      expect(stats.evictions, 0);
    });

    test('values and NULLs alternate on one cached statement', () async {
      final values = <Object?>[1, null, 'a', 2.5, true, null, -7, 'ção'];
      for (final v in values) {
        final r = await conn.execute('select ? as v', [v]);
        final got = r.rows.single.colAt(0);
        if (v == null) {
          expect(got, isNull);
        } else if (v == true) {
          expect(got, '1');
        } else {
          expect(got, '$v');
        }
      }
    });
  });

  group('prepared statements', () {
    test('execute after deallocate fails on the server; connection usable',
        () async {
      final stmt = await conn.prepare('select ? as v');
      expect((await stmt.execute([1])).rows.single.colAt(0), '1');
      await stmt.deallocate();
      await expectLater(
          stmt.execute([2]),
          throwsA(isA<MySQLServerException>()
              .having((e) => e.errorCode, 'errorCode', 1243)));
      expect(await _echo(conn, 5), 5);
      // A second deallocate has no reply to wait for.
      await stmt.deallocate();
      expect(await _echo(conn, 6), 6);
      final again = await conn.prepare('select ? as v');
      expect((await again.execute([3])).rows.single.colAt(0), '3');
      await again.deallocate();
    });

    test('prepare errors and wrong parameter counts', () async {
      await expectLater(
          conn.prepare('selec ? as v'), throwsA(isA<MySQLServerException>()));
      expect(await _echo(conn, 7), 7);
      final stmt = await conn.prepare('select ? + ? as v');
      await expectLater(
          stmt.execute([1]), throwsA(isA<MySQLClientException>()));
      expect(await _echo(conn, 8), 8);
      expect((await stmt.execute([1, 2])).rows.single.colAt(0), isNotNull);
      await stmt.deallocate();
      // Auto-prepared: extra parameters were ignored, missing ones sent a
      // malformed packet.
      await expectLater(conn.execute('select ? as v', [1, 2]),
          throwsA(isA<MySQLClientException>()));
      await expectLater(conn.execute('select ? + ? as v', [1]),
          throwsA(isA<MySQLClientException>()));
      expect(await _echo(conn, 9), 9);
    });

    test('many statements prepared at once, executed out of order', () async {
      final stmts = await Future.wait([
        for (var i = 0; i < 10; i++)
          conn.prepare('select cast(? + $i as signed) as v'),
      ]);
      final results = await Future.wait([
        for (var i = 9; i >= 0; i--) stmts[i].execute([100]),
      ]);
      for (var i = 0; i < 10; i++) {
        expect(
            int.parse(results[9 - i].rows.single.colAt(0) as String), 100 + i);
      }
      await Future.wait([for (final s in stmts) s.deallocate()]);
      expect(await _echo(conn, 1), 1);
    });
  });

  group('concurrency on one connection', () {
    test(
        'an error inside transactional: queued outside callers run after '
        'the rollback with their own results', () async {
      final entered = Completer<void>();
      final transaction = conn.transactional((c) async {
        await c.execute("insert into $_table (name) values ('tx')");
        entered.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await c.execute('select * from cov_recovery_missing');
      });
      await entered.future;
      final outside = [
        names(conn),
        for (var i = 0; i < 6; i++) _echo(conn, i),
        conn
            .execute("insert into $_table (name) values ('out')")
            .then((r) => r.affectedRows.toInt()),
      ];
      await expectLater(transaction, throwsA(isA<MySQLServerException>()));
      final results = await Future.wait(outside);
      expect(results.first, isEmpty); // ran after the rollback
      expect(results.sublist(1, 7), List.generate(6, (i) => i));
      expect(results.last, 1);
      expect(await names(conn), ['out']);
    });

    test('nested transactions on two connections do not deadlock', () async {
      final other = await _open();
      addTearDown(other.close);
      final result = await conn
          .transactional((a) => other.transactional(
                (b) async {
                  await a.execute("insert into $_table (name) values ('a')");
                  await b.execute("insert into $_table (name) values ('b')");
                  return 'done';
                },
              ))
          .timeout(const Duration(seconds: 5));
      expect(result, 'done');
      expect(await names(admin), ['a', 'b']);
    });

    test('work a transaction left running does not join a later one', () async {
      final leaked = Completer<void>();
      await conn.transactional((c) async {
        unawaited(
            Future<void>.delayed(const Duration(milliseconds: 150), () async {
          await c.execute("insert into $_table (name) values ('leak')");
          leaked.complete();
        }));
      });
      // Another caller's transaction, open when the leaked insert runs.
      await expectLater(conn.transactional((c) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        throw StateError('roll back');
      }), throwsStateError);
      await leaked.future;
      // The insert waited for that transaction instead of being rolled back
      // with it.
      expect(await names(conn), ['leak']);
    });

    test('mixed commands with failures interleaved keep their replies',
        () async {
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 40; i++) {
        if (i % 7 == 3) {
          futures.add(conn
              .execute('select * from cov_recovery_missing')
              .then<Object?>((_) => 'no error',
                  onError: (Object e) => 'error'));
        } else if (i % 7 == 5) {
          futures.add(conn
              .execute(_errorAfterRows, [], i.isEven)
              .then<Object?>((rs) => rs.rowsStream.toList())
              .then<Object?>((_) => 'no error',
                  onError: (Object e) => 'error'));
        } else {
          futures.add(_echo(conn, i));
        }
      }
      final results = await Future.wait(futures);
      for (var i = 0; i < 40; i++) {
        expect(results[i], i % 7 == 3 || i % 7 == 5 ? 'error' : i,
            reason: 'command #$i');
      }
      expect(conn.connected, isTrue);
    });
  });

  group('pool', () {
    test('concurrent load: every caller gets its own result', () async {
      final pool = _pool(4);
      addTearDown(pool.close);
      final futures = <Future<int>>[];
      for (var i = 0; i < 200; i++) {
        switch (i % 5) {
          case 0:
            futures.add(_value(pool.execute('select $i as v')));
          case 1:
            futures.add(
                _value(pool.execute('select cast(:v as signed)', {'v': i})));
          case 2:
            futures.add(pool.transactional((c) async {
              await c.execute("insert into $_table (name) values ('p$i')");
              return _value(c.execute('select cast(? as signed)', [i]));
            }));
          case 3:
            futures.add(Future.value(pool.withConnection((c) => _echo(c, i))));
          default:
            futures.add(pool.withPrepared('select cast(? as signed) as v',
                (stmt) => _value(stmt.execute([i]))));
        }
      }
      final results = await Future.wait(futures);
      expect(results, List.generate(200, (i) => i));
      expect(pool.allConnectionsQty, lessThanOrEqualTo(4));
      expect(pool.activeConnectionsQty, 0);
      expect((await names(conn)).length, 40);
    });

    test('concurrent load with failing callers', () async {
      final pool = _pool(3);
      addTearDown(pool.close);
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 90; i++) {
        if (i % 3 == 0) {
          futures.add(pool
              .execute('select * from cov_recovery_missing')
              .then<Object?>((_) => 'no error',
                  onError: (Object e) => 'error'));
        } else if (i % 3 == 1) {
          futures.add(pool.transactional((c) async {
            await c.execute("insert into $_table (name) values ('r$i')");
            throw StateError('roll back');
          }).then<Object?>((_) => 'no error', onError: (Object e) => 'error'));
        } else {
          futures.add(_value(pool.execute('select $i as v')));
        }
      }
      final results = await Future.wait(futures);
      for (var i = 0; i < 90; i++) {
        expect(results[i], i % 3 == 2 ? i : 'error');
      }
      expect(await names(conn), isEmpty);
      expect(pool.activeConnectionsQty, 0);
    });

    test('a pooled connection killed while idle is replaced', () async {
      final pool = _pool(1);
      addTearDown(pool.close);
      final id = await _value(pool.execute('select connection_id()'));
      await admin.execute('KILL $id');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final next = await _value(pool.execute('select connection_id()'));
      expect(next, isNot(id));
    });

    test('a pooled connection killed mid-query fails the caller, not hangs',
        () async {
      final pool = _pool(1);
      addTearDown(pool.close);
      final id = await _value(pool.execute('select connection_id()'));
      final running = pool
          .execute('select sleep(5)')
          .then<Object?>((v) => v, onError: (Object e) => e);
      final waiting = _value(pool.execute('select 7'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await admin.execute('KILL $id');
      expect(
          await running.timeout(const Duration(seconds: 3)), isA<Exception>());
      // The caller waiting for the pool's only connection gets a new one.
      expect(await waiting.timeout(const Duration(seconds: 5)), 7);
    });
  });
}
