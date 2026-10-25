import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';
import 'package:mysql_dart/src/mysql_client/caching_sha2_auth.dart';
import 'package:mysql_dart/src/utils/byte_data_writer.dart';
import 'package:mysql_dart/src/utils/hash.dart';
import 'package:mysql_dart/src/utils/hex.dart';
import 'package:test/test.dart';

const String _valid1024BitPublicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDckgVqA8sCZ+1xqauRZyUYEcSi
BpFPBbA09BzLx7xd00f2cHtB90g2eUTz6Q+1xOlcOxpE2NjFttW+tF2PrXuCm0Wv
Hlv570PG1lE0VoRl92BJZzjAqpz+1HN35wX8SujF27RXvOhYyDUEpQ6q3j006vs3
8BVC4PAGQCdnJIgVrQIDAQAB
-----END PUBLIC KEY-----
''';

const List<int> _rsaAlgorithmIdentifierDer = [
  0x30,
  0x0d,
  0x06,
  0x09,
  0x2a,
  0x86,
  0x48,
  0x86,
  0xf7,
  0x0d,
  0x01,
  0x01,
  0x01,
  0x05,
  0x00,
];

final Uint8List _twentyByteSeed =
    Uint8List.fromList(List<int>.generate(20, (i) => i + 1));

String _pemWrapPublicKey(List<int> derBytes) =>
    '-----BEGIN PUBLIC KEY-----\n${base64.encode(derBytes)}\n-----END PUBLIC KEY-----';

String _pemWrapPkcs1(List<int> derBytes) =>
    '-----BEGIN RSA PUBLIC KEY-----\n${base64.encode(derBytes)}\n-----END RSA PUBLIC KEY-----';

Uint8List _derElement(int tag, List<int> value) {
  final len = value.length;
  final out = BytesBuilder(copy: false)..addByte(tag);
  if (len < 0x80) {
    out.addByte(len);
  } else if (len <= 0xff) {
    out
      ..addByte(0x81)
      ..addByte(len);
  } else {
    out
      ..addByte(0x82)
      ..addByte((len >> 8) & 0xff)
      ..addByte(len & 0xff);
  }
  out.add(value);
  return out.takeBytes();
}

Uint8List _framePacket(int seqId, List<int> payload) {
  final len = payload.length;
  return Uint8List.fromList([
    len & 0xff,
    (len >> 8) & 0xff,
    (len >> 16) & 0xff,
    seqId & 0xff,
    ...payload,
  ]);
}

Uint8List _buildOkPacket(int seqId) =>
    _framePacket(seqId, const [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]);

Uint8List _buildColDefPayload(String name) {
  final writer = ByteDataWriter(endian: Endian.little);
  for (final field in ['def', 'db', 't', 't', name, name]) {
    writer.writeVariableEncInt(field.length);
    writer.write(utf8.encode(field));
  }
  writer
    ..writeVariableEncInt(0x0c)
    ..writeUint16(45, Endian.little)
    ..writeUint32(10, Endian.little)
    ..writeUint8(mysqlColumnTypeVarString)
    ..writeUint16(0, Endian.little)
    ..writeUint8(0)
    ..writeUint16(0, Endian.little);
  return writer.toBytes();
}

Uint8List _buildHandshakePacket({
  String pluginName = 'caching_sha2_password',
  List<int> part1 = const [1, 2, 3, 4, 5, 6, 7, 8],
  List<int>? part2 = const [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 0],
  bool includeSecureConnection = true,
  int? declaredAuthLen,
}) {
  final caps = includeSecureConnection
      ? (mysqlCapFlagClientProtocol41 |
          mysqlCapFlagClientSecureConnection |
          mysqlCapFlagClientPluginAuth)
      : (mysqlCapFlagClientProtocol41 | mysqlCapFlagClientPluginAuth);
  final p2 = part2 ?? const <int>[];
  final authLen = declaredAuthLen ?? (part1.length + p2.length);
  final writer = ByteDataWriter(endian: Endian.little)
    ..writeUint8(10)
    ..write(utf8.encode('8.4.0'))
    ..writeUint8(0)
    ..writeUint32(42, Endian.little)
    ..write(part1)
    ..writeUint8(0)
    ..writeUint16(caps & 0xffff, Endian.little)
    ..writeUint8(45)
    ..writeUint16(0x0002, Endian.little)
    ..writeUint16((caps >> 16) & 0xffff, Endian.little)
    ..writeUint8(authLen)
    ..write(List<int>.filled(10, 0));
  if (includeSecureConnection) {
    writer.write(p2);
  }
  writer
    ..write(utf8.encode(pluginName))
    ..writeUint8(0);
  return _framePacket(0, writer.toBytes());
}

Future<T> _withFakeSocket<T>(
  _FakeSocket socket,
  Future<T> Function(MySQLConnection conn) action, {
  bool allowPublicKeyRetrieval = false,
}) async {
  try {
    return await IOOverrides.runZoned(
      () async {
        final conn = await MySQLConnection.createConnection(
          host: '127.0.0.1',
          port: 3306,
          userName: 'u',
          password: 'p',
          secure: false,
          allowPublicKeyRetrieval: allowPublicKeyRetrieval,
        );
        return await action(conn);
      },
      socketConnect: (host, port,
              {sourceAddress, sourcePort = 0, timeout}) async =>
          socket,
    );
  } finally {
    socket.destroy();
  }
}

void main() {
  _registerPemAndDerBoundsTests();
  _registerUtilityBoundsTests();
  _registerStreamAndHandshakeTests();
  _registerCommandBoundsTests();
  _registerRowAndParamBoundsTests();
}

void _registerPemAndDerBoundsTests() {
  group('caching_sha2_auth PEM and ASN.1 DER bounds', () {
    test('rejects empty RSA auth seed with FormatException', () {
      expect(
        () => buildCachingSha2EncryptedPassword(
          'secret',
          Uint8List(0),
          _valid1024BitPublicKeyPem,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects truncated single-byte and multi-byte DER lengths', () {
      // Single-byte DER [0x30] and truncated 2-byte length [0x30, 0x82, 0x01].
      for (final der in const <List<int>>[
        [0x30],
        [0x30, 0x82, 0x01],
        [0x30, 0x84, 0x00, 0x00],
      ]) {
        expect(
          () => buildCachingSha2EncryptedPassword(
            'secret',
            _twentyByteSeed,
            _pemWrapPublicKey(der),
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects non-minimal and unsupported DER length encodings', () {
      // X.690 §10.1: <128 in long form (0x81 0x02), leading zero length byte
      // (0x82 0x00 0x80), indefinite length (0x80), and 5-byte length (0x85).
      final nonMinimalShort = [0x30, 0x81, 0x02, 0x05, 0x00];
      final leadingZeroLen = [
        0x30,
        0x82,
        0x00,
        0x80,
        ...List<int>.filled(0x80, 0),
      ];
      const indefiniteLen = [0x30, 0x80];
      const fiveByteLen = [0x30, 0x85, 0x01, 0x00, 0x00, 0x00, 0x00];

      for (final der in [
        nonMinimalShort,
        leadingZeroLen,
        indefiniteLen,
        fiveByteLen,
      ]) {
        expect(
          () => buildCachingSha2EncryptedPassword(
            'secret',
            _twentyByteSeed,
            _pemWrapPublicKey(der),
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects empty PEM, truncated values, and malformed SPKI envelopes',
        () {
      const emptyPem = '-----BEGIN PUBLIC KEY-----\n-----END PUBLIC KEY-----';
      expect(
        () => buildCachingSha2EncryptedPassword(
          'secret',
          _twentyByteSeed,
          emptyPem,
        ),
        throwsA(isA<FormatException>()),
      );

      final malformedDerInputs = <List<int>>[
        const [0x02, 0x01, 0x01], // Top-level is INTEGER instead of SEQUENCE.
        const [0x30, 0x08], // Declared length exceeds buffer.
        const [0x30, 0x02, 0x05, 0x00, 0x00], // Trailing byte after SEQUENCE.
        // SPKI with empty OID (06 00) and empty BIT STRING (03 00).
        const [0x30, 0x06, 0x30, 0x02, 0x06, 0x00, 0x03, 0x00],
        // SPKI with non-zero unused BIT STRING bits (03 02 01 00).
        [
          ..._derElement(0x30, [
            ..._rsaAlgorithmIdentifierDer,
            ..._derElement(0x03, const [0x01, 0x30, 0x00]),
          ]),
        ],
      ];

      for (final der in malformedDerInputs) {
        expect(
          () => buildCachingSha2EncryptedPassword(
            'secret',
            _twentyByteSeed,
            _pemWrapPublicKey(der),
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects zero, negative, non-minimal, even, and degenerate RSA keys',
        () {
      final validModulusBytes = [0x00, 0xc1, ...List<int>.filled(62, 0), 0x01];
      final evenModulusBytes = [0x00, 0xc1, ...List<int>.filled(62, 0), 0x02];
      final negativeModulusBytes = [0xc1, ...List<int>.filled(62, 0), 0x01];

      final invalidPkcs1Keys = <Uint8List>[
        // Zero modulus (02 01 00).
        _derElement(0x30, [
          ..._derElement(0x02, const [0x00]),
          ..._derElement(0x02, const [0x01, 0x00, 0x01]),
        ]),
        // Empty INTEGER (02 00).
        _derElement(0x30, [
          ..._derElement(0x02, const []),
          ..._derElement(0x02, const [0x01, 0x00, 0x01]),
        ]),
        // Negative DER INTEGER (high bit set without leading 0x00).
        _derElement(0x30, [
          ..._derElement(0x02, negativeModulusBytes),
          ..._derElement(0x02, const [0x01, 0x00, 0x01]),
        ]),
        // Non-minimal DER INTEGER (02 02 00 03).
        _derElement(0x30, [
          ..._derElement(0x02, validModulusBytes),
          ..._derElement(0x02, const [0x00, 0x03]),
        ]),
        // Even RSA modulus.
        _derElement(0x30, [
          ..._derElement(0x02, evenModulusBytes),
          ..._derElement(0x02, const [0x01, 0x00, 0x01]),
        ]),
        // Zero public exponent (e == 0).
        _derElement(0x30, [
          ..._derElement(0x02, validModulusBytes),
          ..._derElement(0x02, const [0x00]),
        ]),
        // Even public exponent (e == 65536).
        _derElement(0x30, [
          ..._derElement(0x02, validModulusBytes),
          ..._derElement(0x02, const [0x01, 0x00, 0x00]),
        ]),
        // Exponent >= modulus.
        _derElement(0x30, [
          ..._derElement(0x02, validModulusBytes),
          ..._derElement(0x02, validModulusBytes),
        ]),
        // Oversized >16384-bit modulus (2050 bytes -> 16399 bits).
        _derElement(0x30, [
          ..._derElement(
            0x02,
            [0x40, ...List<int>.filled(2048, 0), 0x01],
          ),
          ..._derElement(0x02, const [0x01, 0x00, 0x01]),
        ]),
      ];

      for (final pkcs1 in invalidPkcs1Keys) {
        expect(
          () => buildCachingSha2EncryptedPassword(
            'secret',
            _twentyByteSeed,
            _pemWrapPkcs1(pkcs1),
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects overly long password for RSA-OAEP with FormatException', () {
      // 1024-bit (128-byte) key fits at most 128 - 42 = 86 message bytes
      // (85 password bytes + NUL).
      expect(
        () => buildCachingSha2EncryptedPassword(
          'a' * 90,
          _twentyByteSeed,
          _valid1024BitPublicKeyPem,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

void _registerUtilityBoundsTests() {
  group('writeVariableEncInt and utility bounds', () {
    test('writeVariableEncInt rejects negative integers', () {
      for (final negative in const [-1, -5, -256, -9223372036854775808]) {
        final writer = ByteDataWriter(endian: Endian.little);
        expect(
          () => writer.writeVariableEncInt(negative),
          throwsA(isA<MySQLProtocolException>()),
        );
        expect(writer.toBytes(), isEmpty);
      }
    });

    test(
        'writeVariableEncInt encodes little-endian regardless of writer endian',
        () {
      const boundaryValues = <int>[
        0,
        250,
        251,
        255,
        300,
        65535,
        65536,
        16777215,
        16777216,
        4294967296,
        9223372036854775807,
      ];

      for (final value in boundaryValues) {
        final bigEndianWriter =
            ByteDataWriter(endian: Endian.big, bufferLength: 2)
              ..writeVariableEncInt(value);
        final littleEndianWriter = ByteDataWriter(endian: Endian.little)
          ..writeVariableEncInt(value);

        final bytes = bigEndianWriter.toBytes();
        expect(bytes, littleEndianWriter.toBytes());

        final decoded = bytes.getVariableEncIntAt(0);
        expect(decoded.$1, BigInt.from(value));
        expect(decoded.$2, bytes.length);
      }
    });

    test('protocol extension readers reject negative and overflowing offsets',
        () {
      const maxInt64 = 0x7fffffffffffffff;
      final buf = Uint8List.fromList([0xfc, 0x01, 0x00, 0x61, 0x00]);
      final bd = ByteData.sublistView(buf);

      for (final badOffset in const [-1, maxInt64, maxInt64 - 2]) {
        expect(
          () => buf.getVariableEncIntAt(badOffset),
          throwsA(isA<MySQLProtocolException>()),
        );
        expect(
          () => bd.getVariableEncInt(badOffset),
          throwsA(isA<MySQLProtocolException>()),
        );
        expect(
          () => bd.getInt2(badOffset),
          throwsA(isA<MySQLProtocolException>()),
        );
        expect(
          () => bd.getInt3(badOffset),
          throwsA(isA<MySQLProtocolException>()),
        );
        expect(
          () => buf.getUtf8NullTerminatedString(badOffset),
          throwsA(isA<MySQLProtocolException>()),
        );
        expect(
          () => buf.getUtf8StringEOF(badOffset),
          throwsA(isA<MySQLProtocolException>()),
        );
      }
    });

    test('hex codec handles odd-length hex and rejects out-of-range inputs',
        () {
      expect(hex.decode('f'), [0x0f]);
      expect(hex.decode('1a b'), [0x01, 0xab]);
      expect(
        const HexEncoder(upperCase: true).convert(const [0x0a, 0xff]),
        '0AFF',
      );

      for (final badHex in const ['zz', '0g', '12\x00']) {
        expect(() => hex.decode(badHex), throwsA(isA<FormatException>()));
      }
      for (final badByte in const [-1, 256, -9223372036854775808]) {
        expect(() => hex.encode([badByte]), throwsA(isA<FormatException>()));
      }
    });

    test('sha1Digest, sha256Digest, and ByteDataWriter handle block boundaries',
        () {
      expect(
        hex.encode(sha1Digest(const <int>[])),
        'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      );
      expect(
        hex.encode(sha256Digest(List<int>.filled(56, 0x61))),
        'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      );

      final zeroBufferWriter = ByteDataWriter(bufferLength: 0)
        ..writeUint8(1)
        ..writeUint16(0x0203, Endian.big);
      expect(zeroBufferWriter.toBytes(), [1, 2, 3]);
    });
  });
}

void _registerStreamAndHandshakeTests() {
  group('In-memory MySQLConnection stream framing and auth bounds', () {
    test('reassembles 1-byte and split-header TCP packet chunks cleanly',
        () async {
      final socket = _FakeSocket();
      final handshake = _buildHandshakePacket();
      final authReply = Uint8List.fromList([
        ..._framePacket(2, const [0x01, 0x03]),
        ..._buildOkPacket(3),
      ]);
      final queryReply = Uint8List.fromList([
        ..._framePacket(1, const [0x01]),
        ..._framePacket(2, _buildColDefPayload('val')),
        ..._framePacket(3, const [0xfe, 0x00, 0x00, 0x02, 0x00]),
        ..._framePacket(4, const [0x02, 0x34, 0x32]),
        ..._framePacket(5, const [0xfe, 0x00, 0x00, 0x02, 0x00]),
      ]);

      var phase = 0;
      socket.onClientWrite = (_) {
        if (phase == 0) {
          phase = 1;
          for (final byte in authReply) {
            socket.emit(Uint8List.fromList([byte]));
          }
        } else if (phase == 1) {
          phase = 2;
          socket.emit(Uint8List(0));
          for (var i = 0; i < queryReply.length; i += 2) {
            final end = i + 2 < queryReply.length ? i + 2 : queryReply.length;
            socket.emit(Uint8List.sublistView(queryReply, i, end));
          }
        }
      };

      await _withFakeSocket(socket, (conn) async {
        final connectFuture =
            conn.connect(timeoutMs: 1000, setCharsetOnConnect: false);
        for (final byte in handshake) {
          socket.emit(Uint8List.fromList([byte]));
        }
        await connectFuture;

        final rs = await conn.execute('SELECT 42 AS val');
        expect(rs.rows.single.colAt(0), '42');
        await conn.close();
      });
    });

    test('rejects initial handshake missing secure auth scramble', () async {
      final socket = _FakeSocket();
      final handshakeNoPart2 = _buildHandshakePacket(
        includeSecureConnection: false,
        part2: null,
        declaredAuthLen: 8,
      );

      await _withFakeSocket(socket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        socket.emit(handshakeNoPart2);
        await expectLater(future, throwsA(isA<MySQLProtocolException>()));
      });
    });

    test('rejects unsupported auth switch plugin without hanging connect()',
        () async {
      final socket = _FakeSocket();
      final handshake =
          _buildHandshakePacket(pluginName: 'mysql_native_password');
      socket.onClientWrite = (_) {
        // Unsupported plugin payload shorter than 9 bytes (previously swallowed
        // and misparsed as EOF, hanging connect() until timeout).
        socket.emit(
          _framePacket(2, [0xfe, ...utf8.encode('sha256'), 0x00]),
        );
      };

      await _withFakeSocket(socket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        socket.emit(handshake);
        await expectLater(future, throwsA(isA<MySQLClientException>()));
      });
    });

    test(
        'coalesced [ERR, OK] handshake packets fail auth instead of connecting',
        () async {
      final socket = _FakeSocket();
      final handshake = _buildHandshakePacket();
      socket.onClientWrite = (_) {
        socket.emit(
          Uint8List.fromList([
            ..._framePacket(2, [
              0xff,
              0x15,
              0x04,
              0x23,
              ...utf8.encode('28000Access denied'),
            ]),
            ..._buildOkPacket(3),
          ]),
        );
      };

      await _withFakeSocket(socket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        socket.emit(handshake);
        await expectLater(future, throwsA(isA<MySQLServerException>()));
        expect(conn.connected, isFalse);
      });
    });

    test('rejects short auth switch challenge (<20 bytes) with protocol error',
        () async {
      final socket = _FakeSocket();
      final handshake =
          _buildHandshakePacket(pluginName: 'mysql_native_password');
      socket.onClientWrite = (_) {
        socket.emit(
          _framePacket(2, [
            0xfe,
            ...utf8.encode('caching_sha2_password'),
            0x00,
            1,
            2,
            3,
          ]),
        );
      };

      await _withFakeSocket(socket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        socket.emit(handshake);
        await expectLater(future, throwsA(isA<MySQLProtocolException>()));
      });
    });

    test('rejects standalone 0-byte MySQL packet without RangeError', () async {
      final socket = _FakeSocket();
      final handshake = _buildHandshakePacket();
      socket.onClientWrite = (_) {
        socket.emit(Uint8List.fromList(const [0x00, 0x00, 0x00, 0x02]));
      };

      await _withFakeSocket(socket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        socket.emit(handshake);
        await expectLater(future, throwsA(isA<MySQLProtocolException>()));
      });
    });
  });
}

void _registerCommandBoundsTests() {
  group('In-memory MySQLConnection command bounds', () {
    test('rejects unexpected OK in COM_QUERY column-definition EOF state',
        () async {
      final socket = _FakeSocket();
      var connected = false;
      socket.onClientWrite = (written) {
        if (!connected) {
          connected = true;
          socket.emit(
            Uint8List.fromList([
              ..._framePacket(2, const [0x01, 0x03]),
              ..._buildOkPacket(3),
            ]),
          );
          return;
        }
        if (written.length >= 5 && written[4] == 0x03) {
          socket.emit(
            Uint8List.fromList([
              ..._framePacket(1, const [0x01]),
              ..._framePacket(2, _buildColDefPayload('c')),
              ..._buildOkPacket(3),
            ]),
          );
        }
      };

      await _withFakeSocket(socket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        socket.emit(_buildHandshakePacket());
        await future;

        await expectLater(
          conn.execute('SELECT 1'),
          throwsA(isA<MySQLProtocolException>()),
        );
      });
    });

    test('rejects ERR and premature EOF during COM_STMT_PREPARE definitions',
        () async {
      // Case 1: ERR packet while waiting for parameter definition.
      final errSocket = _FakeSocket();
      var errConnected = false;
      errSocket.onClientWrite = (written) {
        if (!errConnected) {
          errConnected = true;
          errSocket.emit(
            Uint8List.fromList([
              ..._framePacket(2, const [0x01, 0x03]),
              ..._buildOkPacket(3),
            ]),
          );
          return;
        }
        if (written.length >= 5 && written[4] == 0x16) {
          errSocket.emit(
            Uint8List.fromList([
              ..._framePacket(
                1,
                const [0x00, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0],
              ),
              ..._framePacket(2, [
                0xff,
                0x28,
                0x04,
                0x23,
                ...utf8.encode('HY000Prepare failed'),
              ]),
            ]),
          );
        }
      };

      await _withFakeSocket(errSocket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        errSocket.emit(_buildHandshakePacket());
        await future;

        await expectLater(
          conn.prepare('SELECT ?'),
          throwsA(isA<MySQLServerException>()),
        );
        await conn.close();
      });

      // Case 2: Premature EOF before declared parameter definition arrives.
      final eofSocket = _FakeSocket();
      var eofConnected = false;
      eofSocket.onClientWrite = (written) {
        if (!eofConnected) {
          eofConnected = true;
          eofSocket.emit(
            Uint8List.fromList([
              ..._framePacket(2, const [0x01, 0x03]),
              ..._buildOkPacket(3),
            ]),
          );
          return;
        }
        if (written.length >= 5 && written[4] == 0x16) {
          eofSocket.emit(
            Uint8List.fromList([
              ..._framePacket(
                1,
                const [0x00, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0],
              ),
              ..._framePacket(2, const [0xfe, 0x00, 0x00, 0x02, 0x00]),
            ]),
          );
        }
      };

      await _withFakeSocket(eofSocket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        eofSocket.emit(_buildHandshakePacket());
        await future;

        await expectLater(
          conn.prepare('SELECT ?'),
          throwsA(isA<MySQLProtocolException>()),
        );
      });
    });
  });
}

void _registerRowAndParamBoundsTests() {
  group('In-memory MySQLConnection row and parameter bounds', () {
    test('rejects negative ResultSetRow column indexes and bad parameter maps',
        () async {
      final socket = _FakeSocket();
      var connected = false;
      socket.onClientWrite = (written) {
        if (!connected) {
          connected = true;
          socket.emit(
            Uint8List.fromList([
              ..._framePacket(2, const [0x01, 0x03]),
              ..._buildOkPacket(3),
            ]),
          );
          return;
        }
        if (written.length >= 5 && written[4] == 0x03) {
          socket.emit(
            Uint8List.fromList([
              ..._framePacket(1, const [0x01]),
              ..._framePacket(2, _buildColDefPayload('c')),
              ..._framePacket(3, const [0xfe, 0x00, 0x00, 0x02, 0x00]),
              ..._framePacket(4, const [0x01, 0x78]),
              ..._framePacket(5, const [0xfe, 0x00, 0x00, 0x02, 0x00]),
            ]),
          );
        }
      };

      await _withFakeSocket(socket, (conn) async {
        final future = conn.connect(timeoutMs: 500, setCharsetOnConnect: false);
        socket.emit(_buildHandshakePacket());
        await future;

        await expectLater(
          conn.execute('SELECT :a', <Object, Object?>{1: 'bad'}),
          throwsA(isA<MySQLClientException>()),
        );
        await expectLater(
          conn.execute('SELECT ?', [
            [Object()],
          ]),
          throwsA(isA<MySQLClientException>()),
        );

        final rs = await conn.execute('SELECT 1 AS c');
        final row = rs.rows.single;
        expect(() => row.colAt(-1), throwsA(isA<MySQLClientException>()));
        expect(
          () => row.typedColAt<String>(-1),
          throwsA(isA<MySQLClientException>()),
        );
        await conn.close();
      });
    });
  });
}

class _FakeSocket extends Stream<Uint8List> implements Socket {
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<void> _doneCompleter = Completer<void>();
  void Function(Uint8List data)? onClientWrite;

  void emit(Uint8List bytes) {
    if (!_incoming.isClosed) {
      _incoming.add(bytes);
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _incoming.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;

  @override
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;

  @override
  int get port => 12345;

  @override
  int get remotePort => 3306;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    onClientWrite?.call(Uint8List.fromList(data));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<dynamic> flush() async {}

  @override
  Future<dynamic> close() async {
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  @override
  void destroy() {
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  @override
  Future<dynamic> get done => _doneCompleter.future;

  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  Uint8List getRawOption(RawSocketOption option) => Uint8List(0);

  @override
  void setRawOption(RawSocketOption option) {}

  @override
  void write(Object? object) => add(utf8.encode(object.toString()));

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => add([charCode]);

  @override
  void writeln([Object? object = '']) => write('$object\n');
}
