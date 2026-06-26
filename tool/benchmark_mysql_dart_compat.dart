import 'dart:convert';
import 'dart:io';

import 'package:mysql_dart/mysql_dart.dart';

const _resultSetSizes = <int>[10, 1000, 10000];

String _env(String key, String fallback) =>
    Platform.environment[key]?.trim().isNotEmpty == true
        ? Platform.environment[key]!.trim()
        : fallback;

int _envInt(String key, int fallback) =>
    int.tryParse(Platform.environment[key] ?? '') ?? fallback;

bool _envBool(String key, bool fallback) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) {
    return fallback;
  }

  switch (value.toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return false;
    default:
      return fallback;
  }
}

int _rowIntValue(IResultSet result) {
  final raw = result.rows.first.colAt(0).toString();
  return num.parse(raw).toInt();
}

int _rowChecksum(ResultSetRow row) {
  return num.parse(row.colAt(0).toString()).toInt() +
      row.colAt(1).toString().length +
      row.colAt(2).toString().length +
      row.colAt(3).toString().length +
      row.colAt(4).toString().length;
}

Future<MySQLConnection> _createConnection({
  required String host,
  required int port,
  required String user,
  required String password,
  required String database,
  required bool secure,
}) {
  return MySQLConnection.createConnection(
    host: host,
    port: port,
    userName: user,
    password: password,
    databaseName: database,
    secure: secure,
  );
}

Future<void> _ensureBenchmarkRows(
  MySQLConnection conn,
  int targetRows,
  String benchTableName,
) async {
  await conn.execute('''
    CREATE TABLE IF NOT EXISTS $benchTableName (
      id INT PRIMARY KEY,
      name VARCHAR(64) NOT NULL,
      amount DECIMAL(10, 2) NOT NULL,
      created_at DATETIME NOT NULL,
      payload TEXT NOT NULL
    )
  ''');

  final countResult = await conn.execute(
    'SELECT COUNT(*) FROM $benchTableName',
  );
  final existingRows = _rowIntValue(countResult);
  if (existingRows >= targetRows) {
    return;
  }

  await conn.execute('TRUNCATE TABLE $benchTableName');

  const batchSize = 500;
  for (var start = 1; start <= targetRows; start += batchSize) {
    final end = (start + batchSize - 1 > targetRows)
        ? targetRows
        : start + batchSize - 1;
    final values = StringBuffer();

    for (var id = start; id <= end; id++) {
      if (id > start) {
        values.write(',');
      }

      final cents = id % 100;
      final amount = '$id.${cents.toString().padLeft(2, '0')}';
      final second = id % 60;
      values.write(
        "($id,'name_$id',$amount,'2024-01-01 12:34:${second.toString().padLeft(2, '0')}','payload_${id.toString().padLeft(5, '0')}_abcdefghijklmnopqrstuvwxyz')",
      );
    }

    await conn.execute(
      'INSERT INTO $benchTableName (id, name, amount, created_at, payload) VALUES $values',
    );
  }
}

Future<Map<String, Object?>> _benchmarkResultSet(
  MySQLConnection conn,
  int size,
  int warmupIterations,
  int iterations,
  String benchTableName,
) async {
  final query =
      'SELECT id, name, amount, created_at, payload FROM $benchTableName ORDER BY id LIMIT $size';

  var checksum = 0;
  for (var i = 0; i < warmupIterations; i++) {
    final result = await conn.execute(query);
    for (final row in result.rows) {
      checksum += _rowChecksum(row);
    }
  }

  var rowCount = 0;
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final result = await conn.execute(query);
    for (final row in result.rows) {
      checksum += _rowChecksum(row);
      rowCount++;
    }
  }
  watch.stop();

  final elapsedSeconds = watch.elapsedMicroseconds / 1000000;
  return <String, Object?>{
    'rows_per_query': size,
    'iterations': iterations,
    'warmup_iterations': warmupIterations,
    'total_ms': watch.elapsedMicroseconds / 1000,
    'avg_ms': watch.elapsedMicroseconds / iterations / 1000,
    'queries_per_sec': iterations / elapsedSeconds,
    'rows_per_sec': rowCount / elapsedSeconds,
    'checksum': checksum,
  };
}

