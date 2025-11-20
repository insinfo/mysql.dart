import 'dart:async';
import 'dart:io';
import 'package:mysql_dart/mysql_dart.dart';

class MySQLPoolRetryOptions {
  final int maxAttempts;
  final Duration delay;
  final bool Function(Object error)? retryIf;

  const MySQLPoolRetryOptions({
    this.maxAttempts = 1,
    this.delay = const Duration(milliseconds: 50),
    this.retryIf,
  });
}

class MySQLPoolStatus {
  final int activeConnections;
  final int idleConnections;
  final int pendingConnections;

  const MySQLPoolStatus({
    required this.activeConnections,
    required this.idleConnections,
    required this.pendingConnections,
  });

  int get totalConnections => activeConnections + idleConnections;
}

class _PooledConnection {
  final MySQLConnection connection;
  final DateTime openedAt = DateTime.now();
  DateTime lastUsed = DateTime.now();
  Duration totalUsage = Duration.zero;
  int errorCount = 0;
  DateTime? _borrowedAt;

  _PooledConnection(this.connection);

  Duration get age => DateTime.now().difference(openedAt);

  Duration get idleAge => DateTime.now().difference(lastUsed);

  void markBorrowed() {
    _borrowedAt = DateTime.now();
  }

  void markReleased() {
    if (_borrowedAt != null) {
      totalUsage += DateTime.now().difference(_borrowedAt!);
      lastUsed = DateTime.now();
      _borrowedAt = null;
    }
  }
}

/// Class to create and manage pool of database connections
class MySQLConnectionPool {
  final dynamic host;
  final int port;
  final String userName;
  final String _password;
  final int maxConnections;
  final String? databaseName;
  final bool secure;
  final SecurityContext? securityContext;
  final bool Function(X509Certificate certificate)? onBadCertificate;
  final String collation;
  final int timeoutMs;
  final Duration idleTestThreshold;
  final Duration maxConnectionAge;
  final Duration maxSessionUse;
  final int maxErrorCount;
  final String? timeZone;
  final FutureOr<void> Function(MySQLConnection conn)? onConnectionOpen;
  final MySQLPoolRetryOptions retryOptions;

  final List<_PooledConnection> _activeConnections = [];
  final List<_PooledConnection> _idleConnections = [];
  int _pendingConnections = 0;

  /// Creates new pool
  ///
  /// Almost all parameters are identical to [MySQLConnection.createConnection]
  /// Pass [maxConnections] to tell pool maximum number of connections it can use
  /// You can specify [timeoutMs], it will be passed to [MySQLConnection.connect] method when creating new connections
  MySQLConnectionPool({
    required this.host,
    required this.port,
    required this.userName,
    required password,
    required this.maxConnections,
    this.databaseName,
    this.secure = true,
    this.collation = 'utf8_general_ci',
    this.timeoutMs = 10000,
    this.securityContext,
    this.onBadCertificate,
    this.idleTestThreshold = const Duration(minutes: 1),
    this.maxConnectionAge = const Duration(hours: 12),
    this.maxSessionUse = const Duration(hours: 8),
    this.maxErrorCount = 64,
    this.timeZone,
    this.onConnectionOpen,
    this.retryOptions = const MySQLPoolRetryOptions(),
  }) : _password = password;

  /// Number of active connections in this pool
  /// Active are connections which are currently interacting with the database
  int get activeConnectionsQty => _activeConnections.length;

  /// Number of idle connections in this pool
  /// Idle are connections which are currently not interacting with the database and ready to be used
  int get idleConnectionsQty => _idleConnections.length;

  /// Active + Idle connections
  int get allConnectionsQty => activeConnectionsQty + idleConnectionsQty;

  MySQLPoolStatus status() => MySQLPoolStatus(
        activeConnections: activeConnectionsQty,
        idleConnections: idleConnectionsQty,
        pendingConnections: _pendingConnections,
      );

  Iterable<_PooledConnection> get _allConnections =>
      _idleConnections.followedBy(_activeConnections);

  /// See [MySQLConnection.execute]
  Future<IResultSet> execute(
    String query, [
    Map<String, dynamic>? params,
    bool iterable = false,
  ]) async {
    final pooled = await _getFreeConnection();
    try {
      final result = await pooled.connection.execute(query, params, iterable);
      await _releaseConnection(pooled);
      return result;
    } catch (e) {
      await _releaseConnection(pooled, hadError: true);
      rethrow;
    }
  }

  /// Closes all connections in this pool and frees resources
  Future<void> close() async {
    for (final pooled in _allConnections.toList()) {
      try {
        await pooled.connection.close();
      } catch (_) {}
    }
    _idleConnections.clear();
    _activeConnections.clear();
  }

