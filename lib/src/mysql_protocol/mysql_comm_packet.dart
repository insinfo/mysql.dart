//mysql_comm_packet.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:buffer/buffer.dart' show ByteDataWriter;
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';

/// Representa o comando INIT DB no protocolo MySQL.
///
/// Esse comando é utilizado para selecionar um banco de dados específico logo após
/// a conexão ser estabelecida. O pacote contém:
/// - Um byte de comando (valor 2).
/// - O nome do schema (banco de dados) em formato UTF-8.
class MySQLPacketCommInitDB extends MySQLPacketPayload {
  /// Nome do schema (banco de dados) a ser selecionado.
  final String schemaName;

  /// Construtor da classe.
  MySQLPacketCommInitDB({
    required this.schemaName,
  });

  /// Codifica o comando INIT DB em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (2).
  /// 2. A string do schema em UTF-8.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando INIT DB (2)
    buffer.writeUint8(2);
    // Escreve o nome do schema (UTF-8)
    buffer.write(utf8.encode(schemaName));
    return buffer.toBytes();
  }
}

/// Representa o comando QUERY no protocolo MySQL.
///
/// Esse comando é utilizado para enviar uma consulta SQL ao servidor. O pacote contém:
/// - Um byte de comando (valor 3).
/// - A string da query em formato UTF-8.
class MySQLPacketCommQuery extends MySQLPacketPayload {
  /// Consulta SQL a ser executada.
  final String query;

  /// Construtor da classe.
  MySQLPacketCommQuery({
    required this.query,
  });

  /// Codifica o comando QUERY em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (3).
  /// 2. A query em UTF-8.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando QUERY (3)
    buffer.writeUint8(3);
    // Escreve a query em UTF-8
    buffer.write(utf8.encode(query));
    return buffer.toBytes();
  }
}

/// Representa o comando COM_STMT_PREPARE no protocolo MySQL.
///
/// Esse comando é utilizado para preparar uma instrução (statement) para execução
/// posterior como um prepared statement. O pacote contém:
/// - Um byte de comando (valor 0x16).
/// - A query a ser preparada, em formato UTF-8.
class MySQLPacketCommStmtPrepare extends MySQLPacketPayload {
  /// Consulta SQL que será preparada.
  final String query;

  /// Construtor da classe.
  MySQLPacketCommStmtPrepare({
    required this.query,
  });

  /// Codifica o comando COM_STMT_PREPARE em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (0x16).
  /// 2. A query em UTF-8.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando COM_STMT_PREPARE (0x16)
    buffer.writeUint8(0x16);
    // Escreve a query em UTF-8
    buffer.write(utf8.encode(query));
    return buffer.toBytes();
  }
}

/// Representa o comando COM_STMT_EXECUTE no protocolo MySQL.
///
/// Esse comando é utilizado para executar um prepared statement previamente preparado.
/// Ele inclui:
/// - Um byte de comando (valor 0x17).
/// - O ID do statement (stmtID) (4 bytes, little-endian).
/// - Flags (1 byte; atualmente fixo em 0).
/// - Um contador de iterações (4 bytes, little-endian; sempre 1).
/// - Dados dos parâmetros, que incluem:
///   - Um null-bitmap para indicar parâmetros nulos.
///   - Um flag para indicar se os tipos de parâmetros são novos.
///   - Os tipos de cada parâmetro (2 bytes por parâmetro: tipo e flag).
///   - Os valores dos parâmetros codificados de forma binária (se não nulos).
class MySQLPacketCommStmtExecute extends MySQLPacketPayload {
  /// ID do statement previamente preparado.
  final int stmtID;

  /// Lista de parâmetros para o statement.
  final List<dynamic> params;

  /// Lista de tipos MySQL dos parâmetros, já determinados (ou inferidos).
  final List<MySQLColumnType?> paramTypes;

  /// Construtor da classe.
  MySQLPacketCommStmtExecute({
    required this.stmtID,
    required this.params,
    required this.paramTypes,
  });

