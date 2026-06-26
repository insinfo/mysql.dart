import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:mysql_dart/mysql_dart.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

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
  final existingRows = int.parse(countResult.rows.first.colAt(0).toString());
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

Uri _toWebSocketUri(Uri uri) {
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  final path = uri.path.endsWith('/') ? '${uri.path}ws' : '${uri.path}/ws';
  return uri.replace(scheme: scheme, path: path);
}

Future<VmService> _connectVmService() async {
  final info = await developer.Service.getInfo();
  final uri = info.serverUri;
  if (uri == null) {
    throw StateError(
      'VM service is not available. Run with --enable-vm-service=0 --disable-service-auth-codes.',
    );
  }

  return vmServiceConnectUri(_toWebSocketUri(uri).toString());
}

Future<String> _mainIsolateId(VmService service) async {
  final vm = await service.getVM();
  for (final ref in vm.isolates ?? const <IsolateRef>[]) {
    if (ref.name?.contains('main') ?? false) {
      return ref.id!;
    }
  }
  final first = vm.isolates?.first;
  if (first == null || first.id == null) {
    throw StateError('No running isolate found.');
  }
  return first.id!;
}

Future<Map<String, Object?>> _heapSnapshot(
  VmService service,
  String isolateId,
) async {
  final profile = await service.getAllocationProfile(isolateId, gc: true);
  final memoryUsage = profile.memoryUsage;
  return <String, Object?>{
    'heap_usage': memoryUsage?.heapUsage,
    'heap_capacity': memoryUsage?.heapCapacity,
    'external_usage': memoryUsage?.externalUsage,
  };
}

Future<Map<String, Object?>> _profileScenario(
  MySQLConnection conn,
  VmService service,
  String isolateId, {
  required String name,
  required int size,
  required bool iterable,
  required String benchTableName,
}) async {
  final query =
      'SELECT id, name, amount, created_at, payload FROM $benchTableName ORDER BY id LIMIT $size';

  final before = await _heapSnapshot(service, isolateId);
  var checksum = 0;
  final watch = Stopwatch()..start();

  if (iterable) {
    final result = await conn.execute(query, null, true);
    await for (final row in result.rowsStream) {
      checksum += int.parse(row.colAt(0).toString());
    }
  } else {
    final result = await conn.execute(query);
    for (final row in result.rows) {
      checksum += int.parse(row.colAt(0).toString());
    }
  }

  watch.stop();
  final after = await _heapSnapshot(service, isolateId);

  return <String, Object?>{
    'name': name,
    'rows_per_query': size,
    'iterable': iterable,
    'elapsed_ms': watch.elapsedMicroseconds / 1000,
    'checksum': checksum,
    'before': before,
    'after': after,
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
  final size = _envInt('HEAP_PROFILE_ROWS', 10000);

  final service = await _connectVmService();
  final isolateId = await _mainIsolateId(service);

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
  await _ensureBenchmarkRows(conn, size, benchTableName);

  final materialized = await _profileScenario(
    conn,
    service,
    isolateId,
    name: 'materialized',
    size: size,
    iterable: false,
    benchTableName: benchTableName,
  );
  final streaming = await _profileScenario(
    conn,
    service,
    isolateId,
    name: 'streaming',
    size: size,
    iterable: true,
    benchTableName: benchTableName,
  );

  await conn.close();
  await service.dispose();

  print(jsonEncode({
    'driver': secure ? 'mysql_dart_tls' : 'mysql_dart_plain',
    'host': host,
    'port': port,
    'database': database,
    'secure': secure,
    'heap_profile_rows': size,
    'materialized': materialized,
    'streaming': streaming,
  }));
}