  /// See [MySQLConnection.prepare]
  Future<PreparedStmt> prepare(String query, [bool iterable = false]) async {
    final pooled = await _getFreeConnection();
    try {
      final stmt = pooled.connection.prepare(query, iterable);
      await _releaseConnection(pooled);
      return stmt;
    } catch (e) {
      await _releaseConnection(pooled, hadError: true);
      rethrow;
    }
  }

  /// Get free connection from this pool (possibly new connection) and invoke callback function with this connection
  ///
  /// After callback completes, connection is returned into pool as idle connection
  /// This function returns callback result
  FutureOr<T> withConnection<T>(
      FutureOr<T> Function(MySQLConnection conn) callback) async {
    int attempt = 0;
    while (true) {
      attempt++;
      final pooled = await _getFreeConnection();
      try {
        final result = await callback(pooled.connection);
        await _releaseConnection(pooled);
        return result;
      } catch (e) {
        await _releaseConnection(pooled, hadError: true);
        if (!_shouldRetry(e, attempt)) {
          rethrow;
        }
        await Future.delayed(_retryDelay(attempt));
      }
    }
  }

  /// See [MySQLConnection.transactional]
  Future<T> transactional<T>(
      FutureOr<T> Function(MySQLConnection conn) callback) async {
    return withConnection((conn) {
      return conn.transactional(callback);
    });
  }

  Future<_PooledConnection> _getFreeConnection() async {
    while (true) {
      // if there is idle connection, return it
      if (_idleConnections.isNotEmpty) {
        final pooled = _idleConnections.removeAt(0);
        if (await _ensureConnectionHealthy(pooled)) {
          pooled.markBorrowed();
          _activeConnections.add(pooled);
          return pooled;
        }
        await _retireConnection(pooled);
        continue;
      }

      // we can still open another connection
      if (allConnectionsQty + _pendingConnections < maxConnections) {
        return _createAndTrackConnection();
      }

      // otherwise wait a bit for a connection to become idle
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<_PooledConnection> _createAndTrackConnection() async {
    _pendingConnections++;
    try {
      final conn = await MySQLConnection.createConnection(
        host: host,
        port: port,
        userName: userName,
        password: _password,
        databaseName: databaseName,
        secure: secure,
        collation: collation,
        securityContext: securityContext,
        onBadCertificate: onBadCertificate,
      );

      await conn.connect(timeoutMs: timeoutMs);
      if (timeZone != null) {
        await conn.execute('SET time_zone = :tz', {'tz': timeZone});
      }
      if (onConnectionOpen != null) {
        await onConnectionOpen!(conn);
      }

      final pooled = _PooledConnection(conn)..markBorrowed();
      _activeConnections.add(pooled);

      conn.onClose(() {
        _idleConnections.remove(pooled);
        _activeConnections.remove(pooled);
      });

      return pooled;
    } finally {
      _pendingConnections--;
    }
  }

  Future<void> _releaseConnection(_PooledConnection pooled,
      {bool hadError = false}) async {
    _activeConnections.remove(pooled);
    pooled.markReleased();

    if (hadError) {
      pooled.errorCount++;
    }

    if (_shouldRecycle(pooled)) {
      await _retireConnection(pooled);
      return;
    }

    _idleConnections.add(pooled);
  }

  bool _shouldRetry(Object error, int attempt) {
    if (retryOptions.maxAttempts <= attempt) {
      return false;
    }

    if (retryOptions.retryIf != null) {
      return retryOptions.retryIf!(error);
    }

    return error is SocketException || error is TimeoutException;
  }

  Duration _retryDelay(int attempt) {
    if (attempt <= 1) {
      return retryOptions.delay;
    }
    return retryOptions.delay * attempt;
  }

  bool _shouldRecycle(_PooledConnection pooled) {
    if (pooled.age >= maxConnectionAge) {
      return true;
    }
    if (pooled.totalUsage >= maxSessionUse) {
      return true;
    }
    if (pooled.errorCount >= maxErrorCount) {
      return true;
    }
    return false;
  }

  Future<bool> _ensureConnectionHealthy(_PooledConnection pooled) async {
    if (_shouldRecycle(pooled)) {
      return false;
    }

    if (pooled.idleAge >= idleTestThreshold) {
      try {
        await pooled.connection.execute('SELECT 1');
        pooled.lastUsed = DateTime.now();
      } catch (_) {
        return false;
      }
    }

    return true;
  }

  Future<void> _retireConnection(_PooledConnection pooled) async {
    _idleConnections.remove(pooled);
    _activeConnections.remove(pooled);
    try {
      await pooled.connection.close();
    } catch (_) {}
  }
}
