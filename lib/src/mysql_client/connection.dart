import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/src/mysql_protocol/column_utils.dart';
import 'caching_sha2_auth.dart';

enum _MySQLConnectionState {
  fresh,
  waitInitialHandshake,
  initialHandshakeResponseSend,
  connectionEstablished,
  waitingCommandResponse,
  quitCommandSend,
  closed
}

class AutoPreparedStatementCacheStats {
  final int hits;
  final int misses;
  final int evictions;
  final int cachedStatements;
  final int deferredCloses;
  final int capacity;

  const AutoPreparedStatementCacheStats({
    required this.hits,
    required this.misses,
    required this.evictions,
    required this.cachedStatements,
    required this.deferredCloses,
    required this.capacity,
  });
}

/// Main class to interact with MySQL database
///
/// Use [MySQLConnection.createConnection] to create connection
class MySQLConnection {
  Socket _socket;

  Socket getSocket() {
    return _socket;
  }

  bool _connected = false;
  StreamSubscription<Uint8List>? _socketSubscription;
  _MySQLConnectionState _state = _MySQLConnectionState.fresh;
  final String _username;
  final String _password;
  final String _collation;
  final String? _databaseName;
  Future<void> Function(Uint8List data)? _responseCallback;

  /// Fails the command waiting for its reply; set while it runs. Without it,
  /// a command (and the commands queued behind it) waited forever when the
  /// server closed the connection (KILL, restart, network).
  void Function(Object error, [StackTrace? stackTrace])? _abortCommand;

  /// Incremented for every command sent; see the iterable `onCancel`.
  int _commandSerial = 0;
  final List<void Function()> _onCloseCallbacks = [];

  /// Commands run one at a time, in call order: concurrent callers of one
  /// connection wait for their turn instead of failing with "connection is
  /// busy with another command". The turn ends when the server finished
  /// replying (for an iterable result set, when its last row arrived).
  Future<void> _commandTail = Future<void>.value();

  /// Completes when the running [transactional] commits or rolls back;
  /// `null` when there is none. Commands from outside the transaction wait
  /// for it, so they never run inside another caller's transaction.
  Completer<void>? _transactionGate;

  /// Zone value set while [transactional]'s callback runs: commands issued
  /// from it (and from anything it starts) belong to the transaction. The
  /// key is per connection (a transaction on another connection, nested in
  /// the callback, does not hide it) and the value is the transaction's gate
  /// (work the callback left running does not join a later transaction).
  final Object _transactionZoneKey = Object();

  /// See `queueConcurrentCalls` in [createConnection].
  final bool _queueConcurrentCalls;

  /// Server thread id of this connection (handshake), used by KILL QUERY.
  int _serverConnectionId = 0;
  final bool _secure;
  Uint8List? _pendingPacketBytes;

  /// Chunks received for the incomplete packet in [_pendingPacketBytes],
  /// and the size of that packet (0 while its header is incomplete).
  BytesBuilder? _pendingChunks;
  int _pendingPacketLength = 0;

  /// Parts read so far of a payload split over several packets.
  BytesBuilder? _largePacket;
  Object? _lastError;
  int _serverCapabilities = 0;
  String? _activeAuthPluginName;
  int _timeoutMs = 10000;
  final int _autoPreparedStmtCacheCapacity;
  final LinkedHashMap<String, PreparedStmt> _autoPreparedStmtCache =
      LinkedHashMap();
  final ListQueue<int> _deferredStmtCloseIds = ListQueue<int>();
  int _autoPreparedCacheHits = 0;
  int _autoPreparedCacheMisses = 0;
  int _autoPreparedCacheEvictions = 0;

  SecurityContext? _securityContext;
  bool Function(X509Certificate certificate)? _onBadCertificate;
  final bool _allowPublicKeyRetrieval;
  final String? _serverPublicKey;
  Uint8List? _authSeed;
  bool _awaitingServerPublicKey = false;
  Completer<void>? _readyCompleter;
  final List<Completer<void>> _connectionEstablishedWaiters = [];

  MySQLConnection._({
    required Socket socket,
    required String username,
    required String password,
    required String collation,
    bool secure = true,
    String? databaseName,
    bool allowPublicKeyRetrieval = false,
    String? serverPublicKey,
    int autoPreparedStatementCacheCapacity = 32,
    bool queueConcurrentCalls = true,
  })  : _socket = socket,
        _queueConcurrentCalls = queueConcurrentCalls,
        _username = username,
        _password = password,
        _databaseName = databaseName,
        _secure = secure,
        _collation = collation,
        _allowPublicKeyRetrieval = allowPublicKeyRetrieval,
        _serverPublicKey = serverPublicKey,
        _autoPreparedStmtCacheCapacity = autoPreparedStatementCacheCapacity;

  /// Creates connection with provided options.
  ///
  /// Keep in mind, **this is async** function. So you need to await result.
  /// Don't forget to call [MySQLConnection.connect] to actually connect to database, or you will get errors.
  /// See examples directory for code samples.
  ///
  /// [host] host to connect to. Can be String or InternetAddress.
  /// [userName] database user name.
  /// [password] user password.
  /// [secure] If true - TLS will be used, if false - ordinary TCL connection.
  /// [databaseName] Optional database name to connect to.
  /// [collation] Optional collaction to use.
  ///
  /// By default after connection is established, this library executes query to switch connection charset and collation:
  ///
  /// ```
  /// SET @@collation_connection=$_collation, @@character_set_client=utf8mb4, @@character_set_connection=utf8mb4, @@character_set_results=utf8mb4
  /// ```
  ///
  /// [queueConcurrentCalls] (default true): concurrent callers wait for
  /// their turn, and commands from outside a [transactional] callback wait
  /// for it to end. With false, a command issued while another one runs
  /// fails with "connection is busy with another command" and a second
  /// [transactional] with "Already in transaction" (the 3.0.0 behavior,
  /// useful to detect a connection shared by mistake).
  static Future<MySQLConnection> createConnection({
    required dynamic host,
    required int port,
    required String userName,
    required String password,
    bool secure = true,
    String? databaseName,
    String collation = 'utf8mb4_general_ci',
    SecurityContext? securityContext,
    bool Function(X509Certificate certificate)? onBadCertificate,
    bool allowPublicKeyRetrieval = false,
    String? serverPublicKey,
    int autoPreparedStatementCacheCapacity = 32,
    bool queueConcurrentCalls = true,
  }) async {
    if (autoPreparedStatementCacheCapacity < 1) {
      throw ArgumentError.value(
        autoPreparedStatementCacheCapacity,
        'autoPreparedStatementCacheCapacity',
        'must be at least 1',
      );
    }

    // Logger.level = loggingLevel;
    // logger.d("Establishing socket connection");
    final Socket socket = await Socket.connect(host, port);
    // logger.d("Socket connection established");
    if (socket.address.type != InternetAddressType.unix) {
      // no support for extensions on sockets
      socket.setOption(SocketOption.tcpNoDelay, true);
    }

    final client = MySQLConnection._(
      socket: socket,
      username: userName,
      password: password,
      databaseName: databaseName,
      secure: secure,
      collation: collation,
      allowPublicKeyRetrieval: allowPublicKeyRetrieval,
      serverPublicKey: serverPublicKey,
      autoPreparedStatementCacheCapacity: autoPreparedStatementCacheCapacity,
      queueConcurrentCalls: queueConcurrentCalls,
    );

    // Armazena os parâmetros de SSL no cliente (adicione esses campos na classe)
    client._securityContext = securityContext;
    client._onBadCertificate = onBadCertificate;

    return client;
  }

  /// Returns true if this connection can be used to interact with database
  bool get connected {
    return _connected;
  }

  AutoPreparedStatementCacheStats get autoPreparedStatementCacheStats =>
      AutoPreparedStatementCacheStats(
        hits: _autoPreparedCacheHits,
        misses: _autoPreparedCacheMisses,
        evictions: _autoPreparedCacheEvictions,
        cachedStatements: _autoPreparedStmtCache.length,
        deferredCloses: _deferredStmtCloseIds.length,
        capacity: _autoPreparedStmtCacheCapacity,
      );

  /// Registers callack to be executed when this connection is closed
  void onClose(void Function() callback) {
    _onCloseCallbacks.add(callback);
  }

  /// Initiate connection to database. To close connection, invoke [MySQLConnection.close] method.
  ///
  /// Default [timeoutMs] is 10000 milliseconds
  Future<void> connect({
    int timeoutMs = 10000,
    bool setCharsetOnConnect = true,
  }) async {
    if (_state != _MySQLConnectionState.fresh) {
      throw MySQLClientException("Can not connect: status is not fresh");
    }

    _timeoutMs = timeoutMs;
    _lastError = null;
    _state = _MySQLConnectionState.waitInitialHandshake;
    _readyCompleter = Completer<void>();
    _listenToSocket();

    await _readyCompleter!.future.timeout(
      Duration(milliseconds: timeoutMs),
    );
    _readyCompleter = null;

    // set connection charset
    if (setCharsetOnConnect) {
      await execute(
        'SET @@collation_connection=$_collation, @@character_set_client=utf8mb4, @@character_set_connection=utf8mb4, @@character_set_results=utf8mb4',
      );
    }
  }

  void _handleSocketClose() {
    _connected = false;
    _failConnectionEstablishedWaiters(
      MySQLClientException("Connection closed"),
    );
    _abortPendingCommand(
        _lastError ?? MySQLClientException("Connection closed"));
    _socket.destroy();

    for (var element in _onCloseCallbacks) {
      element();
    }
    _onCloseCallbacks.clear();
  }

  bool get _isTransportSecure {
    return _secure || _socket.address.type == InternetAddressType.unix;
  }

  Uint8List _buildCachingSha2Seed(Uint8List part1, Uint8List? part2) {
    final secondPart = part2 == null ? <int>[] : part2.sublist(0, 12);
    return Uint8List.fromList([...part1, ...secondPart]);
  }

