import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

/// Representa um pacote OK enviado pelo servidor MySQL.
///
/// Esse pacote é utilizado para indicar que uma operação (como INSERT, UPDATE, DELETE, etc.)
/// foi executada com sucesso. Ele contém informações como:
/// - [header]: Um byte que identifica o pacote (geralmente 0x00).
/// - [affectedRows]: Número de linhas afetadas pela operação (valor codificado com length-encoded integer).
/// - [lastInsertID]: Último ID gerado (também codificado como length-encoded integer).
class MySQLPacketOK extends MySQLPacketPayload {
  /// Header do pacote (geralmente 0x00).
  final int header;

  /// Número de linhas afetadas pela operação.
  final BigInt affectedRows;

  /// Último ID inserido (last insert ID).
  final BigInt lastInsertID;

  /// Server status flags (SERVER_MORE_RESULTS_EXISTS tells that another
  /// result follows this one: multi-statement queries, CALL).
  final int statusFlags;

  /// Construtor da classe.
  MySQLPacketOK({
    required this.header,
    required this.affectedRows,
    required this.lastInsertID,
    this.statusFlags = 0,
  });

  /// Decodifica um buffer [Uint8List] recebido do servidor e retorna uma instância de [MySQLPacketOK].
  ///
  /// A decodificação segue a seguinte estrutura:
  /// 1. **Header:** 1 byte, que deve ser 0x00.
  /// 2. **Affected Rows:** Valor length-encoded, representando o número de linhas afetadas.
  /// 3. **Last Insert ID:** Valor length-encoded, representando o último ID gerado.
  ///
  /// O método utiliza a função [getVariableEncInt] para decodificar os valores length-encoded.
  factory MySQLPacketOK.decode(Uint8List buffer) {
    if (buffer.isEmpty) {
      throw const MySQLProtocolException(
        'Truncated MySQLPacketOK: empty buffer',
      );
    }
    int offset = 0;

    // 1) Leitura do header (1 byte; 0x00 or 0xfe when CLIENT_DEPRECATE_EOF is set)
    final header = buffer[offset];
    if (header != 0x00 && header != 0xfe) {
      throw MySQLProtocolException(
        'Invalid MySQLPacketOK header: 0x${header.toRadixString(16)}',
      );
    }
    offset += 1;

    // 2) Leitura do número de linhas afetadas (length-encoded integer)
    final affectedRows = buffer.getVariableEncIntAt(offset);
    offset += affectedRows.$2;

    // 3) Leitura do último ID inserido (length-encoded integer)
    final lastInsertID = buffer.getVariableEncIntAt(offset);
    offset += lastInsertID.$2;

    // 4) Status flags (2 bytes, little-endian; CLIENT_PROTOCOL_41)
    final statusFlags = buffer.length >= offset + 2
        ? buffer[offset] | (buffer[offset + 1] << 8)
        : 0;

    return MySQLPacketOK(
      header: header,
      affectedRows: affectedRows.$1,
      lastInsertID: lastInsertID.$1,
      statusFlags: statusFlags,
    );
  }

  /// O método [encode] não está implementado, pois esse pacote geralmente é utilizado
  /// apenas para leitura dos dados enviados pelo servidor.
  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketOK");
  }
}
