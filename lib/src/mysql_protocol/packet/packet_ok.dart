import 'dart:typed_data';
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

  /// Construtor da classe.
  MySQLPacketOK({
    required this.header,
    required this.affectedRows,
    required this.lastInsertID,
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
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // 1) Leitura do header (1 byte)
    final header = byteData.getUint8(offset);
    offset += 1;

    // 2) Leitura do número de linhas afetadas (length-encoded integer)
    final affectedRows = byteData.getVariableEncInt(offset);
    offset += affectedRows.item2;

    // 3) Leitura do último ID inserido (length-encoded integer)
    final lastInsertID = byteData.getVariableEncInt(offset);
    offset += lastInsertID.item2;

    return MySQLPacketOK(
      header: header,
      affectedRows: affectedRows.item1,
      lastInsertID: lastInsertID.item1,
    );
  }

  /// O método [encode] não está implementado, pois esse pacote geralmente é utilizado
  /// apenas para leitura dos dados enviados pelo servidor.
  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketOK");
  }
}
