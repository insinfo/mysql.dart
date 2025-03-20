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

  // insert some data
  var stmt = await conn.prepare(
    "INSERT INTO book (author_id, title, price, created_at) VALUES (?, ?, ?, ?)",
  );

  await stmt.execute([null, 'Some book 1', 120, '2022-01-01']);
  await stmt.execute([null, 'Some book 2', 10, '2022-01-01']);
  await stmt.deallocate();

  // select data
  stmt = await conn.prepare("SELECT * FROM book");
  var result = await stmt.execute([]);
  await stmt.deallocate();

  for (final row in result.rows) {
    print(row.assoc());
  }

  // close all connections
  await conn.close();
}
