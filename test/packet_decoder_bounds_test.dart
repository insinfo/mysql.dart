import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

Matcher _throwsProtocolException() => throwsA(isA<MySQLProtocolException>());

void main() {
  group('MySQLPacket header and envelope bounds', () {
    test('rejects truncated or negative-offset headers', () {
      expect(
        () => MySQLPacket.getPayloadLength(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getPayloadLength(_bytes(const [0x01, 0x00])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getPayloadLength(
          _bytes(const [0x01, 0x00, 0x00, 0x01]),
          -1,
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getPayloadLength(
          _bytes(const [0x01, 0x00, 0x00, 0x01]),
          2,
        ),
        _throwsProtocolException(),
      );

      expect(
        () => MySQLPacket.getSequenceId(_bytes(const [0x01, 0x00, 0x00])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getSequenceId(
          _bytes(const [0x01, 0x00, 0x00, 0x01]),
          -1,
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getSequenceId(
          _bytes(const [0x01, 0x00, 0x00, 0x01]),
          1,
        ),
        _throwsProtocolException(),
      );

      expect(
        () => MySQLPacket.getPacketLength(_bytes(const [0x01, 0x00, 0x00])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getPacketLength(
          _bytes(const [0x01, 0x00, 0x00, 0x01]),
          -1,
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodePacketHeader(_bytes(const [0x01, 0x00, 0x00])),
        _throwsProtocolException(),
      );
    });

    test('rejects near-max-int64 header offsets without signed overflow', () {
      const maxInt64 = 0x7fffffffffffffff;
      final fiveBytes = Uint8List(5);
      expect(
        () => MySQLPacket.getPayloadLength(fiveBytes, maxInt64),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getPayloadLength(fiveBytes, maxInt64 - 2),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getSequenceId(fiveBytes, maxInt64),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getSequenceId(fiveBytes, maxInt64 - 3),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getPacketLength(fiveBytes, maxInt64),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.getPacketLength(fiveBytes, maxInt64 - 3),
        _throwsProtocolException(),
      );
    });

    test('detectPacketType handles empty and truncated envelopes safely', () {
      // Valid 0-length MySQL packet header (4 bytes total, empty payload).
      expect(
        MySQLPacket.detectPacketType(_bytes(const [0x00, 0x00, 0x00, 0x00])),
        MySQLGenericPacketType.other,
      );

      // Header declares 10 payload bytes, 0 available.
      expect(
        () => MySQLPacket.detectPacketType(
          _bytes(const [0x0a, 0x00, 0x00, 0x01]),
        ),
        _throwsProtocolException(),
      );

      // Header declares 7-byte OK packet, only 1 payload byte present.
      expect(
        () => MySQLPacket.detectPacketType(
          _bytes(const [0x07, 0x00, 0x00, 0x01, 0x00]),
        ),
        _throwsProtocolException(),
      );
    });

    test('envelope decoders reject empty and truncated packet frames', () {
      final emptyPacket = _bytes(const [0x00, 0x00, 0x00, 0x01]);
      expect(
        () => MySQLPacket.decodeInitialHandshake(emptyPacket),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeAuthSwitchRequestPacket(emptyPacket),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeGenericPacket(emptyPacket),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeColumnCountPacket(emptyPacket),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeColumnDefPacket(emptyPacket),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeCommPrepareStmtResponsePacket(emptyPacket),
        _throwsProtocolException(),
      );

      // Header declares 7 bytes for OK, but buffer only has 1 payload byte.
      final truncatedOk = _bytes(const [0x07, 0x00, 0x00, 0x01, 0x00]);
      expect(
        () => MySQLPacket.decodeGenericPacket(truncatedOk),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeColumnCountPacket(truncatedOk),
        _throwsProtocolException(),
      );

      // Short 0x00 payload (< 7 bytes) in COM_QUERY response must not decode as
      // MySQLPacketOK when detectPacketType classifies it as other.
      expect(
        () => MySQLPacket.decodeColumnCountPacket(
          _bytes(const [0x03, 0x00, 0x00, 0x01, 0x00, 0x01, 0x02]),
        ),
        _throwsProtocolException(),
      );

      // Unsupported generic packet type byte.
      expect(
        () => MySQLPacket.decodeGenericPacket(
          _bytes(const [0x01, 0x00, 0x00, 0x01, 0x02]),
        ),
        _throwsProtocolException(),
      );
    });

    test('envelope decoders slice payload to declared header length', () {
      // First packet declares 1 byte ([0xfe]), followed by trailing bytes of a
      // second packet; must reject the 1-byte EOF rather than reading past end.
      final coalescedBuffer = _bytes(
        const [0x01, 0x00, 0x00, 0x01, 0xfe, 0x00, 0x00, 0x08, 0x00],
      );
      expect(
        () => MySQLPacket.decodeGenericPacket(coalescedBuffer),
        _throwsProtocolException(),
      );

      // 5-byte EOF packet followed by extra bytes from a subsequent packet.
      final validEofWithTrailing = _bytes(const [
        0x05,
        0x00,
        0x00,
        0x02,
        0xfe,
        0x00,
        0x00,
        0x08,
        0x00,
        0xaa,
        0xbb,
        0xcc,
        0xdd,
      ]);
      final decoded = MySQLPacket.decodeGenericPacket(validEofWithTrailing);
      expect(decoded.sequenceID, 2);
      expect(decoded.payloadLength, 5);
      expect(decoded.payload, isA<MySQLPacketEOF>());
    });

    test('preserves reassembled multi-packet payloads with 0xffffff header',
        () {
      // Simulate connection packet reassembly: 4-byte header with 0xffffff
      // length followed by > 0xffffff payload bytes (ExtraAuthData 0x01 + data).
      const reassembledPayloadLen = mysqlMaxPacketPayloadLength + 5;
      final reassembled = Uint8List(4 + reassembledPayloadLen);
      reassembled[0] = 0xff;
      reassembled[1] = 0xff;
      reassembled[2] = 0xff;
      reassembled[3] = 0x03;
      reassembled[4] = 0x01;
      reassembled[reassembled.length - 1] = 0x7f;

      final packet = MySQLPacket.decodeGenericPacket(reassembled);
      expect(packet.sequenceID, 3);
      expect(packet.payloadLength, reassembledPayloadLen);
      final extra = packet.payload as MySQLPacketExtraAuthData;
      expect(extra.pluginData.length, reassembledPayloadLen - 1);
      expect(extra.pluginData.last, 0x7f);
    });
  });

  group('MySQLPacketInitialHandshake.decode bounds', () {
    List<int> buildMinimalHandshake({
      int protocolVersion = 10,
      List<int> serverVersion = const [0x38, 0x2e, 0x30, 0x00],
      int capLower = 0x0000,
      int capUpper = 0x0000,
      int authPluginDataLen = 0,
      List<int> trailing = const [],
    }) {
      return <int>[
        protocolVersion,
        ...serverVersion,
        0x01, 0x00, 0x00, 0x00, // connectionID
        1, 2, 3, 4, 5, 6, 7, 8, // authPluginDataPart1
        0x00, // filler
        capLower & 0xff,
        (capLower >> 8) & 0xff,
        0x21, // charset
        0x02, 0x00, // statusFlags
        capUpper & 0xff,
        (capUpper >> 8) & 0xff,
        authPluginDataLen,
        ...List<int>.filled(10, 0), // reserved
        ...trailing,
      ];
    }

    test('rejects empty buffer, non-V10 protocol, and unterminated version',
        () {
      expect(
        () => MySQLPacketInitialHandshake.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketInitialHandshake.decode(
          _bytes(buildMinimalHandshake(protocolVersion: 9)),
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketInitialHandshake.decode(
          _bytes(buildMinimalHandshake(protocolVersion: 0xff)),
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketInitialHandshake.decode(
          _bytes(const [0x0a, 0x38, 0x2e, 0x30]),
        ),
        _throwsProtocolException(),
      );
    });

    test('rejects truncated fixed handshake fields after serverVersion', () {
      final full = buildMinimalHandshake();
      // Removing even 1 byte from the 31-byte fixed region must fail cleanly.
      for (final cut in <int>[2, 6, 15, 17, 18, 20, 22, 23, full.length - 1]) {
        expect(
          () => MySQLPacketInitialHandshake.decode(
            _bytes(full.sublist(0, cut)),
          ),
          _throwsProtocolException(),
          reason: 'Expected MySQLProtocolException at truncated length $cut',
        );
      }
    });

    test('rejects truncated authPluginDataPart2 and missing authPluginName',
        () {
      // CLIENT_SECURE_CONNECTION (0x8000) requires at least 13 bytes in part 2.
      expect(
        () => MySQLPacketInitialHandshake.decode(
          _bytes(
            buildMinimalHandshake(
              capLower: 0x8000,
              trailing: List<int>.filled(12, 0x41),
            ),
          ),
        ),
        _throwsProtocolException(),
      );

      // CLIENT_SECURE_CONNECTION + CLIENT_PLUGIN_AUTH (capUpper 0x0008) with
      // authPluginDataLen = 40 requires max(13, 32) = 32 bytes in part 2.
      expect(
        () => MySQLPacketInitialHandshake.decode(
          _bytes(
            buildMinimalHandshake(
              capLower: 0x8000,
              capUpper: 0x0008,
              authPluginDataLen: 40,
              trailing: List<int>.filled(20, 0x41),
            ),
          ),
        ),
        _throwsProtocolException(),
      );

      // CLIENT_PLUGIN_AUTH set, part 2 satisfied (13 bytes), but 0 bytes left
      // for authPluginName.
      expect(
        () => MySQLPacketInitialHandshake.decode(
          _bytes(
            buildMinimalHandshake(
              capLower: 0x8000,
              capUpper: 0x0008,
              authPluginDataLen: 21,
              trailing: List<int>.filled(13, 0x41),
            ),
          ),
        ),
        _throwsProtocolException(),
      );
    });

    test('accepts EOF-terminated authPluginName without trailing NUL', () {
      // MySQL Bug#59453: older servers omit trailing NUL on authPluginName.
      final hs = MySQLPacketInitialHandshake.decode(
        _bytes(
          buildMinimalHandshake(
            capLower: 0x8000,
            capUpper: 0x0008,
            authPluginDataLen: 21,
            trailing: <int>[
              ...List<int>.filled(13, 0x41),
              ...'mysql_native_password'.codeUnits,
            ],
          ),
        ),
      );
      expect(hs.authPluginName, 'mysql_native_password');
    });
  });

  group('Control packet decoder bounds', () {
    test('MySQLPacketAuthSwitchRequest rejects empty, bad header, and no NUL',
        () {
      expect(
        () => MySQLPacketAuthSwitchRequest.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketAuthSwitchRequest.decode(
          _bytes(const [0x00, 0x61, 0x00]),
        ),
        _throwsProtocolException(),
      );
      // 1-byte OldAuthSwitchRequest (0xfe) has no NUL-terminated plugin name.
      expect(
        () => MySQLPacketAuthSwitchRequest.decode(_bytes(const [0xfe])),
        _throwsProtocolException(),
      );
      // Unterminated plugin name string.
      expect(
        () => MySQLPacketAuthSwitchRequest.decode(
          _bytes(const [0xfe, 0x61, 0x62, 0x63]),
        ),
        _throwsProtocolException(),
      );
    });

    test('MySQLPacketOK rejects empty, bad header, and truncated/0xfb ints',
        () {
      expect(
        () => MySQLPacketOK.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketOK.decode(_bytes(const [0xff, 0x00, 0x00])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketOK.decode(_bytes(const [0x00])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketOK.decode(_bytes(const [0x00, 0x01])),
        _throwsProtocolException(),
      );
      // Truncated 2-byte lenenc_int for affectedRows.
      expect(
        () => MySQLPacketOK.decode(_bytes(const [0x00, 0xfc, 0x01])),
        _throwsProtocolException(),
      );
      // 0xfb NULL marker is invalid for affectedRows / lastInsertID.
      expect(
        () => MySQLPacketOK.decode(_bytes(const [0x00, 0xfb, 0x00])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketOK.decode(_bytes(const [0x00, 0x00, 0xfb])),
        _throwsProtocolException(),
      );
      // Truncated 2-byte lenenc_int for lastInsertID.
      expect(
        () => MySQLPacketOK.decode(_bytes(const [0x00, 0x01, 0xfc, 0x02])),
        _throwsProtocolException(),
      );

      // Valid 0xfe OK packet (CLIENT_DEPRECATE_EOF) still decodes cleanly.
      final deprecateEofOk = MySQLPacketOK.decode(
        _bytes(const [0xfe, 0x01, 0x02, 0x08, 0x00, 0x00, 0x00]),
      );
      expect(deprecateEofOk.header, 0xfe);
      expect(deprecateEofOk.affectedRows, BigInt.one);
      expect(deprecateEofOk.lastInsertID, BigInt.two);
      expect(deprecateEofOk.statusFlags, mysqlServerFlagMoreResultsExists);
    });

    test('MySQLPacketEOF rejects < 5 bytes, >= 9 bytes, and non-0xfe header',
        () {
      expect(
        () => MySQLPacketEOF.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketEOF.decode(_bytes(const [0xfe])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketEOF.decode(_bytes(const [0xfe, 0x00, 0x00, 0x08])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketEOF.decode(
          _bytes(const [0x00, 0x00, 0x00, 0x08, 0x00]),
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketEOF.decode(
          _bytes(const [0xfe, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeGenericPacket(
          _bytes(const [0x01, 0x00, 0x00, 0x01, 0xfe]),
        ),
        _throwsProtocolException(),
      );
    });

    test('MySQLPacketColumnCount rejects empty, zero, 0xfb, and truncated ints',
        () {
      expect(
        () => MySQLPacketColumnCount.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketColumnCount.decode(_bytes(const [0x00])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketColumnCount.decode(_bytes(const [0xfb])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketColumnCount.decode(_bytes(const [0xfc, 0x01])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketColumnCount.decode(_bytes(const [0xff])),
        _throwsProtocolException(),
      );
    });

    test('MySQLColumnDefinitionPacket rejects truncated strings and fixed tail',
        () {
      expect(
        () => MySQLColumnDefinitionPacket.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      // Truncated first length-encoded string (declares 5 bytes, only 1 left).
      expect(
        () => MySQLColumnDefinitionPacket.decode(_bytes(const [0x05, 0x61])),
        _throwsProtocolException(),
      );
      // 0xfb NULL marker in column metadata string.
      expect(
        () => MySQLColumnDefinitionPacket.decode(
          _bytes(const [
            0xfb,
            0,
            0,
            0,
            0,
            0,
            0x0c,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0
          ]),
        ),
        _throwsProtocolException(),
      );
      // 6 empty strings with missing fixed-length fields length byte.
      expect(
        () => MySQLColumnDefinitionPacket.decode(
          _bytes(const [0, 0, 0, 0, 0, 0]),
        ),
        _throwsProtocolException(),
      );
      // Fixed-fields length smaller than 0x0c.
      expect(
        () => MySQLColumnDefinitionPacket.decode(
          _bytes(const [0, 0, 0, 0, 0, 0, 0x04, 0, 0, 0, 0]),
        ),
        _throwsProtocolException(),
      );
      // Declares 0x0c fixed bytes, but only 11 bytes remain (missing filler).
      expect(
        () => MySQLColumnDefinitionPacket.decode(
          _bytes(const [
            0, 0, 0, 0, 0, 0, // 6 empty strings
            0x0c, // fixed length = 12
            0x21, 0x00, // charset
            0x0b, 0x00, 0x00, 0x00, // columnLength
            0x03, // colType
            0x00, 0x00, // flags
            0x00, // decimals
            0x00, // only 1 byte of 2-byte filler
          ]),
        ),
        _throwsProtocolException(),
      );
    });

    test('MySQLPacketStmtPrepareOK rejects < 12 bytes and non-0x00 header', () {
      expect(
        () => MySQLPacketStmtPrepareOK.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketStmtPrepareOK.decode(
          _bytes(const [0x00, 1, 0, 0, 0, 2, 0, 3, 0, 0, 1]),
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketStmtPrepareOK.decode(
          _bytes(const [0x01, 1, 0, 0, 0, 2, 0, 3, 0, 0, 1, 0]),
        ),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacket.decodeCommPrepareStmtResponsePacket(
          _bytes(const [0x01, 0x00, 0x00, 0x01, 0x00]),
        ),
        _throwsProtocolException(),
      );
    });

    test('MySQLPacketExtraAuthData rejects empty buffer and non-0x01 header',
        () {
      expect(
        () => MySQLPacketExtraAuthData.decode(_bytes(const [])),
        _throwsProtocolException(),
      );
      expect(
        () => MySQLPacketExtraAuthData.decode(_bytes(const [0x02, 0x03])),
        _throwsProtocolException(),
      );

      // 1-byte ExtraAuthData with empty pluginData remains valid.
      final emptyExtra = MySQLPacketExtraAuthData.decode(_bytes(const [0x01]));
      expect(emptyExtra.header, 0x01);
      expect(emptyExtra.pluginData, isEmpty);
    });

    test('decodes non-UTF-8 wire strings without throwing FormatException', () {
      // Column definition with raw latin1/non-UTF-8 bytes in metadata strings.
      final colDef = MySQLColumnDefinitionPacket.decode(
        _bytes(const [
          0x01, 0xff, // catalog
          0x01, 0xfe, // schema
          0x02, 0xc3, 0x28, // table
          0x00, // orgTable
          0x02, 0xa0, 0xa1, // name
          0x00, // orgName
          0x0c, // fixed length = 12
          0x08, 0x00, // latin1 charset
          0x10, 0x00, 0x00, 0x00, // columnLength
          0xfd, // varString
          0x00, 0x00, // flags
          0x00, // decimals
          0x00, 0x00, // filler
        ]),
      );
      expect(colDef.catalog, isNotEmpty);
      expect(colDef.name, isNotEmpty);

      // Initial handshake with non-UTF-8 serverVersion and authPluginName.
      final hs = MySQLPacketInitialHandshake.decode(
        _bytes(<int>[
          0x0a, // protocol V10
          0x38, 0xff, 0xfe, 0x00, // serverVersion + NUL
          0x01, 0x00, 0x00, 0x00, // connectionID
          1, 2, 3, 4, 5, 6, 7, 8, // authPluginDataPart1
          0x00, // filler
          0x00, 0x80, // capLower: CLIENT_SECURE_CONNECTION
          0x21, // charset
          0x02, 0x00, // statusFlags
          0x08, 0x00, // capUpper: CLIENT_PLUGIN_AUTH
          21, // authPluginDataLength
          ...List<int>.filled(10, 0), // reserved
          ...List<int>.filled(13, 0x41), // authPluginDataPart2
          0xff, 0xfe, 0x00, // non-UTF-8 authPluginName + NUL
        ]),
      );
      expect(hs.serverVersion, isNotEmpty);
      expect(hs.authPluginName, isNotEmpty);

      // AuthSwitchRequest with non-UTF-8 plugin name bytes.
      final authSwitch = MySQLPacketAuthSwitchRequest.decode(
        _bytes(const [0xfe, 0xff, 0xfe, 0x00, 0x01, 0x02]),
      );
      expect(authSwitch.header, 0xfe);
      expect(authSwitch.authPluginName, isNotEmpty);
      expect(authSwitch.authPluginData, const [0x01, 0x02]);
    });
  });
}
