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

  final hasBinaryCollation = colDef.charset == mysqlBinaryCollationId;
  final hasBinaryFlag = (colDef.flags & mysqlColumnFlagBinary) != 0;

  return hasBinaryCollation || hasBinaryFlag;
}

/// Returns true when a blob-typed column actually carries textual data.
bool columnShouldBeTextual(MySQLColumnDefinitionPacket colDef) {
  return _isBlobFamily(colDef.type) && !columnShouldBeBinary(colDef);
}
