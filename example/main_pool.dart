import 'package:mysql_dart/mysql_dart.dart';

Future<void> main(List<String> arguments) async {
  // create connections pool
  final pool = MySQLConnectionPool(
    host: "localhost",
    port: 3306,
    userName: "dart",
    password: "dart",
    databaseName: "banco_teste", // optional
    maxConnections: 10,
  );

  // update table (inside transaction) and get total number of affected rows
  final updateResult = await pool.transactional((conn) async {
    int totalAffectedRows = 0;

    var res = await conn.execute(
      "UPDATE book SET price = :price",
      {"price": 300},
    );

    totalAffectedRows += res.affectedRows.toInt();

    res = await conn.execute(
      "UPDATE book_author SET name = :name",
      {"name": "John Doe"},
    );

    totalAffectedRows += res.affectedRows.toInt();

    return totalAffectedRows;
  });

  // show total number of updated rows
  print(updateResult);

  // make query
  var result = await pool.execute("SELECT * FROM book");

  // print some result data
  print(result.numOfColumns);
  print(result.numOfRows);
  print(result.lastInsertID);
  print(result.affectedRows);

  // print query result
  for (final row in result.rows) {
    // print(row.colAt(0));
    // print(row.colByName("title"));

    // print all rows as Map<String, String>
    print(row.assoc());
  }

  // close all connections
  await pool.close();
}