  /// Codifica o comando COM_STMT_EXECUTE em um [Uint8List] para envio ao servidor.
  ///
  /// A estrutura codificada é:
  /// 1. Um byte de comando (0x17).
  /// 2. Statement ID (4 bytes, little-endian).
  /// 3. Flags (1 byte; atualmente 0).
  /// 4. Iteration count (4 bytes, little-endian; sempre 1).
  /// 5. Caso haja parâmetros:
  ///    - Null bitmap: Indica quais parâmetros são nulos (cada bit corresponde a 1 parâmetro).
  ///    - Flag de new parameter bound (1 byte; geralmente 1).
  ///    - Para cada parâmetro: 2 bytes (tipo e flags de unsigned, etc.).
  ///    - Para cada parâmetro não-nulo: o valor, no formato binário correspondente ao tipo.
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);

    // Escreve o comando COM_STMT_EXECUTE (0x17)
    buffer.writeUint8(0x17);
    // Escreve o ID do statement (4 bytes, little-endian)
    buffer.writeUint32(stmtID, Endian.little);
    // Escreve flags (1 byte, atualmente 0)
    buffer.writeUint8(0);
    // Escreve o contador de iterações (4 bytes, sempre 1, little-endian)
    buffer.writeUint32(1, Endian.little);

    // Só se há parâmetros
    if (params.isNotEmpty) {
      // Cria o null-bitmap para identificar quais parâmetros são nulos.
      final bitmapSize = ((params.length + 7) ~/ 8);
      final nullBitmap = Uint8List(bitmapSize);

      // Define os bits no null-bitmap para os parâmetros nulos.
      for (int paramIndex = 0; paramIndex < params.length; paramIndex++) {
        if (params[paramIndex] == null) {
          final paramByteIndex = paramIndex ~/ 8;
          final paramBitIndex = paramIndex % 8;
          nullBitmap[paramByteIndex] |= (1 << paramBitIndex);
        }
      }
      // Escreve o null-bitmap no buffer
      buffer.write(nullBitmap);

      // Escreve o new-param-bound flag (1 byte; valor 1 indica que os tipos seguem)
      buffer.writeUint8(1);

      // Escreve os tipos dos parâmetros (2 bytes por parâmetro)
      for (int i = 0; i < params.length; i++) {
        final paramType = paramTypes[i];
        if (paramType == null) {
          // Se for nulo, o tipo é mysqlColumnTypeNull = 0x06
          buffer.writeUint8(mysqlColumnTypeNull);
          buffer.writeUint8(0); // Flag "unsigned" ou outro, geralmente 0
        } else {
          buffer.writeUint8(paramType.intVal);
          // Por exemplo, se quiser indicar "unsigned", poderia setar algo. Aqui, 0 = sem flag.
          buffer.writeUint8(0);
        }
      }

      // Escreve os valores dos parâmetros não-nulos
      for (int i = 0; i < params.length; i++) {
        final param = params[i];
        final paramType = paramTypes[i];
        if (param != null && paramType != null) {
          _writeParamValue(buffer, param, paramType);
        }
      }
    }

    return buffer.toBytes();
  }

  /// Escreve o valor do parâmetro no [buffer] de acordo com seu [type].
  ///
  /// Para cada tipo, o valor é convertido e escrito no formato binário adequado:
  /// - Tipos numéricos e booleanos são escritos em seus respectivos tamanhos.
  /// - Datas e horários são escritos com formatação especial.
  /// - Strings (ou BLOBs) são enviados como length-encoded (primeiro o tamanho, depois o conteúdo).
  void _writeParamValue(
    ByteDataWriter buffer,
    dynamic param,
    MySQLColumnType type,
  ) {
    switch (type.intVal) {
      case mysqlColumnTypeTiny: // 1 byte
        // Se o parâmetro for booleano, converte para 1 ou 0. Caso contrário, assume int 1 byte.
        if (param is bool) {
          buffer.writeUint8(param ? 1 : 0);
        } else {
          // Se param for int, convertendo para 8 bits (pode estourar se for >127).
          buffer.writeInt8(param);
        }
        break;

      case mysqlColumnTypeShort: // 2 bytes (int16)
        buffer.writeInt16(param, Endian.little);
        break;

      case mysqlColumnTypeLong: // 4 bytes (int32)
      case mysqlColumnTypeInt24: // no MySQL, 24 bits, mas normalmente tratamos c/ 32 bits
        buffer.writeInt32(param, Endian.little);
        break;

      case mysqlColumnTypeLongLong: // 8 bytes (int64)
        buffer.writeInt64(param, Endian.little);
        break;

      case mysqlColumnTypeFloat: // 4 bytes float
        buffer.writeFloat32(param, Endian.little);
        break;

      case mysqlColumnTypeDouble: // 8 bytes double
        buffer.writeFloat64(param, Endian.little);
        break;

      case mysqlColumnTypeDate:
      case mysqlColumnTypeDateTime:
      case mysqlColumnTypeTimestamp:
        _writeDateTime(buffer, param);
        break;

      case mysqlColumnTypeTime:
        _writeTime(buffer, param);
        break;

      // Strings, BLOBs, DECIMALS etc. → length encoded + bytes
      case mysqlColumnTypeString:
      case mysqlColumnTypeVarString:
      case mysqlColumnTypeVarChar:
      case mysqlColumnTypeEnum:
      case mysqlColumnTypeSet:
      case mysqlColumnTypeLongBlob:
      case mysqlColumnTypeMediumBlob:
      case mysqlColumnTypeBlob:
      case mysqlColumnTypeTinyBlob:
      case mysqlColumnTypeGeometry:
      case mysqlColumnTypeBit:
      case mysqlColumnTypeDecimal:
      case mysqlColumnTypeNewDecimal:
        {
          // Se o parâmetro for Uint8List, manda-o como binário; caso contrário, converte para string UTF-8
          final encodedData = (param is Uint8List)
              ? param
              : utf8.encode(param.toString());

          // Primeiro escreve o tamanho (length-encoded)
          buffer.writeVariableEncInt(encodedData.length);
          // Depois escreve os bytes
          buffer.write(encodedData);
        }
        break;

      default:
        throw MySQLProtocolException(
          "Unsupported parameter type: ${type.intVal}",
        );
    }
  }

  /// Escreve um valor do tipo DateTime [dateTime] no [buffer] de acordo com o protocolo MySQL.
  ///
  /// Dependendo dos valores de ano, mês, dia, hora, minuto, segundo e microssegundos,
  /// o método escolhe um formato de 4, 7 ou 11 bytes.
  void _writeDateTime(ByteDataWriter buffer, DateTime dateTime) {
    final year = dateTime.year;
    final month = dateTime.month;
    final day = dateTime.day;
    final hour = dateTime.hour;
    final minute = dateTime.minute;
    final second = dateTime.second;
    final microsecond = dateTime.microsecond;

    // Caso todos os valores sejam zero, escreve 0 (sem dados de data/hora).
    if (year == 0 &&
        month == 0 &&
        day == 0 &&
        hour == 0 &&
        minute == 0 &&
        second == 0 &&
        microsecond == 0) {
      buffer.writeUint8(0);
      return;
    }

    if (microsecond > 0) {
      // 11 bytes: 1 de comprimento, 2 para ano, 1 p/ mês, 1 p/ dia,
      // 1 p/ hora, 1 p/ min, 1 p/ seg, 4 p/ microsegundos
      buffer.writeUint8(11);
      buffer.writeUint16(year, Endian.little);
      buffer.writeUint8(month);
      buffer.writeUint8(day);
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
      buffer.writeUint32(microsecond, Endian.little);
    } else if (hour > 0 || minute > 0 || second > 0) {
      // 7 bytes: 1 de comprimento, 2 p/ ano, 1 p/ mês, 1 p/ dia,
      // 1 p/ hora, 1 p/ min, 1 p/ seg
      buffer.writeUint8(7);
      buffer.writeUint16(year, Endian.little);
      buffer.writeUint8(month);
      buffer.writeUint8(day);
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
    } else {
      // 4 bytes: 1 de comprimento, 2 p/ ano, 1 p/ mês, 1 p/ dia
      buffer.writeUint8(4);
      buffer.writeUint16(year, Endian.little);
      buffer.writeUint8(month);
      buffer.writeUint8(day);
    }
  }

  /// Escreve um valor do tipo Time (representado como DateTime) no [buffer]
  /// de acordo com o protocolo MySQL.
  ///
  /// O protocolo binário do MySQL para TIME armazena:
  /// - 1 byte de "tamanho" (pode ser 0, 8 ou 12).
  /// - 1 byte de sinal (0=positivo, 1=negativo).
  /// - 4 bytes p/ "dias".
  /// - 1 hora, 1 min, 1 seg [=3 bytes].
  /// - Opcionalmente 4 bytes de microssegundos, se houver.
  ///
  /// Aqui, interpretamos [time] como um DateTime cujo dia/hora/min/seg representam
  /// apenas a parte de tempo (ex.: 00:00 até 23:59:59).
  void _writeTime(ByteDataWriter buffer, DateTime time) {
    final hour = time.hour;
    final minute = time.minute;
    final second = time.second;
    final microsecond = time.microsecond;

    // Se tudo zero, escreve 0 (tempo = 00:00:00).
    if (hour == 0 && minute == 0 && second == 0 && microsecond == 0) {
      buffer.writeUint8(0);
      return;
    }

    if (microsecond > 0) {
      // 12 bytes: 1 (len) + 1 (sinal) + 4 (dias=0) + 1 (hora) + 1 (min) + 1 (seg) + 4 (microseg)
      buffer.writeUint8(12);
      buffer.writeUint8(0); // sinal = 0 (positivo)
      buffer.writeUint32(0, Endian.little); // dias = 0
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
      buffer.writeUint32(microsecond, Endian.little);
    } else {
      // 8 bytes: 1 (len) + 1 (sinal) + 4 (dias=0) + 1 (hora) + 1 (min) + 1 (seg)
      buffer.writeUint8(8);
      buffer.writeUint8(0); // sinal = 0 (positivo)
      buffer.writeUint32(0, Endian.little); // dias = 0
      buffer.writeUint8(hour);
      buffer.writeUint8(minute);
      buffer.writeUint8(second);
    }
  }
}

