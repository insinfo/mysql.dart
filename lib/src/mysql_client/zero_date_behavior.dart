import 'package:mysql_dart/exception.dart';

/// What the typed reads (`typedAssoc()`, `typedColAt<DateTime>()`,
/// `typedColByName<DateTime>()`) return for a DATE, DATETIME or TIMESTAMP
/// value [DateTime] cannot represent: the zero date `0000-00-00`, a zero
/// month or day (`2024-05-00`) or an invalid date stored under
/// ALLOW_INVALID_DATES (`2024-02-30`). `colAt()` and `assoc()` always return
/// the server's text.
///
/// The same choice as Connector/J's `zeroDateTimeBehavior`.
enum ZeroDateBehavior {
  /// The value is `null`, as for SQL NULL.
  convertToNull,

  /// A [MySQLClientException] naming the value is thrown.
  exception,
}
