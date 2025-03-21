import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa um pacote EOF (End-Of-File) do protocolo MySQL.
///
/// Esse pacote é utilizado pelo servidor para indicar o fim de um conjunto de dados,
/// como o final de um result set ou o final da transmissão de definições de colunas.
/// O pacote EOF contém:
/// - Um header (normalmente 0xfe).
/// - Dois bytes reservados para o número de warnings (geralmente ignorados).
/// - Dois bytes para os flags de status, que podem indicar se há mais resultados.
class MySQLPacketEOF extends MySQLPacketPayload {
  /// Cabeçalho do pacote. Geralmente, o valor é 0xfe.
  final int header;

  /// Flags de status do pacote, que podem conter informações adicionais
  /// (por exemplo, se há mais resultados a serem enviados).
  final int statusFlags;

  /// Construtor da classe.
  MySQLPacketEOF({
    required this.header,
    required this.statusFlags,
  });

  /// Decodifica um [Uint8List] recebido do servidor e retorna uma instância de [MySQLPacketEOF].
  ///
  /// O buffer deve conter os dados do pacote EOF conforme a seguinte estrutura:
  /// 1. Header: 1 byte.
  /// 2. Warnings count: 2 bytes (valor ignorado).
  /// 3. Status flags: 2 bytes (little-endian).
  factory MySQLPacketEOF.decode(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // Leitura do header (1 byte).
    final header = byteData.getUint8(offset);
    offset += 1;

    // Pula os 2 bytes referentes ao count de warnings (normalmente não utilizados).
    offset += 2;

    // Leitura dos status flags (2 bytes, little-endian).
    final statusFlags = byteData.getUint16(offset, Endian.little);
    offset += 2;

    return MySQLPacketEOF(header: header, statusFlags: statusFlags);
  }

  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketEOF");
  }
}