/// Representa o comando COM_QUIT no protocolo MySQL.
///
/// Esse comando é utilizado para fechar a conexão com o servidor.
/// O pacote consiste apenas de um byte de comando (valor 1).
class MySQLPacketCommQuit extends MySQLPacketPayload {
  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando QUIT (1)
    buffer.writeUint8(1);
    return buffer.toBytes();
  }
}

/// Representa o comando COM_STMT_CLOSE no protocolo MySQL.
///
/// Esse comando é utilizado para fechar um prepared statement e liberar
/// os recursos associados no servidor. O pacote contém:
/// - Um byte de comando (valor 0x19).
/// - O ID do statement (stmtID) (4 bytes, little-endian).
class MySQLPacketCommStmtClose extends MySQLPacketPayload {
  /// ID do statement a ser fechado.
  final int stmtID;

  /// Construtor da classe.
  MySQLPacketCommStmtClose({
    required this.stmtID,
  });

  @override
  Uint8List encode() {
    final buffer = ByteDataWriter(endian: Endian.little);
    // Escreve o comando COM_STMT_CLOSE (0x19)
    buffer.writeUint8(0x19);
    // Escreve o statement ID (4 bytes, little-endian)
    buffer.writeUint32(stmtID, Endian.little);
    return buffer.toBytes();
  }
}