Future<void> main() async {
  final host = _env('MYSQL_HOST', '127.0.0.1');
  final port = _envInt('MYSQL_PORT', 3306);
  final user = _env('MYSQL_USER', 'dart');
  final password = _env('MYSQL_PASSWORD', 'dart');
  final database = _env('MYSQL_DATABASE', 'banco_teste');
  final benchTableName = _env('BENCH_TABLE', 'bench_rows_dart_compat');
  final secure = _envBool('MYSQL_SECURE', false);
  final driverName = _env('BENCH_DRIVER_NAME', 'mysql_dart_compat');
  final iterations = _envInt('BENCH_ITERATIONS', 2000);
  final connectIterations = _envInt('BENCH_CONNECT_ITERATIONS', 25);
  final warmupIterations = _envInt('BENCH_WARMUP_ITERATIONS', 200);
  final resultSetIterations = _envInt('BENCH_RESULTSET_ITERATIONS', 20);
  final resultSetWarmupIterations =
      _envInt('BENCH_RESULTSET_WARMUP_ITERATIONS', 5);

  final versionConn = await _createConnection(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    secure: secure,
  );
  await versionConn.connect();
  final versionResult = await versionConn.execute(
    'SELECT VERSION() AS version, @@version_comment AS comment, @@port AS port',
  );
  final versionRow = versionResult.rows.first.assoc();
  await versionConn.close();

  final connectWatch = Stopwatch()..start();
  for (var i = 0; i < connectIterations; i++) {
    final conn = await _createConnection(
      host: host,
      port: port,
      user: user,
      password: password,
      database: database,
      secure: secure,
    );
    await conn.connect();
    await conn.close();
  }
  connectWatch.stop();

  final conn = await _createConnection(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    secure: secure,
  );
  await conn.connect();
  await _ensureBenchmarkRows(conn, _resultSetSizes.last, benchTableName);

  var textChecksum = 0;
  for (var i = 0; i < warmupIterations; i++) {
    final result = await conn.execute('SELECT 1');
    textChecksum += _rowIntValue(result);
  }

  final textWatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final result = await conn.execute('SELECT 1');
    textChecksum += _rowIntValue(result);
  }
  textWatch.stop();

  var autoPreparedChecksum = 0;
  for (var i = 0; i < warmupIterations; i++) {
    final result = await conn.execute('SELECT ? + ?', [40, 2]);
    autoPreparedChecksum += _rowIntValue(result);
  }

  final autoPreparedWatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final result = await conn.execute('SELECT ? + ?', [40, 2]);
    autoPreparedChecksum += _rowIntValue(result);
  }
  autoPreparedWatch.stop();

  final stmt = await conn.prepare('SELECT ? + ?');
  var preparedChecksum = 0;
  for (var i = 0; i < warmupIterations; i++) {
    final result = await stmt.execute([40, 2]);
    preparedChecksum += _rowIntValue(result);
  }

  final preparedWatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final result = await stmt.execute([40, 2]);
    preparedChecksum += _rowIntValue(result);
  }
  preparedWatch.stop();

  await stmt.deallocate();

  final resultSets = <String, Object?>{};
  for (final size in _resultSetSizes) {
    resultSets['rows_$size'] = await _benchmarkResultSet(
      conn,
      size,
      resultSetWarmupIterations,
      resultSetIterations,
      benchTableName,
    );
  }

  await conn.close();

  print(jsonEncode({
    'driver': driverName,
    'host': host,
    'port': port,
    'database': database,
    'secure': secure,
    'connect_mode': 'warm_auth_cache',
    'warmup_iterations': warmupIterations,
    'resultset_warmup_iterations': resultSetWarmupIterations,
    'server': versionRow,
    'connect_iterations': connectIterations,
    'connect_total_ms': connectWatch.elapsedMicroseconds / 1000,
    'connect_avg_ms':
        connectWatch.elapsedMicroseconds / connectIterations / 1000,
    'iterations': iterations,
    'text_total_ms': textWatch.elapsedMicroseconds / 1000,
    'text_avg_ms': textWatch.elapsedMicroseconds / iterations / 1000,
    'text_ops_per_sec': iterations / (textWatch.elapsedMicroseconds / 1000000),
    'text_checksum': textChecksum,
    'auto_prepared_total_ms': autoPreparedWatch.elapsedMicroseconds / 1000,
    'auto_prepared_avg_ms':
        autoPreparedWatch.elapsedMicroseconds / iterations / 1000,
    'auto_prepared_ops_per_sec':
        iterations / (autoPreparedWatch.elapsedMicroseconds / 1000000),
    'auto_prepared_checksum': autoPreparedChecksum,
    'prepared_total_ms': preparedWatch.elapsedMicroseconds / 1000,
    'prepared_avg_ms': preparedWatch.elapsedMicroseconds / iterations / 1000,
    'prepared_ops_per_sec':
        iterations / (preparedWatch.elapsedMicroseconds / 1000000),
    'prepared_checksum': preparedChecksum,
    'result_sets': resultSets,
  }));
}
