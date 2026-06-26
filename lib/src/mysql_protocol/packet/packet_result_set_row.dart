import 'dart:convert';
import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import '../column_utils.dart';

/// Representa um pacote de linha de resultado recebido do servidor MySQL.
///
/// Esse pacote pode conter dados de linhas obtidas através de uma consulta (query)
/// feita com protocolo **textual** (não binário). Cada coluna vem como
/// length-encoded data, que pode representar texto ou bytes (caso de BLOB).
class MySQLResultSetRowPacket extends MySQLPacketPayload {
  /// Lista dos valores decodificados para cada coluna da linha.
  final List<dynamic> values;

  MySQLResultSetRowPacket({
    required this.values,
  });

  /// Decodifica um [Uint8List] recebido do servidor como uma linha de resultado,
  /// considerando que estamos no **protocolo textual**. Para cada coluna:
  ///
  /// - Se for 0xFB, o valor é `NULL`;
  /// - Caso contrário, lê-se o campo como length-encoded data.
  ///   - Se a coluna for BLOB/BINÁRIO, mantém como [Uint8List];
  ///   - Senão, converte para [String].
  factory MySQLResultSetRowPacket.decode(
      Uint8List buffer, List<MySQLColumnDefinitionPacket> columns,
      {List<bool>? binaryColumns}) {
    int offset = 0;
    final values = List<dynamic>.filled(columns.length, null, growable: false);

    for (int x = 0; x < columns.length; x++) {
      final colDef = columns[x];
      final nextByte = buffer[offset];

      // 0xFB = NULL
      if (nextByte == 0xfb) {
        offset++;
      } else {
        late final int valueLength;
        late final int headerLength;

        if (nextByte < 0xfb) {
          valueLength = nextByte;
          headerLength = 1;
        } else if (nextByte == 0xfc) {
          valueLength = buffer[offset + 1] | (buffer[offset + 2] << 8);
          headerLength = 3;
        } else if (nextByte == 0xfd) {
          valueLength = buffer[offset + 1] |
              (buffer[offset + 2] << 8) |
              (buffer[offset + 3] << 16);
          headerLength = 4;
        } else if (nextByte == 0xfe) {
          final low = buffer[offset + 1] |
              (buffer[offset + 2] << 8) |
              (buffer[offset + 3] << 16) |
              (buffer[offset + 4] << 24);
          final high = buffer[offset + 5] |
              (buffer[offset + 6] << 8) |
              (buffer[offset + 7] << 16) |
              (buffer[offset + 8] << 24);
          valueLength =
              ((BigInt.from(high) << 32) | BigInt.from(low & 0xffffffff))
                  .toInt();
          headerLength = 9;
        } else {
          throw MySQLProtocolException(
            "Wrong first byte, while decoding textual result set row",
          );
        }

        final valueStart = offset + headerLength;
        final valueEnd = valueStart + valueLength;
        final fieldBytes = Uint8List.sublistView(buffer, valueStart, valueEnd);
        offset = valueEnd;

        if (binaryColumns?[x] ?? columnShouldBeBinary(colDef)) {
          // Se for BLOB/binário, guardamos como bytes; caso contrário, convertemos p/ String
          values[x] = fieldBytes; // Uint8List
        } else {
          // MySQL always sends textual protocol data using the negotiated connection charset (utf8mb4 by default),
          // so decode as UTF-8 to keep accents and emojis intact.
          final strValue = utf8.decode(fieldBytes, allowMalformed: true);
          values[x] = strValue;
        }
      }
    }

    return MySQLResultSetRowPacket(values: values);
  }

  @override
  Uint8List encode() {
    throw UnimplementedError(
      "Encode não implementado para MySQLResultSetRowPacket",
    );
  }

  /// Retorna `true` se [colType] deve ser tratado como coluna binária (BLOB, BIT, GEOMETRY).
  ///
  /// Observação: Campos `DECIMAL` e `NEWDECIMAL` **não** entram aqui porque,
  /// no protocolo textual, vêm como texto ASCII (por exemplo, `'99.99'`).
}