  void _listenToSocket() {
    // A write to a connection the server already closed (wait_timeout, KILL)
    // fails with "Connection reset by peer", reported on the socket's done
    // future; unobserved, it was an uncaught error in the caller's zone
    // (seen on Linux, where the server resets the closed connection). The
    // read side reports the same failure through onError below, which fails
    // the command.
    unawaited(_socket.done.then<void>((_) {}, onError: (Object error) {
      _lastError ??= error;
    }));
    _socketSubscription = _socket.listen(
      (data) {
        for (final chunk in _splitPackets(data)) {
          unawaited(
            _processSocketData(chunk).catchError((Object error, StackTrace st) {
              _lastError = error;
              _failConnectionEstablishedWaiters(error, st);
            }),
          );
        }
      },
      onDone: _handleSocketClose,
      onError: (Object error, StackTrace st) {
        _lastError = error;
        _failConnectionEstablishedWaiters(error, st);
        _abortPendingCommand(error, st);
        if (_connected) {
          // The socket is unusable after an error.
          _forceClose();
        }
      },
    );
  }

  void _abortPendingCommand(Object error, [StackTrace? stackTrace]) {
    final abort = _abortCommand;
    _abortCommand = null;
    abort?.call(error, stackTrace);
  }

  /// Socket paused by an iterable result set's consumer (backpressure).
  bool _socketPausedForResultSet = false;

  /// Pauses the socket for a slow consumer of a streaming result set. It is
  /// resumed when the consumer resumes or, at the latest, when the command
  /// ends: a stream paused while its last rows were still buffered never
  /// called onResume, and the socket stayed paused, so the next command on
  /// the connection waited forever.
  void _pauseSocketForResultSet() {
    if (!_socketPausedForResultSet) {
      _socketPausedForResultSet = true;
      _socketSubscription?.pause();
    }
  }

  void _resumeSocketForResultSet() {
    if (_socketPausedForResultSet) {
      _socketPausedForResultSet = false;
      _socketSubscription?.resume();
    }
  }

  void _markConnectionEstablished() {
    _abortCommand = null;
    _resumeSocketForResultSet();
    _state = _MySQLConnectionState.connectionEstablished;
    _connected = true;

    final readyCompleter = _readyCompleter;
    if (readyCompleter != null && !readyCompleter.isCompleted) {
      readyCompleter.complete();
    }

    if (_connectionEstablishedWaiters.isEmpty) {
      return;
    }

    for (final waiter in _connectionEstablishedWaiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _connectionEstablishedWaiters.clear();
  }

  void _failConnectionEstablishedWaiters(
    Object error, [
    StackTrace? stackTrace,
  ]) {
    final readyCompleter = _readyCompleter;
    if (readyCompleter != null && !readyCompleter.isCompleted) {
      readyCompleter.completeError(error, stackTrace);
    }

    if (_connectionEstablishedWaiters.isEmpty) {
      return;
    }

    for (final waiter in _connectionEstablishedWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(error, stackTrace);
      }
    }
    _connectionEstablishedWaiters.clear();
  }

  Future<void> _handleCachingSha2AuthMoreData(MySQLPacket packet) async {
    final payload = packet.payload as MySQLPacketExtraAuthData;
    final pluginData = payload.pluginData;

    if (_awaitingServerPublicKey) {
      final publicKeyPem = utf8.decode(pluginData, allowMalformed: true);
      final encryptedPassword = buildCachingSha2EncryptedPassword(
        _password,
        _authSeed!,
        publicKeyPem,
      );

      final responsePacket = MySQLPacket(
        sequenceID: packet.sequenceID + 1,
        payload: MySQLPacketExtraAuthDataResponse(
          data: encryptedPassword,
          appendNullTerminator: false,
        ),
        payloadLength: 0,
      );

      _awaitingServerPublicKey = false;
      _socket.add(responsePacket.encode());
      return;
    }

    if (pluginData.isEmpty) {
      throw MySQLClientException("Received empty extra auth data payload");
    }

    final status = pluginData[0];

    if (status == 3) {
      return;
    }

    if (status != 4) {
      throw MySQLClientException("Unsupported extra auth data status: $status");
    }

    if (_isTransportSecure) {
      final responsePacket = MySQLPacket(
        sequenceID: packet.sequenceID + 1,
        payload: MySQLPacketExtraAuthDataResponse(
          data: buildCachingSha2CleartextPassword(_password),
        ),
        payloadLength: 0,
      );

      _socket.add(responsePacket.encode());
      return;
    }

    if (_serverPublicKey != null) {
      final encryptedPassword = buildCachingSha2EncryptedPassword(
        _password,
        _authSeed!,
        _serverPublicKey,
      );

      final responsePacket = MySQLPacket(
        sequenceID: packet.sequenceID + 1,
        payload: MySQLPacketExtraAuthDataResponse(
          data: encryptedPassword,
          appendNullTerminator: false,
        ),
        payloadLength: 0,
      );

      _socket.add(responsePacket.encode());
      return;
    }

    if (_allowPublicKeyRetrieval) {
      final responsePacket = MySQLPacket(
        sequenceID: packet.sequenceID + 1,
        payload: MySQLPacketExtraAuthDataResponse(
          data: buildCachingSha2PublicKeyRequest(),
          appendNullTerminator: false,
        ),
        payloadLength: 0,
      );

      _awaitingServerPublicKey = true;
      _socket.add(responsePacket.encode());
      return;
    }

    throw MySQLClientException(
      "Auth plugin caching_sha2_password requires TLS, a pinned serverPublicKey, or allowPublicKeyRetrieval: true",
    );
  }

  Future<void> _processSocketData(Uint8List data) async {
    // logger.d("Processing socket data. Current state is $_state");
    // logger.v(data);
    if (_state == _MySQLConnectionState.closed) {
      // don't process any data if state is closed
      return;
    }

    if (_state == _MySQLConnectionState.waitInitialHandshake) {
      await _processInitialHandshake(data);
      return;
    }

    if (_state == _MySQLConnectionState.initialHandshakeResponseSend) {
      // check for auth switch request
      try {
        final authSwitchPacket =
            MySQLPacket.decodeAuthSwitchRequestPacket(data);

        final payload =
            authSwitchPacket.payload as MySQLPacketAuthSwitchRequest;
        // logger.d("Processing AuthSwitchRequestPacket");
        _activeAuthPluginName = payload.authPluginName;
        _authSeed = payload.authPluginData.length >= 20
            ? Uint8List.sublistView(payload.authPluginData, 0, 20)
            : Uint8List.fromList(payload.authPluginData);

        switch (payload.authPluginName) {
          case 'mysql_native_password':
            final responsePayload =
                MySQLPacketAuthSwitchResponse.createWithNativePassword(
              password: _password,
              challenge: payload.authPluginData.sublist(0, 20),
            );
            final responsePacket = MySQLPacket(
              sequenceID: authSwitchPacket.sequenceID + 1,
              payload: responsePayload,
              payloadLength: 0,
            );

            _socket.add(responsePacket.encode());
            return;
          case 'caching_sha2_password':
            final responsePayload =
                MySQLPacketAuthSwitchResponse.createWithCachingSha2Password(
              password: _password,
              challenge: payload.authPluginData.sublist(0, 20),
            );
            final responsePacket = MySQLPacket(
              sequenceID: authSwitchPacket.sequenceID + 1,
              payload: responsePayload,
              payloadLength: 0,
            );

            _socket.add(responsePacket.encode());
            return;
          default:
            throw MySQLClientException(
                "Unsupported auth plugin name: ${payload.authPluginName}");
        }
      } catch (e) {
        // not auth switch request packet, continue packet processing
      }

      MySQLPacket packet;

      try {
        packet = MySQLPacket.decodeGenericPacket(data);
      } catch (e) {
        // logger.e("Skipping invalid packet: $data");
        rethrow;
      }

      if (packet.payload is MySQLPacketExtraAuthData) {
        assert(_activeAuthPluginName != null);

        if (_activeAuthPluginName != 'caching_sha2_password') {
          throw MySQLClientException(
              "Unexpected auth plugin name $_activeAuthPluginName, while receiving MySQLPacketExtraAuthData packet");
        }

        await _handleCachingSha2AuthMoreData(packet);
        return;
      }

      if (packet.isErrorPacket()) {
        final errorPayload = packet.payload as MySQLPacketError;
        throw MySQLServerException(
            errorPayload.errorMessage, errorPayload.errorCode);
      }

      if (packet.isOkPacket()) {
        // logger.i("Got OK packet. Connection established");
        _markConnectionEstablished();
      }

      return;
    }

    if (_state == _MySQLConnectionState.waitingCommandResponse) {
      _processCommandResponse(data);
      return;
    }

    throw MySQLClientException(
      "Skipping socket data, because of connection bad state\nState: ${_state.name}\nData: $data",
    );
  }

  Iterable<Uint8List> _splitPackets(Uint8List data) sync* {
    var buffer = data;
    final pending = _pendingPacketBytes;

    if (pending != null && pending.isNotEmpty) {
      // Chunks are collected until the packet is complete: merging all the
      // bytes received so far on every chunk was quadratic for packets of
      // several megabytes (over TLS, a 16 MB row took tens of seconds).
      final chunks =
          _pendingChunks ??= (BytesBuilder(copy: false)..add(pending));
      chunks.add(data);
      if (chunks.length < _pendingPacketLength) {
        return;
      }
      buffer = chunks.takeBytes();
      _pendingChunks = null;
      _pendingPacketBytes = null;
    }

    var offset = 0;

    while (buffer.length - offset >= 4) {
      final packetLength = MySQLPacket.getPacketLength(buffer, offset);

      if (buffer.length - offset < packetLength) {
        break;
      }

      final packet =
          Uint8List.sublistView(buffer, offset, offset + packetLength);
      offset += packetLength;

      // A payload of 0xffffff bytes or more arrives split: packets of
      // 0xffffff bytes, then a shorter (possibly empty) one. They are joined
      // under the first header; the empty last packet used to throw a
      // RangeError and the parts were decoded as separate packets.
      final large = _largePacket;
      final isPart = packetLength - 4 == mysqlMaxPacketPayloadLength;
      if (isPart || large != null) {
        final builder = large ?? (BytesBuilder()..add(packet));
        if (large != null) {
          builder.add(Uint8List.sublistView(packet, 4));
        }
        if (isPart) {
          _largePacket = builder;
          continue;
        }
        _largePacket = null;
        yield builder.takeBytes();
        continue;
      }

      yield packet;
    }

    if (offset < buffer.length) {
      final remaining = buffer.length - offset;
      final pendingCopy = Uint8List(remaining);
      pendingCopy.setRange(0, remaining, buffer, offset);
      _pendingPacketBytes = pendingCopy;
      _pendingPacketLength =
          remaining >= 4 ? MySQLPacket.getPacketLength(pendingCopy) : 0;
    }
  }

