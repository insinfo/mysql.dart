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

Map<String, Object?> _latencyStats(List<double> samplesMs) {
  final sorted = List<double>.from(samplesMs)..sort();
  double percentile(double fraction) {
    if (sorted.isEmpty) {
      return 0;
    }
    final index = ((sorted.length - 1) * fraction).round();
    return sorted[index];
  }

  final total = sorted.fold<double>(0, (sum, value) => sum + value);
  return <String, Object?>{
    'samples': sorted.length,
    'min_ms': sorted.isEmpty ? 0 : sorted.first,
    'median_ms': percentile(0.5),
    'p95_ms': percentile(0.95),
    'p99_ms': percentile(0.99),
    'max_ms': sorted.isEmpty ? 0 : sorted.last,
    'avg_ms': sorted.isEmpty ? 0 : total / sorted.length,
    'total_ms': total,
  };
}

Future<double> _measureConnectOnce({
  required String host,
  required int port,
  required String user,
  required String password,
  required String database,
  required bool secure,
  required bool setCharsetOnConnect,
}) async {
  final watch = Stopwatch()..start();
  final conn = await MySQLConnection.createConnection(
    host: host,
    port: port,
    userName: user,
    password: password,
    databaseName: database,
    secure: secure,
    allowPublicKeyRetrieval: !secure,
  );
  await conn.connect(setCharsetOnConnect: setCharsetOnConnect);
  await conn.close();
  watch.stop();
  return watch.elapsedMicroseconds / 1000;
}

Future<Map<String, Object?>> _benchmarkConnectScenarios({
  required String host,
  required int port,
  required String user,
  required String password,
  required String database,
  required bool secure,
  required int iterations,
}) async {
  final withCharsetSamples = <double>[];
  final withoutCharsetSamples = <double>[];

  for (var i = 0; i < iterations; i++) {
    final runWithCharsetFirst = i.isEven;

    if (runWithCharsetFirst) {
      withCharsetSamples.add(
        await _measureConnectOnce(
          host: host,
          port: port,
          user: user,
          password: password,
          database: database,
          secure: secure,
          setCharsetOnConnect: true,
        ),
      );
      withoutCharsetSamples.add(
        await _measureConnectOnce(
          host: host,
          port: port,
          user: user,
          password: password,
          database: database,
          secure: secure,
          setCharsetOnConnect: false,
        ),
      );
    } else {
      withoutCharsetSamples.add(
        await _measureConnectOnce(
          host: host,
          port: port,
          user: user,
          password: password,
          database: database,
          secure: secure,
          setCharsetOnConnect: false,
        ),
      );
      withCharsetSamples.add(
        await _measureConnectOnce(
          host: host,
          port: port,
          user: user,
          password: password,
          database: database,
          secure: secure,
          setCharsetOnConnect: true,
        ),
      );
    }
  }

  return <String, Object?>{
    'alternating_order': true,
    'with_charset': _latencyStats(withCharsetSamples),
    'without_charset': _latencyStats(withoutCharsetSamples),
  };
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

  var materializedChecksum = 0;
  for (var i = 0; i < warmupIterations; i++) {
    final result = await conn.execute(query);
    for (final row in result.rows) {
      materializedChecksum += _rowChecksum(row);
    }
  }

  var materializedRowCount = 0;
  var materializedFirstRowMicros = 0;
  final materializedRssBefore = ProcessInfo.currentRss;
  var materializedPeakRss = materializedRssBefore;
  final materializedWatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final firstRowWatch = Stopwatch()..start();
    final result = await conn.execute(query);
    var sawFirstRow = false;
    for (final row in result.rows) {
      if (!sawFirstRow) {
        firstRowWatch.stop();
        materializedFirstRowMicros += firstRowWatch.elapsedMicroseconds;
        sawFirstRow = true;
      }
      materializedChecksum += _rowChecksum(row);
      materializedRowCount++;
    }
    final currentRss = ProcessInfo.currentRss;
    if (currentRss > materializedPeakRss) {
      materializedPeakRss = currentRss;
    }
  }
  materializedWatch.stop();
  final materializedRssAfter = ProcessInfo.currentRss;

  var streamingChecksum = 0;
  for (var i = 0; i < warmupIterations; i++) {
    final result = await conn.execute(query, null, true);
    await for (final row in result.rowsStream) {
      streamingChecksum += _rowChecksum(row);
    }
  }

  var streamingRowCount = 0;
  var streamingFirstRowMicros = 0;
  final streamingRssBefore = ProcessInfo.currentRss;
  var streamingPeakRss = streamingRssBefore;
  final streamingWatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final firstRowWatch = Stopwatch()..start();
    final result = await conn.execute(query, null, true);
    var sawFirstRow = false;
    await for (final row in result.rowsStream) {
      if (!sawFirstRow) {
        firstRowWatch.stop();
        streamingFirstRowMicros += firstRowWatch.elapsedMicroseconds;
        sawFirstRow = true;
      }
      streamingChecksum += _rowChecksum(row);
      streamingRowCount++;
    }
    final currentRss = ProcessInfo.currentRss;
    if (currentRss > streamingPeakRss) {
      streamingPeakRss = currentRss;
    }
  }
  streamingWatch.stop();
  final streamingRssAfter = ProcessInfo.currentRss;

  final materializedElapsedSeconds =
      materializedWatch.elapsedMicroseconds / 1000000;
  final streamingElapsedSeconds = streamingWatch.elapsedMicroseconds / 1000000;
  return <String, Object?>{
    'rows_per_query': size,
    'iterations': iterations,
    'warmup_iterations': warmupIterations,
    'total_ms': materializedWatch.elapsedMicroseconds / 1000,
    'avg_ms': materializedWatch.elapsedMicroseconds / iterations / 1000,
    'queries_per_sec': iterations / materializedElapsedSeconds,
    'rows_per_sec': materializedRowCount / materializedElapsedSeconds,
    'first_row_avg_ms': materializedFirstRowMicros / iterations / 1000,
    'checksum': materializedChecksum,
    'materialized_total_ms': materializedWatch.elapsedMicroseconds / 1000,
    'materialized_avg_ms':
        materializedWatch.elapsedMicroseconds / iterations / 1000,
    'materialized_queries_per_sec': iterations / materializedElapsedSeconds,
    'materialized_rows_per_sec':
        materializedRowCount / materializedElapsedSeconds,
    'materialized_first_row_avg_ms':
        materializedFirstRowMicros / iterations / 1000,
    'materialized_checksum': materializedChecksum,
    'materialized_rss_before': materializedRssBefore,
    'materialized_rss_after': materializedRssAfter,
    'materialized_rss_peak': materializedPeakRss,
    'materialized_rss_delta': materializedRssAfter - materializedRssBefore,
    'streaming_total_ms': streamingWatch.elapsedMicroseconds / 1000,
    'streaming_avg_ms': streamingWatch.elapsedMicroseconds / iterations / 1000,
    'streaming_queries_per_sec': iterations / streamingElapsedSeconds,
    'streaming_rows_per_sec': streamingRowCount / streamingElapsedSeconds,
    'streaming_first_row_avg_ms': streamingFirstRowMicros / iterations / 1000,
    'streaming_checksum': streamingChecksum,
    'streaming_rss_before': streamingRssBefore,
    'streaming_rss_after': streamingRssAfter,
    'streaming_rss_peak': streamingPeakRss,
    'streaming_rss_delta': streamingRssAfter - streamingRssBefore,
  };
}

