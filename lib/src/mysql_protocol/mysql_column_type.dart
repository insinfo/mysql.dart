import 'dart:typed_data';
import 'package:tuple/tuple.dart';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

/// Constantes que representam os tipos de coluna do MySQL conforme o protocolo.
const mysqlColumnTypeDecimal = 0x00;
const mysqlColumnTypeTiny = 0x01;
const mysqlColumnTypeShort = 0x02;
const mysqlColumnTypeLong = 0x03;
const mysqlColumnTypeFloat = 0x04;
const mysqlColumnTypeDouble = 0x05;
const mysqlColumnTypeNull = 0x06;
const mysqlColumnTypeTimestamp = 0x07;
const mysqlColumnTypeLongLong = 0x08;
const mysqlColumnTypeInt24 = 0x09;
const mysqlColumnTypeDate = 0x0a;
const mysqlColumnTypeTime = 0x0b;
const mysqlColumnTypeDateTime = 0x0c;
const mysqlColumnTypeYear = 0x0d; // 13 decimal
const mysqlColumnTypeNewDate = 0x0e;
const mysqlColumnTypeVarChar = 0x0f;
const mysqlColumnTypeBit = 0x10;
const mysqlColumnTypeTimestamp2 = 0x11;
const mysqlColumnTypeDateTime2 = 0x12;
const mysqlColumnTypeTime2 = 0x13;

/// A partir do MySQL 5.7, colunas JSON podem ser reportadas como 0xf5
const mysqlColumnTypeJson = 0xf5;

const mysqlColumnTypeNewDecimal = 0xf6;
const mysqlColumnTypeEnum = 0xf7;
const mysqlColumnTypeSet = 0xf8;
const mysqlColumnTypeTinyBlob = 0xf9;
const mysqlColumnTypeMediumBlob = 0xfa;
const mysqlColumnTypeLongBlob = 0xfb;
const mysqlColumnTypeBlob = 0xfc;
const mysqlColumnTypeVarString = 0xfd;
const mysqlColumnTypeString = 0xfe;
const mysqlColumnTypeGeometry = 0xff;

/// Representa o tipo de uma coluna no MySQL.
///
/// Essa classe encapsula o valor numérico que identifica o tipo de coluna
/// e fornece métodos para converter valores lidos do MySQL para tipos Dart,
/// além de determinar o melhor tipo Dart para representar os dados.
class MySQLColumnType {
  final int _value;

  /// Construtor privado que define o valor interno.
  const MySQLColumnType._(int value) : _value = value;

  /// Cria uma instância de [MySQLColumnType] a partir de um valor inteiro.
  factory MySQLColumnType.create(int value) => MySQLColumnType._(value);

  /// Retorna o valor inteiro interno que representa o tipo.
  int get intVal => _value;

  // Constantes para cada tipo de coluna (mapeadas às acima)
  static const decimalType = MySQLColumnType._(mysqlColumnTypeDecimal);
  static const tinyType = MySQLColumnType._(mysqlColumnTypeTiny);
  static const shortType = MySQLColumnType._(mysqlColumnTypeShort);
  static const longType = MySQLColumnType._(mysqlColumnTypeLong);
  static const floatType = MySQLColumnType._(mysqlColumnTypeFloat);
  static const doubleType = MySQLColumnType._(mysqlColumnTypeDouble);
  static const nullType = MySQLColumnType._(mysqlColumnTypeNull);
  static const timestampType = MySQLColumnType._(mysqlColumnTypeTimestamp);
  static const longLongType = MySQLColumnType._(mysqlColumnTypeLongLong);
  static const int24Type = MySQLColumnType._(mysqlColumnTypeInt24);
  static const dateType = MySQLColumnType._(mysqlColumnTypeDate);
  static const timeType = MySQLColumnType._(mysqlColumnTypeTime);
  static const dateTimeType = MySQLColumnType._(mysqlColumnTypeDateTime);
  static const yearType = MySQLColumnType._(mysqlColumnTypeYear);
  static const newDateType = MySQLColumnType._(mysqlColumnTypeNewDate);
  static const varCharType = MySQLColumnType._(mysqlColumnTypeVarChar);
  static const bitType = MySQLColumnType._(mysqlColumnTypeBit);
  static const timestamp2Type = MySQLColumnType._(mysqlColumnTypeTimestamp2);
  static const dateTime2Type = MySQLColumnType._(mysqlColumnTypeDateTime2);
  static const time2Type = MySQLColumnType._(mysqlColumnTypeTime2);

  /// Novo: JSON
  static const jsonType = MySQLColumnType._(mysqlColumnTypeJson);

