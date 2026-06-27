# Roadmap de desempenho do `mysql_dart`

**Pacote:** `mysql_dart`  
**Versao atual:** `2.0.0`  
**Repositorio:** <https://github.com/insinfo/mysql.dart>  
**Objetivo:** reduzir latencia, uso de CPU, alocacoes e memoria sem comprometer compatibilidade com Percona Server 5.7/8, MySQL Community Server 9/9.7 e MariaDB 10.

> Principio central: nenhuma otimizacao entra apenas por parecer mais rapida. Cada mudanca deve ter benchmark reproduzivel, perfil de CPU/memoria e teste de regressao do protocolo.

## Status atual

### O que ja foi entregue

- `connect()` deixou de usar polling com `Future.delayed(100 ms)` e passou a sinalizar o handshake com `Completer`.
- `close()` deixou de ter atraso artificial fixo de `10 ms`.
- O `SET` de charset/collation no inicio da conexao virou opcional via `setCharsetOnConnect`.
- O parser do header de pacote MySQL passou a usar leitura direta do `Uint8List`, sem `ByteData(4)` temporario.
- `getVariableEncInt`, `getUtf8NullTerminatedString`, `getInt2` e `getInt3` foram reescritos para evitar `hex string + BigInt.parse` no caminho quente.
- `_splitPackets` deixou de concatenar `List<int>` e passou a trabalhar com `Uint8List` e `sublistView`.
- O decode de linhas textuais e binarias passou a pre-alocar listas fixas e precomputar metadados binario/textual por result set.
- `ResultSetRow.colByName()` deixou de fazer busca linear com `toLowerCase()` repetido e passou a usar indice por nome de coluna precomputado por result set.
- `ResultSet` e `PreparedStmtResultSet` passaram a cachear wrappers de linha e metadata de colunas, reduzindo alocacao repetida ao iterar `rows` e `cols`.
- `typedAssoc()` passou a reutilizar o tipo Dart preferido ja precomputado por coluna.
- O decode textual de row passou a ler o campo length-encoded inline no loop, sem criar `Tuple2` auxiliar por celula no caminho quente.
- O decode binario passou a ter fast path para colunas length-encoded comuns (`VARCHAR`, `TEXT`, `JSON`, `DECIMAL`, `BLOB`, `BIT`, `GEOMETRY`), evitando `Tuple2` e dispatch generico por celula nesses tipos.
- Result sets iteraveis agora propagam `pause` / `resume` do `rowsStream` ate a leitura do socket, reduzindo risco de buffer crescer sem controle com consumidor lento.
- O pool deixou de esperar conexao com polling de `10 ms` e passou a acordar esperas por fila FIFO de `Completer`.
- `MySQLConnectionPool.execute(..., iterable: true)` passou a falhar explicitamente, porque o fluxo anterior liberava a conexao cedo demais e era semanticamente inseguro.
- `MySQLConnectionPool.prepare()` passou a falhar explicitamente; a API segura nova para prepared statement em pool e `withPrepared(...)`.
- A conexao agora falha rapido quando uma segunda query tenta usar a mesma conexao ocupada, em vez de ficar pendurada.
- `COM_STMT_EXECUTE` agora evita reenviar tipos de parametros quando a assinatura nao mudou desde a ultima execucao do mesmo prepared statement.
- A eviction do cache automatico de prepared statements passou a usar uma fila de `COM_STMT_CLOSE` diferidos, evitando disputa imediata pela mesma conexao.
- A capacidade do cache automatico de prepared statements passou a ser configuravel por conexao e por pool via `autoPreparedStatementCacheCapacity`.
- O mapeamento de tamanhos de BLOB em prepared statements foi corrigido para `tiny/blob/mediumBlob/longBlob`.

### Resultado medido localmente apos essas mudancas

- Ambiente de referencia: MySQL Community Server `9.7.1`, porta `3308`, TLS habilitado, benchmark local em Windows.
- `connect_avg_ms`: caiu de aproximadamente `129 ms` para aproximadamente `4.95 ms`.
- `connect_avg_ms` sem `SET` inicial de charset: aproximadamente `4.19 ms`.
- `connect_avg_ms` com `SET` inicial de charset: aproximadamente `9.74 ms`.
- `prepared_ops_per_sec` ficou na faixa de `3386 ops/s` no benchmark curto local.
- O gargalo dominante restante deixou de ser handshake e passou a ser parser/alocacao em prepared statements reutilizados e result sets medios/grandes.
- No benchmark comparativo curto atual com MySQL `9.7.1` e TLS:
  - `mysql_dart` ficou em `3448 ops/s` para prepared reutilizado;
  - `PDO` ficou em `12717 ops/s`;
  - `mysqli` ficou em `7039 ops/s`.
- Nos result sets, o gap atual permaneceu concentrado no parser:
  - `rows_1000`: `mysql_dart` ~`260k rows/s`, `PDO` ~`504k rows/s`, `mysqli` ~`498k rows/s`;
  - `rows_10000`: `mysql_dart` ~`300k rows/s`, `PDO` ~`523k rows/s`, `mysqli` ~`602k rows/s`.