  Future<void> _processInitialHandshake(Uint8List data) async {
    // logger.d("Processing initial handshake");
    // First packet can be error packet
    if (MySQLPacket.detectPacketType(data) == MySQLGenericPacketType.error) {
      final packet = MySQLPacket.decodeGenericPacket(data);
      final payload = packet.payload as MySQLPacketError;
      throw MySQLServerException(payload.errorMessage, payload.errorCode);
    }

    final packet = MySQLPacket.decodeInitialHandshake(data);
    final payload = packet.payload;

    if (payload is! MySQLPacketInitialHandshake) {
      throw MySQLClientException("Expected MySQLPacketInitialHandshake packet");
    }
    // logger.d(payload);
    _serverCapabilities = payload.capabilityFlags;
    _serverConnectionId = payload.connectionID;
    _authSeed = _buildCachingSha2Seed(
      payload.authPluginDataPart1,
      payload.authPluginDataPart2,
    );

    if (_secure && (_serverCapabilities & mysqlCapFlagClientSsl == 0)) {
      throw MySQLClientException(
        "Server does not support SSL connection. Pass secure: false to createConnection or enable SSL support",
      );
    }

    if (_secure) {
      // it secure = true, initiate ssl connection
      Future<void> initiateSSL() async {
        // logger.d("Initiating SSL connection");
        final responsePayload = MySQLPacketSSLRequest.createDefault(
          initialHandshakePayload: payload,
          connectWithDB: _databaseName != null,
        );

        final responsePacket = MySQLPacket(
          sequenceID: 1,
          payload: responsePayload,
          payloadLength: 0,
        );

        _socket.add(responsePacket.encode());

        _socketSubscription?.pause();

        final secureSocket = await SecureSocket.secure(
          _socket,
          context: _securityContext, // novo parâmetro
          onBadCertificate: _onBadCertificate ?? ((cert) => true),
        );

        // logger.d("SSL connection established");
        // switch socket
        _socket = secureSocket;
        _listenToSocket();
      }

      await initiateSSL();
    }

    final authPluginName = payload.authPluginName;
    // logger.d("Auth plugin name is: ${payload.authPluginName}");
    _activeAuthPluginName = authPluginName;
    // logger.d("Auth plugin name is: $authPluginName");
    switch (authPluginName) {
      case 'mysql_native_password':
        final responsePayload =
            MySQLPacketHandshakeResponse41.createWithNativePassword(
          username: _username,
          password: _password,
          initialHandshakePayload: payload,
        );

        responsePayload.database = _databaseName;

        final responsePacket = MySQLPacket(
          payload: responsePayload,
          sequenceID: _secure ? 2 : 1,
          payloadLength: 0,
        );

        _state = _MySQLConnectionState.initialHandshakeResponseSend;
        _socket.add(responsePacket.encode());
        // logger.d("Native password response send");
        break;
      case 'caching_sha2_password':
        final responsePayload =
            MySQLPacketHandshakeResponse41.createWithCachingSha2Password(
          username: _username,
          password: _password,
          initialHandshakePayload: payload,
        );

        responsePayload.database = _databaseName;

        final responsePacket = MySQLPacket(
          payload: responsePayload,
          sequenceID: _secure ? 2 : 1,
          payloadLength: 0,
        );

        _state = _MySQLConnectionState.initialHandshakeResponseSend;
        _socket.add(responsePacket.encode());
        // logger.d("Caching sha2 password response send");
        break;
      default:
        throw MySQLClientException(
            "Unsupported auth plugin name: $authPluginName");
    }
  }

  void _processCommandResponse(Uint8List data) {
    // logger.d("Processing command response packet");
    assert(_responseCallback != null);
    _responseCallback!(data);
  }

  /// Executes a SQL [query].
  ///
  /// This convenience method understands three invocation styles:
  ///
  /// ```dart
  /// // 1) Literals only (protocol text):
  /// final rs = await conn.execute('SELECT NOW() AS ts');
  ///
  /// // 2) Named parameters:
  /// await conn.execute(
  ///   'INSERT INTO book (title, price) VALUES (:title, :price)',
  ///   {'title': 'Dart Up', 'price': 42.5},
  /// );
  ///
  /// // 3) Positional parameters:
  /// await conn.execute(
  ///   'UPDATE book SET cover = ? WHERE id = ?',
  ///   [Uint8List.fromList(bytes), 10],
  /// );
  /// ```
  ///
  /// When [params] is a `Map<String, Object?>` or `List`, the driver transparently
  /// prepares and caches the statement so that binary values (BLOB/VARBINARY)
  /// travel via the MySQL binary protocol without manual `prepare()` calls.
  ///
  /// Set [iterable] to true to stream rows instead of buffering them all.
  Future<IResultSet> execute(
    String query, [
    Object? params,
    bool iterable = false,
    Duration? queryTimeout,
  ]) =>
      _serialized(() => _execute(query, params, iterable, queryTimeout));

