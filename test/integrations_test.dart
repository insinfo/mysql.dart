import 'dart:typed_data';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

void main() {
  MySQLConnection? conn;

  setUpAll(() async {
    // Cria a conexão com o banco
    conn = await MySQLConnection.createConnection(
      host: 'localhost', // Ajuste conforme seu ambiente
      port: 3306,
      userName: 'dart', // Ajuste conforme seu usuário
      password: 'dart', // Ajuste conforme sua senha
      databaseName: 'banco_teste', // Ajuste conforme seu banco
      secure: false,
    );
    await conn!.connect();

    // Recria a tabela com diversas colunas para os tipos
    await conn!.execute('DROP TABLE IF EXISTS my_table');
    await conn!.execute('''
      CREATE TABLE my_table (
        id INT AUTO_INCREMENT PRIMARY KEY,
        int_column INT,
        string_column VARCHAR(255),
        datetime_column DATETIME,
        blob_column BLOB,
        bool_column TINYINT(1),
        decimal_column DECIMAL(10,2),
        float_column FLOAT,
        double_column DOUBLE,
        date_column DATE,
        time_column TIME,
        year_column YEAR
      )
    ''');
  });

  tearDownAll(() async {
    try {
      await conn!.close();
    } catch (e) {
      // Log ou ignore a exceção se a conexão já estiver fechada
    }
  });

  test("Inserindo um inteiro via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (int_column) VALUES (?)');
    final result = await stmt.execute([42]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo uma string via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (string_column) VALUES (?)');
    final result = await stmt.execute(['Hello, world!']);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo um DateTime via prepared statement", () async {
    final now = DateTime.now();
    final stmt = await conn!
        .prepare('INSERT INTO my_table (datetime_column) VALUES (?)');
    final result = await stmt.execute([now]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo dados binários (Uint8List) via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (blob_column) VALUES (?)');
    // Representa "Hello"
    final myBytes = Uint8List.fromList([0x48, 0x65, 0x6c, 0x6c, 0x6f]);
    final result = await stmt.execute([myBytes]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo um booleano via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (bool_column) VALUES (?)');
    final result = await stmt.execute([true]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo um valor DECIMAL via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (decimal_column) VALUES (?)');
    // Usamos um número que possa ser convertido para String ou num;
    // neste exemplo, 1234.56
    final result = await stmt.execute([1234.56]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo um valor FLOAT via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (float_column) VALUES (?)');
    final result = await stmt.execute([3.14]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo um valor DOUBLE via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (double_column) VALUES (?)');
    final result = await stmt.execute([2.718281828]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo uma DATA via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (date_column) VALUES (?)');
    final result = await stmt.execute(['2023-05-01']);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo um TIME via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (time_column) VALUES (?)');
    // Usando uma string no formato "HH:MM:SS"
    final result = await stmt.execute(['15:30:45']);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });

  test("Inserindo um YEAR via prepared statement", () async {
    final stmt =
        await conn!.prepare('INSERT INTO my_table (year_column) VALUES (?)');
    // Usando um inteiro ou string representando o ano
    final result = await stmt.execute([2023]);
    expect(result.affectedRows.toInt(), equals(1));
    await stmt.deallocate();
  });
  
  test('Strings com acentuação são preservadas em ambos os protocolos', () async {
    const accented = 'Notícias – çãõáéíú';

    // Insere via prepared statement (protocolo binário na ida)
    final insertStmt =
        await conn!.prepare('INSERT INTO my_table (string_column) VALUES (?)');
    final insertResult = await insertStmt.execute([accented]);
    expect(insertResult.affectedRows.toInt(), equals(1));
    final insertedId = insertResult.lastInsertID.toInt();
    await insertStmt.deallocate();

    // Consulta textual pura (sem parâmetros) deve retornar com UTF-8 correto
    final textualResult = await conn!
        .execute('SELECT string_column FROM my_table WHERE id = $insertedId');
    expect(textualResult.numOfRows, greaterThan(0));
    expect(textualResult.rows.first.colAt(0), equals(accented));

    // Consulta preparada (protocolo binário) também deve preservar os acentos
    final binaryStmt = await conn!
        .prepare('SELECT string_column FROM my_table WHERE id = ?');
    final binaryResult = await binaryStmt.execute([insertedId]);
    expect(binaryResult.numOfRows, greaterThan(0));
    expect(binaryResult.rows.first.colAt(0), equals(accented));
    await binaryStmt.deallocate();
  });
  final dt = DateTime(2023, 6, 15, 10, 20, 30);
  final blobData = Uint8List.fromList([0x01, 0x02, 0x03]);

  test('Inserindo e validando linha completa', () async {
    // Insere a linha e obtém o ID
    final stmtInsert = await conn!.prepare('''
      INSERT INTO my_table 
      (int_column, string_column, datetime_column, blob_column, bool_column, 
       decimal_column, float_column, double_column, date_column, time_column, year_column)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    final insertResult = await stmtInsert.execute([
      123,
      'Test String',
      dt,
      blobData,
      false,
      99.99,
      1.23,
      4.56,
      '2023-06-15',
      '12:34:56',
      2023,
    ]);
    expect(insertResult.affectedRows.toInt(), equals(1));
    await stmtInsert.deallocate();

    final stmtId = await conn!.prepare('SELECT LAST_INSERT_ID() AS id');
    final idResult = await stmtId.execute([]);
    expect(idResult.numOfRows, greaterThan(0));
    final insertedId = int.tryParse(idResult.rows.first.colAt(0)!);
    await stmtId.deallocate();

    // Valida os valores inseridos
    final stmtSelect = await conn!.prepare('''
      SELECT int_column, string_column, datetime_column, blob_column, bool_column, 
             decimal_column, float_column, double_column, date_column, time_column, year_column
      FROM my_table
      WHERE id = ?
    ''');
    final selectResult = await stmtSelect.execute([insertedId]);
    expect(selectResult.numOfRows, greaterThan(0));
    final row = selectResult.rows.first;

    expect(row.colAt(0), equals('123'));
    expect(row.colAt(1), equals('Test String'));
    expect(row.typedColAt<DateTime>(2), equals(dt));
    expect(row.colAt(3), isNotNull);
    expect(row.colAt(4), equals('0'));
    expect(row.colAt(5), equals('99.99'));
    expect(double.parse(row.colAt(6)!), closeTo(1.23, 0.001));
    expect(double.parse(row.colAt(7)!), closeTo(4.56, 0.001));
    expect(row.colAt(8)?.substring(0, 10), equals('2023-06-15'));
    expect(row.colAt(9), startsWith('12:34:56'));
    expect(row.colAt(10), equals('2023'));

    await stmtSelect.deallocate();
  });

  test("Inserção duplicada deve lançar erro de chave duplicada", () async {
    // Cria (ou recria) a tabela de teste com chave primária para o id
    await conn!.execute("DROP TABLE IF EXISTS test_dup");
    await conn!.execute('''
      CREATE TABLE test_dup (
        id INT PRIMARY KEY,
        name VARCHAR(50)
      )
    ''');

    // Insere a primeira linha com id = 1
    final stmtInsert =
        await conn!.prepare("INSERT INTO test_dup (id, name) VALUES (?, ?)");
    final result1 = await stmtInsert.execute([1, "Original"]);
    expect(result1.affectedRows.toInt(), equals(1));
    await stmtInsert.deallocate();

    // Tenta inserir outra linha com id = 1, o que deve gerar erro
    final stmtDup =
        await conn!.prepare("INSERT INTO test_dup (id, name) VALUES (?, ?)");
    try {
      await stmtDup.execute([1, "Duplicado"]);
      fail("Deveria lançar erro de chave duplicada");
    } catch (e) {      
      // Verifica se a mensagem de erro contém "Duplicate entry"
      expect(e.toString(), contains("Duplicate entry"),
          reason:
              "O erro deveria indicar que já existe uma entrada com a chave '1'");
    }
    await stmtDup.deallocate();
  });
//end
}
