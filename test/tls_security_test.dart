// TLS: certificate verification, a stalled handshake, and the RawSocket
// adapter TLS connections use. The certificates are generated with openssl
// when the tests run (the tests are skipped without it): macOS rejects a TLS
// certificate valid for more than 825 days, so a committed one would expire.
// Based on the report and tests by Brett Sutton.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:mysql_dart/src/mysql_client/raw_socket_adapter.dart';
import 'package:test/test.dart';

import 'test_config.dart';

/// A self-signed certificate for `localhost` only (not 127.0.0.1), or null
/// without openssl.
String? _generateCertificate() {
  try {
    final dir = Directory.systemTemp.createTempSync('mysql_dart_tls_');
    final result = Process.runSync('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '30',
      '-keyout',
      '${dir.path}/key.pem',
      '-out',
      '${dir.path}/cert.pem',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'extendedKeyUsage=serverAuth',
    ]);
    if (result.exitCode != 0) return null;
    return dir.path;
  } on ProcessException {
    return null;
  }
}

/// Initial handshake offering CLIENT_SSL with mysql_native_password.
List<int> _greeting() {
  final payload = <int>[
    10,
    ...ascii.encode('8.0.0'),
    0,
    1, 0, 0, 0, // connection id
    ...ascii.encode('12345678'),
    0,
    0x00, 0x8a, // CLIENT_SSL, CLIENT_PROTOCOL_41, secure connection
    45, // utf8mb4
    2, 0, // server status
    0x08, 0x00, // CLIENT_PLUGIN_AUTH
    21, // auth plugin data length
    ...List<int>.filled(10, 0),
    ...ascii.encode('abcdefghijkl'),
    0,
    ...ascii.encode('mysql_native_password'),
    0,
  ];
  return <int>[
    payload.length & 0xff,
    (payload.length >> 8) & 0xff,
    (payload.length >> 16) & 0xff,
    0,
    ...payload,
  ];
}

/// A server that sends the greeting and answers the SSLRequest with TLS
/// using the certificate in [certDir].
class _FakeTlsServer {
  _FakeTlsServer._(this._listener, this._context) {
    _listener.listen(_accept);
  }

  static Future<_FakeTlsServer> start(String certDir) async {
    final context = SecurityContext()
      ..useCertificateChain('$certDir/cert.pem')
      ..usePrivateKey('$certDir/key.pem');
    return _FakeTlsServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      context,
    );
  }

  final ServerSocket _listener;
  final SecurityContext _context;
  final _peers = <Socket>[];

  /// Completes with whether the TLS handshake succeeded.
  final tlsAccepted = Completer<bool>();

  /// Completes when the client sends its handshake response (user name and
  /// password) over TLS.
  final credentialsReceived = Completer<void>();

  int get port => _listener.port;

  void _accept(Socket peer) {
    _peers.add(peer);
    peer.add(_greeting());
    final received = BytesBuilder(copy: false);
    late StreamSubscription<Uint8List> subscription;
    void failed() {
      if (!tlsAccepted.isCompleted) tlsAccepted.complete(false);
    }

    subscription = peer.listen((data) {
      received.add(data);
      final bytes = received.toBytes();
      if (bytes.length < 4) return;
      final length = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
      if (bytes.length < 4 + length) return;
      subscription.pause();
      SecureSocket.secureServer(
        peer,
        _context,
        bufferedData: bytes.sublist(4 + length),
      ).then<void>((securePeer) {
        _peers.add(securePeer);
        if (!tlsAccepted.isCompleted) tlsAccepted.complete(true);
        securePeer.listen((_) {
          if (!credentialsReceived.isCompleted) credentialsReceived.complete();
          securePeer.destroy();
        }, onError: (Object _) => securePeer.destroy());
      }, onError: (Object _) => failed());
    }, onError: (Object _) => failed(), onDone: failed);
  }

  Future<void> close() async {
    for (final peer in _peers) {
      peer.destroy();
    }
    await _listener.close();
  }
}

/// Connects to [server] and returns the error connect() failed with.
Future<Object?> _connectTo(
  _FakeTlsServer server, {
  String host = 'localhost',
  SecurityContext? context,
  bool verifyServerCertificate = true,
  bool Function(X509Certificate certificate)? onBadCertificate,
}) async {
  final connection = await MySQLConnection.createConnection(
    host: host,
    port: server.port,
    userName: 'test',
    password: 'test',
    securityContext: context,
    verifyServerCertificate: verifyServerCertificate,
    onBadCertificate: onBadCertificate,
    socketTimeout: const Duration(seconds: 2),
  );
  try {
    await connection.connect(timeoutMs: 1500);
    return null;
  } catch (error) {
    return error;
  }
}

