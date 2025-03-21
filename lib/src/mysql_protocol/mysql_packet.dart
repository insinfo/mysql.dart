import 'dart:typed_data';
import 'package:buffer/buffer.dart' show ByteDataWriter;
import 'package:crypto/crypto.dart' as crypto;
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:tuple/tuple.dart' show Tuple2;

//
// Constantes de flags de capabilities do protocolo MySQL
//
// Cada flag indica funcionalidades específicas que o cliente/servidor suportam ou não.
const mysqlCapFlagClientLongPassword = 0x00000001;
const mysqlCapFlagClientFoundRows = 0x00000002;
const mysqlCapFlagClientLongFlag = 0x00000004;
const mysqlCapFlagClientConnectWithDB = 0x00000008;
const mysqlCapFlagClientNoSchema = 0x00000010;
const mysqlCapFlagClientCompress = 0x00000020;
const mysqlCapFlagClientODBC = 0x00000040;
const mysqlCapFlagClientLocalFiles = 0x00000080;
const mysqlCapFlagClientIgnoreSpace = 0x00000100;
const mysqlCapFlagClientProtocol41 = 0x00000200;
const mysqlCapFlagClientInteractive = 0x00000400;
const mysqlCapFlagClientSsl = 0x00000800;
const mysqlCapFlagClientIgnoreSigPipe = 0x00001000;
const mysqlCapFlagClientTransactions = 0x00002000;
const mysqlCapFlagClientReserved = 0x00004000;
const mysqlCapFlagClientSecureConnection = 0x00008000;
const mysqlCapFlagClientMultiStatements = 0x00010000;
const mysqlCapFlagClientMultiResults = 0x00020000;
const mysqlCapFlagClientPsMultiResults = 0x00040000;
const mysqlCapFlagClientPluginAuth = 0x00080000;
const mysqlCapFlagClientPluginAuthLenEncClientData = 0x00200000;
const mysqlCapFlagClientDeprecateEOF = 0x01000000;

const mysqlServerFlagMoreResultsExists = 0x0008;

/// Enum que representa o tipo genérico de pacote MySQL.
enum MySQLGenericPacketType {
  /// Pacote OK (header 0x00).
  ok,

  /// Pacote de erro (header 0xff).
  error,

  /// Pacote EOF (header 0xfe).
  eof,

  /// Qualquer outro tipo de pacote não identificado.
  other
}

/// Interface que define um payload de pacote MySQL.
///
/// Cada payload deve ser capaz de se [encode]ar em um [Uint8List] para envio.
abstract class MySQLPacketPayload {
  Uint8List encode();
}

/// Representa um pacote MySQL completo, contendo cabeçalho (4 bytes) e payload.
///
/// O cabeçalho do pacote consiste em:
/// - 3 bytes para o tamanho do payload.
/// - 1 byte para sequenceID.
/// O [payload] contém o conteúdo real do pacote.
class MySQLPacket {
  /// Sequence ID do pacote, usado para garantir a ordem dos pacotes.
  int sequenceID;

  /// Tamanho do payload (excluindo os 4 bytes do cabeçalho).
  int payloadLength;

  /// Conteúdo do pacote.
  MySQLPacketPayload payload;

  MySQLPacket({
    required this.sequenceID,
    required this.payload,
    required this.payloadLength,
  });

  /// Retorna o tamanho total do pacote (cabeçalho de 4 bytes + payload).
  ///
  /// Lê os 3 primeiros bytes do [buffer] para calcular [payloadLength]
  /// e soma 4 (bytes do cabeçalho).
  static int getPacketLength(Uint8List buffer) {
    var header = ByteData(4)
      ..setUint8(0, buffer[0])
      ..setUint8(1, buffer[1])
      ..setUint8(2, buffer[2])
      ..setUint8(3, 0);
    final payloadLength = header.getUint32(0, Endian.little);
    return payloadLength + 4;
  }