  Future<IResultSet> _execute(
    String query,
    Object? params,
    bool iterable,
    Duration? queryTimeout,
  ) async {
    if (!_connected) {
      throw MySQLClientException("Can not execute query: connection closed");
    }

    if (_state == _MySQLConnectionState.waitingCommandResponse) {
      throw MySQLClientException(
        "Can not execute query: connection is busy with another command",
      );
    }

    final plan = _buildExecutePlan(query, params);

    if (plan.usePrepared) {
      final stmt = await _getOrCreateAutoPreparedStmt(
          plan.query, iterable, plan.positionalParams);
      // As in PreparedStmt.execute: extra parameters were silently ignored,
      // missing ones sent a malformed packet.
      if (stmt.numOfParams != plan.positionalParams.length) {
        throw MySQLClientException(
          "Can not execute query: number of passed params != number of prepared params",
        );
      }
      final futureResult =
          _executePreparedStmt(stmt, plan.positionalParams, iterable);
      return _applyQueryTimeout(futureResult, queryTimeout);
    }

    query = plan.query;

    if (_autoPreparedStmtCache.isNotEmpty && _schemaChange.hasMatch(query)) {
      _invalidateAutoPreparedStmts();
    }

    // wait for ready state
    if (_state != _MySQLConnectionState.connectionEstablished) {
      await _waitForState(_MySQLConnectionState.connectionEstablished)
          .timeout(Duration(milliseconds: _timeoutMs));
    }

    final payload = MySQLPacketCommQuery(query: query);

    final packet = MySQLPacket(
      sequenceID: 0,
      payload: payload,
      payloadLength: 0,
    );
    // Encoded before the connection is marked busy: a failure here must not
    // leave it "busy with another command" forever.
    final encodedPacket = packet.encode();

    _state = _MySQLConnectionState.waitingCommandResponse;

    final completer = Completer<IResultSet>();

    /**
     * 0 - initial
     * 1 - columnCount decoded
     * 2 - columnDefs parsed
     * 3 - eofParsed
     * 4 - rowsParsed
     */
    int state = 0;
    int colsCount = 0;
    List<MySQLColumnDefinitionPacket> colDefs = [];
    List<bool>? binaryColumns;
    List<MySQLResultSetRowPacket> resultSetRows = [];

    // support for iterable result set
    IterableResultSet? iterableResultSet;
    StreamSink<ResultSetRow>? sink;

    // used as a pointer to handle multiple result sets
    IResultSet? currentResultSet;
    IResultSet? firstResultSet;

    // An iterable result streams the first result only: the results after
    // it (multi-statement queries, CALL) are read and discarded. They used
    // to be left unread, and the next command got them as its reply.
    var discardResults = false;
    var streamClosed = false;

    void addResult(IResultSet resultSet) {
      if (currentResultSet != null) {
        currentResultSet!.next = resultSet;
      } else {
        firstResultSet = resultSet;
      }
      currentResultSet = resultSet;
    }

    void closeStream() {
      if (sink != null && !streamClosed) {
        streamClosed = true;
        unawaited(sink!.close());
      }
    }

    void fail(Object error, [StackTrace? stackTrace]) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      } else if (sink != null && !streamClosed) {
        sink!.addError(error, stackTrace);
        closeStream();
      }
    }

    final command = ++_commandSerial;
    _abortCommand = fail;
    _responseCallback = (data) async {
      try {
        MySQLPacket? packet;

        switch (state) {
          case 0:
            // if packet is OK packet, there is no data
            if (MySQLPacket.detectPacketType(data) ==
                MySQLGenericPacketType.ok) {
              final okPacket = MySQLPacket.decodeGenericPacket(data);
              final ok = okPacket.payload as MySQLPacketOK;
              if (!discardResults) {
                if (iterable) {
                  completer.complete(EmptyResultSet(okPacket: ok));
                  discardResults = true;
                } else {
                  addResult(EmptyResultSet(okPacket: ok));
                }
              }
              if (ok.statusFlags & mysqlServerFlagMoreResultsExists != 0) {
                // Another result follows (`INSERT ...; SELECT ...`, CALL).
                return;
              }
              _markConnectionEstablished();
              if (iterable) {
                closeStream();
              } else {
                completer.complete(firstResultSet);
              }

              return;
            }

            packet = MySQLPacket.decodeColumnCountPacket(data);
            break;
          case 1:
            packet = MySQLPacket.decodeColumnDefPacket(data);
            break;
          case 2:
            packet = MySQLPacket.decodeGenericPacket(data);
            if (packet.isEOFPacket()) {
              state = 3;
            }
            break;
          case 3:
            // An ERR packet can end a result set after some rows (e.g. an
            // error raised while a row is computed). It used to be decoded as
            // a row, which threw and closed the connection.
            if (MySQLPacket.detectPacketType(data) ==
                MySQLGenericPacketType.error) {
              final errorPacket = MySQLPacket.decodeGenericPacket(data);
              final error = errorPacket.payload as MySQLPacketError;
              final exception =
                  MySQLServerException(error.errorMessage, error.errorCode);
              _markConnectionEstablished();
              fail(exception);
              return;
            }
            if (iterable) {
              if (!discardResults && iterableResultSet == null) {
                iterableResultSet = IterableResultSet._(
                  columns: colDefs,
                  // Backpressure while this result set streams; see
                  // _pauseSocketForResultSet.
                  onPause: () {
                    if (command == _commandSerial &&
                        _state ==
                            _MySQLConnectionState.waitingCommandResponse) {
                      _pauseSocketForResultSet();
                    }
                  },
                  onResume: _resumeSocketForResultSet,
                  // Only while this result set is still streaming: once it
                  // ended, the connection may be running the next command
                  // (queued meanwhile), which must not be killed.
                  onCancel: () {
                    if (command == _commandSerial &&
                        _state ==
                            _MySQLConnectionState.waitingCommandResponse) {
                      _forceClose();
                    }
                  },
                );

                sink = iterableResultSet!._sink;
                completer.complete(iterableResultSet);
              }

              // check eof
              if (MySQLPacket.detectPacketType(data) ==
                  MySQLGenericPacketType.eof) {
                discardResults = true;
                final eofPayload = MySQLPacket.decodeGenericPacket(data).payload
                    as MySQLPacketEOF;
                if (eofPayload.statusFlags & mysqlServerFlagMoreResultsExists !=
                    0) {
                  state = 0;
                  colsCount = 0;
                  colDefs = [];
                  return;
                }
                state = 4;

                _markConnectionEstablished();
                closeStream();
                return;
              }

              if (discardResults) {
                return;
              }

              packet = MySQLPacket.decodeResultSetRowPacket(
                data,
                colDefs,
                binaryColumns: binaryColumns,
              );
              final values = (packet.payload as MySQLResultSetRowPacket).values;
              sink!.add(
                ResultSetRow._(
                  metadata: iterableResultSet!._metadata,
                  values: values,
                ),
              );
              packet = null;
              break;
            } else {
              // check eof
              if (MySQLPacket.detectPacketType(data) ==
                  MySQLGenericPacketType.eof) {
                final resultSetPacket = MySQLPacketResultSet(
                  columnCount: BigInt.from(colsCount),
                  columns: colDefs,
                  rows: resultSetRows,
                );

                final resultSet = ResultSet._(resultSetPacket: resultSetPacket);

                if (currentResultSet != null) {
                  currentResultSet!.next = resultSet;
                } else {
                  firstResultSet = resultSet;
                }
                currentResultSet = resultSet;

                final eofPacket = MySQLPacket.decodeGenericPacket(data);
                final eofPayload = eofPacket.payload as MySQLPacketEOF;

                if (eofPayload.statusFlags & mysqlServerFlagMoreResultsExists !=
                    0) {
                  state = 0;
                  colsCount = 0;
                  colDefs = [];
                  resultSetRows = [];
                  return;
                } else {
                  // there is no more results, just return
                  state = 4;
                  _markConnectionEstablished();
                  completer.complete(firstResultSet);
                  return;
                }
              }

              packet = MySQLPacket.decodeResultSetRowPacket(
                data,
                colDefs,
                binaryColumns: binaryColumns,
              );
              break;
            }
        }

        if (packet != null) {
          final payload = packet.payload;

          if (payload is MySQLPacketError) {
            // Also the error of a later statement of a multi-statement query.
            _markConnectionEstablished();
            fail(MySQLServerException(payload.errorMessage, payload.errorCode));
            return;
          } else if (payload is MySQLPacketOK || payload is MySQLPacketEOF) {
            // do nothing
          } else if (payload is MySQLPacketColumnCount) {
            state = 1;
            colsCount = payload.columnCount.toInt();
            return;
          } else if (payload is MySQLColumnDefinitionPacket) {
            colDefs.add(payload);

            if (colDefs.length == colsCount) {
              binaryColumns = List<bool>.generate(
                colDefs.length,
                (i) => columnShouldBeBinary(colDefs[i]),
                growable: false,
              );
              state = 2;
            }
          } else if (payload is MySQLResultSetRowPacket) {
            assert(iterable == false);
            resultSetRows.add(payload);
          } else {
            fail(
              MySQLClientException(
                "Unexpected payload received in response to COMM_QUERY request",
              ),
              StackTrace.current,
            );
            _forceClose();
            return;
          }
        }
      } catch (e) {
        //print('execute $e $s');
        fail(e, StackTrace.current);
        _forceClose();
      }
    };

    _socket.add(encodedPacket);

    return _applyQueryTimeout(completer.future, queryTimeout);
  }

  /// Execute [callback] inside database transaction
  ///
  /// If MySQLClientException is thrown inside [callback] function, transaction is rolled back
  ///
  /// The transaction holds the connection: commands (and other
  /// transactions) from other callers wait until it commits or rolls back,
  /// then run in call order. Commands issued from [callback], including
  /// concurrent ones, run inside the transaction. Do not wait, inside
  /// [callback], for work started outside it that uses this connection: that
  /// work waits for the transaction, which waits for it.
  ///
  /// A `START TRANSACTION` sent with [execute] gets no such protection:
  /// other callers' commands run inside it. Use [transactional].
  Future<T> transactional<T>(
      FutureOr<T> Function(MySQLConnection conn) callback) async {
    if (_inOwnTransaction ||
        (!_queueConcurrentCalls && _transactionGate != null)) {
      throw MySQLClientException("Already in transaction");
    }
    while (_transactionGate != null) {
      await _transactionGate!.future;
    }
    final gate = Completer<void>();
    _transactionGate = gate;
    try {
      return await runZoned(() => _runTransaction(callback),
          zoneValues: {_transactionZoneKey: gate});
    } finally {
      _transactionGate = null;
      gate.complete();
    }
  }

  bool get _inOwnTransaction =>
      _transactionGate != null &&
      identical(Zone.current[_transactionZoneKey], _transactionGate);

  /// Runs [command] in its turn (see [_commandTail]). Outside the running
  /// transaction, waits for it first.
  Future<T> _serialized<T>(Future<T> Function() command) async {
    if (!_queueConcurrentCalls) return command();
    // No await before the command is queued when there is no transaction:
    // the call order is the execution order.
    while (_transactionGate != null && !_inOwnTransaction) {
      await _transactionGate!.future;
    }
    final previous = _commandTail;
    final turn = Completer<void>();
    _commandTail = turn.future;
    try {
      await previous;
      return await command();
    } finally {
      _releaseTurnWhenIdle(turn);
    }
  }

  void _releaseTurnWhenIdle(Completer<void> turn) {
    if (_connected && _state == _MySQLConnectionState.waitingCommandResponse) {
      // An iterable result set is still streaming its rows.
      _waitForState(_MySQLConnectionState.connectionEstablished)
          .then((_) {}, onError: (_) {})
          .whenComplete(turn.complete);
    } else {
      turn.complete();
    }
  }

  Future<T> _runTransaction<T>(
      FutureOr<T> Function(MySQLConnection conn) callback) async {
    // A failing START or ROLLBACK leaves no transaction state behind.
    await execute("START TRANSACTION");

    try {
      final result = await callback(this);
      await execute("COMMIT");
      return result;
    } catch (e, stackTrace) {
      try {
        await execute("ROLLBACK");
      } catch (_) {
        // The transaction could not be rolled back (connection busy or
        // broken): close it, so the open transaction cannot leak into the
        // next user of this connection. The original error is kept.
        _forceClose();
      }
      Error.throwWithStackTrace(e, stackTrace);
    }
  }

  String _substitureParams(String query, Map<String, Object?> params) {
    final tokens = _findBindableNamedParams(query);

    if (tokens.isEmpty) {
      return query;
    }

    final buffer = StringBuffer();
    var lastIndex = 0;
    for (final token in tokens) {
      if (!params.containsKey(token.name)) {
        throw MySQLClientException(
            "There is no parameter with name: ${token.name}");
      }
      final value = params[token.name];
      final String sql;
      if (value == null) {
        sql = "NULL";
      } else if (value is String) {
        sql = "'${_escapeString(value)}'";
      } else if (value is num) {
        sql = value.toString();
      } else if (value is bool) {
        sql = value ? "TRUE" : "FALSE";
      } else {
        sql = "'${_escapeString(value.toString())}'";
      }
      buffer
        ..write(query.substring(lastIndex, token.start))
        ..write(sql);
      lastIndex = token.end;
    }
    buffer.write(query.substring(lastIndex));
    return buffer.toString();
  }

  /// `:name` placeholders outside string literals ('...', "..."),
  /// identifiers (`...`) and comments (-- , #, /* */). Counting quotes before
  /// the match broke on `\'` escapes and ignored comments and backticks.
  static List<_NamedParamToken> _findBindableNamedParams(String query) {
    final tokens = <_NamedParamToken>[];
    final length = query.length;
    bool isWord(int c) =>
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        c == 0x5f;
    var i = 0;
    while (i < length) {
      final c = query.codeUnitAt(i);
      if (c == 0x27 || c == 0x22 || c == 0x60) {
        // '...', "..." (backslash and doubled-quote escapes), `...`.
        i++;
        while (i < length) {
          final d = query.codeUnitAt(i);
          if (d == 0x5c && c != 0x60 && i + 1 < length) {
            i += 2;
            continue;
          }
          if (d == c) {
            if (i + 1 < length && query.codeUnitAt(i + 1) == c) {
              i += 2;
              continue;
            }
            break;
          }
          i++;
        }
        i++;
        continue;
      }
      final isDashComment = c == 0x2d &&
          i + 1 < length &&
          query.codeUnitAt(i + 1) == 0x2d &&
          (i + 2 >= length || query.codeUnitAt(i + 2) <= 0x20);
      if (c == 0x23 || isDashComment) {
        while (i < length && query.codeUnitAt(i) != 0x0a) {
          i++;
        }
        continue;
      }
      if (c == 0x2f && i + 1 < length && query.codeUnitAt(i + 1) == 0x2a) {
        final close = query.indexOf('*/', i + 2);
        i = close < 0 ? length : close + 2;
        continue;
      }
      if (c == 0x3a &&
          i + 1 < length &&
          isWord(query.codeUnitAt(i + 1)) &&
          (i == 0 || query.codeUnitAt(i - 1) != 0x3a)) {
        var end = i + 1;
        while (end < length && isWord(query.codeUnitAt(end))) {
          end++;
        }
        tokens.add(_NamedParamToken(i, end, query.substring(i + 1, end)));
        i = end;
        continue;
      }
      i++;
    }
    return tokens;
  }

  _ExecutePlan _buildExecutePlan(String query, Object? params) {
    if (params == null) {
      return _ExecutePlan.text(query);
    }

    if (params is Map) {
      final mapParams = params.cast<String, Object?>();

      if (mapParams.isEmpty) {
        return _ExecutePlan.text(query);
      }

      final conversion = _convertNamedParamsToPositional(query);

      if (conversion.paramNames.isEmpty) {
        final substitutedQuery = _substitureParams(query, mapParams);
        return _ExecutePlan.text(substitutedQuery);
      }

      final positional = conversion.paramNames.map<dynamic>((name) {
        if (!mapParams.containsKey(name)) {
          throw MySQLClientException("There is no parameter with name: $name");
        }

        return mapParams[name];
      }).toList();

      return _ExecutePlan.prepared(conversion.query, positional);
    }

    if (params is List) {
      if (params.isEmpty) {
        return _ExecutePlan.text(query);
      }

      return _ExecutePlan.prepared(
        query,
        List<dynamic>.from(params),
      );
    }

    throw MySQLClientException(
      "Unsupported params type: ${params.runtimeType}. Use Map<String, Object?> "
      "for named params or List for positional params.",
    );
  }

  _NamedParamConversionResult _convertNamedParamsToPositional(String query) {
    final matches = _findBindableNamedParams(query);

    if (matches.isEmpty) {
      return _NamedParamConversionResult(query, const <String>[]);
    }

    final buffer = StringBuffer();
    final names = <String>[];
    int lastIndex = 0;

    for (final match in matches) {
      buffer.write(query.substring(lastIndex, match.start));
      buffer.write('?');
      names.add(match.name);
      lastIndex = match.end;
    }

    buffer.write(query.substring(lastIndex));

    return _NamedParamConversionResult(buffer.toString(), names);
  }

  /// [params] are part of the key: MySQL 8.0.22+ derives the type of a
  /// parameter when the statement is prepared (or reprepared after a DDL)
  /// and converts later values to it. `select ? as v` prepared for an int
  /// returned 0 for 'a', and an insert prepared while a column was temporal
  /// rejected utf8mb4 text once the column became varchar (error 3988).
  Future<PreparedStmt> _getOrCreateAutoPreparedStmt(
    String query,
    bool iterable,
    List<dynamic> params,
  ) async {
    final key =
        '${_buildAutoPreparedCacheKey(query, iterable)}::${_paramTypesKey(params)}';
    final cached = _autoPreparedStmtCache.remove(key);

    if (cached != null) {
      _autoPreparedCacheHits++;
      _autoPreparedStmtCache[key] = cached;
      return cached;
    }

    _autoPreparedCacheMisses++;
    final stmt = await _prepare(query, iterable);
    _autoPreparedStmtCache[key] = stmt;

    if (_autoPreparedStmtCache.length > _autoPreparedStmtCacheCapacity) {
      final oldestKey = _autoPreparedStmtCache.keys.first;
      final oldestStmt = _autoPreparedStmtCache.remove(oldestKey);
      if (oldestStmt != null) {
        _autoPreparedCacheEvictions++;
        _deferPreparedStmtClose(oldestStmt._preparedPacket.stmtID);
      }
    }

    return stmt;
  }

  String _buildAutoPreparedCacheKey(String query, bool iterable) {
    return '${iterable ? 'iter' : 'plain'}::$query';
  }

  String _paramTypesKey(List<dynamic> params) {
    final key = StringBuffer();
    for (final param in params) {
      key
        ..write(_determineParamType(_normalizeParam(param))?.intVal ?? -1)
        ..write(',');
    }
    return key.toString();
  }

  /// A statement that changes the schema: the auto-prepared statements may
  /// refer to tables whose columns changed, and MySQL keeps the parameter
  /// types derived when they were prepared. They are closed and prepared
  /// again on their next use.
  static final _schemaChange = RegExp(
      r'^\s*(create|alter|drop|rename|truncate)\b',
      caseSensitive: false);

  void _invalidateAutoPreparedStmts() {
    for (final stmt in _autoPreparedStmtCache.values) {
      _deferPreparedStmtClose(stmt._preparedPacket.stmtID);
    }
    _autoPreparedStmtCache.clear();
  }

  void _deferPreparedStmtClose(int stmtId) {
    _deferredStmtCloseIds.addLast(stmtId);
  }

  Future<void> _flushDeferredStmtCloses() async {
    while (_deferredStmtCloseIds.isNotEmpty) {
      final stmtId = _deferredStmtCloseIds.removeFirst();
      final packet = MySQLPacket(
        sequenceID: 0,
        payload: MySQLPacketCommStmtClose(stmtID: stmtId),
        payloadLength: 0,
      );
      _socket.add(packet.encode());
    }
  }

  Future<IResultSet> _applyQueryTimeout(
    Future<IResultSet> future,
    Duration? queryTimeout,
  ) async {
    if (queryTimeout == null) {
      return future;
    }
    try {
      return await future.timeout(queryTimeout);
    } on TimeoutException {
      // The statement kept running on the server and the connection stayed
      // "busy" until it finished. Interrupt it and wait for its reply, so the
      // connection is ready for the next command when the error is thrown.
      await _killRunningQuery();
      try {
        await _waitForState(_MySQLConnectionState.connectionEstablished)
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        _forceClose();
      }
      throw MySQLClientException("Query timed out after $queryTimeout");
    }
  }

  /// `KILL QUERY <thread id>` through a short-lived second connection (the
  /// MySQL protocol has no in-band cancel). Errors are ignored.
  Future<void> _killRunningQuery() async {
    if (_serverConnectionId == 0) return;
    MySQLConnection? killer;
    try {
      killer = await MySQLConnection.createConnection(
        host: _socket.remoteAddress,
        port: _socket.remotePort,
        userName: _username,
        password: _password,
        secure: _secure,
        collation: _collation,
        securityContext: _securityContext,
        onBadCertificate: _onBadCertificate,
        allowPublicKeyRetrieval: _allowPublicKeyRetrieval,
        serverPublicKey: _serverPublicKey,
      );
      await killer.connect();
      await killer.execute('KILL QUERY $_serverConnectionId');
    } catch (_) {
      // Best effort: the caller still gets the timeout.
    } finally {
      try {
        await killer?.close();
      } catch (_) {}
    }
  }

  /// Prepares given [query]
  ///
  /// Returns [PreparedStmt] which can be used to execute prepared statement multiple times with different parameters
  /// See [PreparedStmt.execute]
  /// You shoud call [PreparedStmt.deallocate] when you don't need prepared statement anymore to prevent memory leaks
  ///
  /// Pass [iterable] true if you want to iterable result set. See [execute] for details
  Future<PreparedStmt> prepare(String query, [bool iterable = false]) =>
      _serialized(() => _prepare(query, iterable));

  Future<PreparedStmt> _prepare(String query, bool iterable) async {
    if (!_connected) {
      throw MySQLClientException("Can not prepare stmt: connection closed");
    }

    if (_state == _MySQLConnectionState.waitingCommandResponse) {
      throw MySQLClientException(
        "Can not prepare stmt: connection is busy with another command",
      );
    }

    // wait for ready state
    if (_state != _MySQLConnectionState.connectionEstablished) {
      await _waitForState(_MySQLConnectionState.connectionEstablished)
          .timeout(Duration(milliseconds: _timeoutMs));
    }

    await _flushDeferredStmtCloses();

    _state = _MySQLConnectionState.waitingCommandResponse;

    final payload = MySQLPacketCommStmtPrepare(query: query);

    final packet = MySQLPacket(
      sequenceID: 0,
      payload: payload,
      payloadLength: 0,
    );

    final completer = Completer<PreparedStmt>();

    /**
     * 0 - initial
     * 1 - first packet decoded
     * 2 - eof decoded
     */
    int state = 0;
    int numOfEofPacketsParsed = 0;
    MySQLPacketStmtPrepareOK? preparedPacket;

    ++_commandSerial;
    _abortCommand = (Object error, [StackTrace? stackTrace]) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    };
    _responseCallback = (data) async {
      try {
        MySQLPacket? packet;

        switch (state) {
          case 0:
            packet = MySQLPacket.decodeCommPrepareStmtResponsePacket(data);
            state = 1;
            break;
          default:
            packet = null;

            if (MySQLPacket.detectPacketType(data) ==
                MySQLGenericPacketType.eof) {
              numOfEofPacketsParsed++;

              var done = false;

              assert(preparedPacket != null);

              if (preparedPacket!.numOfCols > 0 &&
                  preparedPacket!.numOfParams > 0) {
                // there should be two EOF packets in this case
                if (numOfEofPacketsParsed == 2) {
                  done = true;
                }
              } else {
                // there should be only one EOF packet otherwise
                done = true;
              }

              if (done) {
                state = 2;

                completer.complete(PreparedStmt._(
                  preparedPacket: preparedPacket!,
                  connection: this,
                  iterable: iterable,
                ));

                _markConnectionEstablished();

                return;
              }
            }

            break;
        }

        if (packet != null) {
          final payload = packet.payload;

          if (payload is MySQLPacketStmtPrepareOK) {
            preparedPacket = payload;
            if (payload.numOfCols == 0 && payload.numOfParams == 0) {
              // No definitions and no EOF follow (DDL, INSERT without
              // placeholders, ...): prepare() used to wait forever for them.
              state = 2;
              _markConnectionEstablished();
              completer.complete(PreparedStmt._(
                preparedPacket: payload,
                connection: this,
                iterable: iterable,
              ));
              return;
            }
          } else if (payload is MySQLPacketError) {
            completer.completeError(
              MySQLServerException(payload.errorMessage, payload.errorCode),
            );
            _markConnectionEstablished();
            return;
          } else {
            completer.completeError(
              MySQLClientException(
                "Unexpected payload received in response to COMM_STMT_PREPARE request",
              ),
              StackTrace.current,
            );
            _forceClose();
            return;
          }
        }
      } catch (e) {
        completer.completeError(e, StackTrace.current);
        _forceClose();
      }
    };

    _socket.add(packet.encode());

    return completer.future;
  }

  Future<IResultSet> _executePreparedStmt(
    PreparedStmt stmt,
    List<dynamic> params,
    bool iterable,
  ) async {
    if (!_connected) {
      throw MySQLClientException(
          "Can not execute prepared stmt: connection closed");
    }

    if (_state == _MySQLConnectionState.waitingCommandResponse) {
      throw MySQLClientException(
        "Can not execute prepared stmt: connection is busy with another command",
      );
    }

    // wait for ready state
    if (_state != _MySQLConnectionState.connectionEstablished) {
      await _waitForState(_MySQLConnectionState.connectionEstablished)
          .timeout(Duration(milliseconds: _timeoutMs));
    }

    await _flushDeferredStmtCloses();

    // Everything that can fail on the client side happens before the
    // connection is marked busy (an unsupported parameter used to leave it
    // "busy with another command" forever).
    params = params.map(_normalizeParam).toList(growable: false);
    final paramTypeCodes = _determineParamTypeCodes(params);
    final sendTypes = stmt._shouldSendParamTypes(paramTypeCodes);
    final payload = MySQLPacketCommStmtExecute(
      stmtID: stmt._preparedPacket.stmtID,
      params: params,
      paramTypeCodes: paramTypeCodes,
      sendTypes: sendTypes,
    );
    final encodedPayload = payload.encodePacket(0);
    stmt._updateParamTypeCache(paramTypeCodes, sendTypes);

    _state = _MySQLConnectionState.waitingCommandResponse;

    final completer = Completer<IResultSet>();

    /**
     * 0 - initial
     * 1 - columnCount decoded
     * 2 - columnDefs parsed
     * 3 - eofParsed
     * 4 - rowsParsed
     */
    int state = 0;
    int colsCount = 0;
    List<MySQLColumnDefinitionPacket> colDefs = [];
    List<bool>? textualColumns;
    List<MySQLBinaryResultSetRowPacket> resultSetRows = [];

    // support for iterable result set
    IterablePreparedStmtResultSet? iterableResultSet;
    StreamSink<ResultSetRow>? sink;

    // A CALL replies with its result sets and a final OK. Non-iterable
    // results are chained through `next`; an iterable result streams the
    // first one and the others are read and discarded. They used to be left
    // unread, and the next command got them as its reply.
    IResultSet? currentResultSet;
    IResultSet? firstResultSet;
    var discardResults = false;
    var streamClosed = false;

    void addResult(IResultSet resultSet) {
      if (currentResultSet != null) {
        currentResultSet!.next = resultSet;
      } else {
        firstResultSet = resultSet;
      }
      currentResultSet = resultSet;
    }

    void closeStream() {
      if (sink != null && !streamClosed) {
        streamClosed = true;
        unawaited(sink!.close());
      }
    }

    void fail(Object error, [StackTrace? stackTrace]) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      } else if (sink != null && !streamClosed) {
        sink!.addError(error, stackTrace);
        closeStream();
      }
    }

    // Ends the command, or waits for the next result.
    void endResult(int statusFlags) {
      if (statusFlags & mysqlServerFlagMoreResultsExists != 0) {
        state = 0;
        colsCount = 0;
        colDefs = [];
        resultSetRows = [];
        return;
      }
      state = 4;
      _markConnectionEstablished();
      if (iterable) {
        closeStream();
      } else {
        completer.complete(firstResultSet);
      }
    }

    final command = ++_commandSerial;
    _abortCommand = fail;
    _responseCallback = (data) async {
      try {
        MySQLPacket? packet;

        switch (state) {
          case 0:
            // if packet is OK packet, there is no data
            if (MySQLPacket.detectPacketType(data) ==
                MySQLGenericPacketType.ok) {
              final okPacket = MySQLPacket.decodeGenericPacket(data);
              final ok = okPacket.payload as MySQLPacketOK;
              if (!discardResults) {
                if (iterable) {
                  completer.complete(EmptyResultSet(okPacket: ok));
                  discardResults = true;
                } else {
                  addResult(EmptyResultSet(okPacket: ok));
                }
              }
              endResult(ok.statusFlags);

              return;
            }

            packet = MySQLPacket.decodeColumnCountPacket(data);
            break;
          case 1:
            packet = MySQLPacket.decodeColumnDefPacket(data);
            break;
          case 2:
            packet = MySQLPacket.decodeGenericPacket(data);
            if (packet.isEOFPacket()) {
              state = 3;
            } else if (packet.isErrorPacket()) {
              final errorPayload = packet.payload as MySQLPacketError;
              _markConnectionEstablished();
              fail(
                MySQLServerException(
                    errorPayload.errorMessage, errorPayload.errorCode),
              );
              return;
            } else {
              fail(
                MySQLClientException("Unexcpected packet type"),
                StackTrace.current,
              );
              _forceClose();
              return;
            }
            break;
          case 3:
            // An ERR packet can end a result set after some rows (e.g. an
            // error raised while a row is computed). It used to be decoded as
            // a row, which threw and closed the connection.
            if (MySQLPacket.detectPacketType(data) ==
                MySQLGenericPacketType.error) {
              final errorPacket = MySQLPacket.decodeGenericPacket(data);
              final error = errorPacket.payload as MySQLPacketError;
              final exception =
                  MySQLServerException(error.errorMessage, error.errorCode);
              _markConnectionEstablished();
              fail(exception);
              return;
            }
            if (iterable) {
              if (!discardResults && iterableResultSet == null) {
                iterableResultSet = IterablePreparedStmtResultSet._(
                  columns: colDefs,
                  // Backpressure while this result set streams; see
                  // _pauseSocketForResultSet.
                  onPause: () {
                    if (command == _commandSerial &&
                        _state ==
                            _MySQLConnectionState.waitingCommandResponse) {
                      _pauseSocketForResultSet();
                    }
                  },
                  onResume: _resumeSocketForResultSet,
                  // Only while this result set is still streaming: once it
                  // ended, the connection may be running the next command
                  // (queued meanwhile), which must not be killed.
                  onCancel: () {
                    if (command == _commandSerial &&
                        _state ==
                            _MySQLConnectionState.waitingCommandResponse) {
                      _forceClose();
                    }
                  },
                );

                sink = iterableResultSet!._sink;
                completer.complete(iterableResultSet);
              }

              // check eof
              if (MySQLPacket.detectPacketType(data) ==
                  MySQLGenericPacketType.eof) {
                discardResults = true;
                final eofPayload = MySQLPacket.decodeGenericPacket(data).payload
                    as MySQLPacketEOF;
                endResult(eofPayload.statusFlags);
                return;
              }

              if (discardResults) {
                return;
              }

              packet = MySQLPacket.decodeBinaryResultSetRowPacket(
                data,
                colDefs,
                textualColumns: textualColumns,
              );
              final values =
                  (packet.payload as MySQLBinaryResultSetRowPacket).values;
              sink!.add(
                ResultSetRow._(
                  metadata: iterableResultSet!._metadata,
                  values: values,
                ),
              );

              packet = null;
              break;
            } else {
              // check eof
              if (MySQLPacket.detectPacketType(data) ==
                  MySQLGenericPacketType.eof) {
                final resultSetPacket = MySQLPacketBinaryResultSet(
                  columnCount: BigInt.from(colsCount),
                  columns: colDefs,
                  rows: resultSetRows,
                );
                addResult(
                    PreparedStmtResultSet._(resultSetPacket: resultSetPacket));

                final eofPayload = MySQLPacket.decodeGenericPacket(data).payload
                    as MySQLPacketEOF;
                endResult(eofPayload.statusFlags);

                return;
              }

              packet = MySQLPacket.decodeBinaryResultSetRowPacket(
                data,
                colDefs,
                textualColumns: textualColumns,
              );

              break;
            }
        }

        if (packet != null) {
          final payload = packet.payload;

          if (payload is MySQLPacketError) {
            _markConnectionEstablished();
            fail(MySQLServerException(payload.errorMessage, payload.errorCode));
            return;
          } else if (payload is MySQLPacketOK || payload is MySQLPacketEOF) {
            // do nothing
          } else if (payload is MySQLPacketColumnCount) {
            state = 1;
            colsCount = payload.columnCount.toInt();
            return;
          } else if (payload is MySQLColumnDefinitionPacket) {
            colDefs.add(payload);
            //  print(  '  _executePreparedStmt [Debug] -> Column definition: name=${payload.name}, type=${payload.type.intVal}');
            if (colDefs.length == colsCount) {
              textualColumns = List<bool>.generate(
                colDefs.length,
                (i) => columnShouldBeTextual(colDefs[i]),
                growable: false,
              );
              state = 2;
            }
          } else if (payload is MySQLBinaryResultSetRowPacket) {
            resultSetRows.add(payload);
          } else {
            fail(
              MySQLClientException(
                "Unexpected payload received in response to COMM_QUERY request",
              ),
              StackTrace.current,
            );
            _forceClose();
            return;
          }
        }
      } catch (e) {
        fail(e, StackTrace.current);
        _forceClose();
      }
    };

    _socket.add(encodedPayload);

    return completer.future;
  }

  /// Parameter values with no native MySQL binary type: maps, lists and sets
  /// become JSON text (for JSON columns), BigInt its decimal text.
  static Object? _normalizeParam(Object? value) {
    if (value is Uint8List) return value;
    if (value is Map || value is List) return jsonEncode(value);
    if (value is Set) return jsonEncode(value.toList());
    if (value is BigInt) return value.toString();
    return value;
  }

  // adicionei esta função para determinar os tipos
  /// Função para determinar o tipo MySQL correspondente a [param].
  MySQLColumnType? _determineParamType(dynamic param) {
    if (param == null) {
      return MySQLColumnType.nullType;
    } else if (param is int) {
      // Seleciona o tipo inteiro apropriado com base no valor.
      if (param >= -128 && param <= 127) {
        return MySQLColumnType.tinyType;
      } else if (param >= -32768 && param <= 32767) {
        return MySQLColumnType.shortType;
      } else if (param >= -2147483648 && param <= 2147483647) {
        return MySQLColumnType.longType;
      } else {
        return MySQLColumnType.longLongType;
      }
    } else if (param is double) {
      return MySQLColumnType.doubleType;
    } else if (param is String) {
      // Poderia haver lógica adicional para diferenciar entre varStringType e stringType

      return MySQLColumnType.varStringType;
    } else if (param is DateTime) {
      return MySQLColumnType.dateTimeType;
    } else if (param is bool) {
      // Valores booleanos geralmente são representados como TINYINT(1)

      return MySQLColumnType.tinyType;
    } else if (param is Uint8List) {
      // Escolhe o tipo BLOB com base no tamanho dos dados
      final len = param.length;
      if (len <= 255) {
        return MySQLColumnType.tinyBlobType;
      } else if (len <= 65535) {
        return MySQLColumnType.blobType;
      } else if (len <= 16777215) {
        return MySQLColumnType.mediumBlobType;
      } else {
        return MySQLColumnType.longBlobType;
      }
    } else {
      throw MySQLClientException(
        "Unsupported parameter type: ${param.runtimeType}",
      );
    }
  }

  Uint8List _determineParamTypeCodes(List<dynamic> params) {
    final codes = Uint8List(params.length);
    for (var i = 0; i < params.length; i++) {
      final type = _determineParamType(params[i]);
      codes[i] = type?.intVal ?? mysqlColumnTypeNull;
    }
    return codes;
  }

  Future<void> _deallocatePreparedStmt(PreparedStmt stmt) async {
    if (!_connected) {
      throw MySQLClientException("Can not execute query: connection closed");
    }

    if (_state == _MySQLConnectionState.waitingCommandResponse) {
      throw MySQLClientException(
        "Can not deallocate prepared stmt: connection is busy with another command",
      );
    }

    // wait for ready state
    if (_state != _MySQLConnectionState.connectionEstablished) {
      await _waitForState(_MySQLConnectionState.connectionEstablished)
          .timeout(Duration(milliseconds: _timeoutMs));
    }

    await _flushDeferredStmtCloses();

    final payload = MySQLPacketCommStmtClose(
      stmtID: stmt._preparedPacket.stmtID,
    );

    final packet = MySQLPacket(
      sequenceID: 0,
      payload: payload,
      payloadLength: 0,
    );

    _socket.add(packet.encode());
  }

  String _escapeString(String value) {
    value = value.replaceAll(r"\", r'\\');
    value = value.replaceAll(r"'", r"''");
    return value;
  }

  /// Close this connection gracefully
  ///
  /// This is an error to use this connection after connection has been closed
  Future<void> close() async {
    final packet = MySQLPacket(
      sequenceID: 0,
      payload: MySQLPacketCommQuit(),
      payloadLength: 0,
    );

    if (_state == _MySQLConnectionState.closed) {
      // Already closed by the driver (cancelled stream, broken connection).
      return;
    }

    if (!_connected &&
        (_state == _MySQLConnectionState.connectionEstablished ||
            _state == _MySQLConnectionState.waitingCommandResponse)) {
      // The server already closed the socket (KILL, restart, network). There
      // is nothing to send; flushing the destroyed socket never completed,
      // so close() used to hang (or threw, when it happened mid-command).
      _forceClose();
      return;
    }

    if (_state != _MySQLConnectionState.connectionEstablished) {
      throw MySQLClientException(
        "Can not close connection. Connection state is not in connectionEstablished state",
      );
    }

    _socket.add(packet.encode());
    _state = _MySQLConnectionState.quitCommandSend;

    await _closeSocketAndCallHandlers();
  }

  Future<void> _closeSocketAndCallHandlers() async {
    if (_socketSubscription != null) {
      await _socketSubscription!.cancel();
    }

    await _socket.flush();
    await _socket.close();
    _socket.destroy();

    _pendingPacketBytes = null;

    _connected = false;
    _state = _MySQLConnectionState.closed;

    for (var element in _onCloseCallbacks) {
      element();
    }

    _onCloseCallbacks.clear();
    _responseCallback = null;
    _pendingPacketBytes = null;
    _lastError = null;
    _autoPreparedStmtCache.clear();
    _deferredStmtCloseIds.clear();
  }

  void _forceClose() {
    if (_socketSubscription != null) {
      _socketSubscription!.cancel();
    }

    _socket.destroy();
    _pendingPacketBytes = null;

    _connected = false;
    _state = _MySQLConnectionState.closed;
    _failConnectionEstablishedWaiters(
      _lastError ?? MySQLClientException("Connection closed"),
    );
    _abortPendingCommand(
        _lastError ?? MySQLClientException("Connection closed"));

    for (var element in _onCloseCallbacks) {
      element();
    }

    _onCloseCallbacks.clear();
    _responseCallback = null;
    _pendingPacketBytes = null;
    _lastError = null;
    _autoPreparedStmtCache.clear();
    _deferredStmtCloseIds.clear();
  }

  Future<void> _waitForState(_MySQLConnectionState state) async {
    if (_state == state) {
      return;
    }
    if (state != _MySQLConnectionState.connectionEstablished) {
      throw MySQLClientException(
        "_waitForState only supports connectionEstablished",
      );
    }

    final completer = Completer<void>();
    _connectionEstablishedWaiters.add(completer);

    if (_state == state && !completer.isCompleted) {
      completer.complete();
    }

    await completer.future;
  }
}

