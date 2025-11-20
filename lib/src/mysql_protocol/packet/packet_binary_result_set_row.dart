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
    Uint8List buffer,
    List<MySQLColumnDefinitionPacket> colDefs,
  ) {
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
    List<dynamic> values = [];

    // Calcula o tamanho do null bitmap.
    // O tamanho do bitmap é determinado por: ((numCols + 9) / 8).floor()
    int nullBitmapSize = ((colDefs.length + 9) / 8).floor();

    // Obtém o null bitmap a partir do buffer.
    final nullBitmap = Uint8List.sublistView(
      buffer,
      offset,
      offset + nullBitmapSize,
    );
    offset += nullBitmapSize;

    // Itera sobre cada coluna para decodificar os dados.
    for (int x = 0; x < colDefs.length; x++) {
      // Determina qual byte e bit verificar no bitmap.
      final bitmapByteIndex = ((x + 2) / 8).floor();
      final bitmapBitIndex = (x + 2) % 8;
      final byteToCheck = nullBitmap[bitmapByteIndex];
      final isNull = (byteToCheck & (1 << bitmapBitIndex)) != 0;

      if (isNull) {
        // Se o bit correspondente está setado, o valor da coluna é NULL.
        values.add(null);
      } else {
        // Caso contrário, chama a função parseBinaryColumnData para ler o valor.
        final parseResult = parseBinaryColumnData(
          colDefs[x].type.intVal,
          byteData,
          buffer,
          offset,
        );
        // Avança o offset de acordo com o número de bytes lidos.
        offset += parseResult.item2;
        var value = parseResult.item1;
        if (value is Uint8List && columnShouldBeTextual(colDefs[x])) {
          value = String.fromCharCodes(value);
        }
        values.add(value);
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
