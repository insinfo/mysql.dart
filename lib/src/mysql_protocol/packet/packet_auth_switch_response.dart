import 'dart:convert';
import 'dart:typed_data';
import 'package:buffer/buffer.dart';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa o pacote de resposta para o Auth Switch Request.
///
/// Esse pacote é utilizado pelo cliente para enviar a resposta à solicitação
/// de mudança de autenticação enviada pelo servidor. No caso da autenticação
/// nativa (mysql_native_password), a resposta é construída utilizando uma
/// operação XOR entre o SHA1 da senha e o SHA1 da concatenação do desafio
/// enviado pelo servidor com o SHA1 do SHA1 da senha.
class MySQLPacketAuthSwitchResponse extends MySQLPacketPayload {
  /// Dados de autenticação a serem enviados para o servidor.
  final Uint8List authData;

  /// Construtor que recebe os dados de autenticação.
  MySQLPacketAuthSwitchResponse({
    required this.authData,
  });

  /// Cria uma resposta de autenticação para o método nativo utilizando
  /// a senha e o desafio recebido pelo servidor.
  ///
  /// - [password]: A senha do usuário.
  /// - [challenge]: Os dados do desafio enviados pelo servidor (deve ter 20 bytes).
  ///
  /// Se a senha estiver vazia, retorna um pacote com [authData] vazio.
  ///
  /// A resposta é calculada da seguinte forma:
  ///   authData = xor(sha1(password), sha1(challenge + sha1(sha1(password))))
  factory MySQLPacketAuthSwitchResponse.createWithNativePassword({
    required String password,
    required Uint8List challenge,
  }) {
    // Verifica se o tamanho do desafio é o esperado.
    assert(challenge.length == 20);
    if (password == '') {
      return MySQLPacketAuthSwitchResponse(authData: Uint8List(0));
    }
    // Converte a senha para bytes UTF-8.
    final passwordBytes = utf8.encode(password);

    // Calcula a resposta de autenticação utilizando a função xor e os hashes SHA1.
    final authData =
        xor(sha1(passwordBytes), sha1(challenge + sha1(sha1(passwordBytes))));

    return MySQLPacketAuthSwitchResponse(
      authData: authData,
    );
  }

  /// Codifica o pacote em um [Uint8List] para envio ao servidor.
  ///
  /// Esse método simplesmente escreve os dados de autenticação no buffer.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    buffer.write(authData);
    return buffer.toBytes();
  }
}
