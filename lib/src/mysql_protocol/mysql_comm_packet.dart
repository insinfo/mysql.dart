//mysql_comm_packet.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/src/utils/byte_data_writer.dart';

/// Representa o comando INIT DB no protocolo MySQL.
///
/// Esse comando é utilizado para selecionar um banco de dados específico logo após
/// a conexão ser estabelecida. O pacote contém:
/// - Um byte de comando (valor 2).
/// - O nome do schema (banco de dados) em formato UTF-8.
class MySQLPacketCommInitDB extends MySQLPacketPayload {
  /// Nome do schema (banco de dados) a ser selecionado.
  final String schemaName;

  /// Construtor da classe.
  MySQLPacketCommInitDB({
    required this.schemaName,
  });

  /// Codifica o comando INIT DB em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (2).
  /// 2. A string do schema em UTF-8.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando INIT DB (2)
    buffer.writeUint8(2);
    // Escreve o nome do schema (UTF-8)
    buffer.write(utf8.encode(schemaName));
    return buffer.toBytes();
  }
}

/// Representa o comando QUERY no protocolo MySQL.
///
/// Esse comando é utilizado para enviar uma consulta SQL ao servidor. O pacote contém:
/// - Um byte de comando (valor 3).
/// - A string da query em formato UTF-8.
class MySQLPacketCommQuery extends MySQLPacketPayload {
  /// Consulta SQL a ser executada.
  final String query;

  /// Construtor da classe.
  MySQLPacketCommQuery({
    required this.query,
  });

  /// Codifica o comando QUERY em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (3).
  /// 2. A query em UTF-8.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando QUERY (3)
    buffer.writeUint8(3);
    // Escreve a query em UTF-8
    buffer.write(utf8.encode(query));
    return buffer.toBytes();
  }
}

/// Representa o comando COM_STMT_PREPARE no protocolo MySQL.
///
/// Esse comando é utilizado para preparar uma instrução (statement) para execução
/// posterior como um prepared statement. O pacote contém:
/// - Um byte de comando (valor 0x16).
/// - A query a ser preparada, em formato UTF-8.
class MySQLPacketCommStmtPrepare extends MySQLPacketPayload {
  /// Consulta SQL que será preparada.
  final String query;

  /// Construtor da classe.
  MySQLPacketCommStmtPrepare({
    required this.query,
  });

  /// Codifica o comando COM_STMT_PREPARE em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (0x16).
  /// 2. A query em UTF-8.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando COM_STMT_PREPARE (0x16)
    buffer.writeUint8(0x16);
    // Escreve a query em UTF-8
    buffer.write(utf8.encode(query));
    return buffer.toBytes();
  }
}

/// Representa o comando COM_STMT_EXECUTE no protocolo MySQL.
///
/// Esse comando é utilizado para executar um prepared statement previamente preparado.
/// Ele inclui:
/// - Um byte de comando (valor 0x17).
/// - O ID do statement (stmtID) (4 bytes, little-endian).
/// - Flags (1 byte; atualmente fixo em 0).
/// - Um contador de iterações (4 bytes, little-endian; sempre 1).
/// - Dados dos parâmetros, que incluem:
///   - Um null-bitmap para indicar parâmetros nulos.
///   - Um flag para indicar se os tipos de parâmetros são novos.
///   - Os tipos de cada parâmetro (2 bytes por parâmetro: tipo e flag).
///   - Os valores dos parâmetros codificados de forma binária (se não nulos).
class MySQLPacketCommStmtExecute extends MySQLPacketPayload {
  /// ID do statement previamente preparado.
  final int stmtID;

  /// Lista de parâmetros para o statement.
  final List<dynamic> params;

  /// Tipos MySQL dos parâmetros em formato já serializado (1 byte por parâmetro).
  final Uint8List paramTypeCodes;

  /// Indica se os tipos precisam ser reenviados nesta execução.
  final bool sendTypes;

  /// Construtor da classe.
  MySQLPacketCommStmtExecute({
    required this.stmtID,
    required this.params,
    required this.paramTypeCodes,
    required this.sendTypes,
  });

