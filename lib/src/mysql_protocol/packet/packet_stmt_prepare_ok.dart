import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa o pacote de resposta ao comando COM_STMT_PREPARE (Prepare Statement OK)
/// do protocolo MySQL.
///
/// Esse pacote é enviado pelo servidor em resposta à requisição de preparação
/// de um statement, e contém informações necessárias para a execução do prepared statement,
/// tais como:
/// - Um header identificando o pacote.
/// - Um ID único para o statement (stmtID).
/// - O número de colunas que o statement irá retornar.
/// - O número de parâmetros que o statement espera receber.
/// - O número de warnings (se houver).
class MySQLPacketStmtPrepareOK extends MySQLPacketPayload {
  /// Header do pacote (geralmente 0x00).
  final int header;

  /// ID único do statement gerado pelo servidor.
  final int stmtID;

  /// Número de colunas que o statement retornará.
  final int numOfCols;

  /// Número de parâmetros esperados pelo statement.
  final int numOfParams;

  /// Número de warnings gerados durante a preparação do statement.
  final int numOfWarnings;

  /// Construtor da classe.
  MySQLPacketStmtPrepareOK({
    required this.header,
    required this.stmtID,
    required this.numOfCols,
    required this.numOfParams,
    required this.numOfWarnings,
  });

  /// Decodifica um buffer [Uint8List] recebido do servidor e retorna uma instância de
  /// [MySQLPacketStmtPrepareOK].
  ///
  /// A estrutura do pacote segue a especificação do protocolo MySQL para COM_STMT_PREPARE:
  /// 1. **Header:** 1 byte (geralmente 0x00).
  /// 2. **Statement ID (stmtID):** 4 bytes (little-endian).
  /// 3. **Number of columns:** 2 bytes (little-endian).
  /// 4. **Number of parameters:** 2 bytes (little-endian).
  /// 5. **Filler:** 1 byte (valor ignorado).
  /// 6. **Number of warnings:** 2 bytes (little-endian).
  factory MySQLPacketStmtPrepareOK.decode(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // 1) Leitura do header (1 byte)
    final header = byteData.getUint8(offset);
    offset += 1;

    // 2) Leitura do Statement ID (4 bytes, little-endian)
    final statementID = byteData.getUint32(offset, Endian.little);
    offset += 4;

    // 3) Leitura do número de colunas (2 bytes, little-endian)
    final numColumns = byteData.getUint16(offset, Endian.little);
    offset += 2;

    // 4) Leitura do número de parâmetros (2 bytes, little-endian)
    final numParams = byteData.getUint16(offset, Endian.little);
    offset += 2;

    // 5) Pula 1 byte de filler (não utilizado)
    offset += 1;

    // 6) Leitura do número de warnings (2 bytes, little-endian)
    final numWarnings = byteData.getUint16(offset, Endian.little);
    offset += 2;

    return MySQLPacketStmtPrepareOK(
      header: header,
      stmtID: statementID,
      numOfCols: numColumns,
      numOfParams: numParams,
      numOfWarnings: numWarnings,
    );
  }

  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketStmtPrepareOK");
  }
}
