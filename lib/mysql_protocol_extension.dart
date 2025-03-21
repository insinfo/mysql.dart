import 'dart:convert';
import 'dart:typed_data';
import 'package:buffer/buffer.dart' show ByteDataWriter;
import 'package:mysql_dart/exception.dart';
import 'package:tuple/tuple.dart' show Tuple2;

/// Extensão para [Uint8List] contendo métodos auxiliares para ler strings e
/// dados length-encoded conforme o protocolo MySQL.
extension MySQLUint8ListExtension on Uint8List {
  /// Lê uma string UTF-8 terminada em nulo (null-terminated) a partir de [startOffset].
  ///
  /// Retorna uma [Tuple2] onde:
  /// - item1: A string decodificada.
  /// - item2: O número total de bytes consumidos (incluindo o byte nulo).
  ///
  /// No protocolo MySQL, algumas strings são terminadas em byte 0x00 para sinalizar fim.
  Tuple2<String, int> getUtf8NullTerminatedString(int startOffset) {
    // Obtém os bytes a partir de startOffset até encontrar um 0.
    final tmp = Uint8List.sublistView(this, startOffset)
        .takeWhile((value) => value != 0);

    // Decodifica para UTF-8 e retorna também o número de bytes consumidos
    // (conteúdo + 1 byte nulo).
    return Tuple2(utf8.decode(tmp.toList()), tmp.length + 1);
  }

  /// Lê uma string UTF-8 a partir de [startOffset] até o final do buffer.
  ///
  /// Retorna a string decodificada.
  ///
  /// Em algumas situações (por exemplo, mensagens de erro ou final de buffer),
  /// o protocolo envia o restante dos dados como texto até o EOF (End Of File).
  String getUtf8StringEOF(int startOffset) {
    final tmp = Uint8List.sublistView(this, startOffset);
    return utf8.decode(tmp);
  }

  /// Lê uma string UTF-8 length‑encoded a partir de [startOffset].
  ///
  /// O formato length‑encoded consiste em um inteiro (também length-encoded) que
  /// indica o tamanho da string, seguido pelos bytes da própria string.
  /// Retorna uma [Tuple2] onde:
  /// - item1: A string decodificada.
  /// - item2: O número total de bytes consumidos (tamanho do inteiro + tamanho da string).
  Tuple2<String, int> getUtf8LengthEncodedString(int startOffset) {
    // `tmp` contém a porção do buffer a partir de startOffset.
    final tmp = Uint8List.sublistView(this, startOffset);
    final bd = ByteData.sublistView(tmp);

    // Lê o tamanho da string (formato length-encoded).
    final strLength = bd.getVariableEncInt(0);

    // Lê a string exatamente com `strLength.item1` bytes.
    final tmp2 = Uint8List.sublistView(
      tmp,
      strLength.item2,
      strLength.item2 + strLength.item1.toInt(),
    );

    // Decodifica em UTF-8 e soma (tamanho do inteiro + tamanho da string).
    return Tuple2(
      utf8.decode(tmp2),
      strLength.item2 + strLength.item1.toInt(),
    );
  }

  /// Lê dados binários length‑encoded a partir de [startOffset].
  ///
  /// O protocolo MySQL frequentemente codifica campos binários em formato length-encoded,
  /// primeiro indicando quantos bytes serão lidos, depois os dados brutos.
  /// Retorna uma [Tuple2] onde:
  /// - item1: Um [Uint8List] contendo os bytes lidos.
  /// - item2: O número total de bytes consumidos (tamanho do inteiro + tamanho dos bytes).
  Tuple2<Uint8List, int> getLengthEncodedBytes(int startOffset) {
    final tmp = Uint8List.sublistView(this, startOffset);
    final bd = ByteData.sublistView(tmp);

    // Lê o tamanho em formato length-encoded.
    final lengthTuple = bd.getVariableEncInt(0);
    final length = lengthTuple.item1.toInt();
    final totalLength = lengthTuple.item2 + length;

    // Copia apenas `length` bytes após o inteiro que guarda o tamanho.
    final bytes = Uint8List.sublistView(tmp, lengthTuple.item2, totalLength);
    return Tuple2(bytes, totalLength);
  }
}

