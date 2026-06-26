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
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // O primeiro byte do pacote deve ser 0x00 (header).
    final type = byteData.getUint8(offset);
    offset += 1;
    if (type != 0) {
      throw MySQLProtocolException(
        "Cannot decode MySQLBinaryResultSetRowPacket: packet type is not 0x00",
      );
    }

    // Inicializa a lista de valores (pode conter diferentes tipos).
    final values = List<dynamic>.filled(colDefs.length, null, growable: false);

    // Calcula o tamanho do null bitmap.
    // O tamanho do bitmap é determinado por: ((numCols + 9) / 8).floor()
    final nullBitmapSize = (colDefs.length + 9) >> 3;
    final nullBitmapOffset = offset;
    offset += nullBitmapSize;

    // Itera sobre cada coluna para decodificar os dados.
    for (int x = 0; x < colDefs.length; x++) {
      // Determina qual byte e bit verificar no bitmap.
      final bit = x + 2;
      final bitmapByteIndex = bit >> 3;
      final bitmapBitIndex = bit & 7;
      final byteToCheck = buffer[nullBitmapOffset + bitmapByteIndex];
      final isNull = (byteToCheck & (1 << bitmapBitIndex)) != 0;

      if (isNull) {
        // Já inicializado com null.
      } else {
        final colDef = colDefs[x];
        final colType = colDef.type.intVal;
        if (_isLengthEncodedBinaryColumnType(colType)) {
          final packedLength = _readLengthEncodedHeader(buffer, offset);
          final headerLength = packedLength & 0x0f;
          final valueLength = packedLength >> 4;
          final valueStart = offset + headerLength;
          final valueEnd = valueStart + valueLength;

          if (valueEnd > buffer.length) {
            throw MySQLProtocolException(
              "Cannot decode MySQLBinaryResultSetRowPacket: length-encoded column exceeds packet size",
            );
          }

          final fieldBytes =
              Uint8List.sublistView(buffer, valueStart, valueEnd);
          offset = valueEnd;
          values[x] = _shouldDecodeLengthEncodedColumnAsText(
            colDef,
            textualColumns?[x],
          )
              ? utf8.decode(fieldBytes, allowMalformed: true)
              : fieldBytes;
          continue;
        }

        // Caso contrário, chama a função parseBinaryColumnData para ler o valor.
        final parseResult = parseBinaryColumnData(
          colType,
          byteData,
          buffer,
          offset,
        );
        // Avança o offset de acordo com o número de bytes lidos.
        offset += parseResult.item2;
        var value = parseResult.item1;
        if (value is Uint8List &&
            (textualColumns?[x] ?? columnShouldBeTextual(colDefs[x]))) {
          // Prepared statements also deliver textual blobs using the negotiated charset; decode accordingly.
          value = utf8.decode(value, allowMalformed: true);
        }
        values[x] = value;
      }
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

@pragma('vm:prefer-inline')
int _readLengthEncodedHeader(Uint8List buffer, int offset) {
  final first = buffer[offset];

  if (first < 0xfb) {
    return (first << 4) | 1;
  }

  if (first == 0xfc) {
    final value = buffer[offset + 1] | (buffer[offset + 2] << 8);
    return (value << 4) | 3;
  }

  if (first == 0xfd) {
    final value = buffer[offset + 1] |
        (buffer[offset + 2] << 8) |
        (buffer[offset + 3] << 16);
    return (value << 4) | 4;
  }

  if (first == 0xfe) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value |= buffer[offset + 1 + i] << (8 * i);
    }
    return (value << 4) | 9;
  }

  throw MySQLProtocolException(
    "Cannot decode MySQLBinaryResultSetRowPacket: invalid length-encoded column header",
  );
}
