import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';
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
    Uint8List buffer,
    List<MySQLColumnDefinitionPacket> columns,
  ) {
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;
    final values = <dynamic>[];

    for (int x = 0; x < columns.length; x++) {
      final colDef = columns[x];
      final nextByte = byteData.getUint8(offset);

      // 0xFB = NULL
      if (nextByte == 0xfb) {
        values.add(null);
        offset++;
      } else {
        // Lê o valor como length-encoded bytes
        final lengthEncoded = buffer.getLengthEncodedBytes(offset);
        offset += lengthEncoded.item2;

        if (columnShouldBeBinary(colDef)) {
          // Se for BLOB/binário, guardamos como bytes; caso contrário, convertemos p/ String
          values.add(lengthEncoded.item1); // Uint8List
        } else {
          final strValue = String.fromCharCodes(lengthEncoded.item1);
          values.add(strValue);
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
