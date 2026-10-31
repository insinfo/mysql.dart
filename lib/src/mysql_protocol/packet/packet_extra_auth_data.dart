import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa o pacote de dados extras de autenticação enviado pelo servidor.
///
/// Esse pacote é utilizado durante o processo de autenticação quando o
/// servidor precisa enviar dados adicionais para o cliente (por exemplo,
/// no contexto do plugin de autenticação caching_sha2_password).
///
/// O pacote possui a seguinte estrutura:
/// 1. Um byte de header.
/// 2. Dados do plugin (pluginData) no restante do buffer.
class MySQLPacketExtraAuthData extends MySQLPacketPayload {
  /// Header do pacote (1 byte).
  final int header;

  /// Dados do plugin de autenticação enviados pelo servidor.
  final Uint8List pluginData;

  /// Construtor para criar uma instância de [MySQLPacketExtraAuthData].
  MySQLPacketExtraAuthData({
    required this.header,
    required this.pluginData,
  });

  /// Decodifica um buffer [Uint8List] recebido do servidor e retorna uma instância
  /// de [MySQLPacketExtraAuthData].
  ///
  /// O buffer é interpretado da seguinte forma:
  /// 1. O primeiro byte é lido como o header.
  /// 2. O restante do buffer é lido como uma string UTF-8, que representa os dados do plugin.
  factory MySQLPacketExtraAuthData.decode(Uint8List buffer) {
    if (buffer.isEmpty) {
      throw const MySQLProtocolException(
        'Truncated MySQLPacketExtraAuthData: empty buffer',
      );
    }
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // Leitura do header (1 byte; AuthMoreData header is 0x01)
    final header = byteData.getUint8(offset);
    if (header != 0x01) {
      throw MySQLProtocolException(
        'Invalid MySQLPacketExtraAuthData header: '
        'expected 0x01, got 0x${header.toRadixString(16)}',
      );
    }
    offset += 1;

    final pluginData = Uint8List.sublistView(buffer, offset);

    return MySQLPacketExtraAuthData(
      header: header,
      pluginData: pluginData,
    );
  }

  @override
  Uint8List encode() {
    throw UnimplementedError(
        "Encode não implementado para MySQLPacketExtraAuthData");
  }
}
