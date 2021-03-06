// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class InvalidEncodingError {
  final String headers;
  InvalidEncodingError(this.headers);

  @override
  String toString() =>
      'Encoding in supplied headers is not supported.\n\nHeaders:\n$headers';
}

class LspHeaders {
  final String rawHeaders;
  final int contentLength;
  final String? encoding;
  LspHeaders(this.rawHeaders, this.contentLength, this.encoding);
}

/// Transforms a stream of LSP data in the form:
///
///     Content-Length: xxx\r\n
///     Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n
///     \r\n
///     { JSON payload }
///
/// into just the JSON payload, decoded with the specified encoding. Line endings
/// for headers must be \r\n on all platforms as defined in the LSP spec.
class LspPacketTransformer extends StreamTransformerBase<List<int>, String> {
  @override
  Stream<String> bind(Stream<List<int>> stream) {
    late StreamSubscription<int> input;
    late StreamController<String> _output;
    final buffer = <int>[];
    var isParsingHeaders = true;
    LspHeaders? headers;
    _output = StreamController<String>(
      onListen: () {
        input = stream.expand((b) => b).listen(
          (codeUnit) {
            buffer.add(codeUnit);
            if (isParsingHeaders && _endsWithCrLfCrLf(buffer)) {
              headers = _parseHeaders(buffer);
              buffer.clear();
              isParsingHeaders = false;
            } else if (!isParsingHeaders &&
                buffer.length >= headers!.contentLength) {
              // UTF-8 is the default - and only supported - encoding for LSP.
              // The string 'utf8' is valid since it was published in the original spec.
              // Any other encodings should be rejected with an error.
              if ([null, 'utf-8', 'utf8']
                  .contains(headers?.encoding?.toLowerCase())) {
                _output.add(utf8.decode(buffer));
              } else {
                _output.addError(InvalidEncodingError(headers!.rawHeaders));
              }
              buffer.clear();
              isParsingHeaders = true;
            }
          },
          onError: _output.addError,
          onDone: _output.close,
        );
      },
      onPause: () => input.pause(),
      onResume: () => input.resume(),
      onCancel: () => input.cancel(),
    );
    return _output.stream;
  }

  /// Whether [buffer] ends in '\r\n\r\n'.
  static bool _endsWithCrLfCrLf(List<int> buffer) {
    var l = buffer.length;
    return l > 4 &&
        buffer[l - 1] == 10 &&
        buffer[l - 2] == 13 &&
        buffer[l - 3] == 10 &&
        buffer[l - 4] == 13;
  }

  static String? _extractEncoding(String header) {
    final charset = header
        .split(';')
        .map((s) => s.trim().toLowerCase())
        .firstWhere((s) => s.startsWith('charset='), orElse: () => '');

    return charset == '' ? null : charset.split('=')[1];
  }

  /// Decodes [buffer] into a String and returns the 'Content-Length' header value.
  static LspHeaders _parseHeaders(List<int> buffer) {
    // Headers are specified as always ASCII in LSP.
    final asString = ascii.decode(buffer);
    final headers = asString.split('\r\n');
    final lengthHeader =
        headers.firstWhere((h) => h.startsWith('Content-Length'));
    final length = lengthHeader.split(':').last.trim();
    final contentTypeHeader = headers
        .firstWhere((h) => h.startsWith('Content-Type'), orElse: () => '');
    final encoding = _extractEncoding(contentTypeHeader);
    return LspHeaders(asString, int.parse(length), encoding);
  }
}

/// Transforms a stream of [Uint8List]s to [List<int>]s. Used because
/// [ServerSocket] and [Socket] use [Uint8List] but stdin and stdout use
/// [List<int>] and the server needs to operate against both.
class Uint8ListTransformer extends StreamTransformerBase<Uint8List, List<int>> {
  // TODO(dantup): Is there a built-in (or better) way to do this?
  @override
  Stream<List<int>> bind(Stream<Uint8List> stream) {
    late StreamSubscription<Uint8List> input;
    late StreamController<List<int>> _output;
    _output = StreamController<List<int>>(
      onListen: () {
        input = stream.listen(
          (uints) => _output.add(uints),
          onError: _output.addError,
          onDone: _output.close,
        );
      },
      onPause: () => input.pause(),
      onResume: () => input.resume(),
      onCancel: () => input.cancel(),
    );
    return _output.stream;
  }
}
