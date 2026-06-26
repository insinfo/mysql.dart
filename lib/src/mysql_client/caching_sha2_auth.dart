import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mysql_dart/src/utils/hash.dart';

Uint8List buildCachingSha2CleartextPassword(String password) {
  return Uint8List.fromList(utf8.encode(password));
}

Uint8List buildCachingSha2PublicKeyRequest() {
  return Uint8List.fromList([0x02]);
}

Uint8List buildCachingSha2EncryptedPassword(
  String password,
  Uint8List seed,
  String publicKeyPem,
) {
  final prepared = _preparePassword(password, seed);
  final publicKey = _parseRsaPublicKeyFromPem(publicKeyPem);
  final encodedMessage = _oaepEncode(
    prepared,
    publicKey.modulusLength,
  );
  final message = _bytesToBigInt(encodedMessage);
  final encrypted = message.modPow(publicKey.exponent, publicKey.modulus);
  return _bigIntToFixedLengthBytes(encrypted, publicKey.modulusLength);
}

Uint8List _preparePassword(String password, Uint8List seed) {
  final passwordBytes = utf8.encode(password);
  final plain = Uint8List(passwordBytes.length + 1);
  plain.setRange(0, passwordBytes.length, passwordBytes);

  for (var i = 0; i < plain.length; i++) {
    plain[i] ^= seed[i % seed.length];
  }

  return plain;
}

Uint8List _oaepEncode(Uint8List message, int modulusLength) {
  final hLen = 20; // SHA-1
  if (message.length > modulusLength - 2 * hLen - 2) {
    throw ArgumentError('Message too long for RSA OAEP envelope');
  }

  final labelHash = sha1Digest(const <int>[]);
  final ps = Uint8List(modulusLength - message.length - 2 * hLen - 2);
  final db = Uint8List.fromList([
    ...labelHash,
    ...ps,
    0x01,
    ...message,
  ]);

  final seed = _randomBytes(hLen);
  final dbMask = _mgf1(seed, db.length);
  final maskedDb = _xor(db, dbMask);
  final seedMask = _mgf1(maskedDb, hLen);
  final maskedSeed = _xor(seed, seedMask);

  return Uint8List.fromList([
    0x00,
    ...maskedSeed,
    ...maskedDb,
  ]);
}

Uint8List _mgf1(Uint8List seed, int length) {
  final output = BytesBuilder(copy: false);
  var counter = 0;

  while (output.length < length) {
    final c = Uint8List(4);
    final data = ByteData.sublistView(c);
    data.setUint32(0, counter, Endian.big);
    output.add(sha1Digest([...seed, ...c]));
    counter++;
  }

  final bytes = output.toBytes();
  return Uint8List.sublistView(bytes, 0, length);
}

Uint8List _xor(Uint8List left, Uint8List right) {
  final result = Uint8List(left.length);
  for (var i = 0; i < left.length; i++) {
    result[i] = left[i] ^ right[i];
  }
  return result;
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

_RsaPublicKey _parseRsaPublicKeyFromPem(String pem) {
  final normalized = pem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll('-----BEGIN RSA PUBLIC KEY-----', '')
      .replaceAll('-----END RSA PUBLIC KEY-----', '')
      .replaceAll(RegExp(r'\s+'), '');

  final derBytes = base64.decode(normalized);
  final topLevel = _readDerObject(derBytes, 0);
  if (topLevel.tag != 0x30) {
    throw ArgumentError('Unsupported RSA public key format');
  }

  final children = _readDerChildren(topLevel.value);
  if (children.length >= 2 &&
      children[0].tag == 0x02 &&
      children[1].tag == 0x02) {
    return _readPkcs1PublicKey(children);
  }

  final bitString = children.firstWhere(
    (child) => child.tag == 0x03,
    orElse: () => throw ArgumentError('Unsupported SubjectPublicKeyInfo'),
  );

  if (bitString.value.isEmpty || bitString.value[0] != 0x00) {
    throw ArgumentError('Unsupported RSA bit string encoding');
  }

  final publicKeySequence = _readDerObject(
    Uint8List.sublistView(bitString.value, 1),
    0,
  );
  if (publicKeySequence.tag != 0x30) {
    throw ArgumentError('Unsupported RSA public key payload');
  }

  return _readPkcs1PublicKey(_readDerChildren(publicKeySequence.value));
}

_RsaPublicKey _readPkcs1PublicKey(List<_DerObject> children) {
  if (children.length < 2 ||
      children[0].tag != 0x02 ||
      children[1].tag != 0x02) {
    throw ArgumentError('Unsupported PKCS#1 RSA public key');
  }

  final modulus = _unsignedBigIntFromDerInteger(children[0].value);
  final exponent = _unsignedBigIntFromDerInteger(children[1].value);
  return _RsaPublicKey(modulus, exponent);
}

List<_DerObject> _readDerChildren(Uint8List bytes) {
  final children = <_DerObject>[];
  var offset = 0;
  while (offset < bytes.length) {
    final child = _readDerObject(bytes, offset);
    children.add(child);
    offset = child.endOffset;
  }
  return children;
}

_DerObject _readDerObject(Uint8List bytes, int offset) {
  if (offset >= bytes.length) {
    throw ArgumentError('Unexpected end of DER stream');
  }

  final tag = bytes[offset];
  final lengthInfo = _readDerLength(bytes, offset + 1);
  final valueStart = lengthInfo.valueStart;
  final valueEnd = valueStart + lengthInfo.length;
  if (valueEnd > bytes.length) {
    throw ArgumentError('Invalid DER object length');
  }

  return _DerObject(
    tag,
    Uint8List.sublistView(bytes, valueStart, valueEnd),
    valueEnd,
  );
}

_DerLength _readDerLength(Uint8List bytes, int offset) {
  final first = bytes[offset];
  if (first < 0x80) {
    return _DerLength(offset + 1, first);
  }

  final lengthBytesCount = first & 0x7f;
  if (lengthBytesCount == 0 || lengthBytesCount > 4) {
    throw ArgumentError('Unsupported DER length encoding');
  }

  var length = 0;
  for (var i = 0; i < lengthBytesCount; i++) {
    length = (length << 8) | bytes[offset + 1 + i];
  }
  return _DerLength(offset + 1 + lengthBytesCount, length);
}

BigInt _unsignedBigIntFromDerInteger(Uint8List bytes) {
  final unsigned = (bytes.isNotEmpty && bytes[0] == 0x00)
      ? Uint8List.sublistView(bytes, 1)
      : bytes;
  return _bytesToBigInt(unsigned);
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

Uint8List _bigIntToFixedLengthBytes(BigInt value, int length) {
  final bytes = Uint8List(length);
  var current = value;
  for (var i = length - 1; i >= 0; i--) {
    bytes[i] = (current & BigInt.from(0xff)).toInt();
    current = current >> 8;
  }
  return bytes;
}

class _RsaPublicKey {
  final BigInt modulus;
  final BigInt exponent;

  _RsaPublicKey(this.modulus, this.exponent);

  int get modulusLength => (modulus.bitLength + 7) >> 3;
}

class _DerObject {
  final int tag;
  final Uint8List value;
  final int endOffset;

  _DerObject(this.tag, this.value, this.endOffset);
}

class _DerLength {
  final int valueStart;
  final int length;

  _DerLength(this.valueStart, this.length);
}