  /// Codifica o comando COM_STMT_EXECUTE em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (0x17).
  /// 2. Statement ID (4 bytes, little-endian).
  /// 3. Flags (1 byte; atualmente 0).
  /// 4. Iteration count (4 bytes, little-endian; sempre 1).
  /// 5. Caso haja parâmetros:
  ///    - Null bitmap: Indica quais parâmetros são nulos (cada bit corresponde a 1 parâmetro).
  ///    - Flag de new parameter bound (1 byte; geralmente 1).
  ///    - Para cada parâmetro: 2 bytes (tipo e flags de unsigned, etc.).
  ///    - Para cada parâmetro não-nulo: o valor, no formato binário correspondente ao tipo.
  @override
  Uint8List encode() => _encode(0, 0);

  Uint8List encodePacket(int sequenceID) => _encode(4, sequenceID);

  Uint8List _encode(int packetHeaderSize, int sequenceID) {
    final paramCount = params.length;
    if (paramCount == 0) {
      final out = Uint8List(packetHeaderSize + 10);
      final data = out.buffer.asByteData();
      _writePacketHeader(out, packetHeaderSize, sequenceID, 10);
      final base = packetHeaderSize;
      out[base] = 0x17;
      data.setUint32(base + 1, stmtID, Endian.little);
      out[base + 5] = 0;
      data.setUint32(base + 6, 1, Endian.little);
      return out;
    }

    final bitmapSize = ((paramCount + 7) ~/ 8);
    final encodedValues = _hasVariableLengthParam(paramTypeCodes)
        ? List<List<int>?>.filled(paramCount, null)
        : null;
    var payloadLength = 10 + bitmapSize + 1 + (sendTypes ? paramCount * 2 : 0);

    for (var i = 0; i < paramCount; i++) {
      final param = params[i];
      if (param == null) {
        continue;
      }

      payloadLength += _encodedParamLength(
        param,
        paramTypeCodes[i],
        encodedValues,
        i,
      );
    }

    final out = Uint8List(packetHeaderSize + payloadLength);
    final data = out.buffer.asByteData();
    _writePacketHeader(out, packetHeaderSize, sequenceID, payloadLength);
    final base = packetHeaderSize;
    out[base] = 0x17;
    data.setUint32(base + 1, stmtID, Endian.little);
    out[base + 5] = 0;
    data.setUint32(base + 6, 1, Endian.little);

    var offset = base + 10;
    for (var i = 0; i < paramCount; i++) {
      if (params[i] == null) {
        out[offset + (i ~/ 8)] |= 1 << (i % 8);
      }
    }
    offset += bitmapSize;

    out[offset++] = sendTypes ? 1 : 0;
    if (sendTypes) {
      for (var i = 0; i < paramCount; i++) {
        out[offset++] = paramTypeCodes[i];
        out[offset++] = 0;
      }
    }

    for (var i = 0; i < paramCount; i++) {
      final param = params[i];
      if (param != null) {
        offset = _writeEncodedParamValue(
          out,
          data,
          offset,
          param,
          paramTypeCodes[i],
          encodedValues?[i],
        );
      }
    }

    return out;
  }

  void _writePacketHeader(
    Uint8List out,
    int packetHeaderSize,
    int sequenceID,
    int payloadLength,
  ) {
    if (packetHeaderSize == 0) {
      return;
    }

    out[0] = payloadLength & 0xff;
    out[1] = (payloadLength >> 8) & 0xff;
    out[2] = (payloadLength >> 16) & 0xff;
    out[3] = sequenceID;
  }

