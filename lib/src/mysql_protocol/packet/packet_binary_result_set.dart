import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa um result set binário conforme o protocolo MySQL.
///
/// Esse pacote encapsula os dados de um result set que foi enviado em formato binário,
/// geralmente como resultado da execução de um prepared statement.
/// 
/// Contém:
/// - [columnCount]: Número de colunas retornadas.
/// - [columns]: Lista de pacotes de definição de coluna ([MySQLColumnDefinitionPacket]) que descrevem cada coluna.
/// - [rows]: Lista de linhas do result set, onde cada linha é um [MySQLBinaryResultSetRowPacket].
class MySQLPacketBinaryResultSet extends MySQLPacketPayload {
  /// Número de colunas no result set.
  final BigInt columnCount;

  /// Lista de definições das colunas.
  final List<MySQLColumnDefinitionPacket> columns;

  /// Lista de linhas do result set.
  final List<MySQLBinaryResultSetRowPacket> rows;

  MySQLPacketBinaryResultSet({
    required this.columnCount,
    required this.columns,
    required this.rows,
  });

  /// Método de codificação não implementado.
  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketBinaryResultSet");
  }
}