Future<void> main() async {
  final host = _env('MYSQL_HOST', '127.0.0.1');
  final port = _envInt('MYSQL_PORT', 3306);
  final user = _env('MYSQL_USER', 'dart');
  final password = _env('MYSQL_PASSWORD', 'dart');
  final database = _env('MYSQL_DATABASE', 'banco_teste');
  final benchTableName = _env('BENCH_TABLE', 'bench_rows_dart');
  final secure = _envBool('MYSQL_SECURE', false);
  final iterations = _envInt('BENCH_ITERATIONS', 2000);
  final connectIterations = _envInt('BENCH_CONNECT_ITERATIONS', 25);
  final warmupIterations = _envInt('BENCH_WARMUP_ITERATIONS', 200);
  final resultSetIterations = _envInt('BENCH_RESULTSET_ITERATIONS', 20);
  final resultSetWarmupIterations =
      _envInt('BENCH_RESULTSET_WARMUP_ITERATIONS', 5);

  final versionConn = await MySQLConnection.createConnection(
    host: host,
    port: port,
    userName: user,
    password: password,
    databaseName: database,
    secure: secure,
    allowPublicKeyRetrieval: !secure,
  );
  await versionConn.connect();
  final versionResult = await versionConn.execute(
    'SELECT VERSION() AS version, @@version_comment AS comment, @@port AS port',
  );
  final versionRow = versionResult.rows.first.assoc();
  await versionConn.close();

  final connectScenarios = await _benchmarkConnectScenarios(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    secure: secure,
    iterations: connectIterations,
  );

  final conn = await MySQLConnection.createConnection(
    host: host,
    port: port,
    userName: user,
    password: password,
    databaseName: database,
    secure: secure,
    allowPublicKeyRetrieval: !secure,
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
    'driver': secure ? 'mysql_dart_tls' : 'mysql_dart_plain',
    'host': host,
    'port': port,
    'database': database,
    'secure': secure,
    'connect_mode': 'warm_auth_cache',
    'connect_scenarios': connectScenarios,
    'warmup_iterations': warmupIterations,
    'resultset_warmup_iterations': resultSetWarmupIterations,
    'server': versionRow,
    'connect_iterations': connectIterations,
    'connect_total_ms':
        (connectScenarios['with_charset'] as Map<String, Object?>)['total_ms'],
    'connect_avg_ms':
        (connectScenarios['with_charset'] as Map<String, Object?>)['avg_ms'],
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
