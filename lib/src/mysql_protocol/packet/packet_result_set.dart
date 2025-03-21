import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa um result set retornado pelo servidor MySQL.
///
/// Esse pacote encapsula todas as informações de um result set que foi recebido
/// após a execução de uma consulta. Ele inclui:
/// - [columnCount]: Número de colunas presentes no result set.
/// - [columns]: Lista de definições de coluna ([MySQLColumnDefinitionPacket]),
///   que descrevem os metadados de cada coluna (nome, tipo, charset, etc.).
/// - [rows]: Lista de linhas do result set, onde cada linha é um
///   [MySQLResultSetRowPacket] contendo os valores decodificados de cada coluna.
class MySQLPacketResultSet extends MySQLPacketPayload {
  /// Número de colunas no result set.
  final BigInt columnCount;

  /// Lista de definições das colunas.
  final List<MySQLColumnDefinitionPacket> columns;

  /// Lista de linhas do result set.
  final List<MySQLResultSetRowPacket> rows;

  /// Construtor da classe.
  MySQLPacketResultSet({
    required this.columnCount,
    required this.columns,
    required this.rows,
  });

  /// O método [encode] não está implementado, pois este pacote geralmente é utilizado
  /// para decodificação dos dados enviados pelo servidor.
  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketResultSet");
  }
}