  int _encodedParamLength(
    dynamic param,
    int typeCode,
    List<List<int>?>? encodedValues,
    int paramIndex,
  ) {
    switch (typeCode) {
      case mysqlColumnTypeTiny:
        return 1;
      case mysqlColumnTypeShort:
        return 2;
      case mysqlColumnTypeLong:
      case mysqlColumnTypeInt24:
      case mysqlColumnTypeFloat:
        return 4;
      case mysqlColumnTypeLongLong:
      case mysqlColumnTypeDouble:
        return 8;
      case mysqlColumnTypeDate:
      case mysqlColumnTypeDateTime:
      case mysqlColumnTypeTimestamp:
        return _encodedDateTimeLength(param);
      case mysqlColumnTypeTime:
        return _encodedTimeLength(param);
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
        final encoded =
            param is Uint8List ? param : utf8.encode(param.toString());
        encodedValues![paramIndex] = encoded;
        return _lengthEncodedIntSize(encoded.length) + encoded.length;
      default:
        throw MySQLProtocolException(
          "Unsupported parameter type: $typeCode",
        );
    }
  }

  bool _hasVariableLengthParam(Uint8List typeCodes) {
    for (var i = 0; i < typeCodes.length; i++) {
      switch (typeCodes[i]) {
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
          return true;
      }
    }

    return false;
  }

  int _writeEncodedParamValue(
    Uint8List out,
    ByteData data,
    int offset,
    dynamic param,
    int typeCode,
    List<int>? encodedValue,
  ) {
    switch (typeCode) {
      case mysqlColumnTypeTiny:
        out[offset] = param is bool ? (param ? 1 : 0) : (param as int) & 0xff;
        return offset + 1;
      case mysqlColumnTypeShort:
        data.setInt16(offset, param as int, Endian.little);
        return offset + 2;
      case mysqlColumnTypeLong:
      case mysqlColumnTypeInt24:
        data.setInt32(offset, param as int, Endian.little);
        return offset + 4;
      case mysqlColumnTypeLongLong:
        data.setInt64(offset, param as int, Endian.little);
        return offset + 8;
      case mysqlColumnTypeFloat:
        data.setFloat32(offset, param as double, Endian.little);
        return offset + 4;
      case mysqlColumnTypeDouble:
        data.setFloat64(offset, param as double, Endian.little);
        return offset + 8;
      case mysqlColumnTypeDate:
      case mysqlColumnTypeDateTime:
      case mysqlColumnTypeTimestamp:
        return _writeDateTimeTo(out, data, offset, param as DateTime);
      case mysqlColumnTypeTime:
        return _writeTimeTo(out, data, offset, param as DateTime);
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
        final encoded = encodedValue!;
        offset = _writeLengthEncodedInt(out, data, offset, encoded.length);
        out.setRange(offset, offset + encoded.length, encoded);
        return offset + encoded.length;
      default:
        throw MySQLProtocolException(
          "Unsupported parameter type: $typeCode",
        );
    }
  }

  int _encodedDateTimeLength(DateTime dateTime) {
    if (dateTime.year == 0 &&
        dateTime.month == 0 &&
        dateTime.day == 0 &&
        dateTime.hour == 0 &&
        dateTime.minute == 0 &&
        dateTime.second == 0 &&
        dateTime.millisecond == 0 &&
        dateTime.microsecond == 0) {
      return 1;
    }

    if (dateTime.millisecond > 0 || dateTime.microsecond > 0) {
      return 12;
    }

    if (dateTime.hour > 0 || dateTime.minute > 0 || dateTime.second > 0) {
      return 8;
    }

    return 5;
  }

  int _encodedTimeLength(DateTime time) {
    if (time.hour == 0 &&
        time.minute == 0 &&
        time.second == 0 &&
        time.microsecond == 0) {
      return 1;
    }

    return time.microsecond > 0 ? 13 : 9;
  }