  static const newDecimalType = MySQLColumnType._(mysqlColumnTypeNewDecimal);
  static const enumType = MySQLColumnType._(mysqlColumnTypeEnum);
  static const setType = MySQLColumnType._(mysqlColumnTypeSet);
  static const tinyBlobType = MySQLColumnType._(mysqlColumnTypeTinyBlob);
  static const mediumBlobType = MySQLColumnType._(mysqlColumnTypeMediumBlob);
  static const longBlobType = MySQLColumnType._(mysqlColumnTypeLongBlob);
  static const blobType = MySQLColumnType._(mysqlColumnTypeBlob);
  static const varStringType = MySQLColumnType._(mysqlColumnTypeVarString);
  static const stringType = MySQLColumnType._(mysqlColumnTypeString);
  static const geometryType = MySQLColumnType._(mysqlColumnTypeGeometry);

  /// Converte um valor (normalmente lido do MySQL em formato string ou binário)
  /// para o tipo Dart desejado [T].
  ///
  /// [value]: valor lido (pode ser uma string ou Uint8List, dependendo da coluna).
  /// [columnLength]: (opcional) o tamanho da coluna, usado para decisões de conversão.
  ///
  /// Se o valor for nulo, retorna `null`.
  /// Se [T] for `Uint8List` e o valor já for do tipo `Uint8List`, retorna-o diretamente.
  /// Se [T] for `String` ou `dynamic`, retorna o valor como está.
  /// Para tipos numéricos, bool ou DateTime, o método tenta converter a string
  /// utilizando as funções parse correspondentes.
  ///
  /// Lança [MySQLProtocolException] se não for possível converter.
  T? convertStringValueToProvidedType<T>(dynamic value, [int? columnLength]) {
    if (value == null) {
      return null;
    }

    // Se T é Uint8List e o valor já é desse tipo, retorna direto.
    if (T == Uint8List && value is Uint8List) {
      return value as T;
    }

    // Se T é String ou dynamic, retornamos como está.
    if (T == String || T == dynamic) {
      return value as T;
    }

    // Se T é bool e o tipo é TINY(1), convertendo '0' ou '1'.
    if (T == bool) {
      if (_value == mysqlColumnTypeTiny && columnLength == 1) {
        return int.parse(value) > 0 as T;
      } else {
        throw MySQLProtocolException(
          "Cannot convert MySQL type $_value to requested type bool",
        );
      }
    }

    // Conversão para int
    if (T == int) {
      switch (_value) {
        case mysqlColumnTypeTiny:
        case mysqlColumnTypeShort:
        case mysqlColumnTypeLong:
        case mysqlColumnTypeLongLong:
        case mysqlColumnTypeInt24:
        case mysqlColumnTypeYear:
          return int.parse(value) as T;
        default:
          throw MySQLProtocolException(
            "Cannot convert MySQL type $_value to requested type int",
          );
      }
    }

    // Conversão para double
    if (T == double) {
      switch (_value) {
        case mysqlColumnTypeTiny:
        case mysqlColumnTypeShort:
        case mysqlColumnTypeLong:
        case mysqlColumnTypeLongLong:
        case mysqlColumnTypeInt24:
        case mysqlColumnTypeFloat:
        case mysqlColumnTypeDouble:
          return double.parse(value) as T;
        default:
          throw MySQLProtocolException(
            "Cannot convert MySQL type $_value to requested type double",
          );
      }
    }

    // Conversão para num
    if (T == num) {
      switch (_value) {
        case mysqlColumnTypeTiny:
        case mysqlColumnTypeShort:
        case mysqlColumnTypeLong:
        case mysqlColumnTypeLongLong:
        case mysqlColumnTypeInt24:
        case mysqlColumnTypeFloat:
        case mysqlColumnTypeDouble:
          return num.parse(value) as T;
        default:
          throw MySQLProtocolException(
            "Cannot convert MySQL type $_value to requested type num",
          );
      }
    }

    // Conversão para DateTime
    if (T == DateTime) {
      switch (_value) {
        case mysqlColumnTypeDate:
        case mysqlColumnTypeDateTime2:
        case mysqlColumnTypeDateTime:
        case mysqlColumnTypeTimestamp:
        case mysqlColumnTypeTimestamp2:
          return DateTime.parse(value) as T;
        default:
          throw MySQLProtocolException(
            "Cannot convert MySQL type $_value to requested type DateTime",
          );
      }
    }

    throw MySQLProtocolException(
      "Cannot convert MySQL type $_value to requested type ${T.runtimeType}",
    );
  }