- No benchmark local mais recente, materializado e streaming ficaram proximos em throughput bruto, mas o streaming reduziu fortemente o tempo ate a primeira linha:
  - `rows_1000`: materializado `~2.88 ms` para primeira linha vs streaming `~0.85 ms`;
  - `rows_10000`: materializado `~26.64 ms` para primeira linha vs streaming `~0.99 ms`.
- No mesmo benchmark local, o throughput final ficou assim:
  - `rows_1000`: materializado `~310k rows/s`, streaming `~266k rows/s`;
  - `rows_10000`: materializado `~352k rows/s`, streaming `~346k rows/s`.
- O benchmark agora separa `connect` com e sem `SET` inicial de charset, alternando a ordem entre iteracoes e registrando `median`, `p95` e `p99`.
- Em MySQL `9.7.1` local:
  - com TLS: `median` de connect `~4.91 ms` com charset e `~4.30 ms` sem charset;
  - sem TLS: `median` de connect `~1.12 ms` com charset e `~0.96 ms` sem charset.
- O benchmark de result set agora tambem registra um proxy simples de memoria via `ProcessInfo.currentRss` antes/depois/pico para materializado e streaming.
- Alem do RSS bruto, o laboratorio agora inclui `tool/profile_resultset_heap.dart`, que usa `vm_service` para medir `heapUsage` e `heapCapacity` antes/depois de workloads materializados e iteraveis.
- O laboratorio tambem inclui `tool/benchmark_auto_prepare_cache.dart`, que mede hot set vs thrash set e expõe hits, misses e evictions do cache automatico de prepared statements.
- O benchmark hot set vs thrash set esta documentado em `doc/AUTO_PREPARED_CACHE_BENCHMARK.md`; no baseline local com capacidade `32`, o hot set ficou em `~3058 ops/s` com `3999` hits, enquanto um thrash set de `64` variantes caiu para `~1906 ops/s` com `4000` misses e `3969` evictions. Com capacidade `65`, o mesmo conjunto de 64 variantes ficou residente apos warmup e subiu para `~3903 ops/s`.

### Proximo foco confirmado

1. Medir novamente result sets pequenos, medios e grandes depois do fast path binario por celula.
2. Refinar a medicao de memoria/alocacoes alem do RSS bruto, idealmente com perfil de heap por workload.
3. Revisar o auto-cache de prepared statements sob carga prolongada, variando `autoPreparedStatementCacheCapacity` e o tamanho do hot set.
4. Explorar novas reducoes de custo em decode/materializacao por coluna e por linha.
5. Avaliar a elevacao do SDK minimo de `>=2.16.0 <4.0.0` para `>=3.6.0 <4.0.0` em uma proxima versao, para alinhar o pacote ao baseline real dos benchmarks AOT e liberar refatoracoes modernas no caminho quente.

### Baseline de SDK para a proxima versao

A versao `2.0.0` ja foi publicada mantendo o range atual de SDK. Para a proxima linha de evolucao, vale planejar a troca de:

```yaml
environment:
  sdk: '>=2.16.0 <4.0.0'
```

para:

```yaml
environment:
  sdk: '>=3.6.0 <4.0.0'
```

Essa mudanca nao melhora a performance automaticamente. O codigo ja roda com as otimizacoes da VM/AOT do Dart instalado pelo usuario mesmo quando o `pubspec.yaml` aceita Dart `2.16`. O ganho esperado e indireto: permitir que o driver use recursos modernos do Dart no hot path e simplifique codigo que hoje existe para manter compatibilidade ampla.

Beneficios esperados:

- usar `records` ou estruturas equivalentes para substituir retornos auxiliares como `Tuple2` em leitores internos;
- avaliar `extension types` para wrappers leves de cursor, offsets, metadados e planos de decode;
- reduzir codigo defensivo legado e alinhar CI, benchmarks e suporte oficial ao Dart usado nos testes AOT;
- facilitar planos de encoding/decoding mais especializados sem carregar compatibilidade antiga no caminho quente;
- manter a documentacao de performance vinculada ao mesmo SDK que produz os numeros publicados.

Cuidados:

- elevar o SDK minimo e uma quebra para usuarios ainda presos em Dart `2.x`;
- se a politica de semver for estrita, essa mudanca deve ser tratada como breaking e pode justificar uma futura linha `3.0.0`;
- se for feita em `2.1.x`, documentar explicitamente que o pacote passa a exigir Dart `3.6+`;
- nao vender a troca do constraint como otimizacao isolada; ela so gera ganho quando vier acompanhada de refatoracoes medidas no parser, no `COM_STMT_EXECUTE`, nos wrappers de row e no streaming.

### Ideias de outras bases de codigo

