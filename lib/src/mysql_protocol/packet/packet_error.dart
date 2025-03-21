import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

/// Representa um pacote de erro do protocolo MySQL.
///
/// Esse pacote é enviado pelo servidor quando ocorre um erro durante a execução
/// de uma requisição. Ele contém:
/// - Um header que identifica o pacote como um erro.
/// - Um código de erro (errorCode).
/// - Uma mensagem de erro (errorMessage) detalhando o problema.
class MySQLPacketError extends MySQLPacketPayload {
  /// Header do pacote (geralmente 0xff, indicando um pacote de erro).
  final int header;

  /// Código do erro, conforme definido pelo MySQL.
  final int errorCode;

  /// Mensagem descritiva do erro.
  final String errorMessage;

  /// Construtor para criar uma instância de [MySQLPacketError].
  MySQLPacketError({
    required this.header,
    required this.errorCode,
    required this.errorMessage,
  });

  /// Decodifica um buffer [Uint8List] recebido do servidor e retorna uma instância
  /// de [MySQLPacketError].
  ///
  /// O formato esperado do buffer é:
  /// 1. Header: 1 byte (geralmente 0xff).
  /// 2. Error code: 2 bytes.
  /// 3. SQL state marker e SQL state: 1 + 5 bytes (total de 6 bytes, ignorados).
  /// 4. Error message: o restante do buffer é interpretado como uma string UTF-8.
  factory MySQLPacketError.decode(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // 1) Leitura do header (1 byte)
    final header = byteData.getUint8(offset);
    offset += 1;

    // 2) Leitura do código de erro (2 bytes)
    final errorCode = byteData.getInt2(offset);
    offset += 2;

    // 3) Pula o marcador de SQL state e o SQL state (1 + 5 bytes = 6 bytes)
    offset += 6;

    // 4) O restante do buffer corresponde à mensagem de erro
    final errorMessage = buffer.getUtf8StringEOF(offset);

    return MySQLPacketError(
      header: header,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }

  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketError");
  }
}
