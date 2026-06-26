import 'dart:typed_data';

Uint8List sha1Digest(List<int> data) => _Sha1().convert(data);

Uint8List sha256Digest(List<int> data) => _Sha256().convert(data);

abstract class _BlockHash {
  const _BlockHash(this.blockSize, this.outputSize);

  final int blockSize;
  final int outputSize;

  Uint8List convert(List<int> input) {
    final bytes = Uint8List.fromList(input);
    final padded = _pad(bytes);
    final state = initialState();

    for (var offset = 0; offset < padded.length; offset += blockSize) {
      processBlock(
          Uint8List.sublistView(padded, offset, offset + blockSize), state);
    }

    return buildDigest(state);
  }

  Uint8List _pad(Uint8List input) {
    final bitLength = input.length * 8;
    final totalLength =
        ((input.length + 9 + blockSize - 1) ~/ blockSize) * blockSize;
    final padded = Uint8List(totalLength);
    padded.setRange(0, input.length, input);
    padded[input.length] = 0x80;

    final footer = ByteData.sublistView(padded, totalLength - 8);
    footer.setUint32(0, bitLength >> 32, Endian.big);
    footer.setUint32(4, bitLength & 0xffffffff, Endian.big);
    return padded;
  }

  List<int> initialState();

  void processBlock(Uint8List block, List<int> state);

  Uint8List buildDigest(List<int> state) {
    final out = ByteData(outputSize);
    for (var i = 0; i < state.length; i++) {
      out.setUint32(i * 4, state[i] & 0xffffffff, Endian.big);
    }
    return out.buffer.asUint8List();
  }
}

class _Sha1 extends _BlockHash {
  const _Sha1() : super(64, 20);

  @override
  List<int> initialState() => [
        0x67452301,
        0xefcdab89,
        0x98badcfe,
        0x10325476,
        0xc3d2e1f0,
      ];

  @override
  void processBlock(Uint8List block, List<int> state) {
    final words = Uint32List(80);
    final data = ByteData.sublistView(block);
    for (var i = 0; i < 16; i++) {
      words[i] = data.getUint32(i * 4, Endian.big);
    }
    for (var i = 16; i < 80; i++) {
      words[i] = _rotl32(
        words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16],
        1,
      );
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];

    for (var i = 0; i < 80; i++) {
      late int f;
      late int k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }

      final temp = (_rotl32(a, 5) + f + e + k + words[i]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotl32(b, 30);
      b = a;
      a = temp;
    }

    state[0] = (state[0] + a) & 0xffffffff;
    state[1] = (state[1] + b) & 0xffffffff;
    state[2] = (state[2] + c) & 0xffffffff;
    state[3] = (state[3] + d) & 0xffffffff;
    state[4] = (state[4] + e) & 0xffffffff;
  }
}

class _Sha256 extends _BlockHash {
  const _Sha256() : super(64, 32);

  static const List<int> _k = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  @override
  List<int> initialState() => [
        0x6a09e667,
        0xbb67ae85,
        0x3c6ef372,
        0xa54ff53a,
        0x510e527f,
        0x9b05688c,
        0x1f83d9ab,
        0x5be0cd19,
      ];

  @override
  void processBlock(Uint8List block, List<int> state) {
    final words = Uint32List(64);
    final data = ByteData.sublistView(block);
    for (var i = 0; i < 16; i++) {
      words[i] = data.getUint32(i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr32(words[i - 15], 7) ^
          _rotr32(words[i - 15], 18) ^
          (words[i - 15] >> 3);
      final s1 = _rotr32(words[i - 2], 17) ^
          _rotr32(words[i - 2], 19) ^
          (words[i - 2] >> 10);
      words[i] = (words[i - 16] + s0 + words[i - 7] + s1) & 0xffffffff;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final temp1 = (h + s1 + ch + _k[i] + words[i]) & 0xffffffff;
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    state[0] = (state[0] + a) & 0xffffffff;
    state[1] = (state[1] + b) & 0xffffffff;
    state[2] = (state[2] + c) & 0xffffffff;
    state[3] = (state[3] + d) & 0xffffffff;
    state[4] = (state[4] + e) & 0xffffffff;
    state[5] = (state[5] + f) & 0xffffffff;
    state[6] = (state[6] + g) & 0xffffffff;
    state[7] = (state[7] + h) & 0xffffffff;
  }
}

int _rotl32(int value, int shift) =>
    ((value << shift) | (value >> (32 - shift))) & 0xffffffff;

int _rotr32(int value, int shift) =>
    ((value >> shift) | (value << (32 - shift))) & 0xffffffff;