As referencias em `C:\MyDartProjects\dpgsql` e `C:\MyDartProjects\dpgsql\referencias\npgsql` trazem ideias uteis para o `mysql_dart`, principalmente no desenho de pool, observabilidade e ciclo de vida de conexao. Essas ideias devem ser usadas como referencia arquitetural e reimplementadas de forma propria para MySQL; nao devem ser copiadas mecanicamente, porque o protocolo, licenca, linguagem e modelo de execucao sao diferentes.

#### dpgsql: pool orientado a sessao

O trecho analisado do `dpgsql` mostra um `PgPool` com endpoint configuravel, configuracoes centralizadas, execucao por sessao e eventos estruturados. Ideias aplicaveis ao `mysql_dart`:

- criar uma camada de configuracao de endpoint/pool mais coesa, separando host, porta, database, TLS, usuario, senha, unix socket e parametros de inicializacao;
- oferecer parse de connection URL MySQL, por exemplo `mysql://user:pass@host:port/db?sslmode=require`, sem substituir a API atual por construtores manuais;
- expor eventos opcionais de pool/conexao/query com `connectionId`, `sessionId`, `traceId`, acao, SQL, parametros mascaraveis, duracao, erro e stack trace;
- manter `status()` mais rico, incluindo conexoes abertas, ociosas, ocupadas, idade, contagem de queries, erros, fila e tempo acumulado de uso;
- reciclar conexoes por `maxConnectionAge`, `maxSessionUse`, `maxErrorCount` e `maxQueryCount`, nao apenas por idle/erro;
- testar conexoes ociosas somente apos `idleTestThreshold`, evitando `PING` em toda aquisicao;
- garantir que apenas uma abertura fisica de conexao seja iniciada quando varias chamadas concorrentes tentam expandir o pool ao mesmo tempo;
- padronizar `withConnection`/`withPrepared` como unidade de sessao: a conexao fica emprestada ate a callback terminar e nunca vaza objetos presos a conexao para fora do ciclo de vida correto;
- centralizar retry com backoff, jitter e predicado por erro, mantendo retries fora de transacoes ou usando regras conservadoras para nao repetir operacoes nao idempotentes;
- incluir hook `onOpen`/`onConnectionOpen` com medicao separada, para diferenciar custo de handshake, autenticacao e comandos iniciais como `SET time_zone` ou `SET NAMES`.

Cuidados para MySQL:

- o protocolo classico MySQL nao multiplexa comandos independentes na mesma conexao, entao a sessao precisa continuar serializada;
- prepared statements pertencem a conexao fisica, entao qualquer cache/eviction precisa respeitar o ciclo de vida da conexao do pool;
- retries precisam ser conservadores, porque um erro de rede depois de enviar um `INSERT` pode deixar o resultado real desconhecido;
- eventos nao podem montar strings caras nem serializar parametros no caminho quente quando nao houver listener ativo.

#### Npgsql: data source, auto-prepare e observabilidade

O Npgsql e uma base madura para estudar comportamento de driver, especialmente em:

- `NpgsqlDataSource`/builder: separar configuracao imutavel compartilhada de conexoes fisicas; uma ideia equivalente em Dart seria um `MySQLDataSource` opcional que concentre pool, codecs, cache de prepared statements, TLS, hooks e metricas;
- auto-prepare: estudar politica de preparo automatico, contadores de uso, limite de statements e eviction para melhorar o `autoPreparedStatementCacheCapacity` atual;
- reset de conexao: estudar o modelo de devolver conexao limpa ao pool. Em MySQL, avaliar `COM_RESET_CONNECTION` como alternativa a fechar/reabrir ou executar varios `SET` manuais;
- batch/command pipeline: adaptar apenas o que couber no protocolo MySQL, como multi-row insert, batch helpers e envio eficiente de varios comandos quando a semantica permitir;
- logs/eventos gerados de forma barata: manter mensagens e parametros fora do caminho quente quando logging/telemetria estiver desativado;
- OpenTelemetry/metrics como pacote opcional: expor hooks leves no nucleo e deixar integracoes pesadas fora do runtime principal;
- multi-host/failover como investigacao futura: mapear hosts, prioridades, backoff e health checks sem aumentar custo para quem usa um unico servidor local.

Trabalho recomendado inspirado nessas referencias:

1. Criar um documento `doc/POOL_AND_DATASOURCE_DESIGN.md` antes de mudar API publica.
2. Adicionar benchmarks de pool com fila saturada, abertura concorrente, reciclagem por idade/uso e retries desativados/ativados.
3. Expor eventos opcionais de pool com custo zero ou quase zero quando nao houver listeners.
4. Medir `COM_RESET_CONNECTION` ao devolver conexao e comparar com `SET` manual e reconexao completa.
5. Reavaliar auto-prepare com politica de uso minimo antes de preparar, evitando thrash em SQLs raros.
6. Garantir que qualquer nova API mantenha a regra principal: objetos presos a conexao fisica nao podem escapar do periodo em que a conexao esta emprestada ao usuario.

### Leitura apos benchmark AOT

