import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart' show MySQLConnection;
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/src/utils/byte_data_writer.dart';
import 'package:test/test.dart';

const int _int64Min = -0x8000000000000000;
const Duration _maxMysqlTime = Duration(
  hours: 838,
  minutes: 59,
  seconds: 59,
  microseconds: 999999,
);

void main() {
  group('Duration binary MYSQL_TYPE_TIME encoding', () {
    test('encodes Duration.zero as single 0x00 length byte and round-trips',
        () {
      final valueBytes = _encodeSingleTimeParam(Duration.zero);
      expect(valueBytes, [0]);

      final decoded = _decodeBinaryTime(valueBytes);
      expect(decoded, ('00:00:00', 1));
    });

    test('encodes positive, negative, and multi-day 8-byte TIME payloads', () {
      final cases = <(Duration, List<int>, String)>[
        (
          const Duration(hours: 12, minutes: 34, seconds: 56),
          [8, 0, 0, 0, 0, 0, 12, 34, 56],
          '12:34:56',
        ),
        (
          -const Duration(hours: 5, minutes: 6, seconds: 7),
          [8, 1, 0, 0, 0, 0, 5, 6, 7],
          '-05:06:07',
        ),
        (
          const Duration(days: 2, hours: 3, minutes: 4, seconds: 5),
          [8, 0, 2, 0, 0, 0, 3, 4, 5],
          '51:04:05',
        ),
        (
          -const Duration(days: 1, hours: 0, minutes: 0, seconds: 0),
          [8, 1, 1, 0, 0, 0, 0, 0, 0],
          '-24:00:00',
        ),
      ];

      for (final (duration, expectedBytes, expectedText) in cases) {
        final encoded = _encodeSingleTimeParam(duration);
        expect(encoded, expectedBytes, reason: 'wire bytes for $duration');
        expect(
          _decodeBinaryTime(encoded),
          (expectedText, 9),
          reason: 'round-trip for $duration',
        );
      }
    });

    test('encodes sub-second microseconds as 12-byte TIME payloads', () {
      final cases = <(Duration, List<int>, String)>[
        (
          const Duration(
            hours: 1,
            minutes: 2,
            seconds: 3,
            milliseconds: 25,
            microseconds: 7,
          ),
          [12, 0, 0, 0, 0, 0, 1, 2, 3, ..._u32le(25007)],
          '01:02:03.025007',
        ),
        (
          -const Duration(microseconds: 5),
          [12, 1, 0, 0, 0, 0, 0, 0, 0, ..._u32le(5)],
          '-00:00:00.000005',
        ),
        (
          -const Duration(
            days: 3,
            hours: 1,
            minutes: 2,
            seconds: 3,
            microseconds: 456789,
          ),
          [12, 1, 3, 0, 0, 0, 1, 2, 3, ..._u32le(456789)],
          '-73:02:03.456789',
        ),
      ];

      for (final (duration, expectedBytes, expectedText) in cases) {
        final encoded = _encodeSingleTimeParam(duration);
        expect(encoded, expectedBytes, reason: 'wire bytes for $duration');
        expect(
          _decodeBinaryTime(encoded),
          (expectedText, 13),
          reason: 'round-trip for $duration',
        );
      }
    });

    test('encodes exact +/-838:59:59.999999 boundaries and round-trips', () {
      final positive = _encodeSingleTimeParam(_maxMysqlTime);
      expect(
        positive,
        [12, 0, 34, 0, 0, 0, 22, 59, 59, ..._u32le(999999)],
      );
      expect(_decodeBinaryTime(positive), ('838:59:59.999999', 13));

      final negative = _encodeSingleTimeParam(-_maxMysqlTime);
      expect(
        negative,
        [12, 1, 34, 0, 0, 0, 22, 59, 59, ..._u32le(999999)],
      );
      expect(_decodeBinaryTime(negative), ('-838:59:59.999999', 13));
    });

    test('throws MySQLClientException on out-of-range Duration values', () {
      final outOfRange = <Duration>[
        const Duration(hours: 839),
        -const Duration(hours: 839),
        _maxMysqlTime + const Duration(microseconds: 1),
        -_maxMysqlTime - const Duration(microseconds: 1),
        const Duration(microseconds: _int64Min),
      ];

      for (final duration in outOfRange) {
        expect(
          () => _encodeSingleTimeParam(duration),
          throwsA(
            isA<MySQLClientException>().having(
              (e) => e.message,
              'message',
              contains(duration.toString()),
            ),
          ),
          reason: 'expected MySQLClientException for $duration',
        );
      }
    });

    test('throws MySQLClientException on incompatible TIME parameter object',
        () {
      final packet = MySQLPacketCommStmtExecute(
        stmtID: 1,
        params: ['12:00:00'],
        paramTypeCodes: Uint8List.fromList([mysqlColumnTypeTime]),
        sendTypes: true,
      );
      expect(packet.encode, throwsA(isA<MySQLClientException>()));
    });
  });

  group('TypedData & sub-buffer offset views without sentinel leakage', () {
    test('encodes sliced views in MySQLPacketCommStmtExecute without leak', () {
      final backing = Uint8List.fromList([
        0xDE,
        0xAD,
        0xBE,
        0xEF,
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0xCA,
        0xFE,
        0xBA,
        0xBE,
      ]);

      final u8Slice = Uint8List.sublistView(backing, 4, 8);
      final byteDataSlice = ByteData.sublistView(backing, 6, 11);
      final roByteDataSlice = ByteData.sublistView(
        backing.asUnmodifiableView(),
        5,
        9,
      );
      final u16Slice = Uint16List.sublistView(backing, 4, 10);
      final i32Full = Int32List.fromList([0x04030201, -0x01020304]);
      final i32Slice = Int32List.sublistView(backing, 4, 12);
      final emptySlice = ByteData.sublistView(backing, 4, 4);

      final cases = <(Object, List<int>)>[
        (u8Slice, [0x11, 0x22, 0x33, 0x44]),
        (byteDataSlice, [0x33, 0x44, 0x55, 0x66, 0x77]),
        (roByteDataSlice, [0x22, 0x33, 0x44, 0x55]),
        (u16Slice, [0x11, 0x22, 0x33, 0x44, 0x55, 0x66]),
        (
          i32Full,
          i32Full.buffer.asUint8List(
            i32Full.offsetInBytes,
            i32Full.lengthInBytes,
          ),
        ),
        (i32Slice, [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]),
        (emptySlice, const <int>[]),
      ];

      for (final (view, expectedPayload) in cases) {
        final packet = MySQLPacketCommStmtExecute(
          stmtID: 42,
          params: [view],
          paramTypeCodes: Uint8List.fromList([mysqlColumnTypeTinyBlob]),
          sendTypes: true,
        ).encodePacket(0);

        expect(packet.offsetInBytes, 0);
        expect(packet.buffer.lengthInBytes, packet.length);
        // Header (4) + cmd/stmt/flags/iter (10) + null-bitmap (1) +
        // sendTypes (1) + type/flag (2) = offset 18.
        expect(
          packet.sublist(18),
          [expectedPayload.length, ...expectedPayload],
          reason: 'encoded payload for ${view.runtimeType}',
        );
        expect(
          _containsSubsequence(packet.buffer.asUint8List(), [0xDE, 0xAD]),
          isFalse,
        );
        expect(
          _containsSubsequence(packet.buffer.asUint8List(), [0xCA, 0xFE]),
          isFalse,
        );
      }
    });

    test('ByteDataWriter and MySQLPacket isolate Uint8List.sublistView bounds',
        () {
      final backing = Uint8List.fromList([
        0xDE,
        0xAD,
        0x10,
        0x20,
        0x30,
        0xBE,
        0xEF,
      ]);
      final slice = Uint8List.sublistView(backing, 2, 5);

      final multiChunk = ByteDataWriter(endian: Endian.little)
        ..writeUint8(0x16)
        ..write(slice);
      final multiBytes = multiChunk.toBytes();
      expect(multiBytes, [0x16, 0x10, 0x20, 0x30]);
      expect(multiBytes.offsetInBytes, 0);
      expect(multiBytes.buffer.lengthInBytes, 4);

      final copiedSingle = ByteDataWriter(endian: Endian.little)
        ..write(slice, copy: true);
      final copiedBytes = copiedSingle.toBytes();
      expect(copiedBytes, [0x10, 0x20, 0x30]);
      expect(copiedBytes.offsetInBytes, 0);
      expect(copiedBytes.buffer.lengthInBytes, 3);

      final packet = MySQLPacket(
        sequenceID: 2,
        payloadLength: 0,
        payload: _RawSlicePayload(slice),
      ).encode();
      expect(packet, [3, 0, 0, 2, 0x10, 0x20, 0x30]);
      expect(packet.offsetInBytes, 0);
      expect(packet.buffer.lengthInBytes, 7);
    });
  });

  group('End-to-end loopback MySQLConnection binary parameter execution', () {
    late _FakeMySqlBinaryServer server;
    late MySQLConnection conn;

    setUp(() async {
      server = await _FakeMySqlBinaryServer.start();
      conn = await MySQLConnection.createConnection(
        host: '127.0.0.1',
        port: server.port,
        userName: 'dart',
        password: '',
        secure: false,
      );
      await conn.connect(timeoutMs: 5000, setCharsetOnConnect: false);
    });

    tearDown(() async {
      if (conn.connected) {
        await conn.close();
      }
      await server.close();
    });

    test('prepare + stmt.execute encodes Duration and TypedData views cleanly',
        () async {
      final backing = Uint8List.fromList([
        0xDE,
        0xAD,
        0xBE,
        0xEF,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0xFE,
        0xED,
        0xFA,
        0xCE,
      ]);

      final stmt = await conn.prepare('SELECT ?, ?');
      expect(stmt.numOfParams, 2);

      final checks = <(Duration, Object, List<int>, String)>[
        (
          Duration.zero,
          Uint8List.sublistView(backing, 4, 7),
          [0x01, 0x02, 0x03],
          '00:00:00',
        ),
        (
          -const Duration(
            days: 1,
            hours: 2,
            minutes: 3,
            seconds: 4,
            microseconds: 500,
          ),
          ByteData.sublistView(backing, 5, 10),
          [0x02, 0x03, 0x04, 0x05, 0x06],
          '-26:03:04.000500',
        ),
        (
          _maxMysqlTime,
          Uint16List.sublistView(backing, 4, 10),
          [0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
          '838:59:59.999999',
        ),
        (
          -_maxMysqlTime,
          Int32List.sublistView(backing, 4, 12),
          [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
          '-838:59:59.999999',
        ),
      ];

      for (var i = 0; i < checks.length; i++) {
        final (duration, typedView, expectedBlob, expectedTimeText) = checks[i];
        final rs = await stmt.execute([duration, typedView]);
        final rows = rs.rows.toList();
        expect(rows, hasLength(1));
        expect(rows.single.colAt(0), expectedTimeText);
        expect(rows.single.typedColAt<Uint8List>(1), expectedBlob);

        final captured = server.executedCommands[i];
        expect(captured.stmtId, 1);
        // First execution sends parameter types; subsequent executions reuse
        // the cached [timeType, tinyBlobType] signature (`sendTypes == false`).
        if (i == 0) {
          expect(captured.sendTypes, isTrue);
          expect(
            captured.typeCodes,
            [mysqlColumnTypeTime, mysqlColumnTypeTinyBlob],
          );
        } else {
          expect(captured.sendTypes, isFalse);
        }
        expect(captured.blobBytes, expectedBlob);
        expect(
          _containsSubsequence(captured.rawPayload, [0xDE, 0xAD]),
          isFalse,
        );
        expect(
          _containsSubsequence(captured.rawPayload, [0xFE, 0xED]),
          isFalse,
        );
      }

      // Standalone Int32List (not a sublistView) also transmits as binary BLOB,
      // never JSON text.
      final standaloneI32 = Int32List.fromList([0x11223344]);
      final expectedStandalone = standaloneI32.buffer.asUint8List(
        standaloneI32.offsetInBytes,
        standaloneI32.lengthInBytes,
      );
      final rs = await stmt.execute([
        const Duration(hours: 4, minutes: 5, seconds: 6),
        standaloneI32,
      ]);
      expect(rs.rows.single.colAt(0), '04:05:06');
      expect(rs.rows.single.typedColAt<Uint8List>(1), expectedStandalone);

      await stmt.deallocate();
    });

    test('auto-prepared conn.execute(:t, :b) caches and sends exact slices',
        () async {
      final sentinel = Uint8List(320);
      sentinel.fillRange(0, 10, 0xDE);
      for (var i = 0; i < 300; i++) {
        sentinel[10 + i] = i & 0xff;
      }
      sentinel.fillRange(310, 320, 0xAD);

      final smallByteData = ByteData.sublistView(sentinel, 10, 16);
      final first = await conn.execute(
        'SELECT :t, :b',
        {
          't': const Duration(hours: 9, minutes: 8, seconds: 7),
          'b': smallByteData,
        },
      );
      expect(first.rows.single.colAt(0), '09:08:07');
      expect(first.rows.single.typedColAt<Uint8List>(1), [0, 1, 2, 3, 4, 5]);
      expect(conn.autoPreparedStatementCacheStats.misses, 1);
      expect(conn.autoPreparedStatementCacheStats.hits, 0);
      expect(server.preparedQueries, ['SELECT ?, ?']);
      expect(
        server.executedCommands.last.typeCodes,
        [mysqlColumnTypeTime, mysqlColumnTypeTinyBlob],
      );

      // Re-executing with negative Duration and Uint16List.sublistView <= 255B
      // hits the same auto-prepared cache entry ([timeType, tinyBlobType]).
      final smallU16 = Uint16List.sublistView(sentinel, 12, 20);
      final second = await conn.execute(
        'SELECT :t, :b',
        {
          't': -const Duration(days: 2, microseconds: 99),
          'b': smallU16,
        },
      );
      expect(second.rows.single.colAt(0), '-48:00:00.000099');
      expect(
        second.rows.single.typedColAt<Uint8List>(1),
        [2, 3, 4, 5, 6, 7, 8, 9],
      );
      expect(conn.autoPreparedStatementCacheStats.hits, 1);
      expect(conn.autoPreparedStatementCacheStats.misses, 1);
      expect(
        _containsSubsequence(
          server.executedCommands.last.rawPayload,
          [0xDE, 0xDE],
        ),
        isFalse,
      );
      expect(
        _containsSubsequence(
          server.executedCommands.last.rawPayload,
          [0xAD, 0xAD],
        ),
        isFalse,
      );

      // Crossing 255 bytes switches parameter type to blobType (cache miss)
      // and uses 0xfc length-encoded header without leaking sentinel bytes.
      final mediumByteData = ByteData.sublistView(sentinel, 10, 310);
      final third = await conn.execute(
        'SELECT :t, :b',
        {
          't': Duration.zero,
          'b': mediumByteData,
        },
      );
      expect(third.rows.single.colAt(0), '00:00:00');
      expect(
        third.rows.single.typedColAt<Uint8List>(1),
        List<int>.generate(300, (i) => i & 0xff),
      );
      expect(conn.autoPreparedStatementCacheStats.misses, 2);
      expect(
        server.executedCommands.last.typeCodes,
        [mysqlColumnTypeTime, mysqlColumnTypeBlob],
      );
      expect(
        _containsSubsequence(
          server.executedCommands.last.rawPayload,
          [0xDE, 0xDE],
        ),
        isFalse,
      );
      expect(
        _containsSubsequence(
          server.executedCommands.last.rawPayload,
          [0xAD, 0xAD],
        ),
        isFalse,
      );
    });

    test('out-of-range Duration fails fast without poisoning connection state',
        () async {
      await expectLater(
        conn.execute('SELECT :t, :b', {
          't': const Duration(hours: 839),
          'b': Uint8List.fromList([1]),
        }),
        throwsA(isA<MySQLClientException>()),
      );
      // Fails before COM_STMT_PREPARE is even sent to the server.
      expect(server.preparedQueries, isEmpty);

      final stmt = await conn.prepare('SELECT ?, ?');
      for (final invalid in [
        const Duration(hours: 839),
        -const Duration(hours: 839),
        const Duration(microseconds: _int64Min),
      ]) {
        await expectLater(
          stmt.execute([
            invalid,
            Uint8List.fromList([1])
          ]),
          throwsA(isA<MySQLClientException>()),
        );
      }
      expect(server.executedCommands, isEmpty);

      // Connection and statement remain healthy for subsequent valid calls.
      final valid = await stmt.execute([
        const Duration(minutes: 15),
        ByteData.sublistView(Uint8List.fromList([0xAA, 0x42, 0xBB]), 1, 2),
      ]);
      expect(valid.rows.single.colAt(0), '00:15:00');
      expect(valid.rows.single.typedColAt<Uint8List>(1), [0x42]);
    });
  });
}

Uint8List _encodeSingleTimeParam(Duration duration) {
  final payload = MySQLPacketCommStmtExecute(
    stmtID: 1,
    params: [duration],
    paramTypeCodes: Uint8List.fromList([mysqlColumnTypeTime]),
    sendTypes: true,
  ).encode();
  // cmd (1) + stmtID (4) + flags (1) + iter (4) + nullBitmap (1) +
  // sendTypes (1) + paramType/flag (2) = 14 bytes header.
  return Uint8List.sublistView(payload, 14);
}

(String, int) _decodeBinaryTime(Uint8List bytes) {
  final parsed = parseBinaryColumnData(
    mysqlColumnTypeTime,
    ByteData.sublistView(bytes),
    bytes,
    0,
  );
  return (parsed.$1 as String, parsed.$2);
}

List<int> _u32le(int value) => [
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

bool _containsSubsequence(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

class _RawSlicePayload extends MySQLPacketPayload {
  final Uint8List slice;

  _RawSlicePayload(this.slice);

  @override
  Uint8List encode() {
    final writer = ByteDataWriter(endian: Endian.little)..write(slice);
    return writer.toBytes();
  }
}

class _CapturedStmtExecute {
  final int stmtId;
  final bool sendTypes;
  final List<int> typeCodes;
  final Uint8List timeWireBytes;
  final Uint8List blobBytes;
  final Uint8List rawPayload;

  _CapturedStmtExecute({
    required this.stmtId,
    required this.sendTypes,
    required this.typeCodes,
    required this.timeWireBytes,
    required this.blobBytes,
    required this.rawPayload,
  });
}

/// Minimal loopback MySQL 4.1 binary-protocol server that completes native
/// handshake, prepares 2-param `(TIME, BLOB)` statements, captures raw
/// `COM_STMT_EXECUTE` payloads, and echoes parameters back as a binary row.
class _FakeMySqlBinaryServer {
  final ServerSocket _listener;
  final List<Socket> _clients = [];
  final List<String> preparedQueries = [];
  final List<_CapturedStmtExecute> executedCommands = [];
  final Map<int, List<int>> _lastStmtTypeCodes = {};
  int _nextStmtId = 0;

  _FakeMySqlBinaryServer._(this._listener) {
    _listener.listen(_handleClient);
  }

  int get port => _listener.port;

  static Future<_FakeMySqlBinaryServer> start() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeMySqlBinaryServer._(socket);
  }

  Future<void> close() async {
    for (final client in _clients) {
      client.destroy();
    }
    await _listener.close();
  }

  void _handleClient(Socket client) {
    _clients.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    client.done.ignore();
    client.add(_frame(0, _greetingPayload()));

    var authenticated = false;
    final pending = BytesBuilder(copy: false);

    client.listen(
      (chunk) {
        pending.add(chunk);
        final bytes = pending.takeBytes();
        var offset = 0;
        while (bytes.length - offset >= 4) {
          final length = bytes[offset] |
              (bytes[offset + 1] << 8) |
              (bytes[offset + 2] << 16);
          if (bytes.length - offset < 4 + length) break;
          final seq = bytes[offset + 3];
          final payload = Uint8List.fromList(
            bytes.sublist(offset + 4, offset + 4 + length),
          );
          offset += 4 + length;

          if (!authenticated) {
            authenticated = true;
            client.add(_frame(seq + 1, _okPayload()));
            continue;
          }

          if (payload.isEmpty) continue;
          switch (payload[0]) {
            case 0x01: // COM_QUIT
            case 0x19: // COM_STMT_CLOSE
              break;
            case 0x03: // COM_QUERY
              client.add(_frame(seq + 1, _okPayload()));
            case 0x16: // COM_STMT_PREPARE
              _handlePrepare(client, seq, payload);
            case 0x17: // COM_STMT_EXECUTE
              _handleExecute(client, seq, payload);
          }
        }
        if (offset < bytes.length) {
          pending.add(Uint8List.sublistView(bytes, offset));
        }
      },
      onError: (_) {},
      onDone: client.destroy,
    );
  }

  void _handlePrepare(Socket client, int seq, Uint8List payload) {
    final sql = utf8.decode(Uint8List.sublistView(payload, 1));
    preparedQueries.add(sql);
    final stmtId = ++_nextStmtId;
    final numParams = '?'.allMatches(sql).length;
    const numCols = 2;

    var outSeq = seq + 1;
    final out = BytesBuilder(copy: false);
    out.add(
      _frame(outSeq++, [
        0x00,
        ..._u32le(stmtId),
        numCols & 0xff,
        (numCols >> 8) & 0xff,
        numParams & 0xff,
        (numParams >> 8) & 0xff,
        0x00,
        0x00,
        0x00,
      ]),
    );
    for (var i = 0; i < numParams; i++) {
      out.add(
        _frame(
          outSeq++,
          _colDefPayload('p$i', mysqlColumnTypeVarString, charset: 45),
        ),
      );
    }
    if (numParams > 0) {
      out.add(_frame(outSeq++, _eofPayload()));
    }
    out.add(
      _frame(
        outSeq++,
        _colDefPayload('t', mysqlColumnTypeTime, charset: 63, decimals: 6),
      ),
    );
    out.add(
      _frame(
        outSeq++,
        _colDefPayload(
          'b',
          mysqlColumnTypeBlob,
          charset: 63,
          flags: 0x80,
        ),
      ),
    );
    out.add(_frame(outSeq++, _eofPayload()));
    client.add(out.takeBytes());
  }

  void _handleExecute(Socket client, int seq, Uint8List payload) {
    final data = ByteData.sublistView(payload);
    final stmtId = data.getUint32(1, Endian.little);
    // Fixed 2-param layout: nullBitmap (1 byte at 10), sendTypes (1 byte at 11).
    var offset = 11;
    final sendTypes = payload[offset++] == 1;
    final List<int> typeCodes;
    if (sendTypes) {
      typeCodes = [payload[offset], payload[offset + 2]];
      _lastStmtTypeCodes[stmtId] = typeCodes;
      offset += 4;
    } else {
      typeCodes = _lastStmtTypeCodes[stmtId]!;
    }

    // Read binary TIME wire field (1 + 0/8/12 bytes).
    final timeLen = payload[offset];
    final timeTotal = 1 + timeLen;
    final timeWireBytes = Uint8List.fromList(
      payload.sublist(offset, offset + timeTotal),
    );
    offset += timeTotal;

    // Read length-encoded BLOB slice.
    final (blobHeaderLen, blobLen) = _readLenEnc(payload, offset);
    offset += blobHeaderLen;
    final blobBytes = Uint8List.fromList(
      payload.sublist(offset, offset + blobLen),
    );

    executedCommands.add(
      _CapturedStmtExecute(
        stmtId: stmtId,
        sendTypes: sendTypes,
        typeCodes: typeCodes,
        timeWireBytes: timeWireBytes,
        blobBytes: blobBytes,
        rawPayload: payload,
      ),
    );

    // Echo [timeWireBytes, length-encoded blobBytes] in a binary result row.
    var outSeq = seq + 1;
    final out = BytesBuilder(copy: false)
      ..add(_frame(outSeq++, [2]))
      ..add(
        _frame(
          outSeq++,
          _colDefPayload('t', mysqlColumnTypeTime, charset: 63, decimals: 6),
        ),
      )
      ..add(
        _frame(
          outSeq++,
          _colDefPayload(
            'b',
            mysqlColumnTypeBlob,
            charset: 63,
            flags: 0x80,
          ),
        ),
      )
      ..add(_frame(outSeq++, _eofPayload()))
      ..add(
        _frame(outSeq++, [
          0x00, // binary row header
          0x00, // null bitmap for 2 columns: ((2 + 9) >> 3) == 1 byte
          ...timeWireBytes,
          ..._writeLenEnc(blobBytes.length),
          ...blobBytes,
        ]),
      )
      ..add(_frame(outSeq++, _eofPayload()));
    client.add(out.takeBytes());
  }

  static (int, int) _readLenEnc(Uint8List buf, int offset) {
    final first = buf[offset];
    if (first < 0xfb) return (1, first);
    if (first == 0xfc) {
      return (3, buf[offset + 1] | (buf[offset + 2] << 8));
    }
    throw StateError('Unexpected length-encoded prefix: $first');
  }

  static List<int> _writeLenEnc(int length) {
    if (length < 0xfb) return [length];
    return [0xfc, length & 0xff, (length >> 8) & 0xff];
  }

  static List<int> _greetingPayload() => [
        10,
        ...ascii.encode('8.0.0'),
        0,
        1, 0, 0, 0, // connection id
        ...ascii.encode('12345678'),
        0,
        0x00, 0x82, // CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION
        45, // utf8mb4
        2, 0, // server status
        0x08, 0x00, // CLIENT_PLUGIN_AUTH
        21,
        ...List<int>.filled(10, 0),
        ...ascii.encode('abcdefghijkl'),
        0,
        ...ascii.encode('mysql_native_password'),
        0,
      ];

  static List<int> _okPayload() => [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00];

  static List<int> _eofPayload() => [0xfe, 0x00, 0x00, 0x02, 0x00];

  static List<int> _colDefPayload(
    String name,
    int colType, {
    required int charset,
    int flags = 0,
    int decimals = 0,
  }) {
    final nameBytes = utf8.encode(name);
    return [
      3, ...ascii.encode('def'), // catalog
      0, // schema
      0, // table
      0, // org_table
      nameBytes.length, ...nameBytes, // name
      0, // org_name
      0x0c, // fixed-length fields
      charset & 0xff, (charset >> 8) & 0xff,
      0xff, 0x00, 0x00, 0x00, // column_length
      colType,
      flags & 0xff, (flags >> 8) & 0xff,
      decimals,
      0x00, 0x00, // filler
    ];
  }

  static Uint8List _frame(int seq, List<int> payload) => Uint8List.fromList([
        payload.length & 0xff,
        (payload.length >> 8) & 0xff,
        (payload.length >> 16) & 0xff,
        seq & 0xff,
        ...payload,
      ]);
}
