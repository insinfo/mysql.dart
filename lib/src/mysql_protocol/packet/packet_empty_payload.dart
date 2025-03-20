import 'dart:typed_data';
import 'package:mysql_dart/mysql_protocol.dart';

class MySQLPacketEmptyPayload extends MySQLPacketPayload {
  @override
  Uint8List encode() {
    throw UnimplementedError();
  }
}