  /// Decodifica o cabeçalho do pacote, retornando (payloadLength, sequenceID).
  static Tuple2<int, int> decodePacketHeader(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    // Lê os 3 primeiros bytes para payloadLength.
    var header = ByteData(4)
      ..setUint8(0, buffer[0])
      ..setUint8(1, buffer[1])
      ..setUint8(2, buffer[2])
      ..setUint8(3, 0);
    final payloadLength = header.getUint32(0, Endian.little);

    // O 4º byte é o sequenceNumber.
    final sequenceNumber = byteData.getUint8(3);
    return Tuple2(payloadLength, sequenceNumber);
  }

  /// Detecta o tipo genérico do pacote com base no primeiro byte do payload.
  ///
  /// Observando o payload:
  /// - 0x00 -> OK (se payloadLength >= 7),
  /// - 0xfe -> EOF (se payloadLength < 9),
  /// - 0xff -> Error,
  /// - Caso contrário -> other.
  static MySQLGenericPacketType detectPacketType(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    final header = decodePacketHeader(buffer);
    final payloadLength = header.item1;
    final type = byteData.getUint8(4);
    if (type == 0x00 && payloadLength >= 7) {
      return MySQLGenericPacketType.ok;
    } else if (type == 0xfe && payloadLength < 9) {
      return MySQLGenericPacketType.eof;
    } else if (type == 0xff) {
      return MySQLGenericPacketType.error;
    } else {
      return MySQLGenericPacketType.other;
    }
  }

