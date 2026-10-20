// Every entry point (text, named/positional parameters, prepare, iterable
// result sets, pool, transactional) against every kind of statement. After
// each one the NEXT command on the same connection must get its own reply:
// a reply left unread (or read too far) desynchronizes the connection.

import 'dart:async';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _table = 'cov_matrix';

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

MySQLConnectionPool _pool({int maxConnections = 1}) => MySQLConnectionPool(
      host: mysqlTestHost,
      port: mysqlTestPort,
      userName: mysqlTestUser,
      password: mysqlTestPassword,
      databaseName: mysqlTestDatabase,
      secure: mysqlTestSecure,
      maxConnections: maxConnections,
    );

/// A result read the same way whatever the entry point.
class _Result {
  final List<Map<String, dynamic>> rows;
  final int columns;
  final BigInt affectedRows;
  final BigInt lastInsertID;

  _Result(this.rows, this.columns, this.affectedRows, this.lastInsertID);
}

Future<_Result> _collect(IResultSet rs) async {
  final rows = <Map<String, dynamic>>[];
  await for (final row in rs.rowsStream) {
    rows.add(row.typedAssoc());
  }
  return _Result(rows, rs.numOfColumns, rs.affectedRows, rs.lastInsertID);
}

String _literal(Object? value) {
  if (value == null) return 'NULL';
  if (value is num) return '$value';
  return "'${value.toString().replaceAll("'", "''")}'";
}

/// `?` placeholders replaced by SQL literals (the text protocol).
String _inline(String sql, List<Object?> params) {
  var i = 0;
  return sql.replaceAllMapped('?', (_) => _literal(params[i++]));
}

/// `?` placeholders replaced by `:p0`, `:p1`, ...
String _named(String sql) {
  var i = 0;
  return sql.replaceAllMapped('?', (_) => ':p${i++}');
}

Map<String, Object?> _namedParams(List<Object?> params) =>
    {for (var i = 0; i < params.length; i++) 'p$i': params[i]};

/// One way of running a statement, plus a way to check that the connection
/// it used still answers its own commands.
class _Api {
  final String name;
  final Future<_Result> Function(String sql, List<Object?> params) run;
  final Future<int> Function(int value) echo;

  _Api(this.name, this.run, this.echo);
}

/// One statement kind: [sql] uses `?` placeholders; [check] verifies the
/// result, or [error] the exception it must raise.
class _Case {
  final String name;
  final String sql;
  final List<Object?> params;
  final void Function(_Result result)? check;
  final Matcher? error;

  _Case(this.name, this.sql, this.params, {this.check, this.error});
}

