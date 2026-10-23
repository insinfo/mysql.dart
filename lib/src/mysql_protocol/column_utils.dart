import 'package:mysql_dart/mysql_protocol.dart';

const int mysqlBinaryCollationId = 63;
const int mysqlColumnFlagBinary = 0x80;

bool _isBlobFamily(MySQLColumnType type) {
  return type.intVal == MySQLColumnType.tinyBlobType.intVal ||
      type.intVal == MySQLColumnType.mediumBlobType.intVal ||
      type.intVal == MySQLColumnType.longBlobType.intVal ||
      type.intVal == MySQLColumnType.blobType.intVal;
}

bool _isAlwaysBinary(MySQLColumnType type) {
  return type.intVal == MySQLColumnType.geometryType.intVal ||
      type.intVal == MySQLColumnType.bitType.intVal;
}

/// Returns true when a column should stay as raw bytes (Uint8List).
bool columnShouldBeBinary(MySQLColumnDefinitionPacket colDef) {
  if (_isAlwaysBinary(colDef.type)) {
    return true;
  }

  if (!_isBlobFamily(colDef.type)) {
    return false;
  }

  // Only the `binary` character set (63) means bytes. BINARY_FLAG is also set
  // for every `_bin` collation (utf8mb4_bin, MariaDB's JSON), which made those
  // TEXT columns come back as Uint8List instead of String.
  return colDef.charset == mysqlBinaryCollationId;
}

/// Returns true when a blob-typed column actually carries textual data.
bool columnShouldBeTextual(MySQLColumnDefinitionPacket colDef) {
  return _isBlobFamily(colDef.type) && !columnShouldBeBinary(colDef);
}

/// Parses a DATE, DATETIME or TIMESTAMP value as the server sends it
/// (`2024-03-10`, `2024-03-10 12:34:56`, `2024-03-10 12:34:56.123456`; the
/// fraction has 1 to 6 digits), reading each field once.
///
/// Returns null for a date [DateTime] cannot represent: the zero date
/// `0000-00-00`, a zero month or day (`2024-05-00`, allowed without
/// NO_ZERO_IN_DATE) and an invalid date stored under ALLOW_INVALID_DATES
/// (`2024-02-30`). `DateTime.parse` rolled those over to another day
/// (`-0001-11-30`, `2024-04-30`, `2024-03-01`). Throws a [FormatException]
/// for text in any other format.
DateTime? tryParseMySqlDateTime(String text) {
  final length = text.length;
  if (length < 10 ||
      text.codeUnitAt(4) != _dash ||
      text.codeUnitAt(7) != _dash) {
    throw FormatException('Invalid MySQL date', text);
  }
  final year = _digits(text, 0, 4);
  final month = _digits(text, 5, 7);
  final day = _digits(text, 8, 10);

  var hour = 0, minute = 0, second = 0, microsecond = 0;
  if (length > 10) {
    if (length < 19 ||
        text.codeUnitAt(10) != _space ||
        text.codeUnitAt(13) != _colon ||
        text.codeUnitAt(16) != _colon) {
      throw FormatException('Invalid MySQL date', text);
    }
    hour = _digits(text, 11, 13);
    minute = _digits(text, 14, 16);
    second = _digits(text, 17, 19);
    if (length > 19) {
      if (length == 20 || length > 26 || text.codeUnitAt(19) != _dot) {
        throw FormatException('Invalid MySQL date', text);
      }
      // '.5' is half a second: scale the fraction to microseconds.
      microsecond = _digits(text, 20, length) * _powersOf10[26 - length];
    }
    if (hour > 23 || minute > 59 || second > 59) {
      throw FormatException('Invalid MySQL date', text);
    }
  }

  if (month < 1 || month > 12 || day < 1 || day > _daysInMonth(year, month)) {
    return null;
  }
  return DateTime(year, month, day, hour, minute, second, microsecond ~/ 1000,
      microsecond % 1000);
}

const _dash = 0x2d, _space = 0x20, _colon = 0x3a, _dot = 0x2e, _zero = 0x30;
const _powersOf10 = [1, 10, 100, 1000, 10000, 100000];

/// The decimal number in `text[start, end)`, digits only.
int _digits(String text, int start, int end) {
  var value = 0;
  for (var i = start; i < end; i++) {
    final digit = text.codeUnitAt(i) - _zero;
    if (digit < 0 || digit > 9) {
      throw FormatException('Invalid MySQL date', text, i);
    }
    value = value * 10 + digit;
  }
  return value;
}

int _daysInMonth(int year, int month) {
  if (month == 2) {
    final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    return leap ? 29 : 28;
  }
  return const [31, 0, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
}
