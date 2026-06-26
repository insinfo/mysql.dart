### Native MySQL client written in Dart for Dart

[![CI](https://github.com/insinfo/mysql.dart/actions/workflows/dart.yml/badge.svg)](https://github.com/insinfo/mysql.dart/actions/workflows/dart.yml)
[![Pub Package](https://img.shields.io/pub/v/mysql_dart.svg)](https://pub.dev/packages/mysql_dart)  

#### Support My Work
[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/isaqueneves)

I’m on @buymeacoffee. If you like my work, you can buy me a ☕ and share your thoughts 🎉 [Buy me a coffee](https://www.buymeacoffee.com/isaqueneves)

#### fork from https://github.com/zim32/mysql.dart

See [example](example/) directory for examples and usage

Tested in CI:
 * MariaDB 10.11
 * MariaDB 11.8
 * MySQL Community Server 9
 * MySQL Community Server 9.7

Also verified outside CI:
 * MySQL Percona Server 5.7 and 8
 * MariaDB 10.x
 * MariaDB 11.7.2

### What's New in 2.0.0

- Added compatibility with MySQL Community Server 9 and 9.7, including full `caching_sha2_password` authentication with TLS, pinned RSA public keys, or optional server public key retrieval.
- Added binary protocol support for MySQL JSON columns (`column type 245`), decoding them as UTF-8 JSON strings instead of failing at the protocol layer.
- Integration tests now read `MYSQL_*` environment variables, so the suite can run against arbitrary local or CI host/port/database configurations.
- GitHub Actions now runs the test suite against MariaDB 10.11, MariaDB 11.8, MySQL 9, and MySQL 9.7.
- Removed external runtime dependencies on `asn1lib`, `pointycastle`, `buffer`, `crypto`, and `tuple` by inlining the required PEM/RSA/OAEP, hashing, tuple, and byte-writer logic.
- Removed the unsafe pooled APIs `MySQLConnectionPool.prepare()` and `MySQLConnectionPool.execute(..., iterable: true)`. Use `withPrepared(...)` and `withConnection(...)` instead.
- Result-set streaming now propagates backpressure to the socket subscription, and benchmark tooling now measures TLS/non-TLS connect latency, percentile statistics, result-set first-row latency, and streaming vs materialized throughput.

### Breaking Changes in 2.0.0

- `MySQLConnectionPool.prepare()` no longer exists.
- `MySQLConnectionPool.execute(..., iterable: true)` is no longer supported.

Why:

- A prepared statement belongs to one physical connection. The old `pool.prepare()` API let a statement escape after the pool had already returned the owning connection to the idle queue.
- An iterable result set keeps its connection busy until EOF. The old pooled iterable path could release that connection before the stream had finished.

Those old APIs could lead to concurrency bugs such as:

- `connection is busy` failures when unrelated work reused the same connection;
- `COM_STMT_CLOSE` or `COM_STMT_EXECUTE` arriving on a connection already borrowed by another operation;
- result streams consuming packets while the pool had already handed the same connection to a different query;
- protocol desynchronization when prepared-statement lifecycle and connection lifecycle diverged.

Use:

```dart
await pool.withPrepared(
  'UPDATE book SET price = ? WHERE id = ?',
  (stmt) => stmt.execute([99, 1]),
);

await pool.withConnection((conn) async {
  final result = await conn.execute('SELECT * FROM book', null, true);
  await for (final row in result.rowsStream) {
    print(row.assoc());
  }
});
```

### Local Driver Benchmark

This benchmark compares the current local `mysql_dart` tree (`2.0.0`) against `mysql_dart` `1.2.1`, PHP PDO, PHP mysqli, [`friends-of-reactphp/mysql`](https://github.com/friends-of-reactphp/mysql) via its Composer package `react/mysql`, and [`amphp/mysql`](https://github.com/amphp/mysql).

Environment:

- Server: `10.11.6-MariaDB-log` (`mariadb.org binary distribution`)
- Host/port: `127.0.0.1:3306`
- Transport: plain TCP (`MYSQL_SECURE=false`)
- PHP: `8.3.11` NTS
- Dart SDK: `3.6.2`
- Workload: `2000` scalar iterations, `20` connect iterations, result sets of `10`, `1000`, and `10000` rows with positional row access
- Command: `powershell -ExecutionPolicy Bypass -File tool/run_driver_comparison.ps1`

Scalar results:

| Metric | mysql_dart 2.0.0 | mysql_dart 1.2.1 | PHP PDO | PHP mysqli | ReactPHP mysql | AMPHP mysql |
|---|---:|---:|---:|---:|---:|---:|
| Connect avg ms | 1.131 | 130.411 | 2.711 | 13.266 | 156.278 | 0.618 |
| Text ops/s | 6432 | 6562 | 7333 | 12287 | 7572 | 5092 |
| Auto prepared ops/s | 7113 | 7115 | - | 7207 | 6651 | 2594 |
| Prepared ops/s | 9702 | 10219 | 14741 | 15535 | - | 5065 |

Result-set throughput:

| Result set | mysql_dart 2.0.0 | mysql_dart 1.2.1 | PHP PDO | PHP mysqli | ReactPHP mysql | AMPHP mysql |
|---|---:|---:|---:|---:|---:|---:|
| 10 rows/s | 65,746 | 56,117 | 55,106 | 101,693 | 44,625 | 23,110 |
| 1,000 rows/s | 499,413 | 278,505 | 507,616 | 729,219 | 136,012 | 64,428 |
| 10,000 rows/s | 818,274 | 207,385 | 599,171 | 746,236 | 146,778 | 67,594 |

Reading the numbers:

- `mysql_dart` `2.0.0` removes the artificial connect latency present in `1.2.1`.
- `mysqli` still leads scalar prepared statements because it uses the native PHP/MySQL C stack.
- `mysql_dart` `2.0.0` is materially faster than `1.2.1` on large result sets after the parser and row materialization changes.
- ReactPHP's package does not expose a separate public prepared-statement object in the benchmark path, so only its parameterized query path is reported.

### Roadmap

* [x] Auth with mysql_native_password
* [x] Basic connection
* [x] Connection pool
* [x] Query placeholders
* [x] Transactions
* [x] Prepared statements (real, not emulated)
* [x] SSL connection
* [x] Auth using caching_sha2_password (default since MySQL 8)
* [x] Iterating large result sets
* [x] Typed data access
* [x] Send data in binary form when using prepared stmts (do not convert all into strings)
* [x] Multiple resul sets

### Usage

#### Create connection pool

```dart
final pool = MySQLConnectionPool(
  host: '127.0.0.1',
  port: 3306,
  userName: 'your_user',
  password: 'your_password',
  maxConnections: 10,
  databaseName: 'your_database_name', // optional,
  timeZone: '+00:00', // optional: issues SET time_zone right after connect
  idleTestThreshold: Duration(seconds: 30), // validates idle connections
  maxConnectionAge: Duration(hours: 6),
  onConnectionOpen: (conn) async {
    await conn.execute("SET @app_name = 'api'");
  },
  retryOptions: MySQLPoolRetryOptions(
    maxAttempts: 3,
    delay: Duration(milliseconds: 100),
    retryIf: (error) => error is SocketException,
  ),
  allowPublicKeyRetrieval: true, // optional: for caching_sha2_password without TLS
  // serverPublicKey: '''-----BEGIN PUBLIC KEY-----...''', // safer than retrieval on insecure links
);
```

Starting with version `1.2.1`, the pool exposes extra controls: it validates idle connections, recycles long-lived sessions, lets you apply custom `time_zone`/collation tweaks inside `onConnectionOpen`, and offers a basic **retry** policy (via `MySQLPoolRetryOptions`). For visibility, call `pool.status()` to inspect the active, idle, and pending connection counters.

#### Or single connection

```dart
final conn = await MySQLConnection.createConnection(
  host: "127.0.0.1",
  port: 3306,
  userName: "your_user",
  password: "your_password",
  databaseName: "your_database_name", // optional
  // secure: false,
  // allowPublicKeyRetrieval: true,
  // serverPublicKey: '''-----BEGIN PUBLIC KEY-----...''',
);

// actually connect to database
await conn.connect();
```

**Warning**
By default connection is secure. If you don't want to use SSL (TLS) connection, pass *secure: false*

For MySQL 8.4+ / 9.x with `caching_sha2_password`, non-TLS connections usually need one of:
- `serverPublicKey`: pin the server RSA public key and encrypt the password safely.
- `allowPublicKeyRetrieval: true`: request the RSA public key from the server during auth.

`allowPublicKeyRetrieval` is a compatibility option. If security matters and you are not using TLS, prefer `serverPublicKey` pinning.

#### Query database

```dart
var result = await pool.execute("SELECT * FROM book WHERE id = :id", {"id": 1});
```

#### Passing parameters with `execute()`

`execute()` accepts three invocation styles and, when parameters are present, it transparently switches to the binary protocol (prepared statements under the hood) so that blobs/bytes are transmitted safely and subsequent calls can reuse the cached statement:

```dart
// 1) Literal query only (text protocol)
final rs = await conn.execute('SELECT NOW() AS ts');

// 2) Named parameters
await conn.execute(
  'INSERT INTO book (title, price) VALUES (:title, :price)',
  {'title': 'Dart Up', 'price': 42.5},
);

// 3) Positional parameters
await conn.execute(
  'UPDATE book SET cover = ? WHERE id = ?',
  [Uint8List.fromList(bytes), 10],
);
```

If you need to stream results row-by-row instead of buffering the whole result, pass `iterable: true` to `execute()` (or `prepare()`), and consume `rowsStream`.
For iterable result sets, the driver now propagates `pause` / `resume` from the consumer stream down to the socket subscription, so a slow consumer can apply real backpressure instead of only buffering rows in memory.

The automatic prepared-statement cache is per connection and defaults to 32 statements. If your workload has a larger hot set of parameterized SQL strings, tune it when creating a connection or pool:

```dart
final conn = await MySQLConnection.createConnection(
  host: 'localhost',
  port: 3306,
  userName: 'dart',
  password: 'dart',
  databaseName: 'app',
  autoPreparedStatementCacheCapacity: 128,
);
```

See [doc/AUTO_PREPARED_CACHE_BENCHMARK.md](doc/AUTO_PREPARED_CACHE_BENCHMARK.md) for the hot-set vs thrash-set benchmark and sizing guidance.

#### Print result
```dart
  for (final row in result.rows) {
    print(row.assoc());
  }
```

There are two groups of methods to access column data. 
First group returns result as strings.
Second one (methods starting with **typed** prefix) performs conversion to specified type.

F.e.:  
```dart
row.colAt(0); // returns first column as String
row.typedColAt<int>(0); // returns first column as int 
```

Look at [example/main_simple_conn.dart](example/main_simple_conn.dart) for other ways of getting column data, including typed data access.

> ⚠️ **Decimal / NewDecimal columns** – the driver deliberately returns `String` for these column types to preserve precision/scale. If you need native arithmetic inside Dart, either cast inside SQL (`CAST(col AS DOUBLE)`), parse manually, or rely on arbitrary-precision packages such as [`decimal`](https://pub.dev/packages/decimal). This behavior is covered in `test/mysql_client.dart` and `test/column_type_test.dart`.

### Prepared statements

This library supports real prepared statements (using binary protocol).

#### Prepare statement

```dart
var stmt = await conn.prepare(
  "INSERT INTO book (author_id, title, price, created_at) VALUES (?, ?, ?, ?)",
);
```

#### Execute with params

```dart
await stmt.execute([null, 'Some book 1', 120, '2022-01-01']);
await stmt.execute([null, 'Some book 2', 10, '2022-01-01']);
```

#### Deallocate prepared statement

```dart
await stmt.deallocate();
```

For connection pools, do not keep a prepared statement outside the lifetime of the borrowed connection. Use `pool.withPrepared(...)`:

```dart
await pool.withPrepared(
  'UPDATE book SET price = ? WHERE id = ?',
  (stmt) => stmt.execute([99, 1]),
);
```

### Transactions

To execute queries in transaction, you can use *transactional()* method on *connection* or *pool* object
Example:

```dart
await pool.transactional((conn) async {
  await conn.execute("UPDATE book SET price = :price", {"price": 300});
  await conn.execute("UPDATE book_author SET name = :name", {"name": "John Doe"});
});
```

In case of exception, transaction will roll back automatically.

### Iterating large result sets

In case you need to process large result sets, you can use iterable result set.
To use iterable result set, pass iterable = true, to execute() or prepare() methods.
In this case rows will be ready as soon as they are delivered from the network.
This allows you to process large amount of rows, one by one, in Stream fashion.

When using iterable result set, you need to use **result.rowsStream.listen** instead of **result.rows** to get access to rows.

`MySQLConnectionPool.execute(..., iterable: true)` is intentionally unsupported. A streamed result keeps its connection busy until EOF, so pooled streaming must be done through `pool.withConnection(...)` and fully consumed before the callback returns.

Example:

```dart
// make query (notice third parameter, iterable=true)
var result = await conn.execute("SELECT * FROM book", {}, true);

result.rowsStream.listen((row) {
  print(row.assoc());
});
```

### Multiple statements queries
This library supports multiple statements in query() method. 
If your query contains multiple statements, result will contain **next** property, which will point to the next result set.

IResulSet class implements Iterable<IResulSet> interface, so you can iterate throw all result sets using for..in loop.

**Multple statements are not supported for prepared statements and iterable result sets.**

For example:

```dart
final resultSets = await conn.execute(
  "SELECT 1 as val_1_1; SELECT 2 as val_2_1, 3 as val_2_2",
);

assert(resultSets.next != null);

for (final result in resultSets) {
  // for every result set
  for (final row in result.rows) {
    // for every row in result set
    print(row.assoc());
  }
}
```

### Tests

To run tests execute

```bash
dart test
```

### Error handling

This library throws tree types of exceptions: MySQLServerException, MySQLClientException and MySQLProtocolException.
See api reference for description of each type.

When exception is thrown, connection can be left in **connected** or **closed** state.

As a general rule, if cause of exception is MySQL server error packet, connection will be left in connected state and can be reused. If cause of exception is logical error, such as unexpected packet or something inside parsing of mysql protocol, connection will be closed and can not be used anymore.

It's up to developer to check connection state after catching exception.
Inside your catch block, you can check connection status using **conn.connected** getter and decide what to do next.
