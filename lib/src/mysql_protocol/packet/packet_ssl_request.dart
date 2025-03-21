import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:mysql_dart/mysql_protocol.dart';

/// Flags de capabilities suportadas para a conexão SSL.
/// Essas flags indicam quais funcionalidades o cliente suporta e são combinadas
/// para configurar a conexão com o servidor MySQL.
const _supportedCapabitilies = mysqlCapFlagClientProtocol41 |
    mysqlCapFlagClientSecureConnection |
    mysqlCapFlagClientPluginAuth |
    mysqlCapFlagClientPluginAuthLenEncClientData |
    mysqlCapFlagClientMultiStatements |
    mysqlCapFlagClientMultiResults |
    mysqlCapFlagClientSsl;

/// Representa um pacote SSL Request do protocolo MySQL.
///
/// Esse pacote é enviado pelo cliente para solicitar a ativação do modo SSL na
/// conexão, se o servidor suportar. Ele contém informações como:
/// - capabilityFlags: Flags que informam as capacidades do cliente.
/// - maxPacketSize: Tamanho máximo do pacote suportado.
/// - characterSet: Conjunto de caracteres (charset) a ser utilizado.
/// - connectWithDB: Indica se o cliente deseja se conectar com um banco de dados
///   específico (caso em que a flag mysqlCapFlagClientConnectWithDB será ativada).
class MySQLPacketSSLRequest extends MySQLPacketPayload {
  /// Flags de capabilities do cliente.
  int capabilityFlags;

  /// Tamanho máximo do pacote suportado (por exemplo, 50MB).
  int maxPacketSize;

  /// Conjunto de caracteres (charset) a ser utilizado na conexão.
  int characterSet;

  /// Indica se a conexão deverá selecionar um banco de dados imediatamente.
  final bool connectWithDB;

  /// Construtor privado para criação de instâncias de [MySQLPacketSSLRequest].
  MySQLPacketSSLRequest._({
    required this.capabilityFlags,
    required this.maxPacketSize,
    required this.characterSet,
    required this.connectWithDB,
  });

  /// Fábrica para criar um pacote SSL Request padrão, utilizando as informações
  /// do pacote de handshake inicial.
  ///
  /// - [initialHandshakePayload]: Pacote inicial recebido do servidor contendo o charset, entre outras informações.
  /// - [connectWithDB]: Se `true`, ativa a flag de conexão com banco de dados (mysqlCapFlagClientConnectWithDB).
  factory MySQLPacketSSLRequest.createDefault({
    required MySQLPacketInitialHandshake initialHandshakePayload,
    required bool connectWithDB,
  }) {
    return MySQLPacketSSLRequest._(
      capabilityFlags: _supportedCapabitilies,
      maxPacketSize: 50 * 1024 * 1024, // Exemplo: 50MB
      characterSet: initialHandshakePayload.charset,
      connectWithDB: connectWithDB,
    );
  }

  /// Codifica o pacote SSL Request em um [Uint8List] para envio ao servidor.
  ///
  /// A codificação segue a especificação do protocolo MySQL:
  /// 1. capabilityFlags (4 bytes, little-endian). Se [connectWithDB] for `true`,
  ///    a flag [mysqlCapFlagClientConnectWithDB] é ativada.
  /// 2. maxPacketSize (4 bytes, little-endian).
  /// 3. characterSet (1 byte).
  /// 4. 23 bytes de preenchimento (zeros).
  @override
  Uint8List encode() {
    // Se o cliente deseja se conectar com um banco de dados,
    // ativa a flag mysqlCapFlagClientConnectWithDB.
    if (connectWithDB) {
      capabilityFlags = capabilityFlags | mysqlCapFlagClientConnectWithDB;
    }

    final buffer = ByteDataWriter(endian: Endian.little);
    buffer.writeUint32(capabilityFlags);
    buffer.writeUint32(maxPacketSize);
    buffer.writeUint8(characterSet);
    // Escreve 23 bytes de preenchimento com zeros.
    buffer.write(List.filled(23, 0));

    return buffer.toBytes();
  }
}
