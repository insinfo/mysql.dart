import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:test/test.dart';
import 'package:mysql_dart/mysql_dart.dart';

//openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/ca-key.pem -out certs/ca-cert.pem -days 365 -subj "/C=BR/ST=Rio de Janeiro/L=Rio das Ostras/O=PMRO/OU=ASCOMTI/CN=MyTestCA"
//openssl req -newkey rsa:2048 -nodes -keyout certs/server-key.pem  -out certs/server-req.pem -subj "/C=BR/ST=Rio de Janeiro/L=Rio das Ostras/O=PMRO/OU=ASCOMTI/CN=localhost"
//openssl x509 -req  -in certs/server-req.pem  -CA certs/ca-cert.pem  -CAkey certs/ca-key.pem  -CAcreateserial -out certs/server-cert.pem  -days 365
// colocar em C:\Program Files\MariaDB 10.11\data\my.ini
// ssl_ca="C:/Program Files/MariaDB 10.11/ssl/ca-cert.pem"
// ssl_cert="C:/Program Files/MariaDB 10.11/ssl/server-cert.pem"
// ssl_key="C:/Program Files/MariaDB 10.11/ssl/server-key.pem"

void main() {
  late MySQLConnection connection;

  setUpAll(() async {
    // Cria e conecta uma instância de MySQLConnection para a maioria dos testes
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
    //await connection.close();
  });

  test('A conexão deve ser estabelecida', () async {
    expect(connection.connected, isTrue);
  });

  test('Execute: Query simples retorna resultado esperado', () async {
    final result = await connection.execute("SELECT 1 AS test");
    expect(result.numOfRows, greaterThan(0));
    final row = result.rows.first;
    final assoc = row.assoc();
    expect(assoc['test'], equals('1'));
  });

  test('Auth: mysql_native_password', () async {
    // Verifica a autenticação com mysql_native_password executando uma query que retorna o usuário atual
    final result = await connection.execute("SELECT CURRENT_USER() as user");
    expect(result.numOfRows, greaterThan(0));
    final row = result.rows.first;
    final assoc = row.assoc();
    expect(assoc['user'], contains('dart'));
  });

  test('Connection pool: Query via pool', () async {
    final pool = MySQLConnectionPool(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: false,
      maxConnections: 5,
    );
    final result = await pool.execute("SELECT 1 AS test");
    expect(result.numOfRows, greaterThan(0));
    final row = result.rows.first;
    final assoc = row.assoc();
    expect(assoc['test'], equals('1'));
    await pool.close();
  });

  test('Query placeholders: Usando parâmetros nomeados', () async {
    await connection.execute("DROP TABLE IF EXISTS placeholder_test");
    await connection
        .execute("CREATE TABLE placeholder_test (id INT, value VARCHAR(50))");
    await connection.execute(
        "INSERT INTO placeholder_test (id, value) VALUES (1, 'test1'), (2, 'test2')");
    final result = await connection.execute(
        "SELECT value FROM placeholder_test WHERE id = :id", {"id": 2});
    expect(result.numOfRows, equals(1));
    final row = result.rows.first;
    expect(row.colByName("value"), equals('test2'));
    await connection.execute("DROP TABLE IF EXISTS placeholder_test");
  });

  test('Transactional: Commit da transação', () async {
    await connection.execute("DROP TABLE IF EXISTS temp_test");
    await connection.execute(
        "CREATE TABLE temp_test (id INT AUTO_INCREMENT PRIMARY KEY, value INT)");
    await connection.execute("INSERT INTO temp_test (value) VALUES (10), (20)");

    final updateResult = await connection.transactional((conn) async {
      final res = await conn.execute(
        "UPDATE temp_test SET value = :value",
        {"value": 500},
      );
      return res.affectedRows.toInt();
    });
    expect(updateResult, equals(2));

    final result = await connection.execute("SELECT value FROM temp_test");
    for (final row in result.rows) {
      expect(row.colByName("value"), equals('500'));
    }
    await connection.execute("DROP TABLE IF EXISTS temp_test");
  });

  test('Transactional: Rollback da transação em caso de erro', () async {
    await connection.execute("DROP TABLE IF EXISTS temp_test_rollback");
    await connection.execute(
        "CREATE TABLE temp_test_rollback (id INT AUTO_INCREMENT PRIMARY KEY, value INT) ENGINE=InnoDB;");
    await connection
        .execute("INSERT INTO temp_test_rollback (value) VALUES (10), (20)");

    try {
      await connection.transactional((conn) async {
        await conn.execute(
          "UPDATE temp_test_rollback SET value = :value",
          {"value": 200},
        );
        throw Exception("Forçando rollback");
      });
    } catch (e) {
      // Exceção esperada; o rollback deve ocorrer
    }

    final result =
        await connection.execute("SELECT value FROM temp_test_rollback");
    final values = result.rows.map((row) => row.colByName("value")).toList();
    expect(values, containsAll(['10', '20']));
    await connection.execute("DROP TABLE IF EXISTS temp_test_rollback");
  });

  test('Prepare: Cria, executa e dealloca prepared statement', () async {
    await connection.execute("DROP TABLE IF EXISTS temp_test");
    await connection.execute(
        "CREATE TABLE temp_test (id INT AUTO_INCREMENT PRIMARY KEY, value INT)");
    await connection.execute("INSERT INTO temp_test (value) VALUES (1), (2)");

    final stmt = await connection.prepare("UPDATE temp_test SET value = ?");
    final res = await stmt.execute([999]);
    expect(res.affectedRows.toInt(), equals(2));
    await stmt.deallocate();

    final result = await connection.execute("SELECT value FROM temp_test");
    for (final row in result.rows) {
      expect(row.colByName("value"), equals('999'));
    }
    await connection.execute("DROP TABLE IF EXISTS temp_test");
  });

  test('SSL connection: Conecta com SSL habilitado', () async {
    final sslConn = await MySQLConnection.createConnection(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: true,
    );
    await sslConn.connect();
    expect(sslConn.connected, isTrue);
    await sslConn.close();
  });

  test('SSL connection: Conecta com SSL habilitado', () async {
    // Cria um SecurityContext configurado para SSL.
    // Se o seu servidor requer certificados de cliente,
    // você pode carregar a cadeia de certificados e a chave privada.
    // Exemplo:
    // context.useCertificateChain('path/to/client_cert.pem');
    // context.usePrivateKey('path/to/client_key.pem');
    // context.setTrustedCertificates('path/to/ca_cert.pem');
    final SecurityContext context = SecurityContext(withTrustedRoots: true);
    final sslConn = await MySQLConnection.createConnection(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: true,
      securityContext: context,
      onBadCertificate: (certificate) => true,
    );
    await sslConn.connect();
    expect(sslConn.connected, isTrue);
    await sslConn.close();
  });

  test('Auth: caching_sha2_password', () async {
    // Presume-se que o usuário "dart" esteja configurado para usar caching_sha2_password (padrão no MySQL 8)
    final csConn = await MySQLConnection.createConnection(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: false,
    );
    await csConn.connect();
    expect(csConn.connected, isTrue);
    await csConn.close();
  });

  test('Iterating large result sets', () async {
    await connection.execute("DROP TABLE IF EXISTS large_test");
    await connection.execute(
        "CREATE TABLE large_test (id INT AUTO_INCREMENT PRIMARY KEY, value INT)");
    // Insere 100 registros
    for (int i = 0; i < 100; i++) {
      await connection.execute("INSERT INTO large_test (value) VALUES ($i)");
    }
    final result = await connection.execute("SELECT id, value FROM large_test");
    int count = 0;
    // ignore: unused_local_variable
    for (final row in result.rows) {
      count++;
    }
    expect(count, equals(100));
    await connection.execute("DROP TABLE IF EXISTS large_test");
  });

  test('Typed data access', () async {
    await connection.execute("DROP TABLE IF EXISTS typed_test");
    await connection.execute(
        "CREATE TABLE typed_test (id INT, float_val FLOAT, date_val DATE)");
    await connection.execute(
        "INSERT INTO typed_test (id, float_val, date_val) VALUES (1, 3.14, '2020-01-01')");
    final result = await connection
        .execute("SELECT id, float_val, date_val FROM typed_test");
    final row = result.rows.first;
    expect(int.tryParse(row.colByName("id")!), equals(1));
    expect(double.tryParse(row.colByName("float_val")!), closeTo(3.14, 0.01));
    expect(row.colByName("date_val"), equals('2020-01-01'));
    await connection.execute("DROP TABLE IF EXISTS typed_test");
  });

  test('Prepared statements: Sending binary data', () async {
    await connection.execute("DROP TABLE IF EXISTS binary_test");
    await connection.execute(
        "CREATE TABLE binary_test (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB)");
    final binaryData = Uint8List.fromList([0, 255, 127, 128]);
    final stmt =
        await connection.prepare("INSERT INTO binary_test (data) VALUES (?)");
    final res = await stmt.execute([binaryData]);
    expect(res.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
    final result = await connection.execute("SELECT data FROM binary_test");
    final row = result.rows.first;
    expect(row.typedColByName<Uint8List>("data"), equals(binaryData));
    await connection.execute("DROP TABLE IF EXISTS binary_test");
  });

  test('Execute: parâmetros posicionais com blobs sem prepare explícito',
      () async {
    await connection.execute("DROP TABLE IF EXISTS blob_auto_exec");
    await connection.execute(
        "CREATE TABLE blob_auto_exec (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB)");

    final positionalBlob = Uint8List.fromList([1, 2, 3]);
    await connection.execute(
      "INSERT INTO blob_auto_exec (data) VALUES (?)",
      [positionalBlob],
    );

    final namedBlob = Uint8List.fromList([4, 5, 6]);
    await connection.execute(
      "INSERT INTO blob_auto_exec (data) VALUES (:payload)",
      {"payload": namedBlob},
    );

    final result = await connection
        .execute("SELECT data FROM blob_auto_exec ORDER BY id");
    final rows = result.rows.toList();
    expect(rows.length, equals(2));
    expect(rows[0].colByName("data"), equals(positionalBlob));
    expect(rows[1].colByName("data"), equals(namedBlob));

    await connection.execute("DROP TABLE IF EXISTS blob_auto_exec");
  });

  test('Execute: TEXT columns stay as strings with named params', () async {
    await connection.execute("DROP TABLE IF EXISTS text_auto_exec");
    await connection.execute(
        "CREATE TABLE text_auto_exec (id INT AUTO_INCREMENT PRIMARY KEY, body LONGTEXT)");
    await connection.execute(
        "INSERT INTO text_auto_exec (body) VALUES ('<p>Hello world</p>')");

    final result = await connection.execute(
      "SELECT body FROM text_auto_exec WHERE id = :id",
      {"id": 1},
    );

    final body = result.rows.first.colByName("body");
    expect(body, isA<String>());
    expect(body, contains("Hello"));

    await connection.execute("DROP TABLE IF EXISTS text_auto_exec");
  });

  test('Multiple result sets', () async {
    final results =
        await connection.execute("SELECT 1 AS first; SELECT 2 AS second;");
    // Converte o iterável para uma lista
    final resultList = results.toList();
    expect(resultList.length, equals(2));
    final firstRow = resultList[0].rows.first;
    final secondRow = resultList[1].rows.first;
    expect(firstRow.colByName("first"), equals('1'));
    expect(secondRow.colByName("second"), equals('2'));
  });

  test('truncate table', () async {
    // Remove a tabela se já existir
    await connection.execute('DROP TABLE IF EXISTS clients');
    // Cria a tabela "clients"
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS clients (
        id INT NOT NULL AUTO_INCREMENT,
        name VARCHAR(255) NOT NULL,
        PRIMARY KEY (id)
      );
    ''');
    // Insere alguns registros
    await connection.execute("INSERT INTO clients (name) VALUES ('Alice')");
    await connection.execute("INSERT INTO clients (name) VALUES ('Bob')");
    await connection.execute("INSERT INTO clients (name) VALUES ('Charlie')");
    // Executa o truncate para remover todos os registros
    await connection.execute('TRUNCATE TABLE clients');
    // Verifica se a tabela está vazia
    final res = await connection.execute('SELECT * FROM clients');
    expect(res.numOfRows, equals(0));
  });

  test('onClose: Callback é invocado ao fechar a conexão', () async {
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

  test('Erro de protocolo: Query inválida retorna MySQLServerException',
      () async {
    bool gotServerException = false;
    try {
      // Query propositalmente inválida
      await connection.execute("SELECT * FROM TABELA_INEXISTENTE OU ERRO");
    } catch (e) {
      // Se seu driver lança MySQLServerException ou MySQLClientException em erros de sintaxe
      if (e is MySQLServerException || e is MySQLClientException) {
        gotServerException = true;
      }
    }
    expect(gotServerException, isTrue,
        reason: "Deveria lançar erro de servidor");
  });

  test('Tipos YEAR(2) e YEAR(4)', () async {
    // Dependendo da configuração do MySQL, YEAR(2) pode estar descontinuado a partir do 5.7.
    await connection.execute("DROP TABLE IF EXISTS year_test");
    await connection.execute('''
    CREATE TABLE year_test (
      y2 YEAR(2),
      y4 YEAR(4)
    )
  ''');

    // Insere valores "ano 99" e "ano 2025"
    // Observação: YEAR(2) costuma armazenar 99 como 1999, mas depende da versão do MySQL.
    await connection
        .execute("INSERT INTO year_test (y2, y4) VALUES (99, 2025)");
    final res = await connection.execute("SELECT y2, y4 FROM year_test");
    final row = res.rows.first;
    // Normalmente, colByName("y2") = "1999" ou algo assim, mas pode variar.
    //print("Valor de y2 = ${row.colByName('y2')}, y4 = ${row.colByName('y4')}");
    // Adapte as expectations conforme seu MySQL retorna.
    expect(row.colByName('y2'), anyOf(['1999', '99']),
        reason: 'Depende da versão');
    expect(row.colByName('y4'), equals('2025'));
    await connection.execute("DROP TABLE IF EXISTS year_test");
  });

  test('Coluna BIT', () async {
    await connection.execute("DROP TABLE IF EXISTS bit_test");
    await connection.execute('''
    CREATE TABLE bit_test (
      flags BIT(8)
    )
  ''');

    // Inserimos, por exemplo, b'10101010'
    await connection
        .execute("INSERT INTO bit_test (flags) VALUES (b'10101010')");

    final res = await connection.execute("SELECT flags FROM bit_test");
    final row = res.rows.first;
    final rawVal = row.colByName("flags");
    //print("Valor BIT: $rawVal");

    // Normalmente MySQL envia no protocolo textual como sequência binária/ASCII
    // ou 0/1. Isso pode variar. Você pode checar se a string é algo como "[85]" ou "\x55".
    // Às vezes vem como caracteres estranhos.
    // Se você tiver parse binário, pode querer typedColByName<Uint8List>("flags").
    expect(rawVal, isNotNull);

    await connection.execute("DROP TABLE IF EXISTS bit_test");
  });

  test('Prepared statements: múltiplos execs e re-prepare', () async {
    await connection.execute("DROP TABLE IF EXISTS multi_prepared_test");
    await connection.execute('''
    CREATE TABLE multi_prepared_test (
      id INT AUTO_INCREMENT PRIMARY KEY,
      val VARCHAR(50)
    )
  ''');
    // Prepara a mesma query duas vezes (re-prepare)
    for (int i = 0; i < 2; i++) {
      final stmt = await connection
          .prepare("INSERT INTO multi_prepared_test (val) VALUES (?)");

      // Executa com parâmetros diferentes
      for (var v in ['A', 'B', 'C']) {
        final res = await stmt.execute([v]);
        expect(res.affectedRows.toInt(), 1);
      }
      await stmt.deallocate();
    }
    // Esperamos 2 (prepare) * 3 (exec) = 6 linhas inseridas
    final resAll = await connection
        .execute("SELECT COUNT(*) as total FROM multi_prepared_test");
    final countRow = resAll.rows.first;
    expect(countRow.colByName("total"), anyOf(['6', '6.0']));
    await connection.execute("DROP TABLE IF EXISTS multi_prepared_test");
  });

  test(
      'Concorrência: múltiplas queries simultâneas na mesma conexão (se suportado)',
      () async {
    // Esse teste *pode* falhar se o driver não suportar queries em paralelo na mesma conexão.
    // Em muitos drivers, isso não é permitido e deve ser feito via "pool" ou conexões separadas.
    final futures = <Future>[];
    for (int i = 0; i < 3; i++) {
      futures.add(connection.execute("SELECT SLEEP(1) as s$i"));
    }
    bool gotError = false;
    try {
      await Future.wait(futures);
    } catch (e) {
      gotError = true;
    }
    // Se o driver não suporta, `gotError` deve ser true.
    // Se suportar, deve ser false e as queries concluem sem erro.
    print("Suporta queries paralelas? ${!gotError}");
  });

  test('Conexão perdida em meio a query', () async {
    // Precisamos de um "hack" para fechar o socket no meio da query,
    // ou matar o servidor MySQL (inviável no teste).
    // Exemplo artificial:
    final conn2 = await MySQLConnection.createConnection(
      host: 'localhost',
      port: 3306,
      userName: 'dart',
      password: 'dart',
      databaseName: 'banco_teste',
      secure: false,
    );
    await conn2.connect();
    expect(conn2.connected, isTrue);

    // Supondo que existe algum "closeSocket()" no driver (não-público).
    // Vamos simular jogando uma exceção no meio ou destruindo a conexão:
    // Este teste pode requerer manipular algo no driver.
    conn2
        .getSocket()
        .destroy(); // Se for acessível, destrói o socket abruptamente

    bool gotError = false;
    try {
      await conn2.execute("SELECT SLEEP(2)");
    } catch (e) {
      gotError = true;
      print("Exceção por conexão perdida: $e");
    }
    expect(gotError, isTrue,
        reason: "Deveria falhar pois a conexão foi destruída");
  });

  test('Usando USE para trocar de database', () async {
    // Cria outro database para teste
    try {
      await connection.execute("CREATE DATABASE IF NOT EXISTS outro_db");
    } catch (e) {
      // ignorar se não puder criar
    }
    // Muda para outro_db
    await connection.execute("USE outro_db");
    // Cria tabela nele, se quiser
    await connection.execute("DROP TABLE IF EXISTS table_outrodb");
    await connection.execute("CREATE TABLE table_outrodb (id INT)");
    // Retorna para o banco original
    await connection.execute("USE banco_teste");
  });

  test('Coluna JSON', () async {
    // Certifique-se de que o MySQL >= 5.7 e suporte JSON
    await connection.execute("DROP TABLE IF EXISTS json_test");
    await connection.execute('''
    CREATE TABLE json_test (
      data JSON
    )
  ''');
    // Insere um objeto JSON
    await connection.execute(
      "INSERT INTO json_test (data) VALUES ('{\"name\":\"Alice\",\"age\":30}')",
    );
    final res = await connection.execute("SELECT data FROM json_test");
    final row = res.rows.first;
    final rawVal = row.colByName("data");
    String jsonStr;
    if (rawVal is List<int>) {
      jsonStr = utf8.decode(rawVal);
    } else {
      jsonStr = rawVal.toString();
    }

    print("Valor JSON: $jsonStr");
    // Normalmente o MySQL retorna o JSON como string
    expect(jsonStr, contains('"name":"Alice"'));
    // Se quiser parsear para map:
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
    expect(decoded['age'], equals(30));
    await connection.execute("DROP TABLE IF EXISTS json_test");
  });

  // test('MySQLProtocolException: JSON binary column not implemented', () async {
  //   await connection.execute("DROP TABLE IF EXISTS test_json");
  //   await connection.execute('''
  //     CREATE TABLE test_json (
  //       id INT AUTO_INCREMENT PRIMARY KEY,
  //       data JSON
  //     )
  //   ''');
  //   await connection.execute(
  //       "INSERT INTO test_json (data) VALUES ('{\"name\":\"Alice\",\"age\":30}') ");
  //   // Prepara um statement para selecionar a coluna JSON
  //   final stmt =
  //       await connection.prepare("SELECT data FROM test_json WHERE id = ?");

  //   // A execução deverá disparar uma exceção, pois o tipo JSON (código 245)
  //   // não está implementado para o protocolo binário
  //   final res = await stmt.execute([1]);
  //   final row = res.rows.first;
  //   final rawVal = row.colByName("data");
  //   print('rawVal $rawVal');
  // });

  // test('Timeout: Query muito lenta deve estourar tempo limite', () async {
  //   // Supondo que o seu driver possua connect(timeoutMs: 2000) ou algo parecido:
  //   final connTimeout = await MySQLConnection.createConnection(
  //     host: 'localhost',
  //     port: 3306,
  //     userName: 'dart',
  //     password: 'dart',
  //     databaseName: 'banco_teste',
  //     secure: false,
  //   );

  //   // Força um timeout pequeno.
  //   await connTimeout.connect(timeoutMs: 2000);

  //   // Cria uma procedure que simula demora (por ex. SLEEP(5) > 2s).
  //   // Se a procedure não existir, crie-a. Ajuste SLEEP conforme seu MySQL.
  //   try {
  //     await connTimeout.execute("DROP PROCEDURE IF EXISTS slow_proc");
  //     await connTimeout.execute('''
  //     CREATE PROCEDURE slow_proc()
  //     BEGIN
  //       SELECT SLEEP(5);
  //     END
  //   ''');
  //   } catch (e) {
  //     // Se der erro (sem permissões de criar procedure), ignore para fins de teste
  //   }

  //   bool caughtTimeout = false;
  //   try {
  //     // Tenta chamar a procedure que vai demorar uns 5s
  //     await connTimeout.execute(
  //         "CALL slow_proc()", {}, false, Duration(milliseconds: 2000));
  //   } catch (e) {
  //     // Esperamos que lance alguma exceção por timeout
  //     caughtTimeout = true;
  //   }
  //   expect(caughtTimeout, isTrue,
  //       reason: 'A consulta lenta deveria ter estourado o timeout');
  // });
}