  int _writeDateTimeTo(
    Uint8List out,
    ByteData data,
    int offset,
    DateTime dateTime,
  ) {
    final year = dateTime.year;
    final month = dateTime.month;
    final day = dateTime.day;
    final hour = dateTime.hour;
    final minute = dateTime.minute;
    final second = dateTime.second;
    final millisecond = dateTime.millisecond;
    final microsecond = dateTime.microsecond;

    if (year == 0 &&
        month == 0 &&
        day == 0 &&
        hour == 0 &&
        minute == 0 &&
        second == 0 &&
        millisecond == 0 &&
        microsecond == 0) {
      out[offset] = 0;
      return offset + 1;
    }

    if (millisecond > 0 || microsecond > 0) {
      out[offset++] = 11;
      data.setUint16(offset, year, Endian.little);
      offset += 2;
      out[offset++] = month;
      out[offset++] = day;
      out[offset++] = hour;
      out[offset++] = minute;
      out[offset++] = second;
      data.setUint32(offset, microsecond + millisecond * 1000, Endian.little);
      return offset + 4;
    }

    if (hour > 0 || minute > 0 || second > 0) {
      out[offset++] = 7;
      data.setUint16(offset, year, Endian.little);
      offset += 2;
      out[offset++] = month;
      out[offset++] = day;
      out[offset++] = hour;
      out[offset++] = minute;
      out[offset++] = second;
      return offset;
    }

    out[offset++] = 4;
    data.setUint16(offset, year, Endian.little);
    offset += 2;
    out[offset++] = month;
    out[offset++] = day;
    return offset;
  }

  int _writeTimeTo(
    Uint8List out,
    ByteData data,
    int offset,
    DateTime time,
  ) {
    final hour = time.hour;
    final minute = time.minute;
    final second = time.second;
    final microsecond = time.microsecond;

    if (hour == 0 && minute == 0 && second == 0 && microsecond == 0) {
      out[offset] = 0;
      return offset + 1;
    }

    if (microsecond > 0) {
      out[offset++] = 12;
      out[offset++] = 0;
      data.setUint32(offset, 0, Endian.little);
      offset += 4;
      out[offset++] = hour;
      out[offset++] = minute;
      out[offset++] = second;
      data.setUint32(offset, microsecond, Endian.little);
      return offset + 4;
    }

    out[offset++] = 8;
    out[offset++] = 0;
    data.setUint32(offset, 0, Endian.little);
    offset += 4;
    out[offset++] = hour;
    out[offset++] = minute;
    out[offset++] = second;
    return offset;
  }

  int _lengthEncodedIntSize(int value) {
    if (value < 0xfb) {
      return 1;
    }
    if (value <= 0xffff) {
      return 3;
    }
    if (value <= 0xffffff) {
      return 4;
    }
    return 9;
  }

  int _writeLengthEncodedInt(
    Uint8List out,
    ByteData data,
    int offset,
    int value,
  ) {
    if (value < 0xfb) {
      out[offset] = value;
      return offset + 1;
    }

    if (value <= 0xffff) {
      out[offset] = 0xfc;
      data.setUint16(offset + 1, value, Endian.little);
      return offset + 3;
    }

    if (value <= 0xffffff) {
      out[offset] = 0xfd;
      out[offset + 1] = value & 0xff;
      out[offset + 2] = (value >> 8) & 0xff;
      out[offset + 3] = (value >> 16) & 0xff;
      return offset + 4;
    }

    out[offset] = 0xfe;
    data.setUint64(offset + 1, value, Endian.little);
    return offset + 9;
  }
}

/// Representa o comando COM_QUIT no protocolo MySQL.
///
/// Esse comando é utilizado para fechar a conexão com o servidor.
/// O pacote consiste apenas de um byte de comando (valor 1).
class MySQLPacketCommQuit extends MySQLPacketPayload {
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando QUIT (1)
    buffer.writeUint8(1);
    return buffer.toBytes();
  }
}

/// Representa o comando COM_STMT_CLOSE no protocolo MySQL.
///
/// Esse comando é utilizado para fechar um prepared statement e liberar
/// os recursos associados no servidor. O pacote contém:
/// - Um byte de comando (valor 0x19).
/// - O ID do statement (stmtID) (4 bytes, little-endian).
class MySQLPacketCommStmtClose extends MySQLPacketPayload {
  /// ID do statement a ser fechado.
  final int stmtID;

  /// Construtor da classe.
  MySQLPacketCommStmtClose({
    required this.stmtID,
  });

  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando COM_STMT_CLOSE (0x19)
    buffer.writeUint8(0x19);
    // Escreve o statement ID (4 bytes, little-endian)
    buffer.writeUint32(stmtID, Endian.little);
    return buffer.toBytes();
  }
}