/// A server that sends the greeting, then never answers the TLS handshake.
class _StalledServer {
  _StalledServer._(this._listener) {
    _listener.listen((peer) {
      _peers.add(peer);
      peer.add(_greeting());
      peer.listen((_) {}, onDone: () {
        peer.destroy();
        closed++;
        _closedController.add(closed);
      }, onError: (Object _) {});
    });
  }

  static Future<_StalledServer> start() async => _StalledServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _listener;
  final _peers = <Socket>[];
  final _closedController = StreamController<int>.broadcast();
  int closed = 0;

  int get port => _listener.port;

  /// Completes once [count] client connections were closed.
  Future<void> closedConnections(int count) async {
    if (closed >= count) return;
    await _closedController.stream.firstWhere((n) => n >= count);
  }

  Future<void> close() async {
    for (final peer in _peers) {
      peer.destroy();
    }
    await _listener.close();
  }
}

void main() {
  final certDir = _generateCertificate();
  final noOpenssl = certDir == null ? 'openssl is not available' : null;

  SecurityContext trustTestCertificate() =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('$certDir/cert.pem');

  group('TLS certificate verification', skip: noOpenssl, () {
    late _FakeTlsServer server;
    setUp(() async => server = await _FakeTlsServer.start(certDir!));
    tearDown(() => server.close());

    test('rejects an untrusted certificate before sending credentials',
        () async {
      final error = await _connectTo(server);
      expect(error, isA<HandshakeException>());
      expect(await server.tlsAccepted.future, isFalse);
      expect(server.credentialsReceived.isCompleted, isFalse);
    });

    test('the error says how to trust the CA or opt out', () async {
      final error = await _connectTo(server);
      expect(
        error.toString(),
        allOf(contains('securityContext'),
            contains('verifyServerCertificate: false')),
      );
    });

    test('accepts a certificate trusted for the host it connects to', () async {
      await _connectTo(server, context: trustTestCertificate());
      expect(await server.tlsAccepted.future, isTrue);
      await server.credentialsReceived.future
          .timeout(const Duration(seconds: 2));
    });

    test('rejects a trusted certificate issued for another host', () async {
      final error = await _connectTo(
        server,
        host: InternetAddress.loopbackIPv4.address,
        context: trustTestCertificate(),
      );
      expect(error, isA<HandshakeException>());
      expect(server.credentialsReceived.isCompleted, isFalse);
    });

    test('verifyServerCertificate: false accepts any certificate', () async {
      await _connectTo(server, verifyServerCertificate: false);
      expect(await server.tlsAccepted.future, isTrue);
    });

    test('onBadCertificate decides instead of verifyServerCertificate',
        () async {
      final error = await _connectTo(
        server,
        verifyServerCertificate: false,
        onBadCertificate: (_) => false,
      );
      expect(error, isA<HandshakeException>());
      expect(server.credentialsReceived.isCompleted, isFalse);
    });
  });

  group('stalled TLS handshake', () {
    test('connect() timeout closes the connection to the server', () async {
      final server = await _StalledServer.start();
      try {
        final connection = await MySQLConnection.createConnection(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          userName: 'test',
          password: 'test',
        );
        await expectLater(
          connection.connect(timeoutMs: 300),
          throwsA(isA<TimeoutException>()),
        );
        // Before the fix the server side stayed open indefinitely.
        await server.closedConnections(1).timeout(const Duration(seconds: 2));
        expect(connection.connected, isFalse);
        await connection.close().timeout(const Duration(seconds: 2));
      } finally {
        await server.close();
      }
    });

    test('concurrent timeouts close every connection', () async {
      const count = 8;
      final server = await _StalledServer.start();
      try {
        final connections = await Future.wait(List.generate(
          count,
          (_) => MySQLConnection.createConnection(
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
            userName: 'test',
            password: 'test',
          ),
        ));
        await Future.wait(connections.map((connection) => expectLater(
              connection.connect(timeoutMs: 300),
              throwsA(isA<TimeoutException>()),
            )));
        await server
            .closedConnections(count)
            .timeout(const Duration(seconds: 2));
      } finally {
        await server.close();
      }
    });
  });

  group('RawSocketAdapter', () {
    late ServerSocket listener;
    late Future<Socket> accepted;
    setUp(() async {
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      accepted = listener.first;
    });
    tearDown(() => listener.close());

    Future<(RawSocketAdapter, Socket)> connectPair() async {
      final adapter = RawSocketAdapter(
          await RawSocket.connect(InternetAddress.loopbackIPv4, listener.port));
      return (adapter, await accepted);
    }

    test('a write larger than the socket buffer arrives whole after flush',
        () async {
      final (adapter, peer) = await connectPair();
      const size = 32 * 1024 * 1024;
      final data = Uint8List(size);
      for (var i = 0; i < size; i++) {
        data[i] = i & 0xff;
      }
      final received = BytesBuilder(copy: false);
      final allReceived = Completer<void>();
      peer.listen((chunk) {
        received.add(chunk);
        if (received.length == size) allReceived.complete();
      });
      adapter.add(data);
      await adapter.flush();
      await allReceived.future.timeout(const Duration(seconds: 10));
      expect(received.takeBytes(), equals(data));
      adapter.destroy();
      peer.destroy();
    });

    test('pause stops reading and resume delivers the rest', () async {
      final (adapter, peer) = await connectPair();
      final received = <int>[];
      final subscription = adapter.listen(received.addAll);
      peer.add([1, 2, 3]);
      await peer.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, [1, 2, 3]);

      subscription.pause();
      peer.add([4, 5]);
      await peer.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, [1, 2, 3]);

      subscription.resume();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, [1, 2, 3, 4, 5]);
      adapter.destroy();
      peer.destroy();
    });

    test('the stream ends after the data the peer sent before closing',
        () async {
      final (adapter, peer) = await connectPair();
      final received = <int>[];
      final ended = Completer<void>();
      adapter.listen(received.addAll, onDone: ended.complete);
      peer.add([7, 8, 9]);
      await peer.flush();
      await peer.close();
      await ended.future.timeout(const Duration(seconds: 2));
      expect(received, [7, 8, 9]);
      adapter.destroy();
    });

    test('destroy closes the connection and ends the stream', () async {
      final (adapter, peer) = await connectPair();
      final ended = Completer<void>();
      adapter.listen((_) {}, onDone: ended.complete);
      final peerClosed = Completer<void>();
      peer.listen((_) {}, onDone: peerClosed.complete);
      adapter.destroy();
      await ended.future.timeout(const Duration(seconds: 2));
      await peerClosed.future.timeout(const Duration(seconds: 2));
      expect(() => adapter.add([1]), throwsStateError);
    });
  });

  group('TLS with the test server',
      skip: mysqlTestSecure ? null : 'MYSQL_SECURE is false', () {
    Future<MySQLConnection> open({
      SecurityContext? context,
      bool verifyServerCertificate = true,
    }) async {
      final connection = await MySQLConnection.createConnection(
        host: mysqlTestHost,
        port: mysqlTestPort,
        userName: mysqlTestUser,
        password: mysqlTestPassword,
        databaseName: mysqlTestDatabase,
        securityContext: context,
        verifyServerCertificate: verifyServerCertificate,
      );
      await connection.connect();
      return connection;
    }

    test('rejects the server when its CA is not trusted', () async {
      await expectLater(
        open(context: SecurityContext(withTrustedRoots: false)),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('verifyServerCertificate: false connects without trusting the CA',
        () async {
      final connection = await open(
        context: SecurityContext(withTrustedRoots: false),
        verifyServerCertificate: false,
      );
      final result = await connection.execute("SHOW STATUS LIKE 'Ssl_cipher'");
      expect(result.rows.first.colAt(1), isNotEmpty);
      await connection.close();
    });

    test('getSocket() is a SecureSocket with the server certificate', () async {
      final connection = await open();
      final socket = connection.getSocket();
      expect(socket, isA<SecureSocket>());
      expect((socket as SecureSocket).peerCertificate, isNotNull);
      expect(socket.remotePort, mysqlTestPort);
      await connection.close();
    });

    test('a query timeout kills the statement over TLS', () async {
      // KILL QUERY opens a second TLS connection to the configured host.
      final connection = await open();
      final watch = Stopwatch()..start();
      await expectLater(
        connection.execute(
            'SELECT SLEEP(10)', null, false, const Duration(milliseconds: 300)),
        throwsA(isA<MySQLClientException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      final result = await connection.execute('SELECT 1 AS one');
      expect(result.rows.first.colAt(0), '1');
      await connection.close();
    });

    test('large values cross TLS intact', () async {
      final connection = await open();
      final big = 'xy' * 3000000;
      final sent = await connection.execute(
        "SELECT (:v = REPEAT('xy', 3000000)) AS same",
        {'v': big},
      );
      expect(sent.rows.first.colAt(0), '1');
      final read =
          await connection.execute("SELECT REPEAT('xy', 3000000) AS v");
      expect(read.rows.first.colAt(0), big);
      await connection.close();
    });
  });
}
