import 'dart:typed_data';

import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

/// Representa o pacote "Column Count" do protocolo MySQL.
///
/// Esse pacote é enviado pelo servidor para indicar o número de colunas que serão retornadas
/// em um result set. O número de colunas é codificado como um inteiro com codificação length-encoded.
///
/// Essa classe é utilizada durante a leitura inicial de um result set para determinar quantas
/// colunas serão processadas posteriormente.
class MySQLPacketColumnCount extends MySQLPacketPayload {
  /// Número de colunas presentes no result set.
  final BigInt columnCount;

  /// Construtor da classe.
  MySQLPacketColumnCount({
    required this.columnCount,
  });

  /// Decodifica um buffer [Uint8List] recebido do servidor e cria uma instância de
  /// [MySQLPacketColumnCount].
  ///
  /// O buffer contém o número de colunas codificado como um inteiro com codificação length-encoded.
  /// A função [getVariableEncInt] é utilizada para extrair esse valor a partir do início do buffer.
  factory MySQLPacketColumnCount.decode(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    final columnCount = byteData.getVariableEncInt(0);
    
    return MySQLPacketColumnCount(
      columnCount: columnCount.item1,
    );
  }

  /// Método de codificação não implementado.
  @override
  Uint8List encode() {
    throw UnimplementedError("Encode não implementado para MySQLPacketColumnCount");
  }
}