final _cases = [
  _Case(
      'SELECT with rows',
      'select id, name from $_table where id >= ? order by id',
      [2], check: (r) {
    expect(r.columns, 2);
    expect(r.rows, [
      {'id': 2, 'name': 'b'},
      {'id': 3, 'name': 'c'},
    ]);
  }),
  _Case(
      'SELECT with 0 rows',
      'select id, name from $_table where id > ? order by id',
      [100], check: (r) {
    expect(r.columns, 2);
    expect(r.rows, isEmpty);
  }),
  _Case('INSERT 1 row', 'insert into $_table (name) values (?)', ['x'],
      check: (r) {
    expect(r.columns, 0);
    expect(r.affectedRows, BigInt.one);
    expect(r.lastInsertID, BigInt.from(4));
  }),
  _Case('INSERT n rows', 'insert into $_table (name) values (?), (?), (?)',
      ['x', 'y', 'z'], check: (r) {
    expect(r.affectedRows, BigInt.from(3));
    // The id generated for the first row of the statement.
    expect(r.lastInsertID, BigInt.from(4));
  }),
  _Case('INSERT without placeholders',
      "insert into $_table (name) values ('k')", [], check: (r) {
    expect(r.affectedRows, BigInt.one);
    expect(r.lastInsertID, BigInt.from(4));
  }),
  _Case(
      'INSERT 0 rows (INSERT ... SELECT)',
      'insert into $_table (name) select name from $_table where id > ?',
      [100], check: (r) {
    expect(r.affectedRows, BigInt.zero);
    expect(r.lastInsertID, BigInt.zero);
  }),
  _Case('UPDATE 0 rows', 'update $_table set name = ? where id > ?', ['q', 100],
      check: (r) => expect(r.affectedRows, BigInt.zero)),
  _Case('UPDATE 1 row', 'update $_table set name = ? where id = ?', ['q', 1],
      check: (r) => expect(r.affectedRows, BigInt.one)),
  _Case('UPDATE n rows', 'update $_table set name = ? where id >= ?', ['q', 1],
      check: (r) => expect(r.affectedRows, BigInt.from(3))),
  _Case('UPDATE matching rows without changing them',
      'update $_table set name = ? where id = ?', ['a', 1],
      // Changed rows, not matched rows (CLIENT_FOUND_ROWS is not set).
      check: (r) => expect(r.affectedRows, BigInt.zero)),
  _Case('DELETE 0 rows', 'delete from $_table where id > ?', [100],
      check: (r) => expect(r.affectedRows, BigInt.zero)),
  _Case('DELETE 1 row', 'delete from $_table where id = ?', [2],
      check: (r) => expect(r.affectedRows, BigInt.one)),
  _Case('DELETE n rows', 'delete from $_table where id >= ?', [1],
      check: (r) => expect(r.affectedRows, BigInt.from(3))),
  _Case('DDL', 'create table if not exists ${_table}_ddl (id int)', [],
      check: (r) {
    expect(r.columns, 0);
    expect(r.affectedRows, BigInt.zero);
  }),
  _Case('SET', 'set @cov_matrix_v = ?', [42], check: (r) {
    expect(r.columns, 0);
    expect(r.rows, isEmpty);
  }),
  _Case('statement raising a server error',
      'select * from cov_matrix_missing where id = ?', [1],
      error: throwsA(isA<MySQLServerException>()
          .having((e) => e.errorCode, 'errorCode', 1146))),
  _Case('INSERT raising a duplicate key error',
      'insert into $_table (id, name) values (?, ?)', [1, 'dup'],
      error: throwsA(isA<MySQLServerException>()
          .having((e) => e.errorCode, 'errorCode', 1062))),
  _Case(
      'error after some rows',
      'select g.n, (select 1 union select 2 from dual where g.n > ?) as x '
          'from (select 1 as n union select 2) g',
      [1],
      error: throwsA(isA<MySQLServerException>())),
  _Case('statement with a warning', 'select cast(? as signed) as v', ['12abc'],
      check: (r) => expect(r.rows, [
            {'v': 12}
          ])),
  _Case('utf8mb4 text', 'select ? as v', ['ação 😀 中文'],
      check: (r) => expect(r.rows, [
            {'v': 'ação 😀 中文'}
          ])),
];

Future<void> _resetTable(MySQLConnection c) async {
  await c.execute('drop table if exists ${_table}_ddl');
  await c.execute('drop table if exists $_table');
  await c.execute('create table $_table '
      '(id int auto_increment primary key, name varchar(50)) engine=InnoDB');
  await c.execute("insert into $_table (name) values ('a'), ('b'), ('c')");
}