O `mysql_dart` ainda nao atingiu o maximo possivel em Dart. A serie `2.0.0` removeu o gargalo mais grosseiro, que era a latencia artificial em `connect()`, e melhorou fortemente result sets grandes. Pelos numeros AOT, o proximo gargalo dominante nao parece ser o `Socket` do Dart; ele esta mais concentrado em prepared statements escalares, materializacao de rows e parsing/encoding de pacotes no caminho quente.

#### Prepared escalar pequeno

No benchmark local AOT contra MariaDB `10.11.6`:

| Driver | Prepared ops/s |
|---|---:|
| PDO | `14741` |
| mysqli | `15535` |
| mysql_dart AOT | `11362` |

O custo restante provavelmente esta em:

- criacao de objetos por execucao;
- construcao do pacote `COM_STMT_EXECUTE`;
- parsing do result set de uma linha;
- wrappers de `ResultSet`, `ResultSetRow` e metadados ao redor da resposta pequena.

`mysqli` usa extensao nativa C, entao bater esse caminho em prepared escalar pequeno pode ser dificil. Ainda assim, o gap indica trabalho mensuravel no caminho Dart.

#### Materializacao de rows

Em result sets de `10000` linhas, AOT ja ficou competitivo, mas ainda ha oportunidades:

- reduzir criacao de `ResultSetRow`;
- reduzir uso de `String` e `dynamic` onde a informacao de tipo ja e conhecida;
- criar um plano de decode por coluna, calculado uma vez por result set;
- eliminar mais `ByteData.sublistView` e `Tuple2` no caminho quente restante;
- separar melhor valores raw/lazy de valores convertidos quando a API permitir.

#### Prepared statement execute

Ja foi implementada a otimizacao para nao reenviar metadata de tipos quando a assinatura dos parametros nao muda. Os proximos passos sao:

- codificar `COM_STMT_EXECUTE` diretamente em um `Uint8List` de tamanho conhecido;
- evitar `ByteDataWriter` nesse pacote especifico;
- cachear um plano de encoding dos parametros por prepared statement;
- evitar inferencia de tipo quando a assinatura ja foi estabilizada;
- medir esse caminho isoladamente contra `PDO`/`mysqli` prepared.

#### Pool

O pool deixou de fazer polling para esperar conexao livre, mas ainda pode melhorar:

- usar `Queue`/`Set` de forma consistente em todos os caminhos de idle/active;
- expor metricas internas de espera, fila, tempo de uso e reciclamentos;
- avaliar `COM_RESET_CONNECTION` ao devolver conexao, quando suportado pelo servidor;
- coordenar cache de prepared statements com o ciclo de vida do pool;
- testar carga prolongada para confirmar ausencia de crescimento de statements, conexoes e memoria.

#### Streaming como caminho principal para grandes volumes

O streaming ja propaga backpressure para a subscription do socket, mas o benchmark comparativo do README mede o caminho materializado. Para workloads grandes, o proximo ganho real e tornar o streaming mais barato e documentar quando ele deve ser preferido:

- medir streaming vs materializado em AOT;
- reduzir wrappers e conversoes no fluxo `rowsStream`;
- definir comportamento de cancelamento antes do EOF;
- documentar que a conexao fica ocupada ate consumir ou descartar o result set.

#### Parser incremental e ring buffer

`_splitPackets` ja deixou de fazer a pior concatenacao de listas, mas ainda nao e o desenho final. O limite superior em Dart provavelmente exige:

- leitor incremental por conexao com cursor;
- buffer reutilizavel ou ring buffer;
- leitura do header e payload sem criar views/copia quando possivel;
- tratamento completo de pacotes fragmentados e mensagens acima de `0xFFFFFF` bytes;
- testes de fragmentacao para cada divisao possivel de header/payload.

#### Conclusao de performance

O driver nao esta no limite do Dart. A `2.0.0` e uma base forte, mas ainda ha um caminho plausivel de ganho entre `10%` e `40%` em prepared/result set dependendo do cenario. Em prepared escalar pequeno, `mysqli` pode continuar dificil de bater por usar C nativo. Em result sets medios/grandes, o driver Dart ja compete bem e ainda pode melhorar com reducao de alocacoes, plano de decode por coluna e parser incremental.

## 1. Referencias tecnicas

