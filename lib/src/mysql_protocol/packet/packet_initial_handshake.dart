import 'dart:math';
import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

/// Representa o pacote de handshake inicial enviado pelo servidor MySQL.
///
/// Esse pacote é a primeira mensagem enviada pelo servidor quando um cliente
/// se conecta, contendo informações essenciais para o estabelecimento da
/// conexão, tais como:
/// - Versão do protocolo.
/// - Versão do servidor.
/// - ID da conexão.
/// - Dados de autenticação (divididos em duas partes).
/// - Flags de capabilities (capabilityFlags).
/// - Charset e status.
/// - Nome do plugin de autenticação (se aplicável).
class MySQLPacketInitialHandshake extends MySQLPacketPayload {
  /// Versão do protocolo (geralmente 10).
  final int protocolVersion;
  
  /// Versão do servidor (ex.: "5.7.26-log").
  final String serverVersion;
  
  /// ID da conexão.
  final int connectionID;
  
  /// Primeira parte dos dados de autenticação enviados pelo servidor (8 bytes).
  final Uint8List authPluginDataPart1;
  
  /// Flags de capabilities do servidor.
  final int capabilityFlags;
  
  /// Conjunto de caracteres (charset) utilizado na conexão.
  final int charset;
  
  /// Flags de status (2 bytes) enviados pelo servidor.
  final Uint8List statusFlags;
  
  /// Segunda parte dos dados de autenticação (opcional). Geralmente utilizada quando
  /// a flag mysqlCapFlagClientSecureConnection está ativa.
  final Uint8List? authPluginDataPart2;
  
  /// Nome do plugin de autenticação, se especificado (opcional).
  final String? authPluginName;

  /// Construtor da classe.
  MySQLPacketInitialHandshake({
    required this.protocolVersion,
    required this.serverVersion,
    required this.connectionID,
    required this.authPluginDataPart1,
    required this.authPluginDataPart2,
    required this.capabilityFlags,
    required this.charset,
    required this.statusFlags,
    required this.authPluginName,
  });

  /// Decodifica um buffer [Uint8List] recebido do servidor e retorna uma instância
  /// de [MySQLPacketInitialHandshake].
  ///
  /// A decodificação segue a especificação do protocolo MySQL:
  /// 1. **Protocol Version:** 1 byte.
  /// 2. **Server Version:** String terminada em null.
  /// 3. **Connection ID:** 4 bytes (little-endian).
  /// 4. **Auth Plugin Data Part 1:** 8 bytes, seguida de 1 byte de filler.
  /// 5. **Capability Flags (lower 2 bytes):** 2 bytes.
  /// 6. **Character Set:** 1 byte.
  /// 7. **Status Flags:** 2 bytes.
  /// 8. **Capability Flags (upper 2 bytes):** 2 bytes.
  /// 9. **Length of Auth Plugin Data:** 1 byte (se a flag mysqlCapFlagClientPluginAuth estiver ativa).
  /// 10. **Reserved:** 10 bytes (normalmente zeros).
  /// 11. **Auth Plugin Data Part 2:** Número variável de bytes, se a flag mysqlCapFlagClientSecureConnection estiver ativa.
  /// 12. **Auth Plugin Name:** String terminada em null, se a flag mysqlCapFlagClientPluginAuth estiver ativa.
  factory MySQLPacketInitialHandshake.decode(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    int offset = 0;

    // 1) Protocol Version (1 byte)
    final protocolVersion = byteData.getUint8(offset);
    offset += 1;

    // 2) Server Version: String terminada em null
    final serverVersion = buffer.getUtf8NullTerminatedString(offset);
    offset += serverVersion.item2;

    // 3) Connection ID (4 bytes, little-endian)
    final connectionID = byteData.getUint32(offset, Endian.little);
    offset += 4;

    // 4) Auth Plugin Data Part 1 (8 bytes) e filler (1 byte)
    final authPluginDataPart1 =
        Uint8List.sublistView(buffer, offset, offset + 8);
    offset += 9; // 8 bytes de dados + 1 byte de filler

    // 5) Capability Flags (lower 2 bytes)
    // Cria um buffer de 4 bytes para montar as flags completas.
    final capabilitiesBytesData = ByteData(4);
    // Armazena os 2 bytes inferiores nas posições 3 e 2 (big-endian para posterior conversão)
    capabilitiesBytesData.setUint8(3, buffer[offset]);
    capabilitiesBytesData.setUint8(2, buffer[offset + 1]);
    offset += 2;

    // 6) Character Set (1 byte)
    final charset = byteData.getUint8(offset);
    offset += 1;

    // 7) Status Flags (2 bytes)
    final statusFlags = Uint8List.sublistView(buffer, offset, offset + 2);
    offset += 2;

    // 8) Capability Flags (upper 2 bytes)
    capabilitiesBytesData.setUint8(1, buffer[offset]);
    capabilitiesBytesData.setUint8(0, buffer[offset + 1]);
    offset += 2;
    // Converte as 4 bytes para um inteiro (big-endian)
    final capabilityFlags = capabilitiesBytesData.getUint32(0, Endian.big);

    // 9) Length of Auth Plugin Data (1 byte)
    int authPluginDataLength = 0;
    if (capabilityFlags & mysqlCapFlagClientPluginAuth != 0) {
      authPluginDataLength = byteData.getUint8(offset);
    }
    offset += 1;

    // 10) Reserved: pula 10 bytes (normalmente zeros)
    offset += 10;

    // 11) Auth Plugin Data Part 2 (se aplicável)
    Uint8List? authPluginDataPart2;
    if (capabilityFlags & mysqlCapFlagClientSecureConnection != 0) {
      // O comprimento é o máximo entre 13 e (authPluginDataLength - 8)
      int length = max(13, authPluginDataLength - 8);
      authPluginDataPart2 =
          Uint8List.sublistView(buffer, offset, offset + length);
      offset += length;
    }

    // 12) Auth Plugin Name (se aplicável)
    String? authPluginName;
    if (capabilityFlags & mysqlCapFlagClientPluginAuth != 0) {
      authPluginName = buffer.getUtf8NullTerminatedString(offset).item1;
    }

    return MySQLPacketInitialHandshake(
      protocolVersion: protocolVersion,
      serverVersion: serverVersion.item1,
      connectionID: connectionID,
      authPluginDataPart1: authPluginDataPart1,
      authPluginDataPart2: authPluginDataPart2,
      capabilityFlags: capabilityFlags,
      charset: charset,
      statusFlags: statusFlags,
      authPluginName: authPluginName,
    );
  }

  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketInitialHandshake");
  }

  @override
  String toString() {
    return """
MySQLPacketInitialHandshake:
  protocolVersion: $protocolVersion,
  serverVersion: $serverVersion,
  connectionID: $connectionID,
  authPluginDataPart1: $authPluginDataPart1,
  authPluginDataPart2: $authPluginDataPart2,
  capabilityFlags: $capabilityFlags,
  charset: $charset,
  statusFlags: $statusFlags,
  authPluginName: $authPluginName
""";
  }
}
