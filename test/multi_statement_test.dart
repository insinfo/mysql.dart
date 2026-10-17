import 'package:mysql_dart/mysql_dart.dart';
import 'package:mysql_dart/exception.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  late MySQLConnection conn;

  Future<void> dropAll() async {
    await conn.execute('DROP TABLE IF EXISTS ms_t');
    await conn.execute('DROP TABLE IF EXISTS ms_u');
    await conn.execute('DROP PROCEDURE IF EXISTS ms_proc');
  }

  setUpAll(() async {
    conn = await MySQLConnection.createConnection(
      host: mysqlTestHost,
      port: mysqlTestPort,
      userName: mysqlTestUser,
      password: mysqlTestPassword,
      databaseName: mysqlTestDatabase,
      secure: mysqlTestSecure,
    );
    await conn.connect();
  });

  setUp(() async => dropAll());

  tearDownAll(() async {
    await dropAll();
    await conn.close();
  });

  test('single OK and single SELECT statements are unchanged', () async {
    final ok = await conn.execute('CREATE TABLE ms_t (id INT)');
    expect(ok.next, isNull);
    expect(ok.numOfRows, 0);

    final sel = await conn.execute('SELECT 1 AS a');
    expect(sel.next, isNull);
    expect(sel.rows.first.colAt(0), '1');
  });

  test('SELECT; SELECT keeps chaining', () async {
    final rs = await conn.execute('SELECT 1 AS a; SELECT 2 AS b');
    expect(rs.rows.first.colAt(0), '1');
    expect(rs.next!.rows.first.colAt(0), '2');
    expect(rs.next!.next, isNull);
    expect(rs.map((r) => r.rows.first.colAt(0)).toList(), ['1', '2']);
  });

  test('OK-only batch leaves the connection clean', () async {
    final rs = await conn.execute(
      'DROP TABLE IF EXISTS ms_t; CREATE TABLE ms_t (id INT); '
      'INSERT INTO ms_t VALUES (1)',
    );
    expect(rs.toList().length, 3);
    expect(rs.next!.next!.affectedRows.toInt(), 1);
    expect(rs.next!.next!.next, isNull);

    final sel = await conn.execute('SELECT id FROM ms_t');
    expect(sel.numOfRows, 1);
    expect(sel.rows.first.colAt(0), '1');
  });

  test('failing statement in the middle raises and stops the batch', () async {
    await expectLater(
      conn.execute(
        'CREATE TABLE ms_t (id INT); CREATE TABLE ms_t (id INT); '
        'CREATE TABLE ms_u (id INT)',
      ),
      throwsA(isA<MySQLServerException>()
          .having((e) => e.errorCode, 'code', 1050)
          .having((e) => e.message, 'message', contains('already exists'))),
    );

    final tables = await conn.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = DATABASE() AND table_name IN ('ms_t','ms_u')");
    expect(tables.rows.map((r) => r.colAt(0)!.toLowerCase()).toList(),
        ['ms_t']);

    // syntax error
    await expectLater(
      conn.execute('SELECT 1; SELEC 2; SELECT 3'),
      throwsA(isA<MySQLServerException>()
          .having((e) => e.errorCode, 'code', 1064)),
    );

    final again = await conn.execute('SELECT 42');
    expect(again.rows.first.colAt(0), '42');
  });

  test('mixed batch walks the full chain with per-result OK data', () async {
    final rs = await conn.execute(
      'CREATE TABLE ms_t (id INT AUTO_INCREMENT PRIMARY KEY, v INT); '
      'SET @x = 1; '
      'INSERT INTO ms_t (v) VALUES (10),(20),(30); '
      'SELECT @x AS x; '
      'UPDATE ms_t SET v = v + 1 WHERE v >= 20; '
      'INSERT INTO ms_t (v) VALUES (99); '
      'SELECT 2 AS two',
    );
    final results = rs.toList();
    expect(results.length, 7);

    expect(results[0].numOfColumns, 0);
    expect(results[1].numOfColumns, 0);
    expect(results[2].affectedRows.toInt(), 3);
    expect(results[2].lastInsertID.toInt(), 1);
    expect(results[3].rows.first.colAt(0), '1');
    expect(results[4].affectedRows.toInt(), 2);
    expect(results[5].affectedRows.toInt(), 1);
    expect(results[5].lastInsertID.toInt(), 4);
    expect(results[6].rows.first.colAt(0), '2');
    expect(results[6].next, isNull);

    final after = await conn.execute('SELECT COUNT(*) FROM ms_t');
    expect(after.rows.first.colAt(0), '4');
  });

  test('prepared statement after a batch works (no error 1243)', () async {
    await conn.execute(
        'CREATE TABLE ms_t (id INT); INSERT INTO ms_t VALUES (1),(2);');
    final stmt = await conn.prepare('SELECT COUNT(*) FROM ms_t WHERE id > ?');
    final rs = await stmt.execute([0]);
    expect(rs.rows.first.colAt(0), '2');
    await stmt.deallocate();

    await conn.transactional((c) async {
      await c.execute('INSERT INTO ms_t VALUES (3)');
    });
  });

  test('CALL returning result sets inside a batch', () async {
    await conn.execute('CREATE TABLE ms_t (id INT)');
    await conn.execute(
        'CREATE PROCEDURE ms_proc() BEGIN SELECT 1 AS a; SELECT 2 AS b; '
        'INSERT INTO ms_t VALUES (7); END');

    final rs = await conn.execute(
        'SET @y = 5; CALL ms_proc(); SELECT @y AS y');
    final results = rs.toList();
    // SET ok, proc rs 1, proc rs 2, proc final OK, SELECT
    expect(results.length, 5);
    expect(results[0].numOfColumns, 0);
    expect(results[1].rows.first.colAt(0), '1');
    expect(results[2].rows.first.colAt(0), '2');
    expect(results[3].numOfColumns, 0);
    expect(results[3].affectedRows.toInt(), 1);
    expect(results[4].rows.first.colAt(0), '5');

    final sel = await conn.execute('SELECT id FROM ms_t');
    expect(sel.rows.first.colAt(0), '7');
  });
}