/// Extensão para [ByteData] contendo métodos auxiliares para ler inteiros
/// com codificação length‑encoded e outros inteiros de tamanhos específicos.
extension MySQLByteDataExtension on ByteData {
  /// Lê um inteiro length‑encoded a partir de [startOffset].
  ///
  /// O formato length‑encoded é definido pelo primeiro byte:
  /// - Se for < 0xfb, esse próprio byte é o valor.
  /// - Se for 0xfc, lê 2 bytes (uint16).
  /// - Se for 0xfd, lê 3 bytes (uint24).
  /// - Se for 0xfe, lê 8 bytes (uint64).
  ///
  /// Retorna uma [Tuple2]:
  /// - item1: valor lido como [BigInt].
  /// - item2: número total de bytes consumidos (1 para o header, +2/+3/+8, dependendo do caso).
  Tuple2<BigInt, int> getVariableEncInt(int startOffset) {
    final firstByte = getUint8(startOffset);

    if (firstByte < 0xfb) {
      // Valor direto (ex.: 0x05).
      return Tuple2(BigInt.from(firstByte), 1);
    }

    if (firstByte == 0xfc) {
      // Próximos 2 bytes.
      final radix = getUint8(startOffset + 2).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 1).toRadixString(16).padLeft(2, '0');
      return Tuple2(BigInt.parse(radix, radix: 16), 3);
    }

    if (firstByte == 0xfd) {
      // Próximos 3 bytes.
      final radix = getUint8(startOffset + 3).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 2).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 1).toRadixString(16).padLeft(2, '0');
      return Tuple2(BigInt.parse(radix, radix: 16), 4);
    }

    if (firstByte == 0xfe) {
      // Próximos 8 bytes.
      final radix = getUint8(startOffset + 8).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 7).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 6).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 5).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 4).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 3).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 2).toRadixString(16).padLeft(2, '0')
          + getUint8(startOffset + 1).toRadixString(16).padLeft(2, '0');
      return Tuple2(BigInt.parse(radix, radix: 16), 9);
    }

    throw MySQLProtocolException(
      "Wrong first byte, while decoding getVariableEncInt",
    );
  }

  /// Lê um inteiro de 2 bytes (little-endian) a partir de [startOffset].
  int getInt2(int startOffset) {
    final bd = ByteData(2);
    bd.setUint8(0, getUint8(startOffset));
    bd.setUint8(1, getUint8(startOffset + 1));
    return bd.getUint16(0, Endian.little);
  }

  /// Lê um inteiro de 3 bytes (little-endian) a partir de [startOffset].
  ///
  /// Esse formato (3 bytes) ocorre em algumas partes do protocolo
  /// que usam "int<3>" para valores como comprimentos ou contagens menores que 16M.
  int getInt3(int startOffset) {
    final bd = ByteData(4);
    bd.setUint8(0, getUint8(startOffset));
    bd.setUint8(1, getUint8(startOffset + 1));
    bd.setUint8(2, getUint8(startOffset + 2));
    bd.setUint8(3, 0);
    return bd.getUint32(0, Endian.little);
  }
}

/// Extensão para [ByteDataWriter] para adicionar a capacidade de escrever
/// inteiros com codificação length‑encoded conforme o protocolo MySQL.
extension MySQLByteWriterExtension on ByteDataWriter {
  /// Escreve um inteiro com codificação length‑encoded.
  ///
  /// - Se [value] for menor que 251, escreve-o como 1 byte.
  /// - Se [value] estiver entre 251 e 65535, escreve o marcador 0xfc seguido de 2 bytes.
  /// - Se [value] estiver entre 65536 e 16777215, escreve o marcador 0xfd seguido de 3 bytes.
  /// - Se [value] for maior ou igual a 16777216, escreve o marcador 0xfe seguido de 8 bytes.
  void writeVariableEncInt(int value) {
    if (value < 251) {
      // Valor de 1 byte.
      writeUint8(value);
    } else if (value >= 251 && value < 65536) {
      // 0xfc + 2 bytes.
      writeUint8(0xfc);
      writeInt16(value);
    } else if (value >= 65536 && value < 16777216) {
      // 0xfd + 3 bytes.
      writeUint8(0xfd);
      final bd = ByteData(4);
      bd.setInt32(0, value, Endian.little);
      write(bd.buffer.asUint8List().sublist(0, 3));
    } else if (value >= 16777216) {
      // 0xfe + 8 bytes.
      writeUint8(0xfe);
      writeInt64(value);
    }
  }
}
