import 'dart:convert';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';
import 'package:mysql_dart/src/mysql_protocol/column_utils.dart';
import 'package:mysql_dart/src/mysql_protocol/packet/packet_empty_payload.dart';
import 'package:mysql_dart/src/utils/byte_data_writer.dart';
import 'package:test/test.dart';

void main() {
  group('Column utils', () {
    MySQLColumnDefinitionPacket blobColumn({
      required int charset,
      required int flags,
      int type = mysqlColumnTypeBlob,
    }) {
      return MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'col',
        orgName: 'col',
        charset: charset,
        columnLength: 255,
        type: MySQLColumnType.create(type),
        flags: flags,
        decimals: 0,
      );
    }

    test('binary blob is kept as bytes by binary collation', () {
      final colDef = blobColumn(charset: mysqlBinaryCollationId, flags: 0);
      expect(columnShouldBeBinary(colDef), isTrue);
      expect(columnShouldBeTextual(colDef), isFalse);
    });

    test('binary blob is kept as bytes by binary flag', () {
      final colDef = blobColumn(charset: 45, flags: mysqlColumnFlagBinary);
      expect(columnShouldBeBinary(colDef), isTrue);
    });

    test('textual blob remains textual when no binary hint exists', () {
      final colDef = blobColumn(charset: 45, flags: 0);
      expect(columnShouldBeBinary(colDef), isFalse);
      expect(columnShouldBeTextual(colDef), isTrue);
    });

    test('geometry and bit columns are always binary', () {
      final geometry = blobColumn(
        charset: 45,
        flags: 0,
        type: mysqlColumnTypeGeometry,
      );
      final bit = blobColumn(
        charset: 45,
        flags: 0,
        type: mysqlColumnTypeBit,
      );

      expect(columnShouldBeBinary(geometry), isTrue);
      expect(columnShouldBeBinary(bit), isTrue);
    });
  });

  group('Packet decode helpers', () {
    test('builds auth switch responses for native and caching sha2 auth', () {
      final challenge = Uint8List.fromList(
        List<int>.generate(20, (index) => index + 1),
      );

      final native = MySQLPacketAuthSwitchResponse.createWithNativePassword(
        password: 'dart',
        challenge: challenge,
      );
      final caching =
          MySQLPacketAuthSwitchResponse.createWithCachingSha2Password(
        password: 'dart',
        challenge: challenge,
      );
      final empty = MySQLPacketAuthSwitchResponse.createWithNativePassword(
        password: '',
        challenge: challenge,
      );

      expect(native.authData, hasLength(20));
      expect(caching.authData, hasLength(32));
      expect(empty.authData, isEmpty);
      expect(native.encode(), native.authData);
      expect(caching.encode(), caching.authData);
    });

    test('decodes auth switch request packet', () {
      final buffer = Uint8List.fromList([
        0xfe,
        ...utf8.encode('caching_sha2_password'),
        0x00,
        1,
        2,
        3,
        4,
      ]);

      final packet = MySQLPacketAuthSwitchRequest.decode(buffer);
      expect(packet.header, 0xfe);
      expect(packet.authPluginName, 'caching_sha2_password');
      expect(packet.authPluginData, [1, 2, 3, 4]);
    });

    test('decodes extra auth data packet and response encoding', () {
      final decoded = MySQLPacketExtraAuthData.decode(
        Uint8List.fromList([0x01, 0x02, 0x03]),
      );
      expect(decoded.header, 0x01);
      expect(decoded.pluginData, [0x02, 0x03]);

      final response = MySQLPacketExtraAuthDataResponse(
        data: Uint8List.fromList([0xaa, 0xbb]),
      );
      final responseNoNull = MySQLPacketExtraAuthDataResponse(
        data: Uint8List.fromList([0xaa, 0xbb]),
        appendNullTerminator: false,
      );
      expect(response.encode(), [0xaa, 0xbb, 0x00]);
      expect(responseNoNull.encode(), [0xaa, 0xbb]);
    });

    test('decodes EOF, OK, error and column count packets', () {
      final eof = MySQLPacketEOF.decode(
          Uint8List.fromList([0xfe, 0x00, 0x00, 0x08, 0x00]));
      expect(eof.header, 0xfe);
      expect(eof.statusFlags, mysqlServerFlagMoreResultsExists);

      final ok = MySQLPacketOK.decode(Uint8List.fromList([0x00, 0x02, 0x05]));
      expect(ok.header, 0x00);
      expect(ok.affectedRows, BigInt.from(2));
      expect(ok.lastInsertID, BigInt.from(5));

      final error = MySQLPacketError.decode(
        Uint8List.fromList([
          0xff,
          0x28,
          0x04,
          0x23,
          0x48,
          0x59,
          0x30,
          0x30,
          0x30,
          ...utf8.encode('Syntax error'),
        ]),
      );
      expect(error.header, 0xff);
      expect(error.errorCode, 1064);
      expect(error.errorMessage, 'Syntax error');

      final columnCount =
          MySQLPacketColumnCount.decode(Uint8List.fromList([0xfc, 0x2c, 0x01]));
      expect(columnCount.columnCount, BigInt.from(300));
    });

    test('decodes stmt prepare OK packet', () {
      final packet = MySQLPacketStmtPrepareOK.decode(
        Uint8List.fromList([
          0x00,
          0x39,
          0x30,
          0x00,
          0x00,
          0x02,
          0x00,
          0x03,
          0x00,
          0x00,
          0x01,
          0x00
        ]),
      );

      expect(packet.header, 0x00);
      expect(packet.stmtID, 12345);
      expect(packet.numOfCols, 2);
      expect(packet.numOfParams, 3);
      expect(packet.numOfWarnings, 1);
    });

    test('empty payload encode throws', () {
      expect(
        () => MySQLPacketEmptyPayload().encode(),
        throwsA(isA<UnimplementedError>()),
      );
    });
  });

  group('Column and row packet decoding', () {
    Uint8List lenStr(String value) {
      final writer = ByteDataWriter(endian: Endian.little);
      final bytes = utf8.encode(value);
      writer.writeVariableEncInt(bytes.length);
      writer.write(bytes);
      return writer.toBytes();
    }

    test('decodes column definition packet', () {
      final writer = ByteDataWriter(endian: Endian.little);
      writer.write(lenStr('def'));
      writer.write(lenStr('schema'));
      writer.write(lenStr('table'));
      writer.write(lenStr('org_table'));
      writer.write(lenStr('name'));
      writer.write(lenStr('org_name'));
      writer.writeVariableEncInt(0x0c);
      writer.writeUint16(45, Endian.little);
      writer.writeUint32(255, Endian.little);
      writer.writeUint8(mysqlColumnTypeVarString);
      writer.writeUint16(0x0001, Endian.little);
      writer.writeUint8(0);
      writer.writeUint16(0, Endian.little);

      final col = MySQLColumnDefinitionPacket.decode(writer.toBytes());
      expect(col.catalog, 'def');
      expect(col.schema, 'schema');
      expect(col.table, 'table');
      expect(col.orgTable, 'org_table');
      expect(col.name, 'name');
      expect(col.orgName, 'org_name');
      expect(col.charset, 45);
      expect(col.columnLength, 255);
      expect(col.type.intVal, mysqlColumnTypeVarString);
      expect(col.flags, 1);
    });

    test('decodes textual result row preserving blob bytes and utf8 text', () {
      final textCol = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'txt',
        orgName: 'txt',
        charset: 45,
        columnLength: 255,
        type: MySQLColumnType.varStringType,
        flags: 0,
        decimals: 0,
      );
      final blobCol = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'blob',
        orgName: 'blob',
        charset: mysqlBinaryCollationId,
        columnLength: 255,
        type: MySQLColumnType.blobType,
        flags: mysqlColumnFlagBinary,
        decimals: 0,
      );

      final writer = ByteDataWriter(endian: Endian.little);
      writer.write(lenStr('árvore'));
      writer.writeVariableEncInt(3);
      writer.write([1, 2, 3]);
      final row =
          MySQLResultSetRowPacket.decode(writer.toBytes(), [textCol, blobCol]);

      expect(row.values[0], 'árvore');
      expect(row.values[1], [1, 2, 3]);
    });

    test('decodes binary result row with null and textual blob fallback', () {
      final textBlobCol = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'blob_text',
        orgName: 'blob_text',
        charset: 45,
        columnLength: 255,
        type: MySQLColumnType.blobType,
        flags: 0,
        decimals: 0,
      );
      final intCol = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'num',
        orgName: 'num',
        charset: 45,
        columnLength: 11,
        type: MySQLColumnType.longType,
        flags: 0,
        decimals: 0,
      );
      final nullCol = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'nullable',
        orgName: 'nullable',
        charset: 45,
        columnLength: 11,
        type: MySQLColumnType.longType,
        flags: 0,
        decimals: 0,
      );

      final writer = ByteDataWriter(endian: Endian.little);
      writer.writeUint8(0x00);
      writer.writeUint8(0x10); // column index 2 marked as null
      writer.write(lenStr('olá'));
      writer.writeInt32(321, Endian.little);

      final row = MySQLBinaryResultSetRowPacket.decode(
        writer.toBytes(),
        [textBlobCol, intCol, nullCol],
      );

      expect(row.values[0], 'olá');
      expect(row.values[1], '321');
      expect(row.values[2], isNull);
    });

    test('binary result row rejects non-zero header', () {
      final col = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'num',
        orgName: 'num',
        charset: 45,
        columnLength: 11,
        type: MySQLColumnType.longType,
        flags: 0,
        decimals: 0,
      );

      expect(
        () => MySQLBinaryResultSetRowPacket.decode(
          Uint8List.fromList([0x01, 0x00]),
          [col],
        ),
        throwsA(isA<MySQLProtocolException>()),
      );
    });
  });

  group('MySQLPacket generic helpers', () {
    test('result set wrappers expose constructor data and throw on encode', () {
      final col = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'num',
        orgName: 'num',
        charset: 45,
        columnLength: 11,
        type: MySQLColumnType.longType,
        flags: 0,
        decimals: 0,
      );
      final textRow = MySQLResultSetRowPacket(values: ['1']);
      final binaryRow = MySQLBinaryResultSetRowPacket(values: ['1']);
      final resultSet = MySQLPacketResultSet(
        columnCount: BigInt.one,
        columns: [col],
        rows: [textRow],
      );
      final binaryResultSet = MySQLPacketBinaryResultSet(
        columnCount: BigInt.one,
        columns: [col],
        rows: [binaryRow],
      );

      expect(resultSet.columnCount, BigInt.one);
      expect(resultSet.columns.single.name, 'num');
      expect(resultSet.rows.single.values, ['1']);
      expect(binaryResultSet.rows.single.values, ['1']);
      expect(() => resultSet.encode(), throwsA(isA<UnimplementedError>()));
      expect(
        () => binaryResultSet.encode(),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('detects and decodes packet types', () {
      final okBuffer = Uint8List.fromList([
        0x07,
        0x00,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      final eofBuffer = Uint8List.fromList(
          [0x05, 0x00, 0x00, 0x01, 0xfe, 0x00, 0x00, 0x08, 0x00]);
      final errorBuffer = Uint8List.fromList([
        0x15,
        0x00,
        0x00,
        0x01,
        0xff,
        0x28,
        0x04,
        0x23,
        0x48,
        0x59,
        0x30,
        0x30,
        0x30,
        ...utf8.encode('Syntax error'),
      ]);
      final extraAuthBuffer =
          Uint8List.fromList([0x03, 0x00, 0x00, 0x01, 0x01, 0x04, 0x05]);

      expect(MySQLPacket.detectPacketType(okBuffer), MySQLGenericPacketType.ok);
      expect(
          MySQLPacket.detectPacketType(eofBuffer), MySQLGenericPacketType.eof);
      expect(MySQLPacket.detectPacketType(errorBuffer),
          MySQLGenericPacketType.error);

      expect(MySQLPacket.decodeGenericPacket(okBuffer).payload,
          isA<MySQLPacketOK>());
      expect(MySQLPacket.decodeGenericPacket(eofBuffer).payload,
          isA<MySQLPacketEOF>());
      expect(MySQLPacket.decodeGenericPacket(errorBuffer).payload,
          isA<MySQLPacketError>());
      expect(
        MySQLPacket.decodeGenericPacket(extraAuthBuffer).payload,
        isA<MySQLPacketExtraAuthData>(),
      );
    });

    test('decodeAuthSwitchRequestPacket rejects wrong packet type', () {
      final badPacket =
          Uint8List.fromList([0x02, 0x00, 0x00, 0x01, 0x00, 0x00]);
      expect(
        () => MySQLPacket.decodeAuthSwitchRequestPacket(badPacket),
        throwsA(isA<MySQLProtocolException>()),
      );
    });

    test('encodes packet header and payload bytes', () {
      final packet = MySQLPacket(
        sequenceID: 7,
        payloadLength: 0,
        payload: MySQLPacketExtraAuthDataResponse(
          data: Uint8List.fromList([0xaa, 0xbb]),
        ),
      );

      expect(packet.encode(), [0x03, 0x00, 0x00, 0x07, 0xaa, 0xbb, 0x00]);
    });

    test('stmt execute packet can skip resending parameter types', () {
      final withTypes = MySQLPacketCommStmtExecute(
        stmtID: 99,
        params: [40, 2],
        paramTypeCodes: Uint8List.fromList(
          [mysqlColumnTypeTiny, mysqlColumnTypeTiny],
        ),
        sendTypes: true,
      ).encode();

      final withoutTypes = MySQLPacketCommStmtExecute(
        stmtID: 99,
        params: [40, 2],
        paramTypeCodes: Uint8List.fromList(
          [mysqlColumnTypeTiny, mysqlColumnTypeTiny],
        ),
        sendTypes: false,
      ).encode();

      expect(withTypes[11], 1);
      expect(withoutTypes[11], 0);
      expect(withTypes.length, greaterThan(withoutTypes.length));
      expect(withoutTypes.sublist(withoutTypes.length - 2), [40, 2]);
    });
  });
}
