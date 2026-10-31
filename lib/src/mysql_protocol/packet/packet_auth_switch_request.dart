import 'dart:convert';
import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa o pacote "Auth Switch Request" do protocolo MySQL.
///
/// Esse pacote é enviado pelo servidor para solicitar que o cliente
/// utilize um método de autenticação diferente. O pacote contém:
/// - Um header (1 byte) indicando o tipo de pacote;
/// - O nome do plugin de autenticação (string terminada em null);
/// - Dados do plugin de autenticação (restante do buffer).
class MySQLPacketAuthSwitchRequest extends MySQLPacketPayload {
  /// Cabeçalho do pacote.
  final int header;

  /// Nome do plugin de autenticação solicitado.
  final String authPluginName;

  /// Dados enviados pelo servidor para o plugin de autenticação.
  final Uint8List authPluginData;

  /// Construtor para criar uma instância de [MySQLPacketAuthSwitchRequest].
  MySQLPacketAuthSwitchRequest({
    required this.header,
    required this.authPluginData,
    required this.authPluginName,
  });

  /// Decodifica um [Uint8List] recebido do servidor e cria uma instância
  /// de [MySQLPacketAuthSwitchRequest].
  ///
  /// O formato esperado do buffer é:
  /// 1. Header: 1 byte.
  /// 2. authPluginName: string terminada em null (utiliza [getUtf8NullTerminatedString]).
  /// 3. authPluginData: o restante do buffer.
  factory MySQLPacketAuthSwitchRequest.decode(Uint8List buffer) {
    if (buffer.isEmpty) {
      throw const MySQLProtocolException(
        'Truncated MySQLPacketAuthSwitchRequest: empty buffer',
      );
    }
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // 1) Leitura do header (1 byte)
    final header = byteData.getUint8(offset);
    if (header != 0xfe) {
      throw MySQLProtocolException(
        'Invalid MySQLPacketAuthSwitchRequest header: '
        'expected 0xfe, got 0x${header.toRadixString(16)}',
      );
    }
    offset += 1;

    // 2) Leitura do nome do plugin de autenticação (string null-terminated)
    final pluginEnd = buffer.indexOf(0, offset);
    if (pluginEnd < 0) {
      throw const MySQLProtocolException(
        'Truncated MySQLPacketAuthSwitchRequest: unterminated authPluginName',
      );
    }
    final authPluginName = utf8.decode(
      Uint8List.sublistView(buffer, offset, pluginEnd),
      allowMalformed: true,
    );
    offset = pluginEnd + 1;

    // 3) O restante do buffer corresponde aos dados do plugin
    final authPluginData = Uint8List.sublistView(buffer, offset);

    return MySQLPacketAuthSwitchRequest(
      header: header,
      authPluginData: authPluginData,
      authPluginName: authPluginName,
    );
  }

  @override
  Uint8List encode() {
    throw UnimplementedError(
        "Encode não implementado para MySQLPacketAuthSwitchRequest");
  }
}
