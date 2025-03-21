import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa o pacote de resposta com dados extras de autenticação.
///
/// Esse pacote é utilizado durante a autenticação, especialmente com plugins
/// que requerem dados adicionais (extra auth data) do cliente. O pacote inclui:
/// - Os dados de autenticação extras.
/// - Um byte nulo final (0x00) para finalizar o pacote.
class MySQLPacketExtraAuthDataResponse extends MySQLPacketPayload {
  /// Dados extras de autenticação a serem enviados para o servidor.
  final Uint8List data;

  /// Construtor para criar uma instância de [MySQLPacketExtraAuthDataResponse].
  MySQLPacketExtraAuthDataResponse({
    required this.data,
  });

  /// Codifica o pacote em um [Uint8List] para envio ao servidor.
  ///
  /// A codificação consiste em:
  /// 1. Escrever os dados extras de autenticação.
  /// 2. Escrever um byte nulo (0x00) para finalizar o pacote.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    buffer.write(data);
    buffer.writeUint8(0);
    return buffer.toBytes();
  }
}
