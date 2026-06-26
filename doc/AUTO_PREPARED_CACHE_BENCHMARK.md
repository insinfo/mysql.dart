# Auto-Prepared Statement Cache Benchmark

`mysql_dart` auto-prepares parameterized `execute()` calls and keeps prepared statements in a per-connection LRU cache.

The default cache capacity is `32` statements per physical connection. You can tune it with:

```dart
final conn = await MySQLConnection.createConnection(
  host: '127.0.0.1',
  port: 3308,
  userName: 'dart',
  password: 'dart',
  databaseName: 'banco_teste',
  secure: true,
  autoPreparedStatementCacheCapacity: 128,
);
```

The pool passes the same capacity to every connection:

```dart
final pool = MySQLConnectionPool(
  host: '127.0.0.1',
  port: 3308,
  userName: 'dart',
  password: 'dart',
  databaseName: 'banco_teste',
  maxConnections: 8,
  secure: true,
  autoPreparedStatementCacheCapacity: 128,
);
```

## Running

```powershell
$env:MYSQL_HOST='127.0.0.1'
$env:MYSQL_PORT='3308'
$env:MYSQL_USER='dart'
$env:MYSQL_PASSWORD='dart'
$env:MYSQL_DATABASE='banco_teste'
$env:MYSQL_SECURE='true'
$env:MYSQL_AUTO_PREPARED_CACHE_CAPACITY='32'
dart run tool/benchmark_auto_prepare_cache.dart
```

Optional knobs:

```powershell
$env:BENCH_AUTO_PREPARED_HOT_ITERATIONS='4000'
$env:BENCH_AUTO_PREPARED_THRASH_ITERATIONS='4000'
$env:BENCH_AUTO_PREPARED_THRASH_VARIANTS='64'
```

## Local Baseline

Environment:

- MySQL Community Server `9.7.1`
- Windows local loopback
- TLS enabled
- cache capacity `32`
- `4000` executions per scenario

Observed result:

| Scenario | Query Variants | Hits | Misses | Evictions | Throughput |
|---|---:|---:|---:|---:|---:|
| hot set | 1 | 3999 | 1 | 0 | ~3058 ops/s |
| thrash set | 64 | 0 | 4000 | 3969 | ~1906 ops/s |

With capacity raised to `65` for the same run shape, the 64-variant scenario stayed resident after warmup:

| Scenario | Query Variants | Hits | Misses | Evictions | Throughput |
|---|---:|---:|---:|---:|---:|
| hot set | 1 | 3999 | 1 | 0 | ~3086 ops/s |
| 64-variant set | 64 | 3936 | 64 | 0 | ~3903 ops/s |

Interpretation:

- A stable hot set benefits from the auto-cache after the first miss.
- A working set larger than the cache capacity causes repeated `PREPARE` and deferred `COM_STMT_CLOSE` traffic.
- If `evictions` grows continuously under a steady workload, increase `autoPreparedStatementCacheCapacity` or reduce SQL text variation.
- Include all SQL variants active on the same connection when sizing the cache. In the example above, the previous hot-set query plus 64 variant queries need capacity `65` to avoid eviction.

Operational sizing rule:

```text
maxPoolSize * autoPreparedStatementCacheCapacity < max_prepared_stmt_count
```

Keep a margin for other clients and manually prepared statements.