  /// Retorna o melhor tipo Dart para representar os dados da coluna, levando
  /// em consideração o tamanho da coluna ([columnLength]) e o tipo MySQL (_value).
  ///
  /// Por exemplo, tipos textuais são mapeados para [String], enquanto tipos BLOB
  /// são mapeados para [Uint8List]. Alguns tipos numéricos são mapeados para [int]
  /// ou [double].
  Type getBestMatchDartType(int columnLength) {
    switch (_value) {
      // Para JSON, definimos como string:
      case mysqlColumnTypeJson:
        return String;

      // Tipos de texto e enumerações → String.
      case mysqlColumnTypeString:
      case mysqlColumnTypeVarString:
      case mysqlColumnTypeVarChar:
      case mysqlColumnTypeEnum:
      case mysqlColumnTypeSet:
        return String;

      // Tipos BLOB → Uint8List.
      case mysqlColumnTypeLongBlob:
      case mysqlColumnTypeMediumBlob:
      case mysqlColumnTypeBlob:
      case mysqlColumnTypeTinyBlob:
        return Uint8List;

      // Outros tipos que preferimos como String (ex.: DECIMAL, BIT, etc.).
      case mysqlColumnTypeGeometry:
      case mysqlColumnTypeBit:
      case mysqlColumnTypeDecimal:
      case mysqlColumnTypeNewDecimal:
        return String;

      // TINY(1) → bool; senão int.
      case mysqlColumnTypeTiny:
        if (columnLength == 1) {
          return bool;
        } else {
          return int;
        }

      case mysqlColumnTypeShort:
      case mysqlColumnTypeLong:
      case mysqlColumnTypeLongLong:
      case mysqlColumnTypeInt24:
      case mysqlColumnTypeYear:
        return int;

      case mysqlColumnTypeFloat:
      case mysqlColumnTypeDouble:
        return double;

      case mysqlColumnTypeDate:
      case mysqlColumnTypeDateTime2:
      case mysqlColumnTypeDateTime:
      case mysqlColumnTypeTimestamp:
      case mysqlColumnTypeTimestamp2:
        return DateTime;

      default:
        // Se não reconhecemos, devolvemos como String.
        return String;
    }
  }
}

