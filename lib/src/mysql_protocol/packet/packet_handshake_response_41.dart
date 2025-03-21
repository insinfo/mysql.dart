import 'dart:convert';
import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

/// Flags de capabilities suportadas pelo cliente.
/// Essas flags são combinadas e definem as funcionalidades suportadas na conexão.
const _supportedCapabitilies = mysqlCapFlagClientProtocol41 |
    mysqlCapFlagClientSecureConnection |
    mysqlCapFlagClientPluginAuth |
    mysqlCapFlagClientPluginAuthLenEncClientData |
    mysqlCapFlagClientMultiStatements |
    mysqlCapFlagClientMultiResults;

/// Representa o pacote de resposta ao handshake (versão 41) do protocolo MySQL.
///
/// Esse pacote é enviado pelo cliente como resposta ao handshake inicial do servidor.
/// Ele contém informações como:
/// - capabilityFlags: Flags de capacidades do cliente.
/// - maxPacketSize: Tamanho máximo do pacote suportado.
/// - characterSet: Conjunto de caracteres utilizado na conexão.
/// - authResponse: Dados de autenticação calculados (por exemplo, usando sha1 ou sha256).
/// - authPluginName: Nome do plugin de autenticação a ser utilizado.
/// - username: Nome do usuário conectado.
/// - database (opcional): Nome do banco de dados a ser utilizado, se informado.
class MySQLPacketHandshakeResponse41 extends MySQLPacketPayload {
  int capabilityFlags;
  int maxPacketSize;
  int characterSet;
  Uint8List authResponse;
  String authPluginName;
  String username;
  String? database;

  /// Construtor da classe.
  MySQLPacketHandshakeResponse41({
    required this.capabilityFlags,
    required this.maxPacketSize,
    required this.characterSet,
    required this.authResponse,
    required this.authPluginName,
    required this.username,
    this.database,
  });

  /// Cria uma resposta de handshake utilizando o método nativo de autenticação
  /// (mysql_native_password).
  ///
  /// - [username]: Nome do usuário.
  /// - [password]: Senha do usuário.
  /// - [initialHandshakePayload]: Pacote do handshake inicial enviado pelo servidor.
  ///
  /// A função concatena as partes do desafio (challenge) enviado pelo servidor,
  /// calcula os hashes SHA1 necessários e aplica a operação XOR para gerar os dados
  /// de autenticação.
  factory MySQLPacketHandshakeResponse41.createWithNativePassword({
    required String username,
    required String password,
    required MySQLPacketInitialHandshake initialHandshakePayload,
  }) {
    // Concatena a parte 1 do desafio com os 12 primeiros bytes da parte 2
    final challenge = initialHandshakePayload.authPluginDataPart1 +
        initialHandshakePayload.authPluginDataPart2!.sublist(0, 12);

    // Verifica se o desafio possui 20 bytes, conforme especificado.
    assert(challenge.length == 20);

    // Converte a senha para bytes (UTF-8)
    final passwordBytes = utf8.encode(password);

    // Calcula a resposta de autenticação:
    // authResponse = xor(sha1(password), sha1(challenge + sha1(sha1(password))))
    final authData = xor(
      sha1(passwordBytes),
      sha1(challenge + sha1(sha1(passwordBytes))),
    );

    return MySQLPacketHandshakeResponse41(
      capabilityFlags: _supportedCapabitilies,
      maxPacketSize: 50 * 1024 * 1024,
      authPluginName: initialHandshakePayload.authPluginName!,
      characterSet: initialHandshakePayload.charset,
      authResponse: authData,
      username: username,
    );
  }

