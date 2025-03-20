import 'package:mysql_dart/mysql_dart.dart';

Future<void> main(List<String> arguments) async {
  print("Connecting to mysql server...");

  // create connection
  final conn = await MySQLConnection.createConnection(
    host: "localhost",
    port: 3306,
    userName: "dart",
    password: "dart",
    databaseName: "banco_teste", // optional
  );

  await conn.connect();

  print("Connected");

  final resultSets = await conn.execute(
    "SELECT 1 as val_1_1; SELECT 2 as val_2_1, 3 as val_2_2",
  );

  assert(resultSets.next != null);

  for (final result in resultSets) {
    // for every result set
    for (final row in result.rows) {
      // for every row in result set
      print(row.assoc());
    }
  }

  // close all connections
  await conn.close();
}