/// Base class to represent result of calling [MySQLConnection.execute] and [PreparedStmt.execute]
abstract class IResultSet
    with IterableMixin<IResultSet>
    implements Iterator<IResultSet>, Iterable<IResultSet> {
  /// Number of colums in this result if any
  int get numOfColumns;

  /// Number of rows in this result if any (unavailable for iterable results)
  int get numOfRows;

  /// Number of affected rows
  BigInt get affectedRows;

  /// Last insert ID
  BigInt get lastInsertID;

  /// Next result set, if any.
  /// Prepared statements and iterable result sets does not supprot this
  IResultSet? next;

  IResultSet? _current;

  @override
  Iterator<IResultSet> get iterator => this;

  @override
  IResultSet get current {
    if (_current != null) {
      return _current!;
    } else {
      throw RangeError("Trying to access past the end value");
    }
  }

  @override
  bool moveNext() {
    if (_current == null) {
      _current = this;
      return true;
    } else {
      if (_current!.next != null) {
        _current = _current!.next;
        return true;
      } else {
        return false;
      }
    }
  }

  /// Provides access to data rows (unavailable for iterable results)
  Iterable<ResultSetRow> get rows;

  /// Use [cols] to get info about returned columns
  Iterable<ResultSetColumn> get cols;

  /// Provides Stream like access to data rows. Use [rowsStream] to get rows from iterable results
  Stream<ResultSetRow> get rowsStream => Stream.fromIterable(rows);
}