  /// Decodifica um pacote de handshake inicial [MySQLPacketInitialHandshake].
  factory MySQLPacket.decodeInitialHandshake(Uint8List buffer) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final payload = MySQLPacketInitialHandshake.decode(
      Uint8List.sublistView(buffer, offset),
    );
    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Decodifica um pacote Auth Switch Request [MySQLPacketAuthSwitchRequest].
  factory MySQLPacket.decodeAuthSwitchRequestPacket(Uint8List buffer) {
    final byteData = ByteData.sublistView(buffer);
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final type = byteData.getUint8(offset);

    if (type != 0xfe) {
      throw MySQLProtocolException(
          "Cannot decode AuthSwitchResponse packet: type is not 0xfe");
    }

    final payload = MySQLPacketAuthSwitchRequest.decode(
      Uint8List.sublistView(buffer, offset),
    );
    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Decodifica um pacote genérico, podendo ser OK, EOF, ERROR, etc.
  factory MySQLPacket.decodeGenericPacket(Uint8List buffer) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final byteData = ByteData.sublistView(buffer);
    final payloadLength = header.item1;
    final type = byteData.getUint8(offset);

    late MySQLPacketPayload payload;
    if (type == 0x00 && payloadLength >= 7) {
      payload = MySQLPacketOK.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else if (type == 0xfe && payloadLength < 9) {
      payload = MySQLPacketEOF.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else if (type == 0xff) {
      payload = MySQLPacketError.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else if (type == 0x01) {
      // Extra Auth Data
      payload = MySQLPacketExtraAuthData.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else {
      throw MySQLProtocolException("Unsupported generic packet: $buffer");
    }

    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: payloadLength,
      payload: payload,
    );
  }

  /// Decodifica um pacote que contém a contagem de colunas [MySQLPacketColumnCount].
  factory MySQLPacket.decodeColumnCountPacket(Uint8List buffer) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final byteData = ByteData.sublistView(buffer);
    final type = byteData.getUint8(offset);
    late MySQLPacketPayload payload;

    if (type == 0x00) {
      payload = MySQLPacketOK.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else if (type == 0xff) {
      payload = MySQLPacketError.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else if (type == 0xfb) {
      throw MySQLProtocolException(
        "COM_QUERY_RESPONSE of type 0xfb is not implemented",
      );
    } else {
      payload = MySQLPacketColumnCount.decode(
        Uint8List.sublistView(buffer, offset),
      );
    }

    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Decodifica um pacote de definição de coluna [MySQLColumnDefinitionPacket].
  factory MySQLPacket.decodeColumnDefPacket(Uint8List buffer) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final payload = MySQLColumnDefinitionPacket.decode(
      Uint8List.sublistView(buffer, offset),
    );
    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Decodifica uma linha de ResultSet em formato textual [MySQLResultSetRowPacket].
  factory MySQLPacket.decodeResultSetRowPacket(
    Uint8List buffer,
    List<MySQLColumnDefinitionPacket> colDefs,
  ) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final payload = MySQLResultSetRowPacket.decode(
      Uint8List.sublistView(buffer, offset),
      colDefs,
    );
    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Decodifica uma linha de ResultSet em formato binário [MySQLBinaryResultSetRowPacket].
  factory MySQLPacket.decodeBinaryResultSetRowPacket(
    Uint8List buffer,
    List<MySQLColumnDefinitionPacket> colDefs,
  ) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final payload = MySQLBinaryResultSetRowPacket.decode(
      Uint8List.sublistView(buffer, offset),
      colDefs,
    );
    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Decodifica a resposta ao COM_STMT_PREPARE [MySQLPacketStmtPrepareOK] ou error.
  factory MySQLPacket.decodeCommPrepareStmtResponsePacket(Uint8List buffer) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final byteData = ByteData.sublistView(buffer);
    final type = byteData.getUint8(offset);

    late MySQLPacketPayload payload;
    if (type == 0x00) {
      payload = MySQLPacketStmtPrepareOK.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else if (type == 0xff) {
      payload = MySQLPacketError.decode(
        Uint8List.sublistView(buffer, offset),
      );
    } else {
      throw MySQLProtocolException(
        "Unexpected header type while decoding COM_STMT_PREPARE response: $header",
      );
    }

    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Retorna verdadeiro se o payload for um pacote OK.
  bool isOkPacket() => payload is MySQLPacketOK;

  /// Retorna verdadeiro se o payload for um pacote de erro.
  bool isErrorPacket() => payload is MySQLPacketError;

  /// Retorna verdadeiro se o payload for um pacote EOF.
  bool isEOFPacket() {
    if (payload is MySQLPacketEOF) {
      return true;
    }
    // Alguns servidores enviam OK com header 0xfe e payloadLength < 9 como EOF
    if (payload is MySQLPacketOK &&
        payloadLength < 9 &&
        (payload as MySQLPacketOK).header == 0xfe) {
      return true;
    }
    return false;
  }

  /// Codifica o pacote (cabeçalho + payload) em um [Uint8List] para envio ao servidor.
  Uint8List encode() {
    final payloadData = payload.encode();

    // Prepara 4 bytes para o cabeçalho:
    // 3 bytes para length, 1 para sequenceID.
    final header = ByteData(4);
    header.setUint8(0, payloadData.lengthInBytes & 0xFF);
    header.setUint8(1, (payloadData.lengthInBytes >> 8) & 0xFF);
    header.setUint8(2, (payloadData.lengthInBytes >> 16) & 0xFF);
    header.setUint8(3, sequenceID);

    final writer = ByteDataWriter(endian: Endian.little);
    writer.write(header.buffer.asUint8List());
    writer.write(payloadData);
    return writer.toBytes();
  }
}

/// Calcula o hash SHA1 dos dados [data].
List<int> sha1(List<int> data) {
  return crypto.sha1.convert(data).bytes;
}

/// Calcula o hash SHA256 dos dados [data].
List<int> sha256(List<int> data) {
  return crypto.sha256.convert(data).bytes;
}

/// Realiza a operação XOR entre dois arrays de bytes [aList] e [bList].
///
/// Se um array for menor, os bytes faltantes são considerados 0.
/// Retorna um [Uint8List] com o resultado do XOR byte a byte.
Uint8List xor(List<int> aList, List<int> bList) {
  final a = Uint8List.fromList(aList);
  final b = Uint8List.fromList(bList);
  if (a.isEmpty || b.isEmpty) {
    throw ArgumentError("Uint8List arguments must not be empty");
  }
  final length = a.length > b.length ? a.length : b.length;
  final buffer = Uint8List(length);

  for (int i = 0; i < length; i++) {
    final aa = i < a.length ? a[i] : 0;
    final bb = i < b.length ? b[i] : 0;
    buffer[i] = aa ^ bb;
  }
  return buffer;
}
