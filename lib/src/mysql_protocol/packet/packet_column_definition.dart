import 'dart:convert';
import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

(String, int) _readMetadataString(Uint8List buffer, int offset) {
  final bytes = buffer.getLengthEncodedBytes(offset);
  return (utf8.decode(bytes.$1, allowMalformed: true), bytes.$2);
}

/// Representa um pacote de definição de coluna (Column Definition Packet)
/// no protocolo MySQL.
///
/// Esse pacote contém informações sobre uma coluna retornada em um result set,
/// tais como o catálogo, esquema, nome da tabela, nome da coluna, charset,
/// tamanho da coluna, tipo de dados, flags e número de decimais.
class MySQLColumnDefinitionPacket extends MySQLPacketPayload {
  /// Nome do catálogo da coluna.
  final String catalog;

  /// Nome do esquema (database) da coluna.
  final String schema;

  /// Nome da tabela (alias/`AS`).
  final String table;

  /// Nome original da tabela.
  final String orgTable;

  /// Nome da coluna (alias/`AS`).
  final String name;

  /// Nome original da coluna.
  final String orgName;

  /// Charset utilizado na coluna (collation).
  final int charset;

  /// Tamanho (máximo) da coluna em bytes ou caracteres, dependendo do tipo.
  final int columnLength;

  /// Tipo de dado da coluna (ex.: 0xfd = varString, 0xfc = blob, etc.).
  final MySQLColumnType type;

  /// Flags da coluna (por exemplo, se é unsigned, binária, etc.).
  final int flags;

  /// Número de decimais (para colunas numéricas).
  final int decimals;

  /// Construtor do pacote de definição de coluna.
  MySQLColumnDefinitionPacket({
    required this.catalog,
    required this.schema,
    required this.table,
    required this.orgTable,
    required this.name,
    required this.orgName,
    required this.charset,
    required this.columnLength,
    required this.type,
    required this.flags,
    required this.decimals,
  });

  /// Decodifica um [Uint8List] recebido do servidor MySQL e constrói
  /// um objeto [MySQLColumnDefinitionPacket].
  ///
  /// A sequência de leitura segue a especificação do protocolo MySQL:
  ///
  /// 1. `catalog` (length-encoded string)
  /// 2. `schema` (length-encoded string)
  /// 3. `table` (length-encoded string)
  /// 4. `org_table` (length-encoded string)
  /// 5. `name` (length-encoded string)
  /// 6. `org_name` (length-encoded string)
  /// 7. `lengthOfFixedLengthFields` (length-encoded integer; geralmente 0x0c)
  /// 8. `charset` (2 bytes, little-endian)
  /// 9. `column_length` (4 bytes, little-endian)
  /// 10. `type` (1 byte)
  /// 11. `flags` (2 bytes, little-endian)
  /// 12. `decimals` (1 byte)
  /// 13. `filler` (2 bytes, geralmente 0x00 0x00)
  ///
  /// Ao final, retorna uma instância de [MySQLColumnDefinitionPacket].
  factory MySQLColumnDefinitionPacket.decode(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // 1) Lê catalog (length-encoded string)
    final catalogLE = _readMetadataString(buffer, offset);
    offset += catalogLE.$2;

    // 2) Lê schema (length-encoded string)
    final schemaLE = _readMetadataString(buffer, offset);
    offset += schemaLE.$2;

    // 3) Lê table (length-encoded string)
    final tableLE = _readMetadataString(buffer, offset);
    offset += tableLE.$2;

    // 4) Lê org_table (length-encoded string)
    final orgTableLE = _readMetadataString(buffer, offset);
    offset += orgTableLE.$2;

    // 5) Lê name (length-encoded string)
    final nameLE = _readMetadataString(buffer, offset);
    offset += nameLE.$2;

    // 6) Lê org_name (length-encoded string)
    final orgNameLE = _readMetadataString(buffer, offset);
    offset += orgNameLE.$2;

    // 7) Lê lengthOfFixedLengthFields (geralmente 0x0c)
    final lengthOfFixedLengthFields = buffer.getVariableEncIntAt(offset);
    if (lengthOfFixedLengthFields.$1 < BigInt.from(0x0c)) {
      throw MySQLProtocolException(
        'Invalid fixed-fields length in MySQLColumnDefinitionPacket: '
        '${lengthOfFixedLengthFields.$1}',
      );
    }
    offset += lengthOfFixedLengthFields.$2;

    if (BigInt.from(buffer.length - offset) < lengthOfFixedLengthFields.$1) {
      throw MySQLProtocolException(
        'Truncated fixed-length fields in MySQLColumnDefinitionPacket: '
        'declared ${lengthOfFixedLengthFields.$1} bytes, '
        'available ${buffer.length - offset}',
      );
    }

    // 8) Lê charset (2 bytes, little-endian)
    final charset = byteData.getUint16(offset, Endian.little);
    offset += 2;

    // 9) Lê column_length (4 bytes, little-endian)
    final columnLength = byteData.getUint32(offset, Endian.little);
    offset += 4;

    // 10) Lê type (1 byte)
    final colType = byteData.getUint8(offset);
    offset += 1;

    // 11) Lê flags (2 bytes, little-endian)
    final flags = byteData.getUint16(offset, Endian.little);
    offset += 2;

    // 12) Lê o número de decimais (1 byte)
    final decimals = byteData.getUint8(offset);
    offset += 1;

    // 13) Pula 2 bytes de filler (geralmente 0x00 0x00)
    offset += 2;

    // Retorna a instância
    return MySQLColumnDefinitionPacket(
      catalog: catalogLE.$1,
      schema: schemaLE.$1,
      table: tableLE.$1,
      orgTable: orgTableLE.$1,
      name: nameLE.$1,
      orgName: orgNameLE.$1,
      charset: charset,
      columnLength: columnLength,
      type: MySQLColumnType.create(colType),
      flags: flags,
      decimals: decimals,
    );
  }

  @override
  Uint8List encode() {
    // Esse pacote raramente precisa ser reconstruído e enviado para o servidor,
    // pois é uma mensagem retornada pelo servidor ao cliente. Em geral, não é necessário
    // implementar a codificação ("encode").
    throw UnimplementedError(
      "Encode não implementado para MySQLColumnDefinitionPacket",
    );
  }
}