/// Represents result of [MySQLConnection.execute] method
class ResultSet extends IResultSet {
  final MySQLPacketResultSet _resultSetPacket;
  late final _ResultSetMetadata _metadata =
      _ResultSetMetadata(_resultSetPacket.columns);

  ResultSet._({
    required MySQLPacketResultSet resultSetPacket,
  }) : _resultSetPacket = resultSetPacket;

  @override
  int get numOfColumns => _resultSetPacket.columns.length;

  @override
  int get numOfRows => _resultSetPacket.rows.length;

  @override
  BigInt get affectedRows => BigInt.zero;

  @override
  BigInt get lastInsertID => BigInt.zero;

  @override
  Iterable<ResultSetRow> get rows sync* {
    for (final row in _resultSetPacket.rows) {
      yield ResultSetRow._(
        metadata: _metadata,
        values: row.values,
      );
    }
  }

  @override
  Iterable<ResultSetColumn> get cols => _metadata.resultSetColumns;
}

/// Represents result of [MySQLConnection.execute] method when passing iterable = true
class IterableResultSet with IterableMixin<IResultSet> implements IResultSet {
  final _ResultSetMetadata _metadata;
  late StreamController<ResultSetRow> _controller;

  IterableResultSet._({
    required List<MySQLColumnDefinitionPacket> columns,
    void Function()? onPause,
    void Function()? onResume,
    FutureOr<void> Function()? onCancel,
  }) : _metadata = _ResultSetMetadata(columns) {
    _controller = StreamController<ResultSetRow>(
      sync: true,
      onPause: onPause,
      onResume: onResume,
      onCancel: onCancel,
    );
  }