| Driver | O que estudar | Aplicacao no Dart | Licenca |
|---|---|---|---|
| [`go-sql-driver/mysql`](https://github.com/go-sql-driver/mysql) | Buffer reutilizavel por conexao, leitura incremental de pacotes, `RawBytes`, tratamento de pacotes acima de 16 MiB, `LONG DATA` e benchmarks internos | Principal referencia para o caminho critico de I/O e protocolo | MPL-2.0 |
| [`mysql2`](https://github.com/sidorares/node-mysql2) | Parser binario especializado, cache LRU de prepared statements e API separada para resultados/streams | Referencia para cache por conexao e parser com poucos objetos intermediarios | MIT |
| [`mysql_async`](https://github.com/blackbeam/mysql_async) | Pool assincrono, resultados em stream, cache de statements por conexao, tipos binarios e buffers | Referencia arquitetural para backpressure, pool e API de streaming | MIT/Apache-2.0 |
| [`MySQL Connector/C`](https://dev.mysql.com/doc/c-api/8.0/en/) | Semantica oficial de prepared statements, resultados armazenados ou incrementais, envio de dados longos em partes | Referencia de comportamento e casos-limite do protocolo | GPL/comercial; consultar apenas como referencia |
| [`Pointy Castle`](https://pub.dev/packages/pointycastle) | RSA-OAEP e SHA-1 para o fluxo completo de `caching_sha2_password` sem TLS | Evita implementar primitivas criptograficas manualmente | MIT |
| `C:\MyDartProjects\dpgsql` | Pool por sessao, eventos, status, retries, reciclagem por idade/uso/erro/query count e endpoint configuravel | Referencia local para evoluir `MySQLConnectionPool` sem vazar objetos presos a conexao | Projeto local; usar como referencia conceitual |
| `C:\MyDartProjects\dpgsql\referencias\npgsql` | Data source, pooling maduro, auto-prepare, reset de conexao, logs estruturados, metricas e OpenTelemetry | Referencia arquitetural para uma futura camada `MySQLDataSource`, telemetria e politica de auto-prepare | Consultar licenca antes de portar qualquer trecho |

Nao existe evidencia publica suficiente para declarar um unico driver como "o mais rapido" em todas as cargas. Linguagem, runtime, rede, TLS, servidor e forma de consumo dos resultados mudam o resultado. O objetivo deve ser reproduzir as tecnicas desses drivers e comparar o `mysql_dart` no mesmo ambiente.

## 2. Metas e limites

### Metas para a serie 1.x

- Reduzir em pelo menos **30% as alocacoes por linha** nos benchmarks de resultados medios e grandes.
- Reduzir em pelo menos **20% o tempo de CPU do cliente** ao ler 100 mil linhas.
- Manter a regressao de `p95` abaixo de **5%** nos cenarios que nao forem alvo da mudanca.
- Limitar o crescimento de RSS ao consumir resultados por streaming; a memoria nao deve crescer proporcionalmente ao total de linhas.
- Melhorar em pelo menos **20% o throughput** de statements repetidos quando o cache estiver ativo.
- Manter compatibilidade funcional e resultados identicos em toda a matriz de bancos suportados.

Esses valores sao metas iniciais. Depois do baseline, devem ser ajustados com base nos gargalos realmente encontrados.

### Nao objetivos imediatos

- Reescrever o driver com FFI.
- Criar um isolate por conexao.
- Adicionar compressao por padrao.
- Trocar seguranca por desempenho, desabilitando validacao TLS ou recuperacao segura de chaves.
- Alterar tipos publicos apenas para ganhar microsegundos sem impacto mensuravel na aplicacao.

## 3. Fase 0: baseline e laboratorio de benchmark

**Prioridade:** critica  
**Versao sugerida:** `1.3.x`

### Entregas

- Criar `benchmark/` usando `package:benchmark_harness` ou um executor proprio que tenha aquecimento, varias amostras e exportacao JSON.
- Executar benchmarks em Dart JIT e em executavel AOT (`dart compile exe`). AOT deve ser o numero principal de producao.
- Fixar CPU, memoria, SO, Dart SDK, servidor, charset, TLS e configuracao do MySQL nos resultados.
- Separar tempo do servidor do custo do cliente usando consultas triviais e conjuntos pre-carregados.
- Registrar mediana, `p95`, `p99`, operacoes/s, bytes/s, CPU, RSS maximo, alocacoes e pausas de GC.
- Salvar resultados de referencia em `benchmark/baselines/1.3.0/`.
- Executar cada cenario contra MySQL/Percona 5.7 ou 8, MySQL 9.x e MariaDB 10.x no CI noturno. O CI comum pode usar uma matriz menor.

### Cenarios obrigatorios

| Grupo | Cenario |
|---|---|
| Conexao | cold connect com e sem TLS; `caching_sha2_password` fast auth e full auth; conexao retirada do pool |
| Latencia | `SELECT 1` sequencial, concorrencias 1/8/32/100 e RTT local/artificial |
| Resultados | 1, 100, 10 mil e 100 mil linhas; linhas estreitas e largas |
| Tipos | inteiros signed/unsigned, decimal, float, temporal, `NULL`, UTF-8, JSON, BLOB de 1 KiB/1 MiB/32 MiB |
| Escrita | inserts individuais, prepared repetido, multi-row insert e transacao em lote |
| Protocolo | text protocol contra binary protocol; pacote unico e resposta acima de 16 MiB |
| Memoria | resultado materializado contra streaming com consumidor lento |
| Pool | aquisicao sem espera, fila saturada, timeout, conexao morta e reciclagem |

### Gate de conclusao

- Resultados reproduziveis com variacao menor que 5% nos testes locais controlados.
- Perfil de CPU e memoria identifica os cinco maiores custos antes de qualquer refatoracao ampla.

## 4. Fase 1: caminho critico de bytes e pacotes

**Prioridade:** critica  
**Versao sugerida:** `1.4.0`

### 4.1 Leitor incremental por conexao

- Manter um buffer de recepcao e um cursor, em vez de concatenar e remover bytes a cada evento do `Socket`.
- Interpretar o cabecalho MySQL de 4 bytes diretamente no buffer: 3 bytes de tamanho little-endian e 1 byte de sequencia.
- Preservar pacotes incompletos entre eventos do socket e consumir varios pacotes presentes no mesmo evento.
- Compactar ou aumentar o buffer apenas quando necessario; nao usar `removeRange(0, n)` no caminho quente.
- Implementar corretamente a montagem de mensagens com fragmentos de `0xFFFFFF` bytes.

### 4.2 Menos copias

- Padronizar o caminho binario em `Uint8List`, `ByteData` e views.
- Trocar `sublist()` por `Uint8List.sublistView()` quando a vida util do buffer original estiver garantida.
- Evitar `List<int>`, `map`, `expand`, `toList` e conversoes repetidas no parser.
- Usar `BytesBuilder(copy: false)` somente quando os blocos adicionados ficarem imutaveis. A [API do Dart](https://api.dart.dev/dart-typed_data/BytesBuilder/BytesBuilder.html) pode devolver diretamente o unico `Uint8List` adicionado, mas buffers mutaveis/reutilizados nao podem ser entregues dessa forma.
- Para escrita com tamanho conhecido, alocar um unico `Uint8List`, preencher cabecalho e payload com cursor e chamar `socket.add()` uma vez.
- Reutilizar buffers por conexao com limite de retencao. Um pacote excepcional de 100 MiB nao deve fazer cada conexao conservar 100 MiB para sempre.

### 4.3 Parser orientado a cursor

- Criar um leitor interno pequeno, por exemplo `PacketReader(bytes, offset, end)`, com operacoes little-endian e length-encoded.
- Fazer as rotinas retornarem o novo offset em vez de criarem slices intermediarios.
- Decodificar texto apenas quando a API pedir `String`; oferecer internamente uma representacao de bytes para BLOB e valores ainda nao convertidos.
- Especializar os caminhos comuns de inteiros, `NULL`, strings UTF-8 e length-encoded integers.
- Evitar excecoes como controle de fluxo em parsing normal.

### Gate de conclusao

- Todos os testes de fragmentacao passam para cada possivel divisao do cabecalho e payload em eventos TCP.
- Pelo menos 30% menos alocacoes por linha no benchmark escolhido.
- Nenhuma regressao acima de 5% em respostas pequenas.

## 5. Fase 2: resultados em streaming e conversao sob demanda

**Prioridade:** alta  
**Versao sugerida:** `1.5.0`

### Entregas

- Adicionar uma API do tipo `Stream<MySqlRow> queryStream(...)` sem remover a API que materializa listas.
- Propagar pause/resume do consumidor ate a leitura do socket para obter backpressure real.
- Impedir uma segunda consulta na mesma conexao enquanto o resultado anterior nao tiver sido consumido ou descartado.
- Adicionar cancelamento/fechamento seguro: drenar os pacotes restantes quando barato ou invalidar a conexao quando o estado do protocolo nao puder ser recuperado.
- Implementar `raw`/lazy values internamente, convertendo datas, decimais, JSON e strings somente quando acessados.
- Permitir consumo direto de BLOB como bytes e, numa etapa posterior, stream/chunks para valores muito grandes.
- Disponibilizar helpers `first`, `single`, `forEach` e `fold` que nao materializem todo o resultado.

### Cuidados

- Views zero-copy nao podem sobreviver a reutilizacao do buffer. Linhas publicas duraveis precisam copiar os campos acessados ou manter ownership explicito do bloco.
- Streaming prende a conexao ate o fim do resultado. A documentacao deve explicar esse efeito no pool.

### Gate de conclusao

- Leitura de 1 milhao de linhas com memoria limitada e sem crescimento proporcional ao conjunto.
- Consumidor lento nao provoca fila ilimitada no heap.
- Cancelamento nao devolve ao pool uma conexao com pacotes pendentes.

## 6. Fase 3: prepared statements e protocolo binario

**Prioridade:** alta  
**Versao sugerida:** `1.6.0`

### Entregas

- Criar cache LRU de prepared statements **por conexao**, pois o identificador do statement pertence a conexao que o preparou.
- Usar como chave o SQL exato e as opcoes que alterem sua preparacao.
- Enviar `COM_STMT_CLOSE` ao remover uma entrada, fechar a conexao ou limpar o cache.
- Tornar `statementCacheSize` configuravel, com um padrao conservador entre 32 e 128 apos benchmark.
- Expor metricas de hit, miss, eviction e statements abertos.
- Calcular/documentar o limite operacional: `maxPoolSize * statementCacheSize` deve ficar confortavelmente abaixo de `max_prepared_stmt_count`, compartilhado pelo servidor.
- Reutilizar metadata do statement e codificadores de parametros.
- Implementar bitmap de `NULL`, tipos e valores em uma unica passagem para `COM_STMT_EXECUTE`.
- Usar `COM_STMT_SEND_LONG_DATA` em chunks para parametros grandes, evitando montar copias gigantes.
- Adicionar batch execute/multi-row helpers sem prometer que prepared statements sempre vencem `COM_QUERY`: a propria documentacao do MySQL recomenda medir ambos.

O `mysql2` reutiliza statements automaticamente por meio de cache LRU; o `mysql_async` tambem mantem cache por conexao. Esses sao os modelos mais adequados para o `mysql_dart`.

### Gate de conclusao

- Pelo menos 20% mais throughput em SQL repetido com cache aquecido.
- Contagem de statements no servidor estabiliza sob carga prolongada.
- Eviction, reconexao e fechamento nao deixam statements vazando.

## 7. Fase 4: pool de conexoes

**Prioridade:** alta  
**Versao sugerida:** `1.7.0`

### Modelo recomendado

- Pool lazy com `minConnections`, `maxConnections`, `maxIdle`, `idleTimeout`, `maxLifetime`, `acquireTimeout` e fila FIFO.
- Uma conexao atende somente uma operacao ativa por vez; multiplexar comandos no protocolo classico nao e seguro.
- Validar conexoes ociosas somente quando necessario, evitando um `COM_PING` antes de toda consulta.
- Remover conexoes quebradas imediatamente e limitar tempestades de reconexao com backoff e jitter.
- Ao devolver conexao, assegurar que nao ha transacao, resultado pendente ou statement em estado inconsistente.
- Avaliar `COM_RESET_CONNECTION` para limpar estado de sessao sem refazer TCP/TLS/auth, com fallback conforme servidor e versao.
- Aquecer `minConnections` opcionalmente e nunca bloquear a construcao do pool por padrao.
- Fechamento gracioso deve rejeitar novas aquisicoes, aguardar operacoes por um prazo e fechar as restantes.

### Dimensionamento

- Nao usar `maxConnections` excessivo para mascarar fila: medir saturacao do servidor e latencia de espera.
- Oferecer telemetria de conexoes abertas, ociosas, ocupadas, fila, tempo de espera, timeouts e descartes.
- Publicar um guia inicial: comecar pequeno, normalmente 4 a 16 conexoes por processo, e ajustar por carga e numero de processos.

### Gate de conclusao

- Sem starvation na fila FIFO.
- Sem conexao em estado sujo reutilizada apos erro, cancelamento ou transacao abandonada.
- Teste de carga de pelo menos 30 minutos com numero de conexoes e memoria estaveis.

## 8. Fase 5: rede, TLS e autenticacao

**Prioridade:** media  
**Versao sugerida:** `1.8.0`

- Medir `SocketOption.tcpNoDelay` em consultas pequenas e interativas; oferecer opcao configuravel se houver ganho consistente. Nao assumir que ativar sempre melhora throughput.
- Agrupar cabecalho e payload numa unica escrita sempre que possivel, reduzindo chamadas ao socket.
- Reutilizar conexoes TLS pelo pool; o maior ganho costuma ser evitar novos handshakes.
- Medir session resumption caso a API/plataforma Dart utilizada permita controle confiavel.
- Manter `caching_sha2_password` fast auth e full auth cobertos por benchmarks separados.
- Sem TLS, preferir chave RSA fixada. Recuperacao automatica da chave deve exigir opcao explicita, pois protege contra escuta passiva, mas nao autentica o servidor contra MITM.
- Retirar RSA, PEM e OAEP do caminho comum depois que a conexao estiver autenticada.
- Comparar TCP e Unix domain socket quando ambos estiverem disponiveis localmente.

## 9. Fase 6: compressao e cargas grandes

**Prioridade:** media/baixa  
**Versao sugerida:** `1.9.0`

- Implementar a capacidade de compressao MySQL atras de uma opcao, nunca ativa por padrao inicialmente.
- Medir separadamente LAN, loopback e WAN com RTT/largura de banda controlados.
- Registrar bytes antes/depois, CPU e latencia. Em rede local rapida, compressao pode piorar o resultado.
- Reutilizar buffers de compressao com teto de retencao.
- Implementar streaming/chunks para `LOAD DATA LOCAL INFILE`, BLOB e `LONG DATA`, com allowlist para arquivos locais.
- Adicionar helpers de insert multi-row com limite por `max_allowed_packet`.
- Evitar consultar `max_allowed_packet` em toda conexao por padrao; permitir valor configurado ou descoberta opcional com cache.

## 10. Fase 7: observabilidade e ajuste continuo

**Prioridade:** continua

- Hooks leves e opcionais para tempo de aquisicao, conexao, envio, primeiro byte, parsing e consumo completo.
- Contadores de bytes lidos/escritos, linhas, pacotes, reconexoes, cache de statements e pool.
- Integracao opcional com OpenTelemetry sem dependencia obrigatoria no nucleo.
- Logging desativado no caminho quente; mensagens e interpolacao so devem ser construidas quando o nivel estiver ativo.
- Benchmark de PR comparado ao baseline, com alerta inicialmente e bloqueio apenas apos estabilizar a infraestrutura.
- Publicar dashboard historico por Dart SDK e banco para detectar regressoes do runtime ou servidor.

## 11. Investigacoes condicionais

Estas mudancas so devem ser iniciadas se profiling demonstrar necessidade:

### Isolates

- Nao mover cada conexao para um isolate: sockets, mensagens e copias podem custar mais do que o parser.
- Avaliar isolate apenas para conversao CPU-bound de lotes muito grandes, usando `TransferableTypedData` e um limiar medido.
- Nunca reordenar linhas nem perder backpressure para paralelizar conversao.

### FFI

- Considerar uma implementacao opcional baseada em Connector/C apenas se o parser Dart continuar dominante depois das fases anteriores.
- Manter o driver Dart puro como padrao por portabilidade, instalacao simples e seguranca de memoria.
- Contabilizar custo de crossing FFI, ownership, empacotamento nativo, licenca e suporte multiplataforma.

### Parsers gerados/especializados

- Avaliar code generation para metadata conhecida e mapeamento direto de `Row` para classes.
- Manter parser generico como base e medir o ganho antes de aumentar a superficie publica.

## 12. Estrutura de testes de desempenho

```text
benchmark/
  README.md
  runner.dart
  workloads/
    connect.dart
    query_scalar.dart
    result_text.dart
    result_binary.dart
    prepared_reuse.dart
    bulk_insert.dart
    blob_stream.dart
    pool_contention.dart
  fixtures/
    schema.sql
    seed.sql
  baselines/
    1.3.0/
  reports/
tool/
  benchmark_matrix.dart
  compare_benchmarks.dart
```

Cada resultado deve conter commit, Dart SDK, modo JIT/AOT, SO/CPU, driver versionado, servidor/imagem, TLS, compressao, pool, tamanho do dataset e estatisticas completas. Nao comparar numeros de maquinas diferentes como se fossem uma regressao do codigo.

## 13. Ordem pratica de implementacao

1. Baseline reproduzivel e perfis de CPU/memoria.
2. Parser incremental com testes de fragmentacao TCP.
3. Reducao de copias e alocacoes no leitor/escritor de pacotes.
4. API de resultados em streaming com backpressure.
5. Cache LRU de prepared statements por conexao.
6. Pool com limites, reciclagem e telemetria.
7. Otimizacoes de escrita, batches e `LONG DATA`.
8. Ajustes de TCP/TLS medidos.
9. Compressao opcional para cenarios em que a rede seja o gargalo.
10. Isolates ou FFI somente se os perfis restantes justificarem.

## 14. Checklist para cada PR de desempenho

- [ ] Existe benchmark que reproduz o gargalo?
- [ ] O benchmark foi executado antes e depois no mesmo ambiente?
- [ ] Foram medidos CPU, memoria, alocacoes e latencia de cauda, nao apenas media?
- [ ] A mudanca preserva fragmentacao, sequencia e limites do protocolo?
- [ ] Ha teste para erro, cancelamento, conexao encerrada e payload grande?
- [ ] O ganho permanece em AOT?
- [ ] O ganho permanece com TLS?
- [ ] Nao houve regressao relevante nos outros tamanhos de carga?
- [ ] A nova opcao tem padrao conservador e esta documentada?
- [ ] README e CHANGELOG explicam impacto e migracao, quando aplicavel?

## 15. Fontes

- Go MySQL Driver: <https://github.com/go-sql-driver/mysql>
- Implementacao de buffer do Go MySQL Driver: <https://github.com/go-sql-driver/mysql/blob/master/buffer.go>
- Implementacao de pacotes do Go MySQL Driver: <https://github.com/go-sql-driver/mysql/blob/master/packets.go>
- Benchmarks do Go MySQL Driver: <https://github.com/go-sql-driver/mysql/blob/master/benchmark_test.go>
- mysql2: <https://github.com/sidorares/node-mysql2>
- Prepared statements do mysql2: <https://sidorares.github.io/node-mysql2/docs/documentation/prepared-statements>
- mysql_async: <https://github.com/blackbeam/mysql_async>
- API do mysql_async: <https://docs.rs/mysql_async/latest/mysql_async/>
- MySQL Connector/C 8.0: <https://dev.mysql.com/doc/c-api/8.0/en/>
- MySQL `caching_sha2_password`: <https://dev.mysql.com/doc/refman/9.1/en/caching-sha2-pluggable-authentication.html>
- Dart `BytesBuilder`: <https://api.dart.dev/dart-typed_data/BytesBuilder/BytesBuilder.html>
- Pointy Castle: <https://pub.dev/packages/pointycastle>
