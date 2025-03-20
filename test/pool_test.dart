import 'dart:async';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

/// Cria tabelas de teste com nomes únicos e insere dados iniciais.
/// Retorna um Map com os nomes das tabelas criadas.
Future<Map<String, String>> createTemporaryTables(
    MySQLConnectionPool pool) async {
  final suffix = DateTime.now().millisecondsSinceEpoch.toString();
  final tableBook = 'book_$suffix';
  final tableBookAuthor = 'book_author_$suffix';

  await pool.execute('DROP TABLE IF EXISTS $tableBookAuthor');
  await pool.execute('DROP TABLE IF EXISTS $tableBook');

  await pool.execute('''
    CREATE TABLE $tableBook (
      id INT AUTO_INCREMENT PRIMARY KEY,
      title VARCHAR(255),
      price INT
    )
  ''');

  await pool.execute('''
    CREATE TABLE $tableBookAuthor (
      id INT AUTO_INCREMENT PRIMARY KEY,
      book_id INT,
      name VARCHAR(255)
    )
  ''');

  // Insere dados iniciais usando parâmetros nomeados (aqui não é necessário, mas mantém o padrão)
  await pool.execute(
      "INSERT INTO $tableBook (title, price) VALUES ('Book A', 100), ('Book B', 150)");
  await pool.execute(
      "INSERT INTO $tableBookAuthor (book_id, name) VALUES (1, 'Author A'), (2, 'Author B')");

  return {'book': tableBook, 'book_author': tableBookAuthor};
}

/// Remove as tabelas de teste criadas.
Future<void> dropTemporaryTables(
    MySQLConnectionPool pool, Map<String, String> tables) async {
  await pool.execute('DROP TABLE IF EXISTS ${tables['book_author']}');
  await pool.execute('DROP TABLE IF EXISTS ${tables['book']}');
}

void main() {
  late MySQLConnectionPool pool;

  setUpAll(() async {
    pool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      maxConnections: 10,
      secure: false,
    );
  });

  tearDownAll(() async {
    await pool.close();
  });

  test('Execute: Atualiza dados e retorna linhas afetadas', () async {
    final tables = await createTemporaryTables(pool);
    try {
      final updateResult = await pool.transactional((conn) async {
        int totalAffectedRows = 0;
        // Atualiza os registros da tabela book usando parâmetros nomeados
        final resBook = await conn.execute(
          "UPDATE ${tables['book']} SET price = :price",
          {"price": 300},
        );
        totalAffectedRows += resBook.affectedRows.toInt();
        // Atualiza os registros da tabela book_author usando parâmetros nomeados
        final resAuthor = await conn.execute(
          "UPDATE ${tables['book_author']} SET name = :name",
          {"name": "John Doe"},
        );
        totalAffectedRows += resAuthor.affectedRows.toInt();
        return totalAffectedRows;
      });
      // São 2 registros em cada tabela: total de 4 linhas atualizadas
      expect(updateResult, equals(4));

      final resultBook = await pool.execute("SELECT * FROM ${tables['book']}");
      expect(resultBook.numOfRows, equals(2));
      for (final row in resultBook.rows) {
        expect(row.colByName('price'), equals('300'));
      }

      final resultAuthor =
          await pool.execute("SELECT * FROM ${tables['book_author']}");
      expect(resultAuthor.numOfRows, equals(2));
      for (final row in resultAuthor.rows) {
        expect(row.colByName('name'), equals('John Doe'));
      }
    } finally {
      await dropTemporaryTables(pool, tables);
    }
  });

  test('Prepare: Cria e executa prepared statement usando parâmetros nomeados',
      () async {
    final tables = await createTemporaryTables(pool);
    try {
      // Cria um prepared statement usando a sintaxe com parâmetros nomeados
      final stmt =
          await pool.prepare("UPDATE ${tables['book']} SET price = ?");
      // Executa a atualização definindo o preço para 400
      final result = await stmt.execute([400]);
      expect(result.affectedRows.toInt(), equals(2));
      await stmt.deallocate();

      final resultBook = await pool.execute("SELECT * FROM ${tables['book']}");
      for (final row in resultBook.rows) {
        expect(row.colByName('price'), equals('400'));
      }
    } finally {
      await dropTemporaryTables(pool, tables);
    }
  });

  test('withConnection: Executa ação com conexão e retorna resultado',
      () async {
    final tables = await createTemporaryTables(pool);
    try {
      final result = await pool.withConnection((conn) async {
        final res = await conn.execute("SELECT * FROM ${tables['book']}");
        return res.numOfRows;
      });
      expect(result, equals(2));
    } finally {
      await dropTemporaryTables(pool, tables);
    }
  });

  test('Transactional: Commit da transação', () async {
    final tables = await createTemporaryTables(pool);
    try {
      final result = await pool.transactional((conn) async {
        return await conn.execute(
          "UPDATE ${tables['book']} SET price = :price",
          {"price": 500},
        );
      });
      expect(result.affectedRows.toInt(), equals(2));

      final resultBook = await pool.execute("SELECT * FROM ${tables['book']}");
      for (final row in resultBook.rows) {
        expect(row.colByName('price'), equals('500'));
      }
    } finally {
      await dropTemporaryTables(pool, tables);
    }
  });

  test('Transactional: Rollback da transação em caso de erro', () async {
    // Cria uma tabela temporária para teste
    await pool.execute("DROP TABLE IF EXISTS temp_test_rollback");
    await pool.execute(
        "CREATE TABLE temp_test_rollback (id INT AUTO_INCREMENT PRIMARY KEY, value INT)  ENGINE=InnoDB;");
    await pool.execute("INSERT INTO temp_test_rollback (value) VALUES (10), (20)");

    // Executa uma transação que deve ser revertida
    try {
      await pool.transactional((conn) async {
        await conn.execute(
          "UPDATE temp_test_rollback SET value = :value",
          {"value": 200},
        );
        throw Exception("Forçando rollback");
      });
      
    } catch (e) {
      // Exceção esperada; o rollback deve ter ocorrido
    }

    // Verifica se os valores permanecem inalterados (10 e 20)
    final result = await pool.execute("SELECT value FROM temp_test_rollback");
    final values = result.rows.map((row) => row.colByName("value")).toList();
    expect(values, containsAll(['10', '20']));
    await pool.execute("DROP TABLE IF EXISTS temp_test_rollback");
  });
}