void main() {
  late MySQLConnection conn;
  late MySQLConnectionPool pool;

  Future<int> echoConn(int v) async {
    final text = await conn.execute('select $v as v');
    expect(text.rows.single.typedColByName<int>('v'), v);
    final binary = await conn.execute('select cast(? as signed) as v', [v]);
    return binary.rows.single.typedAssoc()['v'] as int;
  }

  Future<int> echoPool(int v) async {
    final r = await pool.execute('select cast(:v as signed) as v', {'v': v});
    return r.rows.single.typedAssoc()['v'] as int;
  }

  final apis = [
    _Api(
        'execute (text protocol)',
        (sql, p) async => _collect(await conn.execute(_inline(sql, p))),
        echoConn),
    _Api(
        'execute with named params',
        (sql, p) async =>
            _collect(await conn.execute(_named(sql), _namedParams(p))),
        echoConn),
    _Api('execute with positional params',
        (sql, p) async => _collect(await conn.execute(sql, p)), echoConn),
    _Api(
        'execute iterable (text protocol)',
        (sql, p) async =>
            _collect(await conn.execute(_inline(sql, p), null, true)),
        echoConn),
    _Api('execute iterable with params',
        (sql, p) async => _collect(await conn.execute(sql, p, true)), echoConn),
    _Api('prepare + PreparedStmt.execute', (sql, p) async {
      final stmt = await conn.prepare(sql);
      try {
        return await _collect(await stmt.execute(p));
      } finally {
        await stmt.deallocate();
      }
    }, echoConn),
    _Api('prepare(iterable) + PreparedStmt.execute', (sql, p) async {
      final stmt = await conn.prepare(sql, true);
      try {
        return await _collect(await stmt.execute(p));
      } finally {
        await stmt.deallocate();
      }
    }, echoConn),
    _Api(
        'transactional',
        (sql, p) => conn.transactional(
            (c) async => _collect(await c.execute(sql, p.isEmpty ? null : p))),
        echoConn),
    _Api(
        'pool execute',
        (sql, p) async => _collect(await pool.execute(
            _named(sql), p.isEmpty ? null : _namedParams(p))),
        echoPool),
    _Api(
        'pool transactional',
        (sql, p) => pool.transactional(
            (c) async => _collect(await c.execute(sql, p.isEmpty ? null : p))),
        echoPool),
  ];

  setUpAll(() async {
    conn = await _open();
    // One connection: the next pooled command reuses the same session.
    pool = _pool();
  });

  tearDownAll(() async {
    try {
      await conn.execute('drop table if exists ${_table}_ddl');
      await conn.execute('drop table if exists $_table');
    } finally {
      await conn.close();
      await pool.close();
    }
  });

  setUp(() => _resetTable(conn));

  for (final api in apis) {
    group(api.name, () {
      var next = 0;
      for (final c in _cases) {
        test(c.name, () async {
          final result = api.run(c.sql, c.params);
          if (c.error != null) {
            await expectLater(result, c.error);
          } else {
            c.check!(await result);
          }
          // The next commands get their own replies.
          for (var i = 0; i < 3; i++) {
            final v = 1000 + next++;
            expect(await api.echo(v), v);
          }
        });
      }
    });
  }

  group('statements producing several results', () {
    setUpAll(() async {
      await conn.execute('drop procedure if exists cov_matrix_one');
      await conn.execute('drop procedure if exists cov_matrix_two');
      await conn.execute('drop procedure if exists cov_matrix_dml');
      await conn.execute('create procedure cov_matrix_one(in a int) '
          'begin select a as v, a * 2 as w; end');
      await conn.execute('create procedure cov_matrix_two(in a int) '
          'begin select a as v; select a + 1 as v union all select a + 2; end');
      await conn.execute('create procedure cov_matrix_dml(in a varchar(50)) '
          'begin insert into $_table (name) values (a); end');
    });
    tearDownAll(() async {
      await conn.execute('drop procedure if exists cov_matrix_one');
      await conn.execute('drop procedure if exists cov_matrix_two');
      await conn.execute('drop procedure if exists cov_matrix_dml');
    });

    List<List<Map<String, dynamic>>> rowsOf(IResultSet rs) => [
          for (final r in rs) [for (final row in r.rows) row.typedAssoc()],
        ];

    test('multi-statement text query chains every result', () async {
      final rs = await conn.execute("insert into $_table (name) values ('m'); "
          "select name from $_table where id = 4; "
          "update $_table set name = 'n' where id <= 2");
      final results = rs.toList();
      expect(results, hasLength(3));
      expect(results[0].affectedRows, BigInt.one);
      expect(results[0].lastInsertID, BigInt.from(4));
      expect(rowsOf(results[1]).first, [
        {'name': 'm'}
      ]);
      expect(results[2].affectedRows, BigInt.from(2));
      expect(await echoConn(7), 7);
    });

    test('multi-statement text query whose second statement fails', () async {
      await expectLater(
          conn.execute('select 1 as v; select * from cov_matrix_missing'),
          throwsA(isA<MySQLServerException>()));
      expect(await echoConn(8), 8);
    });

    test('iterable multi-statement query streams the first result only',
        () async {
      final rs = await conn.execute(
          'select 1 as v union all select 2; select 3 as w', null, true);
      expect((await _collect(rs)).rows, [
        {'v': 1},
        {'v': 2}
      ]);
      expect(await echoConn(9), 9);

      final dmlFirst = await conn.execute(
          "insert into $_table (name) values ('i'); select 5 as v", null, true);
      expect(dmlFirst.affectedRows, BigInt.one);
      expect(await echoConn(10), 10);
    });

    test('CALL through the text protocol returns its rows', () async {
      final rs = await conn.execute('call cov_matrix_one(3)');
      expect(rowsOf(rs), [
        [
          {'v': 3, 'w': 6}
        ],
        [], // the CALL's own OK
      ]);
      expect(await echoConn(11), 11);

      final two = await conn.execute('call cov_matrix_two(1)');
      expect(rowsOf(two), [
        [
          {'v': 1}
        ],
        [
          {'v': 2},
          {'v': 3}
        ],
        [],
      ]);
      expect(await echoConn(12), 12);
    });

    test('CALL with parameters (auto-prepared) returns its rows', () async {
      final rs = await conn.execute('call cov_matrix_one(?)', [4]);
      expect(rowsOf(rs).first, [
        {'v': 4, 'w': 8}
      ]);
      expect(await echoConn(13), 13);

      final two = await conn.execute('call cov_matrix_two(?)', [5]);
      expect(rowsOf(two).take(2), [
        [
          {'v': 5}
        ],
        [
          {'v': 6},
          {'v': 7}
        ],
      ]);
      expect(await echoConn(14), 14);
    });

    test('CALL through prepare() returns its rows', () async {
      final stmt = await conn.prepare('call cov_matrix_two(?)');
      for (var i = 0; i < 3; i++) {
        final rs = await stmt.execute([i * 10]);
        expect(rowsOf(rs).first, [
          {'v': i * 10}
        ]);
        expect(await echoConn(15 + i), 15 + i);
      }
      await stmt.deallocate();
    });

    test('iterable CALL streams the first result set', () async {
      for (final params in [
        null,
        <Object?>[2]
      ]) {
        final rs = await conn.execute(
            params == null
                ? 'call cov_matrix_two(2)'
                : 'call cov_matrix_two(?)',
            params,
            true);
        expect((await _collect(rs)).rows, [
          {'v': 2}
        ]);
        expect(await echoConn(20), 20);
      }
    });

    test('CALL without result sets', () async {
      final rs = await conn.execute("call cov_matrix_dml('p')");
      expect(rs.affectedRows, BigInt.one);
      final prepared = await conn.execute('call cov_matrix_dml(?)', ['q']);
      expect(prepared.affectedRows, BigInt.one);
      expect(await echoConn(21), 21);
      final names = await conn
          .execute('select name from $_table where id > 3 order by id');
      expect(names.rows.map((r) => r.colAt(0)), ['p', 'q']);
    });

    test('CALL through the pool', () async {
      final rs = await pool.execute('call cov_matrix_one(:a)', {'a': 6});
      expect(rowsOf(rs).first, [
        {'v': 6, 'w': 12}
      ]);
      expect(await echoPool(22), 22);
      final tx = await pool.transactional(
          (c) async => rowsOf(await c.execute('call cov_matrix_two(1)')));
      expect(tx.first, [
        {'v': 1}
      ]);
      expect(await echoPool(23), 23);
    });
  });
}
