import 'dart:convert';
import 'dart:typed_data';
import 'package:buffer/buffer.dart' show ByteDataWriter;
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

class MySQLPacketCommInitDB extends MySQLPacketPayload {
  String schemaName;

  MySQLPacketCommInitDB({
    required this.schemaName,
  });

  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // command type
    buffer.writeUint8(2);
    buffer.write(utf8.encode(schemaName));

    return buffer.toBytes();
  }
}

class MySQLPacketCommQuery extends MySQLPacketPayload {
  String query;

  MySQLPacketCommQuery({
    required this.query,
  });

  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // command type
    buffer.writeUint8(3);
    buffer.write(utf8.encode(query));

    return buffer.toBytes();
  }
}

class MySQLPacketCommStmtPrepare extends MySQLPacketPayload {
  String query;

  MySQLPacketCommStmtPrepare({
    required this.query,
  });

  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // command type
    buffer.writeUint8(0x16);
    buffer.write(utf8.encode(query));

    return buffer.toBytes();
  }
}

class MySQLPacketCommStmtExecute extends MySQLPacketPayload {
  int stmtID;
  List<dynamic> params; // (type, value)
  List<MySQLColumnType?> paramTypes; // Stores the determined MySQL types

  MySQLPacketCommStmtExecute({
    required this.stmtID,
    required this.params,
    required this.paramTypes, // Add paramTypes
  });

  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // command type
    buffer.writeUint8(0x17);
    // stmt id
    buffer.writeUint32(stmtID, Endian.little);
    // flags
    buffer.writeUint8(0);
    // iteration count (always 1)
    buffer.writeUint32(1, Endian.little);

    // params
    if (params.isNotEmpty) {
      // create null-bitmap
      final bitmapSize = ((params.length + 7) / 8).floor();
      final nullBitmap = Uint8List(bitmapSize);

      // write null values into null bitmap
      for (int paramIndex = 0; paramIndex < params.length; paramIndex++) {
        if (params[paramIndex] == null) {
          final paramByteIndex = (paramIndex / 8).floor();
          final paramBitIndex = paramIndex % 8;
          nullBitmap[paramByteIndex] |= (1 << paramBitIndex);
        }
      }

      // write null bitmap
      buffer.write(nullBitmap);

      // write new-param-bound flag
      buffer.writeUint8(1);

      // write param types
      for (int i = 0; i < params.length; i++) {
        final param = params[i];
        final paramType = paramTypes[i];

        if (param == null) {
          buffer.writeUint8(mysqlColumnTypeNull);
          buffer.writeUint8(0); // Unused flag for null type
        } else {
          buffer.writeUint8(paramType!.intVal); // Use determined type
          buffer.writeUint8(0); // Unused flag, could be used for unsigned flag
        }
      }

      // adicionei write param values
      for (int i = 0; i < params.length; i++) {
        final param = params[i];
        final paramType = paramTypes[i];
        if (param != null) {
          _writeParamValue(buffer, param, paramType!); // Write binary data
        }
      }
    }

    return buffer.toBytes();
  }

  // adicionei isso
  void _writeParamValue(
      ByteDataWriter buffer, dynamic param, MySQLColumnType type) {
    switch (type.intVal) {
      case mysqlColumnTypeTiny:
        // Se o parâmetro for bool, converte para 1 ou 0.
        if (param is bool) {
          buffer.writeUint8(param ? 1 : 0);
        } else {
          buffer.writeUint8(param);
        }
        break;
      case mysqlColumnTypeShort:
        buffer.writeInt16(param);
        break;
      case mysqlColumnTypeLong:
      case mysqlColumnTypeInt24:
        buffer.writeInt32(param);
        break;
      case mysqlColumnTypeLongLong:
        buffer.writeInt64(param);
        break;
      case mysqlColumnTypeFloat:
        buffer.writeFloat32(param);
        break;
      case mysqlColumnTypeDouble:
        buffer.writeFloat64(param);
        break;
      case mysqlColumnTypeDate:
      case mysqlColumnTypeDateTime:
      case mysqlColumnTypeTimestamp:
        _writeDateTime(buffer, param);
        break;
      case mysqlColumnTypeTime:
        _writeTime(buffer, param);
        break;
      case mysqlColumnTypeString:
      case mysqlColumnTypeVarString:
      case mysqlColumnTypeVarChar:
      case mysqlColumnTypeEnum:
      case mysqlColumnTypeSet:
      case mysqlColumnTypeLongBlob:
      case mysqlColumnTypeMediumBlob:
      case mysqlColumnTypeBlob:
      case mysqlColumnTypeTinyBlob:
      case mysqlColumnTypeGeometry:
      case mysqlColumnTypeBit:
      case mysqlColumnTypeDecimal:
      case mysqlColumnTypeNewDecimal:
        final encodedData =
            (param is Uint8List) ? param : utf8.encode(param.toString());
        buffer.writeVariableEncInt(encodedData.length);
        buffer.write(encodedData);
        break;
      default:
        throw MySQLProtocolException(
            "Unsupported parameter type: ${type.intVal}");
    }
  }

  void _writeDateTime(ByteDataWriter buffer, DateTime dateTime) {
    final year = dateTime.year;
    final month = dateTime.month;
    final day = dateTime.day;
    final hour = dateTime.hour;
    final minute = dateTime.minute;
    final second = dateTime.second;
    final microsecond = dateTime.microsecond;

    if (year == 0 &&
        month == 0 &&
        day == 0 &&
        hour == 0 &&
        minute == 0 &&
        second == 0 &&
        microsecond == 0) {
      buffer.writeUint8(0); // 0 bytes
      return;
    }

    if (microsecond > 0) {
      buffer.writeUint8(11); // 11 bytes
      buffer.writeUint16(year);
      buffer.writeUint8(month);
      buffer.writeUint8(day);
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
      buffer.writeUint32(microsecond);
    } else if (hour > 0 || minute > 0 || second > 0) {
      buffer.writeUint8(7); // 7 bytes
      buffer.writeUint16(year);
      buffer.writeUint8(month);
      buffer.writeUint8(day);
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
    } else {
      buffer.writeUint8(4);
      buffer.writeUint16(year);
      buffer.writeUint8(month);
      buffer.writeUint8(day);
    }
  }

  void _writeTime(ByteDataWriter buffer, DateTime time) {
    final hour = time.hour;
    final minute = time.minute;
    final second = time.second;
    final microsecond = time.microsecond;
    if (hour == 0 && minute == 0 && second == 0 && microsecond == 0) {
      buffer.writeUint8(0); // 0 bytes
      return;
    }

    if (microsecond > 0) {
      buffer.writeUint8(12); // 12 bytes length
      buffer.writeUint8(0); // is negative
      buffer.writeUint32(0); // days
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
      buffer.writeUint32(microsecond);
    } else {
      buffer.writeUint8(8); // 8 bytes length
      buffer.writeUint8(0); // is negative
      buffer.writeUint32(0); // days
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
    }
  }
}

class MySQLPacketCommQuit extends MySQLPacketPayload {
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // command type
    buffer.writeUint8(1);

    return buffer.toBytes();
  }
}

class MySQLPacketCommStmtClose extends MySQLPacketPayload {
  int stmtID;

  MySQLPacketCommStmtClose({
    required this.stmtID,
  });

  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // command type
    buffer.writeUint8(0x19);
    buffer.writeUint32(stmtID);

    return buffer.toBytes();
  }
}
