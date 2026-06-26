import 'dart:convert';
import 'dart:io';

import 'package:mysql_dart/mysql_dart.dart';

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

Future<Map<String, Object?>> _runScenario(
  MySQLConnection conn, {
  required String name,
  required List<String> queries,
  required int iterations,
}) async {
  var checksum = 0;
  final statsBefore = conn.autoPreparedStatementCacheStats;
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final query = queries[i % queries.length];
    final result = await conn.execute(query, [40, 2]);
    checksum += num.parse(result.rows.first.colAt(0).toString()).toInt();
  }
  watch.stop();

  final statsAfter = conn.autoPreparedStatementCacheStats;
  return <String, Object?>{
    'name': name,
    'iterations': iterations,
    'query_variants': queries.length,
    'total_ms': watch.elapsedMicroseconds / 1000,
    'avg_ms': watch.elapsedMicroseconds / iterations / 1000,
    'ops_per_sec': iterations / (watch.elapsedMicroseconds / 1000000),
    'checksum': checksum,
    'cache_hits': statsAfter.hits - statsBefore.hits,
    'cache_misses': statsAfter.misses - statsBefore.misses,
    'cache_evictions': statsAfter.evictions - statsBefore.evictions,
    'cached_statements': statsAfter.cachedStatements,
    'deferred_closes': statsAfter.deferredCloses,
    'cache_capacity': statsAfter.capacity,
  };
}

Future<void> main() async {
  final host = _env('MYSQL_HOST', '127.0.0.1');
  final port = _envInt('MYSQL_PORT', 3306);
  final user = _env('MYSQL_USER', 'dart');
  final password = _env('MYSQL_PASSWORD', 'dart');
  final database = _env('MYSQL_DATABASE', 'banco_teste');
  final secure = _envBool('MYSQL_SECURE', false);
  final hotIterations = _envInt('BENCH_AUTO_PREPARED_HOT_ITERATIONS', 4000);
  final thrashIterations =
      _envInt('BENCH_AUTO_PREPARED_THRASH_ITERATIONS', 4000);
  final thrashVariants = _envInt('BENCH_AUTO_PREPARED_THRASH_VARIANTS', 64);
  final cacheCapacity = _envInt('MYSQL_AUTO_PREPARED_CACHE_CAPACITY', 32);

  final conn = await MySQLConnection.createConnection(
    host: host,
    port: port,
    userName: user,
    password: password,
    databaseName: database,
    secure: secure,
    allowPublicKeyRetrieval: !secure,
    autoPreparedStatementCacheCapacity: cacheCapacity,
  );
  await conn.connect();

  final hotScenario = await _runScenario(
    conn,
    name: 'hot_set',
    queries: const <String>['SELECT ? + ?'],
    iterations: hotIterations,
  );

  final thrashQueries = List<String>.generate(
    thrashVariants,
    (index) => 'SELECT ? + ? /* thrash_$index */',
    growable: false,
  );

  final thrashScenario = await _runScenario(
    conn,
    name: 'thrash_set',
    queries: thrashQueries,
    iterations: thrashIterations,
  );

  await conn.close();

  print(jsonEncode({
    'driver': secure ? 'mysql_dart_tls' : 'mysql_dart_plain',
    'host': host,
    'port': port,
    'database': database,
    'secure': secure,
    'configured_cache_capacity': cacheCapacity,
    'hot_set': hotScenario,
    'thrash_set': thrashScenario,
  }));
}