  /// Cria uma resposta de handshake utilizando o método
  /// caching_sha2_password para autenticação.
  ///
  /// - [username]: Nome do usuário.
  /// - [password]: Senha do usuário.
  /// - [initialHandshakePayload]: Pacote do handshake inicial enviado pelo servidor.
  ///
  /// O desafio (challenge) é construído de forma similar, mas a resposta de autenticação
  /// é calculada utilizando a função SHA256.
  factory MySQLPacketHandshakeResponse41.createWithCachingSha2Password({
    required String username,
    required String password,
    required MySQLPacketInitialHandshake initialHandshakePayload,
  }) {
    // Concatena a parte 1 do desafio com os 12 primeiros bytes da parte 2
    final challenge = initialHandshakePayload.authPluginDataPart1 +
        initialHandshakePayload.authPluginDataPart2!.sublist(0, 12);

    // Verifica se o desafio possui 20 bytes
    assert(challenge.length == 20);

    // Converte a senha para bytes (UTF-8)
    final passwordBytes = utf8.encode(password);

    // Calcula a resposta de autenticação utilizando SHA256:
    // authResponse = xor(sha256(password), sha256(sha256(sha256(password)) + challenge))
    final authData = xor(
      sha256(passwordBytes),
      sha256(sha256(sha256(passwordBytes)) + challenge),
    );

    return MySQLPacketHandshakeResponse41(
      capabilityFlags: _supportedCapabitilies,
      maxPacketSize: 50 * 1024 * 1024,
      authPluginName: initialHandshakePayload.authPluginName!,
      characterSet: initialHandshakePayload.charset,
      authResponse: authData,
      username: username,
    );
  }

  /// Codifica o pacote de handshake response em um [Uint8List] para envio ao servidor.
  ///
  /// A codificação segue a especificação do protocolo:
  /// 1. capabilityFlags (4 bytes, little-endian)
  /// 2. maxPacketSize (4 bytes, little-endian)
  /// 3. characterSet (1 byte)
  /// 4. 23 bytes de preenchimento (0x00)
  /// 5. username (string UTF-8 seguida de 0x00)
  /// 6. Se a flag mysqlCapFlagClientSecureConnection estiver ativa:
  ///    - tamanho do authResponse (length-encoded integer)
  ///    - authResponse (bytes)
  /// 7. Se houver database e a flag mysqlCapFlagClientConnectWithDB estiver ativa:
  ///    - database (string UTF-8 seguida de 0x00)
  /// 8. Se a flag mysqlCapFlagClientPluginAuth estiver ativa:
  ///    - authPluginName (string UTF-8 seguida de 0x00)
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // Se um banco de dados foi especificado, ativa a flag de conexão com DB.
    if (database != null) {
      capabilityFlags = capabilityFlags | mysqlCapFlagClientConnectWithDB;
    }

    // Escreve capabilityFlags (4 bytes)
    buffer.writeUint32(capabilityFlags);
    // Escreve maxPacketSize (4 bytes)
    buffer.writeUint32(maxPacketSize);
    // Escreve characterSet (1 byte)
    buffer.writeUint8(characterSet);
    // Escreve 23 bytes de preenchimento (zeros)
    buffer.write(List.filled(23, 0));
    // Escreve o username seguido de um byte nulo
    buffer.write(utf8.encode(username));
    buffer.writeUint8(0);

    // Se a flag de conexão segura estiver ativa, envia o authResponse.
    if (capabilityFlags & mysqlCapFlagClientSecureConnection != 0) {
      // Escreve o tamanho do authResponse como um inteiro length-encoded
      buffer.writeVariableEncInt(authResponse.lengthInBytes);
      // Escreve os dados de autenticação
      buffer.write(authResponse);
    }

    // Se o banco de dados foi especificado e a flag de conexão com DB estiver ativa,
    // escreve o nome do database seguido de um byte nulo.
    if (database != null &&
        capabilityFlags & mysqlCapFlagClientConnectWithDB != 0) {
      buffer.write(utf8.encode(database!));
      buffer.writeUint8(0);
    }

    // Se a flag de plugin de autenticação estiver ativa, envia o nome do plugin.
    if (capabilityFlags & mysqlCapFlagClientPluginAuth != 0) {
      buffer.write(utf8.encode(authPluginName));
      buffer.writeUint8(0);
    }

    return buffer.toBytes();
  }
}