  @override
  IResultSet? get next => throw UnimplementedError();

  @override
  set next(val) => throw UnimplementedError();

  @override
  Iterator<IResultSet> get iterator => throw UnimplementedError();

  @override
  IResultSet? _current;

  @override
  IResultSet get current => throw UnimplementedError();

  @override
  bool moveNext() => throw UnimplementedError();

  StreamSink<ResultSetRow> get _sink => _controller.sink;

  @override
  Stream<ResultSetRow> get rowsStream => _controller.stream;

  @override
  int get numOfColumns => _metadata.columns.length;

  @override
  int get numOfRows => throw MySQLClientException(
        "numOfRows is not implemented for IterableResultSet",
      );

  @override
  BigInt get affectedRows => BigInt.zero;

  @override
  BigInt get lastInsertID => BigInt.zero;

  @override
  Iterable<ResultSetColumn> get cols => _metadata.resultSetColumns;

  @override
  Iterable<ResultSetRow> get rows => throw MySQLClientException(
        "Use rowsStream to get rows from IterableResultSet",
      );
}

/// Represents result of [PreparedStmt.execute] method
class PreparedStmtResultSet extends IResultSet {
  final MySQLPacketBinaryResultSet _resultSetPacket;
  late final _ResultSetMetadata _metadata =
      _ResultSetMetadata(_resultSetPacket.columns);

  PreparedStmtResultSet._({
    required MySQLPacketBinaryResultSet resultSetPacket,
  }) : _resultSetPacket = resultSetPacket;

  @override
  int get numOfColumns => _resultSetPacket.columns.length;

  @override
  int get numOfRows => _resultSetPacket.rows.length;

  @override
  BigInt get affectedRows => BigInt.zero;

