import 'dart:convert';
import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/src/utils/byte_data_writer.dart';
import 'package:mysql_dart/src/utils/tuple2.dart';

/// Extensão para [Uint8List] contendo métodos auxiliares para ler strings e
/// dados length-encoded conforme o protocolo MySQL.
extension MySQLUint8ListExtension on Uint8List {
  @pragma('vm:prefer-inline')
  Tuple2<BigInt, int> getVariableEncIntAt(int startOffset) {
    final firstByte = this[startOffset];

    if (firstByte < 0xfb) {
      return Tuple2(BigInt.from(firstByte), 1);
    }

    if (firstByte == 0xfc) {
      final value = this[startOffset + 1] | (this[startOffset + 2] << 8);
      return Tuple2(BigInt.from(value), 3);
    }

    if (firstByte == 0xfd) {
      final value = this[startOffset + 1] |
          (this[startOffset + 2] << 8) |
          (this[startOffset + 3] << 16);
      return Tuple2(BigInt.from(value), 4);
    }

    if (firstByte == 0xfe) {
      final low = this[startOffset + 1] |
          (this[startOffset + 2] << 8) |
          (this[startOffset + 3] << 16) |
          (this[startOffset + 4] << 24);
      final high = this[startOffset + 5] |
          (this[startOffset + 6] << 8) |
          (this[startOffset + 7] << 16) |
          (this[startOffset + 8] << 24);

      return Tuple2(
        (BigInt.from(high) << 32) | BigInt.from(low & 0xffffffff),
        9,
      );
    }

    throw MySQLProtocolException(
      "Wrong first byte, while decoding getVariableEncInt",
    );
  }

  /// Lê uma string UTF-8 terminada em nulo (null-terminated) a partir de [startOffset].
  ///
  /// Retorna uma [Tuple2] onde:
  /// - item1: A string decodificada.
  /// - item2: O número total de bytes consumidos (incluindo o byte nulo).
  ///
  /// No protocolo MySQL, algumas strings são terminadas em byte 0x00 para sinalizar fim.
  Tuple2<String, int> getUtf8NullTerminatedString(int startOffset) {
    var endOffset = startOffset;
    while (endOffset < length && this[endOffset] != 0) {
      endOffset++;
    }

    return Tuple2(
      utf8.decode(Uint8List.sublistView(this, startOffset, endOffset)),
      (endOffset - startOffset) + 1,
    );
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
    final strLength = getVariableEncIntAt(startOffset);
    final stringOffset = startOffset + strLength.item2;

    // Lê a string exatamente com `strLength.item1` bytes.
    final tmp2 = Uint8List.sublistView(
      this,
      stringOffset,
      stringOffset + strLength.item1.toInt(),
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
    final lengthTuple = getVariableEncIntAt(startOffset);
    final length = lengthTuple.item1.toInt();
    final totalLength = lengthTuple.item2 + length;

    // Copia apenas `length` bytes após o inteiro que guarda o tamanho.
    final bytes = Uint8List.sublistView(
      this,
      startOffset + lengthTuple.item2,
      startOffset + totalLength,
    );
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
      return Tuple2(BigInt.from(getUint16(startOffset + 1, Endian.little)), 3);
    }

    if (firstByte == 0xfd) {
      final value = getUint16(startOffset + 1, Endian.little) |
          (getUint8(startOffset + 3) << 16);
      return Tuple2(BigInt.from(value), 4);
    }

    if (firstByte == 0xfe) {
      final low = getUint32(startOffset + 1, Endian.little);
      final high = getUint32(startOffset + 5, Endian.little);
      return Tuple2((BigInt.from(high) << 32) | BigInt.from(low), 9);
    }

    throw MySQLProtocolException(
      "Wrong first byte, while decoding getVariableEncInt",
    );
  }

  /// Lê um inteiro de 2 bytes (little-endian) a partir de [startOffset].
  int getInt2(int startOffset) {
    return getUint8(startOffset) | (getUint8(startOffset + 1) << 8);
  }

  /// Lê um inteiro de 3 bytes (little-endian) a partir de [startOffset].
  ///
  /// Esse formato (3 bytes) ocorre em algumas partes do protocolo
  /// que usam "int<3>" para valores como comprimentos ou contagens menores que 16M.
  int getInt3(int startOffset) {
    return getUint8(startOffset) |
        (getUint8(startOffset + 1) << 8) |
        (getUint8(startOffset + 2) << 16);
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
