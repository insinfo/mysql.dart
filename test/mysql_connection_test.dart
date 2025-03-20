import 'package:test/test.dart';
import 'package:mysql_dart/mysql_dart.dart';

void main() {
  late MySQLConnection connection;

  setUpAll(() async {
    // Cria e conecta a uma instância de MySQLConnection
    connection = await MySQLConnection.createConnection(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: false,
    );
    await connection.connect();
  });

  tearDownAll(() async {
    // Fecha a conexão ao final de todos os testes
    await connection.close();
  });

  test('A conexão deve ser estabelecida', () async {
    expect(connection.connected, isTrue);
  });

  test('Execute: Query simples retorna resultado esperado', () async {
    // Executa uma query simples e verifica se a coluna "test" tem valor "1"
    final result = await connection.execute("SELECT 1 AS test");
    expect(result.numOfRows, greaterThan(0));
    final row = result.rows.first;
    final assoc = row.assoc();
    expect(assoc['test'], equals('1'));
  });

  test('Transactional: Commit da transação', () async {
    // Cria uma tabela temporária para teste
    await connection.execute("DROP TABLE IF EXISTS temp_test");
    await connection.execute(
        "CREATE TABLE temp_test (id INT AUTO_INCREMENT PRIMARY KEY, value INT)");
    await connection.execute("INSERT INTO temp_test (value) VALUES (10), (20)");

    // Executa uma transação que atualiza os valores para 500
    final updateResult = await connection.transactional((conn) async {
      final res = await conn.execute(
        "UPDATE temp_test SET value = :value",
        {"value": 500},
      );
      return res.affectedRows.toInt();
    });
    expect(updateResult, equals(2));

    // Verifica se os valores foram atualizados para 500
    final result = await connection.execute("SELECT value FROM temp_test");
    for (final row in result.rows) {
      expect(row.colByName("value"), equals('500'));
    }
    await connection.execute("DROP TABLE IF EXISTS temp_test");
  });

  test('Transactional: Rollback da transação em caso de erro', () async {
    // Cria uma tabela temporária para teste
    await connection.execute("DROP TABLE IF EXISTS temp_test_rollback");
    await connection.execute(
        "CREATE TABLE temp_test_rollback (id INT AUTO_INCREMENT PRIMARY KEY, value INT)  ENGINE=InnoDB;");
    await connection
        .execute("INSERT INTO temp_test_rollback (value) VALUES (10), (20)");

    // Executa uma transação que deve ser revertida
    try {
      await connection.transactional((conn) async {
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
    final result =
        await connection.execute("SELECT value FROM temp_test_rollback");
    final values = result.rows.map((row) => row.colByName("value")).toList();
    expect(values, containsAll(['10', '20']));
    await connection.execute("DROP TABLE IF EXISTS temp_test_rollback");
  });

  test('Prepare: Cria, executa e dealloca prepared statement', () async {
    // Cria uma tabela temporária para teste
    await connection.execute("DROP TABLE IF EXISTS temp_test");
    await connection.execute(
        "CREATE TABLE temp_test (id INT AUTO_INCREMENT PRIMARY KEY, value INT)");
    await connection.execute("INSERT INTO temp_test (value) VALUES (1), (2)");

    // Prepara um statement usando parâmetros nomeados conforme a API apresentada
    final stmt = await connection.prepare("UPDATE temp_test SET value = ?");
    final res = await stmt.execute([999]);
    expect(res.affectedRows.toInt(), equals(2));
    await stmt.deallocate();

    // Verifica se os registros foram atualizados para 999
    final result = await connection.execute("SELECT value FROM temp_test");
    for (final row in result.rows) {
      expect(row.colByName("value"), equals('999'));
    }
    await connection.execute("DROP TABLE IF EXISTS temp_test");
  });

  test('onClose: Callback é invocado ao fechar a conexão', () async {
    // Cria uma nova conexão para testar o callback onClose
    var closedCalled = false;
    final conn2 = await MySQLConnection.createConnection(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: false,
    );
    conn2.onClose(() {
      closedCalled = true;
    });
    await conn2.connect();
    await conn2.close();
    expect(closedCalled, isTrue);
  });
}