  @override
  BigInt get lastInsertID => BigInt.zero;

  @override
  Iterable<ResultSetRow> get rows sync* {
    for (final row in _resultSetPacket.rows) {
      yield ResultSetRow._(
        metadata: _metadata,
        values: row.values,
      );
    }
  }

  @override
  Iterable<ResultSetColumn> get cols => _metadata.resultSetColumns;
}

/// Represents result of [PreparedStmt.execute] method when using iterable = true
class IterablePreparedStmtResultSet extends IResultSet {
  final _ResultSetMetadata _metadata;
  late StreamController<ResultSetRow> _controller;

  IterablePreparedStmtResultSet._({
    required List<MySQLColumnDefinitionPacket> columns,
    void Function()? onPause,
    void Function()? onResume,
    FutureOr<void> Function()? onCancel,
  }) : _metadata = _ResultSetMetadata(columns) {
    _controller = StreamController<ResultSetRow>(
      sync: true,
      onPause: onPause,
      onResume: onResume,
      onCancel: onCancel,
    );
  }

  StreamSink<ResultSetRow> get _sink => _controller.sink;

  @override
  int get numOfColumns => _metadata.columns.length;

  @override
  int get numOfRows => throw MySQLClientException(
        "numOfRows is not implemented for IterableResultSet",
      );

  @override
  BigInt get affectedRows => BigInt.zero;

  @override
  BigInt get lastInsertID => BigInt.zero;

  @override
  Iterable<ResultSetRow> get rows => throw MySQLClientException(
        "Use rowsStream to get rows from IterablePreparedStmtResultSet",
      );

  @override
  Stream<ResultSetRow> get rowsStream => _controller.stream;

  @override
  Iterable<ResultSetColumn> get cols => _metadata.resultSetColumns;
}

/// Represents empty result set
class EmptyResultSet extends IResultSet {
  final MySQLPacketOK _okPacket;

  EmptyResultSet({required MySQLPacketOK okPacket}) : _okPacket = okPacket;

  @override
  int get numOfColumns => 0;

  @override
  int get numOfRows => 0;

  @override
  BigInt get affectedRows => _okPacket.affectedRows;

  @override
  BigInt get lastInsertID => _okPacket.lastInsertID;

  @override
  Iterable<ResultSetRow> get rows => List<ResultSetRow>.empty();

  @override
  Iterable<ResultSetColumn> get cols => List<ResultSetColumn>.empty();
}

/// Represents result set row data
class ResultSetRow {
  final _ResultSetMetadata _metadata;
  // isaque alterei String? to dynamic
  final List<dynamic> _values;

  ResultSetRow._({
    required _ResultSetMetadata metadata,
    // isaque alterei String? to dynamic
    required List<dynamic> values,
  })  : _metadata = metadata,
        _values = values;

  /// Get number of columns for this row
  int get numOfColumns => _metadata.columns.length;

  /// Get column data by column index (starting form 0)
  dynamic colAt(int colIndex) {
    if (colIndex >= _values.length) {
      throw MySQLClientException("Column index is out of range");
    }

    final value = _values[colIndex];

    return value;
  }

  /// Same as [colAt] but performs conversion of string data, into provided type [T], if possible
  ///
  /// Conversion is "typesafe", meaning that actual MySQL column type will be checked,
  /// to decide is it possible to make such a conversion
  ///
  /// Throws [MySQLClientException] if conversion is not possible
  T? typedColAt<T>(int colIndex) {
    final value = colAt(colIndex);
    final colDef = _metadata.columns[colIndex];

    return colDef.type
        .convertStringValueToProvidedType<T>(value, colDef.columnLength);
  }

  /// Get column data by column name
  dynamic colByName(String columnName) {
    return colAt(_metadata.columnIndex(columnName));
  }

  /// Same as [colByName] but performs conversion of string data, into provided type [T], if possible
  ///
  /// Conversion is "typesafe", meaning that actual MySQL column type will be checked,
  /// to decide is it possible to make such a conversion
  ///
  /// Throws [MySQLClientException] if conversion is not possible
  T? typedColByName<T>(String columnName) {
    final colIndex = _metadata.columnIndex(columnName);
    final value = _values[colIndex];
    final colDef = _metadata.columns[colIndex];

    return colDef.type
        .convertStringValueToProvidedType<T>(value, colDef.columnLength);
  }

  /// Get data for all columns
  Map<String, dynamic> assoc() {
    final result = <String, dynamic>{};
    final columnNames = _metadata.columnNames;
    for (var colIndex = 0; colIndex < columnNames.length; colIndex++) {
      result[columnNames[colIndex]] = _values[colIndex];
    }
    return result;
  }

  /// Same as [assoc] but detects best dart type for columns, and converts string data into appropriate types
  Map<String, dynamic> typedAssoc() {
    final result = <String, dynamic>{};
    final columnNames = _metadata.columnNames;
    final bestMatchDartTypes = _metadata.bestMatchDartTypes;
    for (var colIndex = 0; colIndex < columnNames.length; colIndex++) {
      final columnName = columnNames[colIndex];
      final value = _values[colIndex];

      if (value == null) {
        result[columnName] = null;
        continue;
      }

      final dartType = bestMatchDartTypes[colIndex];

      result[columnName] = _convertTypedAssocValue(dartType, value);
    }

    return result;
  }

  dynamic _convertTypedAssocValue(Type dartType, dynamic value) {
    if (identical(dartType, int)) {
      if (value is int) {
        return value;
      }
      final text = value.toString();
      // BIGINT UNSIGNED above 2^63 - 1 does not fit a Dart int.
      return int.tryParse(text) ?? BigInt.parse(text);
    }

    if (identical(dartType, double)) {
      if (value is double) {
        return value;
      }
      if (value is num) {
        return value.toDouble();
      }
      return double.parse(value.toString());
    }

    if (identical(dartType, num)) {
      if (value is num) {
        return value;
      }
      return num.parse(value.toString());
    }

    if (identical(dartType, bool)) {
      if (value is bool) {
        return value;
      }
      if (value is num) {
        return value != 0;
      }
      return int.parse(value.toString()) > 0;
    }

    if (identical(dartType, DateTime)) {
      if (value is DateTime) {
        return value;
      }
      return DateTime.parse(value.toString());
    }

    return value;
  }
}

class _ResultSetMetadata {
  final List<MySQLColumnDefinitionPacket> columns;
  late final List<String> columnNames = List<String>.unmodifiable(
    columns.map((column) => column.name),
  );
  late final List<Type> bestMatchDartTypes = List<Type>.unmodifiable(
    columns
        .map((column) => column.type.getBestMatchDartType(column.columnLength)),
  );
  late final List<ResultSetColumn> resultSetColumns =
      List<ResultSetColumn>.unmodifiable(
    columns
        .map(
          (column) => ResultSetColumn(
            name: column.name,
            type: column.type,
            length: column.columnLength,
          ),
        )
        .toList(growable: false),
  );
  late final Map<String, int> _columnIndexesByLowerName = {
    for (var i = 0; i < columns.length; i++) columns[i].name.toLowerCase(): i,
  };

  _ResultSetMetadata(this.columns);

  int columnIndex(String columnName) {
    final colIndex = _columnIndexesByLowerName[columnName.toLowerCase()];
    if (colIndex == null) {
      throw MySQLClientException("There is no column with name: $columnName");
    }
    return colIndex;
  }
}

/// Represents column definition
class ResultSetColumn {
  String name;
  MySQLColumnType type;
  int length;

  ResultSetColumn({
    required this.name,
    required this.type,
    required this.length,
  });
}

/// Prepared statement class
class PreparedStmt {
  final MySQLPacketStmtPrepareOK _preparedPacket;
  final MySQLConnection _connection;
  final bool _iterable;
  Uint8List? _lastParamTypeCodes;
  bool _hasSentParamTypes = false;

  PreparedStmt._({
    required MySQLPacketStmtPrepareOK preparedPacket,
    required MySQLConnection connection,
    required bool iterable,
  })  : _preparedPacket = preparedPacket,
        _connection = connection,
        _iterable = iterable;

  int get numOfParams => _preparedPacket.numOfParams;

  bool _shouldSendParamTypes(Uint8List paramTypeCodes) {
    if (!_hasSentParamTypes) {
      return true;
    }

    final last = _lastParamTypeCodes;
    if (last == null || last.length != paramTypeCodes.length) {
      return true;
    }

    for (var i = 0; i < paramTypeCodes.length; i++) {
      if (last[i] != paramTypeCodes[i]) {
        return true;
      }
    }

    return false;
  }

  void _updateParamTypeCache(Uint8List paramTypeCodes, bool sendTypes) {
    if (!sendTypes) {
      return;
    }

    _lastParamTypeCodes = Uint8List.fromList(paramTypeCodes);
    _hasSentParamTypes = true;
  }

  /// Executes this prepared statement with given [params]
  Future<IResultSet> execute(List<dynamic> params) async {
    if (numOfParams != params.length) {
      throw MySQLClientException(
        "Can not execute prepared stmt: number of passed params != number of prepared params",
      );
    }

    return _connection._serialized(
        () => _connection._executePreparedStmt(this, params, _iterable));
  }

  /// Deallocates this prepared statement
  ///
  /// Use this method to prevent memory leaks for long running connections
  /// All prepared statements are automatically deallocated by database when connection is closed
  Future<void> deallocate() {
    return _connection
        ._serialized(() => _connection._deallocatePreparedStmt(this));
  }
}

class _ExecutePlan {
  final bool usePrepared;
  final String query;
  final List<dynamic> positionalParams;

  const _ExecutePlan._(this.usePrepared, this.query, this.positionalParams);

  factory _ExecutePlan.text(String query) =>
      _ExecutePlan._(false, query, const <dynamic>[]);

  factory _ExecutePlan.prepared(String query, List<dynamic> params) =>
      _ExecutePlan._(true, query, params);
}

class _NamedParamToken {
  const _NamedParamToken(this.start, this.end, this.name);

  final int start;
  final int end;
  final String name;
}

class _NamedParamConversionResult {
  final String query;
  final List<String> paramNames;

  const _NamedParamConversionResult(this.query, this.paramNames);
}
