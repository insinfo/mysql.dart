import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';

/// Representa um payload vazio para pacotes MySQL.
///
/// Essa classe é utilizada quando o pacote MySQL não contém nenhum dado adicional
/// além do cabeçalho. Por exemplo, alguns pacotes de resposta (como OK ou EOF) podem
/// não precisar enviar informações no payload. O método [encode] não está implementado,
/// pois esse payload não deve ser enviado ao servidor.
class MySQLPacketEmptyPayload extends MySQLPacketPayload {
  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketEmptyPayload");
  }
}
