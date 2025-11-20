import 'dart:async';
import 'dart:math';
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

  test('Aplica timeZone e callback onOpen', () async {
    bool hookCalled = false;
    final customPool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      maxConnections: 1,
      secure: false,
      timeZone: '+00:00',
      onConnectionOpen: (conn) async {
        hookCalled = true;
        await conn.execute('SET @pool_open_hook = 1');
      },
    );

    try {
      final tz = await customPool.withConnection((conn) async {
        final res = await conn.execute('SELECT @@session.time_zone as tz');
        return res.rows.first.colByName('tz');
      });

      expect(hookCalled, isTrue);
      expect(tz, equals('+00:00'));
    } finally {
      await customPool.close();
    }
  });

  test('Recicla conexões antigas e testa idle', () async {
    final recyclingPool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      maxConnections: 1,
      secure: false,
      maxConnectionAge: const Duration(milliseconds: 1),
      maxSessionUse: const Duration(milliseconds: 1),
      idleTestThreshold: Duration.zero,
    );

    try {
      final firstId = await recyclingPool.withConnection((conn) async {
        final res = await conn.execute('SELECT CONNECTION_ID() AS cid');
        return res.rows.first.colByName('cid');
      });

      await Future.delayed(const Duration(milliseconds: 5));

      final secondId = await recyclingPool.withConnection((conn) async {
        final res = await conn.execute('SELECT CONNECTION_ID() AS cid');
        return res.rows.first.colByName('cid');
      });

      expect(secondId, isNot(equals(firstId)));
      expect(recyclingPool.status().totalConnections, lessThanOrEqualTo(1));
    } finally {
      await recyclingPool.close();
    }
  });

  test('Retry básico reexecuta callback', () async {
    int attempts = 0;
    final retryPool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      maxConnections: 1,
      secure: false,
      retryOptions: MySQLPoolRetryOptions(
        maxAttempts: 2,
        delay: const Duration(milliseconds: 10),
        retryIf: (_) => true,
      ),
    );

    try {
      final result = await retryPool.withConnection((conn) async {
        attempts++;
        if (attempts == 1) {
          throw Exception('Falha temporária');
        }
        final res = await conn.execute('SELECT 1 AS ok');
        return res.rows.first.colByName('ok');
      });

      expect(result, equals('1'));
      expect(attempts, equals(2));
    } finally {
      await retryPool.close();
    }
  });

  test('Respeita maxConnections e enfileira tarefas', () async {
    final limitedPool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      maxConnections: 2,
      secure: false,
    );

    int concurrentConnections = 0;
    int maxObserved = 0;

    Future<void> runTask() async {
      await limitedPool.withConnection((conn) async {
        concurrentConnections++;
        maxObserved = max(maxObserved, concurrentConnections);
        // Mantém a conexão ocupada por um curto período para forçar espera nas demais tarefas.
        await Future.delayed(const Duration(milliseconds: 150));
        concurrentConnections--;
      });
    }

    try {
      await Future.wait(List.generate(5, (_) => runTask()));
      expect(maxObserved, equals(2),
          reason: 'O pool não deve permitir mais conexões do que maxConnections');
      expect(limitedPool.allConnectionsQty, lessThanOrEqualTo(2));
    } finally {
      await limitedPool.close();
    }
  });

  test('withConnection libera conexão mesmo quando há erro', () async {
    final tempPool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      maxConnections: 1,
      secure: false,
    );

    try {
      await expectLater(
        () async {
          await tempPool.withConnection((conn) async {
            throw Exception('Falha proposital');
          });
        },
        throwsException,
      );

      expect(tempPool.activeConnectionsQty, equals(0));
      expect(tempPool.idleConnectionsQty, equals(1));

      // Ainda deve ser possível usar a mesma conexão após o erro.
      final value = await tempPool.withConnection((conn) async {
        final res = await conn.execute('SELECT 1');
        return res.rows.first.colAt(0);
      });
      expect(value, equals('1'));
    } finally {
      await tempPool.close();
    }
  });

  test('close encerra todas as conexões e limpa listas internas', () async {
    final closingPool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      maxConnections: 2,
      secure: false,
    );

    await closingPool.withConnection((conn) async {
      await conn.execute('SELECT 1');
    });

    expect(closingPool.allConnectionsQty, greaterThanOrEqualTo(1));

    await closingPool.close();

    expect(closingPool.activeConnectionsQty, equals(0));
    expect(closingPool.idleConnectionsQty, equals(0));
  });
}
