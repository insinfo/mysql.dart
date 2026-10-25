import 'dart:convert';
import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/exception.dart';
import '../column_utils.dart';

/// Representa um pacote de linha de result set no modo binário.
///
/// Esse pacote é utilizado quando o servidor envia um result set em formato
/// binário (por exemplo, para prepared statements). Ele contém os valores de cada
/// coluna, decodificados conforme os tipos definidos em [colDefs].
///
/// O pacote possui o seguinte formato:
/// - 1 byte de header (deve ser 0x00).
/// - Um bitmap de nulos que indica quais colunas possuem valor nulo.
/// - Os dados binários de cada coluna, conforme o tipo definido.
class MySQLBinaryResultSetRowPacket extends MySQLPacketPayload {
  /// Lista dos valores decodificados para cada coluna.
  /// Pode conter [Uint8List] para colunas binárias ou outros tipos (ex.: [String], [int], etc.).
  final List<dynamic> values;

  MySQLBinaryResultSetRowPacket({
    required this.values,
  });

  /// Decodifica um pacote de linha de result set no modo binário.
  ///
  /// [buffer] é o pacote recebido do servidor.
  /// [colDefs] é a lista de definições de coluna que contém os tipos de cada coluna.
  ///
  /// Retorna uma instância de [MySQLBinaryResultSetRowPacket] com os valores decodificados.
  ///
  /// Lança [MySQLProtocolException] se o header do pacote não for 0x00.
  factory MySQLBinaryResultSetRowPacket.decode(
      Uint8List buffer, List<MySQLColumnDefinitionPacket> colDefs,
      {List<bool>? textualColumns}) {
    if (buffer.isEmpty) {
      throw const MySQLProtocolException(
        'Cannot decode MySQLBinaryResultSetRowPacket: empty packet buffer',
      );
    }

    // O primeiro byte do pacote deve ser 0x00 (header).
    if (buffer[0] != 0) {
      throw const MySQLProtocolException(
        'Cannot decode MySQLBinaryResultSetRowPacket: packet type is not 0x00',
      );
    }

    final numCols = colDefs.length;
    // Inicializa a lista de valores (pode conter diferentes tipos).
    final values = List<dynamic>.filled(numCols, null, growable: false);
    if (numCols == 0) {
      return MySQLBinaryResultSetRowPacket(values: values);
    }

    // Calcula o tamanho do null bitmap.
    // O tamanho do bitmap é determinado por: ((numCols + 9) / 8).floor()
    final nullBitmapSize = (numCols + 9) >> 3;
    const nullBitmapOffset = 1;
    var offset = nullBitmapOffset + nullBitmapSize;
    if (offset > buffer.length) {
      throw const MySQLProtocolException(
        'Cannot decode MySQLBinaryResultSetRowPacket: truncated null bitmap',
      );
    }

    final byteData = ByteData.sublistView(buffer);

    // Itera sobre cada coluna para decodificar os dados.
    for (var x = 0; x < numCols; x++) {
      // Determina qual byte e bit verificar no bitmap.
      final bit = x + 2;
      final byteToCheck = buffer[nullBitmapOffset + (bit >> 3)];
      if ((byteToCheck & (1 << (bit & 7))) != 0) {
        // Já inicializado com null.
        continue;
      }

      final knownTextual = (textualColumns != null && x < textualColumns.length)
          ? textualColumns[x]
          : null;
      final decoded = _decodeBinaryRowColumn(
        colDefs[x],
        byteData,
        buffer,
        offset,
        knownTextual,
      );
      values[x] = decoded.value;
      offset = decoded.nextOffset;
    }

    return MySQLBinaryResultSetRowPacket(
      values: values,
    );
  }

  @override
  Uint8List encode() {
    throw UnimplementedError(
        "Encode not implemented for MySQLBinaryResultSetRowPacket");
  }
}

({dynamic value, int nextOffset}) _decodeBinaryRowColumn(
  MySQLColumnDefinitionPacket colDef,
  ByteData byteData,
  Uint8List buffer,
  int offset,
  bool? knownTextual,
) {
  final colType = colDef.type.intVal;
  if (_isLengthEncodedBinaryColumnType(colType)) {
    final slice = readLengthEncodedSlice(
      buffer,
      offset,
      buffer.length,
      allowNullMarker: false,
    );
    final fieldBytes = slice.bytes!;
    final value = _shouldDecodeLengthEncodedColumnAsText(colDef, knownTextual)
        ? utf8.decode(fieldBytes, allowMalformed: true)
        : fieldBytes;
    return (value: value, nextOffset: slice.nextOffset);
  }

  final parseResult = parseBinaryColumnData(
    colType,
    byteData,
    buffer,
    offset,
    unsigned: (colDef.flags & _unsignedFlag) != 0,
  );
  return (value: parseResult.$1, nextOffset: offset + parseResult.$2);
}

@pragma('vm:prefer-inline')
bool _isLengthEncodedBinaryColumnType(int colType) {
  switch (colType) {
    case mysqlColumnTypeString:
    case mysqlColumnTypeVarString:
    case mysqlColumnTypeVarChar:
    case mysqlColumnTypeEnum:
    case mysqlColumnTypeSet:
    case mysqlColumnTypeJson:
    case mysqlColumnTypeDecimal:
    case mysqlColumnTypeNewDecimal:
    case mysqlColumnTypeLongBlob:
    case mysqlColumnTypeMediumBlob:
    case mysqlColumnTypeBlob:
    case mysqlColumnTypeTinyBlob:
    case mysqlColumnTypeGeometry:
    case mysqlColumnTypeBit:
      return true;
    default:
      return false;
  }
}

@pragma('vm:prefer-inline')
bool _shouldDecodeLengthEncodedColumnAsText(
  MySQLColumnDefinitionPacket colDef,
  bool? knownTextualColumn,
) {
  final colType = colDef.type.intVal;
  switch (colType) {
    case mysqlColumnTypeString:
    case mysqlColumnTypeVarString:
    case mysqlColumnTypeVarChar:
    case mysqlColumnTypeEnum:
    case mysqlColumnTypeSet:
    case mysqlColumnTypeJson:
    case mysqlColumnTypeDecimal:
    case mysqlColumnTypeNewDecimal:
      return true;
    case mysqlColumnTypeLongBlob:
    case mysqlColumnTypeMediumBlob:
    case mysqlColumnTypeBlob:
    case mysqlColumnTypeTinyBlob:
      return knownTextualColumn ?? columnShouldBeTextual(colDef);
    default:
      return false;
  }
}

/// Column definition flag UNSIGNED_FLAG.
const int _unsignedFlag = 0x20;
