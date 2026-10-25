import 'dart:convert';
import 'dart:typed_data';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/src/mysql_protocol/column_utils.dart';

typedef _Nullable<X> = X?;

@pragma('vm:prefer-inline')
bool _matchesType<T, U>() => T == U || T == _Nullable<U>;

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

    if (T == dynamic || _matchesType<T, Object>()) {
      return value as T;
    }

    if (_matchesType<T, Uint8List>()) {
      if (value is Uint8List) {
        return value as T;
      }
      throw MySQLProtocolException(
        'Cannot convert MySQL type $_value (${value.runtimeType}) to requested type $T',
      );
    }

    if (value is! String) {
      throw MySQLProtocolException(
        'Cannot convert MySQL type $_value (${value.runtimeType}) to requested type $T',
      );
    }

    return _convertStringToType<T>(value, columnLength);
  }

  T? _convertStringToType<T>(String value, int? columnLength) {
    if (_matchesType<T, String>()) {
      return value as T;
    }
    if (_matchesType<T, bool>() &&
        _value == mysqlColumnTypeTiny &&
        columnLength == 1) {
      return (int.parse(value) > 0) as T;
    }
    if (_matchesType<T, int>() && _canConvertToInt()) {
      return int.parse(value) as T;
    }
    if (_matchesType<T, double>() && _canConvertToNum()) {
      return double.parse(value) as T;
    }
    if (_matchesType<T, num>() && _canConvertToNum()) {
      return num.parse(value) as T;
    }
    if (_matchesType<T, DateTime>() && _canConvertToDateTime()) {
      return tryParseMySqlDateTime(value) as T?;
    }

    throw MySQLProtocolException(
      'Cannot convert MySQL type $_value to requested type $T',
    );
  }

  bool _canConvertToInt() {
    switch (_value) {
      case mysqlColumnTypeTiny:
      case mysqlColumnTypeShort:
      case mysqlColumnTypeLong:
      case mysqlColumnTypeLongLong:
      case mysqlColumnTypeInt24:
      case mysqlColumnTypeYear:
        return true;
      default:
        return false;
    }
  }

  bool _canConvertToNum() {
    switch (_value) {
      case mysqlColumnTypeTiny:
      case mysqlColumnTypeShort:
      case mysqlColumnTypeLong:
      case mysqlColumnTypeLongLong:
      case mysqlColumnTypeInt24:
      case mysqlColumnTypeFloat:
      case mysqlColumnTypeDouble:
        return true;
      default:
        return false;
    }
  }

  bool _canConvertToDateTime() {
    switch (_value) {
      case mysqlColumnTypeDate:
      case mysqlColumnTypeDateTime2:
      case mysqlColumnTypeDateTime:
      case mysqlColumnTypeTimestamp:
      case mysqlColumnTypeTimestamp2:
        return true;
      default:
        return false;
    }
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
/// Retorna um record `(dynamic, int)` contendo:
/// - `$1`: O valor lido da coluna (geralmente convertido para string ou,
///   em casos binários, um [Uint8List]).
/// - `$2`: O número de bytes consumidos durante a leitura.
///
/// Caso o tipo da coluna não seja implementado, lança [MySQLProtocolException].
(dynamic, int) parseBinaryColumnData(
  int columnType,
  ByteData data,
  Uint8List buffer,
  int startOffset, {
  bool unsigned = false,
}) {
  final limit =
      data.lengthInBytes < buffer.length ? data.lengthInBytes : buffer.length;
  if (startOffset < 0) {
    throw const MySQLProtocolException(
      'Invalid negative startOffset while parsing binary column data',
    );
  }

  // [unsigned] comes from the column's UNSIGNED flag: without it a
  // TINYINT UNSIGNED 200 was read as -56 (and so on for every width).
  switch (columnType) {
    case mysqlColumnTypeTiny:
      _requireBinaryBytes(startOffset, 1, limit);
      final value =
          unsigned ? data.getUint8(startOffset) : data.getInt8(startOffset);
      return (value.toString(), 1);

    case mysqlColumnTypeShort:
      _requireBinaryBytes(startOffset, 2, limit);
      final value = unsigned
          ? data.getUint16(startOffset, Endian.little)
          : data.getInt16(startOffset, Endian.little);
      return (value.toString(), 2);

    case mysqlColumnTypeLong:
    case mysqlColumnTypeInt24:
      _requireBinaryBytes(startOffset, 4, limit);
      final value = unsigned
          ? data.getUint32(startOffset, Endian.little)
          : data.getInt32(startOffset, Endian.little);
      return (value.toString(), 4);

    case mysqlColumnTypeLongLong:
      return _parseBinaryLongLong(data, startOffset, limit, unsigned);

    case mysqlColumnTypeFloat:
      _requireBinaryBytes(startOffset, 4, limit);
      final value = data.getFloat32(startOffset, Endian.little);
      return (value.toString(), 4);

    case mysqlColumnTypeDouble:
      _requireBinaryBytes(startOffset, 8, limit);
      final value = data.getFloat64(startOffset, Endian.little);
      return (value.toString(), 8);

    case mysqlColumnTypeDate:
    case mysqlColumnTypeDateTime:
    case mysqlColumnTypeTimestamp:
      return _parseBinaryDateTime(data, startOffset, limit);

    case mysqlColumnTypeTime:
    case mysqlColumnTypeTime2:
      return _parseBinaryTime(data, startOffset, limit);

    case mysqlColumnTypeString:
    case mysqlColumnTypeVarString:
    case mysqlColumnTypeVarChar:
    case mysqlColumnTypeEnum:
    case mysqlColumnTypeSet:
    case mysqlColumnTypeJson:
    case mysqlColumnTypeDecimal:
    case mysqlColumnTypeNewDecimal:
      final slice = readLengthEncodedSlice(
        buffer,
        startOffset,
        limit,
        allowNullMarker: false,
      );
      final strValue = utf8.decode(slice.bytes!, allowMalformed: true);
      return (strValue, slice.nextOffset - startOffset);

    case mysqlColumnTypeLongBlob:
    case mysqlColumnTypeMediumBlob:
    case mysqlColumnTypeBlob:
    case mysqlColumnTypeTinyBlob:
    case mysqlColumnTypeGeometry:
    case mysqlColumnTypeBit:
      final slice = readLengthEncodedSlice(
        buffer,
        startOffset,
        limit,
        allowNullMarker: false,
      );
      return (slice.bytes!, slice.nextOffset - startOffset);

    case mysqlColumnTypeYear:
      _requireBinaryBytes(startOffset, 2, limit);
      final yearValue = data.getUint16(startOffset, Endian.little);
      return (yearValue.toString(), 2);
  }

  throw MySQLProtocolException(
    "Can not parse binary column data: column type $columnType is not implemented",
  );
}

void _requireBinaryBytes(int startOffset, int count, int limit) {
  if (startOffset < 0 || startOffset > limit - count) {
    throw const MySQLProtocolException(
      'Truncated buffer while parsing binary column data',
    );
  }
}

(String, int) _parseBinaryLongLong(
  ByteData data,
  int startOffset,
  int limit,
  bool unsigned,
) {
  _requireBinaryBytes(startOffset, 8, limit);
  final value = data.getInt64(startOffset, Endian.little);
  if (unsigned && value < 0) {
    // Above 2^63 - 1: the two's-complement int64 plus 2^64.
    return ((BigInt.from(value) + (BigInt.one << 64)).toString(), 8);
  }
  return (value.toString(), 8);
}

(String, int) _parseBinaryDateTime(
  ByteData data,
  int startOffset,
  int limit,
) {
  _requireBinaryBytes(startOffset, 1, limit);
  final numOfBytes = data.getUint8(startOffset);
  if (numOfBytes == 0) {
    return ('0000-00-00 00:00:00', 1);
  }
  if (numOfBytes != 4 && numOfBytes != 7 && numOfBytes != 11) {
    throw MySQLProtocolException(
      'Invalid binary date/datetime length: $numOfBytes',
    );
  }
  _requireBinaryBytes(startOffset, 1 + numOfBytes, limit);

  var offset = startOffset + 1;
  final year = data.getUint16(offset, Endian.little);
  final month = data.getUint8(offset + 2);
  final day = data.getUint8(offset + 3);
  offset += 4;

  var hour = 0, minute = 0, second = 0, microSecond = 0;
  if (numOfBytes >= 7) {
    hour = data.getUint8(offset);
    minute = data.getUint8(offset + 1);
    second = data.getUint8(offset + 2);
    offset += 3;
  }
  if (numOfBytes == 11) {
    microSecond = data.getUint32(offset, Endian.little);
  }

  // Zero-padded like the text protocol: an unpadded year (999) failed
  // DateTime.parse, and unpadded microseconds (5000 -> ".5000") read
  // as half a second.
  final result = StringBuffer()
    ..write('${year.toString().padLeft(4, '0')}-')
    ..write('${month.toString().padLeft(2, '0')}-')
    ..write('${day.toString().padLeft(2, '0')} ')
    ..write('${hour.toString().padLeft(2, '0')}:')
    ..write('${minute.toString().padLeft(2, '0')}:')
    ..write(second.toString().padLeft(2, '0'));

  if (numOfBytes == 11) {
    result.write('.${microSecond.toString().padLeft(6, '0')}');
  }

  return (result.toString(), 1 + numOfBytes);
}

(String, int) _parseBinaryTime(
  ByteData data,
  int startOffset,
  int limit,
) {
  _requireBinaryBytes(startOffset, 1, limit);
  final numOfBytes = data.getUint8(startOffset);
  if (numOfBytes == 0) {
    return ('00:00:00', 1);
  }
  if (numOfBytes != 8 && numOfBytes != 12) {
    throw MySQLProtocolException(
      'Invalid binary time length: $numOfBytes',
    );
  }
  _requireBinaryBytes(startOffset, 1 + numOfBytes, limit);

  final offset = startOffset + 1;
  final isNegative = data.getUint8(offset) > 0;
  final days = data.getUint32(offset + 1, Endian.little);
  final hours = data.getUint8(offset + 5) + days * 24;
  final minutes = data.getUint8(offset + 6);
  final seconds = data.getUint8(offset + 7);

  final timeResult = StringBuffer();
  if (isNegative) {
    timeResult.write('-');
  }
  timeResult.write('${hours.toString().padLeft(2, '0')}:');
  timeResult.write('${minutes.toString().padLeft(2, '0')}:');
  timeResult.write(seconds.toString().padLeft(2, '0'));

  if (numOfBytes == 12) {
    final microSecond = data.getUint32(offset + 8, Endian.little);
    timeResult.write('.${microSecond.toString().padLeft(6, '0')}');
  }

  return (timeResult.toString(), 1 + numOfBytes);
}
