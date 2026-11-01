import 'dart:convert';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/src/mysql_protocol/column_utils.dart';
import 'package:test/test.dart';

void main() {
  test(
    "testing decimal type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeDecimal);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('10.00');
      result = sqlType.convertStringValueToProvidedType<String>('-10.00');
      expect(result, '-10.00');
      result = sqlType.convertStringValueToProvidedType<String>('0');
      expect(result, '0');
      result = sqlType.convertStringValueToProvidedType<String>('9999.99');
      expect(result, '9999.99');
      result = sqlType.convertStringValueToProvidedType<String>('1000123');
      expect(result, '1000123');

      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('10.00'),
        throwsException,
      );

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('10.00'),
        throwsException,
      );

      expect(
        () => sqlType.convertStringValueToProvidedType<double>('10.00'),
        throwsException,
      );

      expect(
        () => sqlType.convertStringValueToProvidedType<num>('10.00'),
        throwsException,
      );
    },
  );

  test(
    "testing tiny type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeTiny);

      dynamic result = sqlType.convertStringValueToProvidedType<bool>('1', 1);
      expect(result, true);
      result = sqlType.convertStringValueToProvidedType<bool>('0', 1);
      expect(result, false);
      result = sqlType.convertStringValueToProvidedType<bool>('10', 1);
      expect(result, true);
      result = sqlType.convertStringValueToProvidedType<int>('1', 1);
      expect(result, 1);
      result = sqlType.convertStringValueToProvidedType<int>('0', 1);
      expect(result, 0);
      result = sqlType.convertStringValueToProvidedType<int>('2', 1);
      expect(result, 2);
      result = sqlType.convertStringValueToProvidedType<double>('10', 1);
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<num>('10', 1);
      expect(result, 10);
      result = sqlType.convertStringValueToProvidedType<String>('10', 1);
      expect(result, '10');

      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('1', 2),
        throwsException,
      );
    },
  );

  test(
    "testing short type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeShort);

      dynamic result = sqlType.convertStringValueToProvidedType<int>('1');
      expect(result, 1);
      result = sqlType.convertStringValueToProvidedType<int>('0');
      expect(result, 0);
      result = sqlType.convertStringValueToProvidedType<int>('2');
      expect(result, 2);
      result = sqlType.convertStringValueToProvidedType<double>('10');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<num>('10');
      expect(result, 10);
      result = sqlType.convertStringValueToProvidedType<String>('10');
      expect(result, '10');

      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('1'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('0'),
        throwsException,
      );
    },
  );

  test(
    "testing long type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeLong);

      dynamic result = sqlType.convertStringValueToProvidedType<int>('1');
      expect(result, 1);
      result = sqlType.convertStringValueToProvidedType<int>('0');
      expect(result, 0);
      result = sqlType.convertStringValueToProvidedType<int>('2');
      expect(result, 2);
      result = sqlType.convertStringValueToProvidedType<double>('10');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<num>('10');
      expect(result, 10);
      result = sqlType.convertStringValueToProvidedType<String>('10');
      expect(result, '10');

      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('1'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('0'),
        throwsException,
      );
    },
  );

  test(
    "testing long long type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeLongLong);

      dynamic result = sqlType.convertStringValueToProvidedType<int>('1');
      expect(result, 1);
      result = sqlType.convertStringValueToProvidedType<int>('0');
      expect(result, 0);
      result = sqlType.convertStringValueToProvidedType<int>('2');
      expect(result, 2);
      result = sqlType.convertStringValueToProvidedType<double>('10');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<num>('10');
      expect(result, 10);
      result = sqlType.convertStringValueToProvidedType<String>('10');
      expect(result, '10');

      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('1'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('0'),
        throwsException,
      );
    },
  );

  test(
    "testing int24 type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeLongLong);

      dynamic result = sqlType.convertStringValueToProvidedType<int>('1');
      expect(result, 1);
      result = sqlType.convertStringValueToProvidedType<int>('0');
      expect(result, 0);
      result = sqlType.convertStringValueToProvidedType<int>('2');
      expect(result, 2);
      result = sqlType.convertStringValueToProvidedType<double>('10');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<num>('10');
      expect(result, 10);
      result = sqlType.convertStringValueToProvidedType<String>('10');
      expect(result, '10');

      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('1'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('0'),
        throwsException,
      );
    },
  );

  test(
    "testing float type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeFloat);

      dynamic result =
          sqlType.convertStringValueToProvidedType<double>('10.00');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<double>('-10.00');
      expect(result, -10.00);
      result = sqlType.convertStringValueToProvidedType<num>('10.00');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<String>('10.00');
      expect(result, '10.00');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('1.0'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('1.0'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('0.0'),
        throwsException,
      );
    },
  );

  test(
    "testing double type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeDouble);

      dynamic result =
          sqlType.convertStringValueToProvidedType<double>('10.00');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<double>('-10.00');
      expect(result, -10.00);
      result = sqlType.convertStringValueToProvidedType<num>('10.00');
      expect(result, 10.00);
      result = sqlType.convertStringValueToProvidedType<String>('10.00');
      expect(result, '10.00');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('1.0'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('1.0'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('0.0'),
        throwsException,
      );
    },
  );

  test(
    "testing timestamp type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeTimestamp);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('123451234');
      expect(result, '123451234');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('123451234'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('123451234'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('123451234'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('123451234'),
        throwsException,
      );
    },
  );

  test(
    "testing date type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeDate);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('2022-01-02');
      expect(result, '2022-01-02');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('2022-01-02'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('2022-01-02'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('2022-01-02'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('2022-01-02'),
        throwsException,
      );
    },
  );

  test(
    "testing time type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeDate);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('02:00:34');
      expect(result, '02:00:34');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('02:00:34'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('02:00:34'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('02:00:34'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('02:00:34'),
        throwsException,
      );
    },
  );

  test(
    "testing datetime type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeDate);

      dynamic result = sqlType
          .convertStringValueToProvidedType<String>('2022-01-05 02:00:34');
      expect(result, '2022-01-05 02:00:34');

      dynamic resultAsDate = sqlType
          .convertStringValueToProvidedType<DateTime>('2022-01-05 02:00:34');
      expect(resultAsDate, DateTime.parse('2022-01-05 02:00:34'));

      expect(
        () => sqlType
            .convertStringValueToProvidedType<int>('2022-01-05 02:00:34'),
        throwsException,
      );
      expect(
        () => sqlType
            .convertStringValueToProvidedType<double>('2022-01-05 02:00:34'),
        throwsException,
      );
      expect(
        () => sqlType
            .convertStringValueToProvidedType<num>('2022-01-05 02:00:34'),
        throwsException,
      );
      expect(
        () => sqlType
            .convertStringValueToProvidedType<bool>('2022-01-05 02:00:34'),
        throwsException,
      );
    },
  );

  test(
    "testing year type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeYear);

      dynamic result = sqlType.convertStringValueToProvidedType<String>('2022');
      expect(result, '2022');
      result = sqlType.convertStringValueToProvidedType<int>('2022');
      expect(result, 2022);

      expect(
        () => sqlType.convertStringValueToProvidedType<double>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('2022'),
        throwsException,
      );
    },
  );

  test(
    "testing varchar type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeVarChar);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('Some text');
      expect(result, 'Some text');

      result =
          sqlType.convertStringValueToProvidedType<String>('Какой-то текст');
      expect(result, 'Какой-то текст');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('2022'),
        throwsException,
      );
    },
  );

  test(
    "testing string type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeString);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('Some text');
      expect(result, 'Some text');

      result =
          sqlType.convertStringValueToProvidedType<String>('Какой-то текст');
      expect(result, 'Какой-то текст');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('2022'),
        throwsException,
      );
    },
  );

  test(
    "testing var string type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeVarString);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('Some text');
      expect(result, 'Some text');

      result =
          sqlType.convertStringValueToProvidedType<String>('Какой-то текст');
      expect(result, 'Какой-то текст');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('2022'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('2022'),
        throwsException,
      );
    },
  );

  test(
    "testing enum type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeEnum);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('process');
      expect(result, 'process');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('process'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('process'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('process'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('process'),
        throwsException,
      );
    },
  );

  test(
    "testing set type",
    () {
      final sqlType = MySQLColumnType.create(mysqlColumnTypeSet);

      dynamic result =
          sqlType.convertStringValueToProvidedType<String>('process');
      expect(result, 'process');

      expect(
        () => sqlType.convertStringValueToProvidedType<int>('process'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<double>('process'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<num>('process'),
        throwsException,
      );
      expect(
        () => sqlType.convertStringValueToProvidedType<bool>('process'),
        throwsException,
      );
    },
  );

  test(
    "testing binary JSON type",
    () {
      const jsonValue = '{"name":"Alice","age":30}';
      final jsonBytes = utf8.encode(jsonValue);
      final buffer = Uint8List.fromList([jsonBytes.length, ...jsonBytes]);
      final byteData = ByteData.sublistView(buffer);

      final result = parseBinaryColumnData(
        mysqlColumnTypeJson,
        byteData,
        buffer,
        0,
      );

      expect(result.$1, jsonValue);
      expect(result.$2, buffer.length);
      expect(jsonDecode(result.$1 as String), {
        'name': 'Alice',
        'age': 30,
      });
    },
  );

  test(
      "a BIGINT UNSIGNED above 2^63-1 read as int throws a "
      "MySQLProtocolException", () {
    final sqlType = MySQLColumnType.create(mysqlColumnTypeLongLong);
    expect(
      () =>
          sqlType.convertStringValueToProvidedType<int>('18446744073709551615'),
      throwsA(isA<MySQLProtocolException>()),
    );
    expect(
      sqlType.convertStringValueToProvidedType<String>('18446744073709551615'),
      '18446744073709551615',
    );
    expect(
      sqlType.convertStringValueToProvidedType<num>('18446744073709551615'),
      18446744073709551615.0,
    );
  });

  test("an invalid date read as DateTime throws a MySQLProtocolException", () {
    final sqlType = MySQLColumnType.create(mysqlColumnTypeDateTime);
    expect(
      () => sqlType.convertStringValueToProvidedType<DateTime>('2024-13-xx'),
      throwsA(isA<MySQLProtocolException>()),
    );
  });

  group('tryParseMySqlDateTime', () {
    test('dates, date-times and fractions of 1 to 6 digits', () {
      expect(tryParseMySqlDateTime('2024-03-10'), DateTime(2024, 3, 10));
      expect(tryParseMySqlDateTime('2024-03-10 12:34:56'),
          DateTime(2024, 3, 10, 12, 34, 56));
      expect(tryParseMySqlDateTime('2024-03-10 12:34:56.5'),
          DateTime(2024, 3, 10, 12, 34, 56, 500));
      expect(tryParseMySqlDateTime('2024-03-10 12:34:56.005'),
          DateTime(2024, 3, 10, 12, 34, 56, 5));
      expect(tryParseMySqlDateTime('2024-03-10 12:34:56.000001'),
          DateTime(2024, 3, 10, 12, 34, 56, 0, 1));
      expect(tryParseMySqlDateTime('9999-12-31 23:59:59.999999'),
          DateTime(9999, 12, 31, 23, 59, 59, 999, 999));
      expect(tryParseMySqlDateTime('0999-01-01'), DateTime(999, 1, 1));
    });

    test('the same instant as DateTime.parse for valid dates', () {
      for (final text in [
        '2024-02-29',
        '2023-12-31 23:59:59',
        '1970-01-01 00:00:00.123456',
        '2000-02-29 08:00:00.1',
      ]) {
        expect(tryParseMySqlDateTime(text), DateTime.parse(text), reason: text);
      }
    });

    test('null for a date DateTime cannot represent', () {
      for (final text in [
        '0000-00-00',
        '0000-00-00 00:00:00',
        '0000-00-00 00:00:00.000000',
        '2024-00-00 10:00:00',
        '2024-05-00',
        '2024-00-10',
        '2024-02-30',
        '2023-02-29', // not a leap year
        '1900-02-29', // not a leap year (divisible by 100)
        '2024-04-31',
        '2024-13-01',
      ]) {
        expect(tryParseMySqlDateTime(text), isNull, reason: text);
      }
      // 2000 is a leap year (divisible by 400).
      expect(tryParseMySqlDateTime('2000-02-29'), DateTime(2000, 2, 29));
    });

    test('FormatException for text in another format', () {
      for (final text in [
        '',
        '2024-3-10',
        '2024/03/10',
        '2024-03-10T12:34:56',
        '2024-03-10 12:34',
        '2024-03-10 12:34:56.',
        '2024-03-10 12:34:56.1234567',
        '2024-03-10 24:00:00',
        '2024-03-10 12:60:00',
        '2024-0a-10',
        '12:34:56',
      ]) {
        expect(() => tryParseMySqlDateTime(text), throwsFormatException,
            reason: text);
      }
    });
  });
}
