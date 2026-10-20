## 3.0.1

- fix: on MySQL 8.0.22+ the auto-prepared statement of an SQL text was reused for parameters of any type, but MySQL derives a parameter's type when the statement is prepared (or reprepared after a DDL) and converts later values to it: `select ? as v` prepared for an int returned `0` for `'a'`, and an insert prepared while a column was temporal failed with error 3988 ("Conversion from collation utf8mb4_0900_ai_ci into latin1_swedish_ci impossible") once the column became `varchar`. The cache key now includes the parameter types, and `create`/`alter`/`drop`/`rename`/`truncate` on the connection close the cached statements (MariaDB was not affected)

- fix: an ERR packet that ends a result set after some rows (an error raised while a row is computed) was decoded as a row, which threw and closed the connection; it is now reported as `MySQLServerException` and the connection stays usable (text and prepared paths, iterable result sets included)
- fix: a parameter rejected on the client (unsupported type) left the connection "busy with another command" forever; parameters are validated and the packet encoded before the connection is marked busy
- fix: prepared-statement (binary) results ignored the UNSIGNED flag: `TINYINT UNSIGNED` 200 came back as -56, and `SMALLINT`/`INT`/`BIGINT UNSIGNED` above the signed range were negative; `BIGINT UNSIGNED` above 2^63 - 1 now becomes a `BigInt` (it threw a `FormatException` in `typedAssoc()`)
- fix: TEXT columns with a `_bin` collation (and MariaDB `JSON`) were returned as `Uint8List`: the server sets BINARY_FLAG for every `_bin` collation, so only the `binary` character set (63) now means bytes
- fix: a query timeout left the statement running and the connection busy until it finished; the statement is now interrupted with `KILL QUERY` (through a short-lived second connection) and the connection is ready when the timeout is reported
- fix: `:name` placeholders inside strings with `'` escapes, backtick identifiers and comments (`-- `, `#`, `/* */`) were treated as parameters
- fix: `transactional()` marked the transaction before `START TRANSACTION` succeeded and a failing `ROLLBACK` replaced the original error and left "Already in transaction" set; the state is now always cleared, the original error kept, and a connection whose rollback failed is closed
- fix: `close()` (and `MySQLConnectionPool.close()`) waited forever after the server closed the session (`KILL`, restart, network): it flushed the destroyed socket; it now just releases the connection
- feat: `Map`, `List` and `Set` parameters are sent as JSON text and `BigInt` as its decimal text (they were rejected)
- feat: concurrent callers of one `MySQLConnection` wait for their turn (FIFO) instead of failing with "connection is busy with another command" (`execute`, `prepare`, `PreparedStmt.execute`/`deallocate`; an iterable result set holds the turn until its last row arrives). `transactional()` holds the connection: commands and transactions from other callers wait until it commits or rolls back, while commands from its callback (concurrent ones included, recognized through a `Zone` value) run inside it; a second `transactional()` from the callback still fails with "Already in transaction". `createConnection(queueConcurrentCalls: false)` keeps the 3.0.0 fail-fast behavior. The pool is unchanged (one caller per connection)
- fix: cancelling an iterable result set's stream after it ended closed the connection when another command was already running on it
- fix: a multi-statement query whose first statement returns no rows (`INSERT ...; SELECT ...`) returned only that first result and left the others unread, so the next command got them as its reply (the OK packet's SERVER_MORE_RESULTS_EXISTS flag was ignored); every result is now chained through `next`
- fix: `CALL` through the text protocol returned only its final OK (its result sets were dropped), and through a prepared statement (`execute` with parameters, `prepare`) left that OK unread, so the next command got it as its reply; the result sets are now returned, chained through `next`, followed by the OK
- fix: an iterable result set of a multi-statement query or `CALL` left the following results unread for the next command; they are now read and discarded, and the stream ends after the last one
- fix: a command waiting for its reply (and the commands queued behind it) waited forever when the server closed the connection (`KILL`, restart, network) or the socket failed; it now fails with `MySQLClientException` ("Connection closed"), an iterable stream gets the error, and `close()` completes (it threw when the connection had been closed mid-command, or by the driver itself)
- fix: pausing an iterable result set's stream after its last rows were buffered (e.g. an `await for` whose body awaits) left the socket paused, so the next command on the connection waited forever; the socket is resumed when the command ends, and a pause after the end no longer pauses the next command
- fix: `prepare()` of a statement with no parameters and no result columns (DDL, `INSERT` without placeholders, ...) waited forever for packets the server does not send
- fix: `execute(sql, [...])` (auto-prepared) silently ignored extra positional parameters and sent a malformed packet for missing ones; a wrong count now throws `MySQLClientException`, as `PreparedStmt.execute` does
- fix: prepared-statement (binary) DATETIME/TIMESTAMP/TIME fractional seconds were not zero-padded: `03:04:05.005` came back as `03:04:05.5000` (half a second) and `.000001` as `.1`; years below 1000 were not padded either, so `typedAssoc()` threw a `FormatException`
- fix: payloads of 0xffffff bytes (16 MB) or more were not split when sent (the 3-byte length was truncated) nor joined when received (a row of exactly 0xffffff bytes threw a `RangeError`); they are now framed as several packets
- fix: nested `transactional()` calls on two connections deadlocked (the inner one hid the outer one's zone value), and work left running by a finished `transactional()` callback joined another caller's later transaction (and its rollback); the zone value is now per connection and per transaction
- perf: a packet arriving in many socket chunks (multi-megabyte rows, especially over TLS) is assembled once instead of re-merging every byte received so far on each chunk, which was quadratic (a 16 MB row over TLS took tens of seconds)
- test: `regression_protocol_test.dart` covers each fix against a real server
- test: `concurrency_test.dart` covers concurrent commands, prepared statements, iterable result sets and transactions on one connection
- test: `coverage_matrix_test.dart` runs every entry point (text, named/positional parameters, `prepare`, iterable, pool, `transactional`) against every statement kind and checks that the next command gets its own reply; `coverage_types_test.dart` round-trips every column type through both protocols (NULLs, limits, fractional seconds, utf8mb4, 16 MB packets); `coverage_recovery_test.dart` covers server errors, timeouts, paused and cancelled streams, killed connections with queued commands, the auto-prepared statement cache and the pool under load

## 3.0.0

- breaking: raised the minimum Dart SDK to `^3.6.0`, aligning the package with the AOT benchmark baseline and allowing future hot-path refactors to use modern Dart features
- perf: `COM_STMT_EXECUTE` can now encode directly into a complete MySQL packet with a precomputed buffer, avoiding the generic `MySQLPacket` + `ByteDataWriter` path for prepared-statement execution
- perf: `typedAssoc()` now avoids reparsing values that already arrived as typed Dart values, reducing overhead for PDO-style integrations such as Eloquent that materialize every row as a typed map
- fix: cleaned up Dart 3 analyzer diagnostics in connection/auth and exception code paths without changing public exception formatting
- fix: the connection pool now validates connections after operation errors and retires broken sockets instead of returning them to the idle queue, improving recovery after database restarts
- test: added protocol unit coverage for direct `COM_STMT_EXECUTE` packet encoding, null bitmaps, variable-length values, temporal values, and exception formatting
- test: added real database integration coverage for prepared-statement binary result decoding with JSON payloads and BLOB bytes
- test: added an opt-in destructive pool restart test controlled by `MYSQL_RESTART_COMMAND`, allowing local validation against a real MySQL/MariaDB service restart under load
- docs: expanded the performance roadmap with Dart SDK baseline planning and architectural ideas from `dpgsql`/Npgsql for pool, data source, telemetry, retries, and auto-prepare evolution

## 2.0.0

- feat: added compatibility with MySQL Community Server 9 and 9.7, including `caching_sha2_password` full authentication with TLS, pinned RSA public keys, or optional server public key retrieval
- feat: binary protocol now supports MySQL JSON columns (`column type 245`), decoding them as UTF-8 JSON strings instead of failing at the protocol layer
- feat: integration tests now read `MYSQL_*` environment variables so they can run against any local or CI port/configuration
- ci: GitHub Actions now runs the test suite against MySQL 9.7 in addition to the existing database coverage
- refactor: removed external runtime dependencies on `asn1lib`, `pointycastle`, `buffer`, `crypto`, and `tuple` by inlining the required PEM/RSA/OAEP, hashing, tuple, and byte-writer logic
- perf: removed artificial latency from `connect()` and `close()` by replacing handshake polling with `Completer` signaling and removing the fixed close delay
- perf: compiled AOT benchmark now reaches `0.532 ms` average connect latency, `11,255` text queries/s, `11,362` prepared queries/s, and `839,539` rows/s on 10,000-row result sets in the local MariaDB benchmark
- perf: local AOT benchmark beats PHP PDO on connect latency, `SELECT 1`, and 10,000-row result-set throughput, and beats PHP mysqli on connect latency and 10,000-row throughput while mysqli still leads tiny prepared statements through its native C extension
- perf: documented remaining performance headroom after 2.0.0, especially direct `COM_STMT_EXECUTE` encoding, per-result-set decode plans, lower row wrapper allocation, streaming memory behavior, and the final incremental packet reader/ring buffer
- perf: `connect()` now supports `setCharsetOnConnect: false`, allowing the initial charset/collation `SET` round-trip to be measured or skipped explicitly
- perf: packet header parsing, length-encoded integers, null-terminated strings, and packet splitting were rewritten to avoid hot-path temporary objects and repeated list concatenation
- perf: `COM_STMT_EXECUTE` now skips resending parameter type metadata when the parameter signature has not changed for the prepared statement
- perf: textual result-set row decoding now parses length-encoded cells inline, removing per-cell helper tuple allocation in the large result-set path
- perf: binary result-set row decoding now fast-paths common length-encoded column types, reducing per-cell helper dispatch and tuple allocation for `VARCHAR`, `TEXT`, `JSON`, `DECIMAL`, `BLOB`, `BIT`, and `GEOMETRY`
- perf: result-set metadata now caches case-insensitive column name lookups and precomputed Dart type hints, reducing repeated work in `colByName()`, `typedColByName()`, and `typedAssoc()`
- feat: iterable result sets now propagate stream `pause` / `resume` to the socket subscription, enabling real backpressure for row-by-row consumers
- feat: benchmark tooling now separates TLS vs non-TLS runs, measures connect latency with and without the initial charset `SET`, records `median`, `p95`, and `p99`, and compares materialized vs streaming result sets
- feat: added profiling and stress tools for result-set heap inspection (`vm_service`) and auto-prepared statement cache behavior under hot-set and thrash-set workloads
- feat: `MySQLConnection` now exposes auto-prepared statement cache statistics for hits, misses, evictions, deferred closes, and current cache occupancy
- feat: auto-prepared statement cache capacity is now configurable per connection and per pool with `autoPreparedStatementCacheCapacity`
- breaking: `MySQLConnectionPool.execute(..., iterable: true)` was removed because streamed results keep the physical connection busy until EOF and the old pooled flow could release the connection early
- breaking: `MySQLConnectionPool.prepare()` was removed and replaced by `withPrepared(...)`, because prepared statements are bound to one physical connection and the old API could return a statement whose owning connection had already been reused by unrelated work
- docs: README and roadmap now document the new pooling constraints, `withPrepared(...)`, iterable result-set backpressure, benchmark methodology, and the distinction between locally tested and CI-covered server versions

## 1.2.1

- fix: textual and binary result sets now decode strings with UTF-8 so accented characters appear correctly
- fix: connection pool returns connections to the idle queue even when `withConnection` callbacks throw, preventing resource leaks
- fix: connection pool enforces `maxConnections` even when multiple connections are being established concurrently
- feat: `MySQLConnectionPool` gained idle connection validation, recycling by age/usage, `timeZone`, `onConnectionOpen` callback, basic retry policy, and `status()` method for inspection.

## 1.2.0

- feat: `MySQLConnection.execute` now accepts positional lists and named maps directly; when parameters are present the driver auto-prepares, caches, and executes statements over the binary protocol so blobs/bytes are handled transparently
- fix: textual BLOB/TEXT columns are decoded as UTF‑8 strings consistently (even for auto-prepared/binary protocol queries), matching the associative API expectations
- docs: README now documents the new `execute()` usage patterns and clarifies that DECIMAL/NEWDECIMAL columns are surfaced as strings to avoid precision loss

## 1.0.0
- implemented "provide SSL certificates in createConnection"
```dart
 final SecurityContext context = SecurityContext(withTrustedRoots: true);
    final sslConn = await MySQLConnection.createConnection(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: true,
      securityContext: context, 
      onBadCertificate: (certificate) => true, 
    );
    await sslConn.connect();
```
- implemented blob support
```dart
 await connection.execute(
        "CREATE TABLE binary_test (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB)");
    final binaryData = Uint8List.fromList([0, 255, 127, 128]);
    final stmt =
        await connection.prepare("INSERT INTO binary_test (data) VALUES (?)");
    final res = await stmt.execute([binaryData]);
    expect(res.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
    final result = await connection.execute("SELECT data FROM binary_test");
    final row = result.rows.first;
    expect(row.typedColByName<Uint8List>("data"), equals(binaryData));
```
- implemented more tests and fix bugs

## 0.0.30

* feat: Binary prepared statements with enhanced integration and unit tests

## 0.0.30

* Rename mysql_client to mysql_dart

## 0.0.29

* Add Support empty password

## 0.0.28

## 0.0.28

* Add support for unix socket on pool connection

## 0.0.27

* Add timeoutMs param to pool constructor

## 0.0.26

* Change default charset to ut8mb4 (fix emojies)
* Add **timeoutMs** option to connect() method
* Increase default timeout from 5 seconds to 10 seconds

## 0.0.25

* Add support for unix socket connection. See example/main_unix_socket.dart

## 0.0.24

* Fix colByName and typedColByName: ignore column name case

## 0.0.23

* Fix caching_sha2_password auth plugin

## 0.0.22

* Check server supports SSL
* Add support for multiple statements

## 0.0.21

* Fix _lastError reset in _forceClose() and used after

## 0.0.20

* Refactor error handling
* Add section about error handling to README.md
* Fix connection pool bugs
* Fix mysql protocol string parsing (ascii instead of utf8)

## 0.0.19

* Expose mysql server error code in MySQLServerException

## 0.0.18

* Remove general Exception class. Add custom exception classes

## 0.0.17

* Fix string encoding in prepared statements

## 0.0.16

* Fix in transaction flag

## 0.0.15

* Fix capability flags parsing

## 0.0.14

* Fix prepared statement select with params (handle two EOF packets if numOfCols and numOfParams are both > 0)

## 0.0.13

* Fix decoding long strings

## 0.0.12

* Add info about typed access to readme and examples

## 0.0.11

* Implement typed access to column data
* Add tests

## 0.0.10

* Add more docs and examples

## 0.0.9

* Use utf8 charset by default
* Encode all data using utf8.encode() and utf8.decode()

## 0.0.8

* Improve error handling
* Add handling of incomplete packets in _spliPackets() method
* Fix parameters substitution
* Add mysql_client tests

## 0.0.7

* Add doc comments and example

## 0.0.6

* Implement iterable result sets

## 0.0.5

* Implement caching_sha2_password auth plugin
* Refactor data packets handling
* Split data packets
* Fix some bugs

## 0.0.4

* Implement SSL connection
* Fix bug with hardcoded host and port

## 0.0.3

* Implement prepared statements
* Add more tests

## 0.0.2

* Fix readme and docs

## 0.0.1

* Initial version.
