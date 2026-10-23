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
/// (`2024-03-10`, `2024-03-10 12:34:56`, `2024-03-10 12:34:56.000001`).
///
/// Returns null for a date [DateTime] cannot represent, which
/// `DateTime.parse` would silently roll over to another day: the zero date
/// `0000-00-00` (`-0001-11-30`), a date with a zero month or day
/// (`2024-00-00`, allowed without NO_ZERO_IN_DATE) and an invalid date stored
/// under ALLOW_INVALID_DATES (`2024-02-30`, read as March 1). The text is
/// still available through `colAt()` and `assoc()`.
DateTime? parseMySqlDateTime(String text) {
  final value = DateTime.parse(text);
  if (text.length >= 10 &&
      (value.year != int.parse(text.substring(0, 4)) ||
          value.month != int.parse(text.substring(5, 7)) ||
          value.day != int.parse(text.substring(8, 10)))) {
    return null;
  }
  return value;
}
