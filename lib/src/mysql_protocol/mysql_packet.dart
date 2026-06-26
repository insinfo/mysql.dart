import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/src/utils/hash.dart';
import 'package:mysql_dart/src/utils/tuple2.dart';

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
  @pragma('vm:prefer-inline')
  static int getPacketLength(Uint8List buffer, [int offset = 0]) {
    return getPayloadLength(buffer, offset) + 4;
  }

  @pragma('vm:prefer-inline')
  static int getPayloadLength(Uint8List buffer, [int offset = 0]) {
    return buffer[offset] |
        (buffer[offset + 1] << 8) |
        (buffer[offset + 2] << 16);
  }

  @pragma('vm:prefer-inline')
  static int getSequenceId(Uint8List buffer, [int offset = 0]) {
    return buffer[offset + 3];
  }

  /// Decodifica o cabeçalho do pacote, retornando (payloadLength, sequenceID).
  static Tuple2<int, int> decodePacketHeader(Uint8List buffer) {
    return Tuple2(getPayloadLength(buffer), getSequenceId(buffer));
  }

  /// Detecta o tipo genérico do pacote com base no primeiro byte do payload.
  ///
  /// Observando o payload:
  /// - 0x00 -> OK (se payloadLength >= 7),
  /// - 0xfe -> EOF (se payloadLength < 9),
  /// - 0xff -> Error,
  /// - Caso contrário -> other.
  static MySQLGenericPacketType detectPacketType(Uint8List buffer) {
    final payloadLength = getPayloadLength(buffer);
    final type = buffer[4];
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
      Uint8List buffer, List<MySQLColumnDefinitionPacket> colDefs,
      {List<bool>? binaryColumns}) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final payload = MySQLResultSetRowPacket.decode(
      Uint8List.sublistView(buffer, offset),
      colDefs,
      binaryColumns: binaryColumns,
    );
    return MySQLPacket(
      sequenceID: header.item2,
      payloadLength: header.item1,
      payload: payload,
    );
  }

  /// Decodifica uma linha de ResultSet em formato binário [MySQLBinaryResultSetRowPacket].
  factory MySQLPacket.decodeBinaryResultSetRowPacket(
      Uint8List buffer, List<MySQLColumnDefinitionPacket> colDefs,
      {List<bool>? textualColumns}) {
    final header = decodePacketHeader(buffer);
    final offset = 4;
    final payload = MySQLBinaryResultSetRowPacket.decode(
      Uint8List.sublistView(buffer, offset),
      colDefs,
      textualColumns: textualColumns,
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
    final payloadLength = payloadData.lengthInBytes;
    final out = Uint8List(payloadLength + 4);
    out[0] = payloadLength & 0xFF;
    out[1] = (payloadLength >> 8) & 0xFF;
    out[2] = (payloadLength >> 16) & 0xFF;
    out[3] = sequenceID;
    out.setRange(4, out.length, payloadData);
    return out;
  }
}

/// Calcula o hash SHA1 dos dados [data].
List<int> sha1(List<int> data) {
  return sha1Digest(data);
}

/// Calcula o hash SHA256 dos dados [data].
List<int> sha256(List<int> data) {
  return sha256Digest(data);
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