/// Função auxiliar para analisar dados de coluna em formato binário.
///
/// [columnType]: O tipo da coluna (valor inteiro representando o tipo MySQL).
/// [data]: Um [ByteData] que fornece acesso aos bytes do buffer.
/// [buffer]: O [Uint8List] original contendo os dados.
/// [startOffset]: A posição inicial no buffer para leitura.
///
/// Retorna uma [Tuple2] contendo:
/// - item1: O valor lido da coluna (geralmente convertido para string ou,
///   em casos binários, um [Uint8List]).
/// - item2: O número de bytes consumidos durante a leitura.
///
/// Caso o tipo da coluna não seja implementado, lança [MySQLProtocolException].
Tuple2<dynamic, int> parseBinaryColumnData(
  int columnType,
  ByteData data,
  Uint8List buffer,
  int startOffset,
) {
  switch (columnType) {
    case mysqlColumnTypeTiny:
      {
        final value = data.getInt8(startOffset);
        return Tuple2(value.toString(), 1);
      }

    case mysqlColumnTypeShort:
      {
        final value = data.getInt16(startOffset, Endian.little);
        return Tuple2(value.toString(), 2);
      }

    case mysqlColumnTypeLong:
    case mysqlColumnTypeInt24:
      {
        final value = data.getInt32(startOffset, Endian.little);
        return Tuple2(value.toString(), 4);
      }

    case mysqlColumnTypeLongLong:
      {
        final value = data.getInt64(startOffset, Endian.little);
        return Tuple2(value.toString(), 8);
      }

    case mysqlColumnTypeFloat:
      {
        final value = data.getFloat32(startOffset, Endian.little);
        return Tuple2(value.toString(), 4);
      }

    case mysqlColumnTypeDouble:
      {
        final value = data.getFloat64(startOffset, Endian.little);
        return Tuple2(value.toString(), 8);
      }

    case mysqlColumnTypeDate:
    case mysqlColumnTypeDateTime:
    case mysqlColumnTypeTimestamp:
      {
        final initialOffset = startOffset;
        // Lê o número de bytes (pode ser 0, 4, 7 ou 11)
        final numOfBytes = data.getUint8(startOffset);
        startOffset += 1;

        // Quando numOfBytes == 0, MySQL envia datas/timestamps '0000-00-00 00:00:00'
        if (numOfBytes == 0) {
          return Tuple2("0000-00-00 00:00:00", 1);
        }

        var year = 0, month = 0, day = 0;
        var hour = 0, minute = 0, second = 0, microSecond = 0;

        if (numOfBytes >= 4) {
          year = data.getUint16(startOffset, Endian.little);
          startOffset += 2;
          month = data.getUint8(startOffset);
          startOffset += 1;
          day = data.getUint8(startOffset);
          startOffset += 1;
        }
        if (numOfBytes >= 7) {
          hour = data.getUint8(startOffset);
          startOffset += 1;
          minute = data.getUint8(startOffset);
          startOffset += 1;
          second = data.getUint8(startOffset);
          startOffset += 1;
        }
        if (numOfBytes >= 11) {
          microSecond = data.getUint32(startOffset, Endian.little);
          startOffset += 4;
        }

        final result = StringBuffer()
          ..write('$year-')
          ..write('${month.toString().padLeft(2, '0')}-')
          ..write('${day.toString().padLeft(2, '0')} ')
          ..write('${hour.toString().padLeft(2, '0')}:')
          ..write('${minute.toString().padLeft(2, '0')}:')
          ..write(second.toString().padLeft(2, '0'));

        if (numOfBytes >= 11) {
          result.write('.$microSecond');
        }

        final consumed = startOffset - initialOffset;
        return Tuple2(result.toString(), consumed);
      }

    case mysqlColumnTypeTime:
    case mysqlColumnTypeTime2:
      {
        final initialOffset = startOffset;
        // Lê o número de bytes (pode ser 0, 8 ou 12)
        final numOfBytes = data.getUint8(startOffset);
        startOffset += 1;

        if (numOfBytes == 0) {
          return Tuple2("00:00:00", 1);
        }

        var isNegative = false;
        var days = 0, hours = 0, minutes = 0, seconds = 0, microSecond = 0;

        if (numOfBytes >= 8) {
          isNegative = data.getUint8(startOffset) > 0;
          startOffset += 1;
          days = data.getUint32(startOffset, Endian.little);
          startOffset += 4;
          hours = data.getUint8(startOffset);
          startOffset += 1;
          minutes = data.getUint8(startOffset);
          startOffset += 1;
          seconds = data.getUint8(startOffset);
          startOffset += 1;
        }

        if (numOfBytes >= 12) {
          microSecond = data.getUint32(startOffset, Endian.little);
          startOffset += 4;
        }

        hours += days * 24;
        final timeResult = StringBuffer();
        if (isNegative) {
          timeResult.write("-");
        }
        timeResult.write('${hours.toString().padLeft(2, '0')}:');
        timeResult.write('${minutes.toString().padLeft(2, '0')}:');
        timeResult.write(seconds.toString().padLeft(2, '0'));

        if (numOfBytes >= 12) {
          timeResult.write('.${microSecond.toString()}');
        }

        final consumed = startOffset - initialOffset;
        return Tuple2(timeResult.toString(), consumed);
      }

    case mysqlColumnTypeString:
    case mysqlColumnTypeVarString:
    case mysqlColumnTypeVarChar:
    case mysqlColumnTypeEnum:
    case mysqlColumnTypeSet:
      {
        // Dados textuais length-encoded
        final result = buffer.getUtf8LengthEncodedString(startOffset);
        return Tuple2(result.item1, result.item2);
      }

    case mysqlColumnTypeDecimal:
    case mysqlColumnTypeNewDecimal:
      {
        final lengthEncoded = buffer.getLengthEncodedBytes(startOffset);
        // Converte ASCII para string, p. ex. "99.99"
        final strValue = String.fromCharCodes(lengthEncoded.item1);
        return Tuple2(strValue, lengthEncoded.item2);
      }

    case mysqlColumnTypeLongBlob:
    case mysqlColumnTypeMediumBlob:
    case mysqlColumnTypeBlob:
    case mysqlColumnTypeTinyBlob:
    case mysqlColumnTypeGeometry:
    case mysqlColumnTypeBit:
      {
        // Para dados binários, retorna os bytes crus
        final lengthEncoded = buffer.getLengthEncodedBytes(startOffset);
        return Tuple2(lengthEncoded.item1, lengthEncoded.item2);
      }

    case mysqlColumnTypeYear:
      {
        // Lê 2 bytes para YEAR
        final yearValue = data.getUint16(startOffset, Endian.little);
        return Tuple2(yearValue.toString(), 2);
      }
  }

  throw MySQLProtocolException(
    "Can not parse binary column data: column type $columnType is not implemented",
  );
}
