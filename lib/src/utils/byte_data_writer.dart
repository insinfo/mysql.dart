import 'dart:typed_data';

// Adapted from the BSD-licensed `buffer` package ByteDataWriter/BytesBuffer
// implementation to keep the runtime dependency surface local to this package.
final ByteData _emptyByteData = ByteData(0);

class BytesBuffer {
  final List<Uint8List> _chunks = <Uint8List>[];
  final bool _copy;
  int _length = 0;

  BytesBuffer({bool copy = false}) : _copy = copy;

  int get length => _length;

  void add(List<int> bytes, {bool? copy}) {
    _chunks.add(_castBytes(bytes, copy: copy ?? _copy));
    _length += bytes.length;
  }

  Uint8List toBytes({bool? copy}) {
    if (_chunks.length == 1 && !(copy ?? _copy)) {
      return _chunks.single;
    }

    final list = Uint8List(_length);
    var offset = 0;
    for (final chunk in _chunks) {
      list.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return list;
  }
}

class ByteDataWriter {
  int bufferLength;
  final Endian endian;
  BytesBuffer? _bytesBuffer;
  ByteData _data = _emptyByteData;
  int _offset = 0;

  ByteDataWriter({this.bufferLength = 128, this.endian = Endian.big});

  void _flush() {
    if (_data == _emptyByteData) {
      return;
    }

    if (_offset > 0) {
      _bytesBuffer ??= BytesBuffer();
      _bytesBuffer!.add(_data.buffer.asUint8List(0, _offset));
    }

    _data = _emptyByteData;
    _offset = 0;
  }

  void _init(int required) {
    if (_data == _emptyByteData || _offset + required > _data.lengthInBytes) {
      _flush();
      _data = ByteData(bufferLength > required ? bufferLength : required);
    }
  }

  void write(List<int> bytes, {bool copy = false}) {
    _flush();
    _bytesBuffer ??= BytesBuffer();
    _bytesBuffer!.add(bytes, copy: copy);
  }

  void writeFloat32(double value, [Endian? endian]) {
    _init(4);
    _data.setFloat32(_offset, value, endian ?? this.endian);
    _offset += 4;
  }

  void writeFloat64(double value, [Endian? endian]) {
    _init(8);
    _data.setFloat64(_offset, value, endian ?? this.endian);
    _offset += 8;
  }

  void writeInt8(int value) {
    _init(1);
    _data.setInt8(_offset, value);
    _offset += 1;
  }

  void writeInt16(int value, [Endian? endian]) {
    _init(2);
    _data.setInt16(_offset, value, endian ?? this.endian);
    _offset += 2;
  }

  void writeInt32(int value, [Endian? endian]) {
    _init(4);
    _data.setInt32(_offset, value, endian ?? this.endian);
    _offset += 4;
  }

  void writeInt64(int value, [Endian? endian]) {
    _init(8);
    _data.setInt64(_offset, value, endian ?? this.endian);
    _offset += 8;
  }

  void writeUint8(int value) {
    _init(1);
    _data.setUint8(_offset, value);
    _offset += 1;
  }

  void writeUint16(int value, [Endian? endian]) {
    _init(2);
    _data.setUint16(_offset, value, endian ?? this.endian);
    _offset += 2;
  }

  void writeUint32(int value, [Endian? endian]) {
    _init(4);
    _data.setUint32(_offset, value, endian ?? this.endian);
    _offset += 4;
  }

  void writeUint64(int value, [Endian? endian]) {
    _init(8);
    _data.setUint64(_offset, value, endian ?? this.endian);
    _offset += 8;
  }

  Uint8List toBytes() {
    if (_bytesBuffer == null) {
      return _data.buffer.asUint8List(0, _offset);
    }

    _flush();
    return _bytesBuffer?.toBytes() ?? _emptyByteData.buffer.asUint8List();
  }
}

Uint8List _castBytes(List<int> bytes, {bool copy = false}) {
  if (bytes is Uint8List) {
    if (!copy) {
      return bytes;
    }

    final list = Uint8List(bytes.length);
    list.setRange(0, list.length, bytes);
    return list;
  }

  return Uint8List.fromList(bytes);
}
