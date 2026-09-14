/// =============================================================================
/// PNG WRITER
/// =============================================================================
///
/// Utilitário simples para salvar imagens como PNG.
///
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// Salva uma imagem RGBA como arquivo PNG
class PngWriter {
  /// Salva um buffer RGBA como PNG
  static Future<void> saveRgba(
    String path,
    Uint8List rgbaData,
    int width,
    int height,
  ) async {
    final png = encodeRgba(rgbaData, width, height);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png);
  }

  /// Salva um buffer de alpha (escala de cinza) como PNG
  static Future<void> saveAlpha(
    String path,
    Uint8List alphaData,
    int width,
    int height, [
    int color = 0xFF000000,
  ]) async {
    // Converter alpha para RGBA
    final rgbaData = Uint8List(width * height * 4);
    final r = (color >> 16) & 0xFF;
    final g = (color >> 8) & 0xFF;
    final b = color & 0xFF;

    for (int i = 0; i < width * height; i++) {
      final alpha = alphaData[i];
      rgbaData[i * 4] = r;
      rgbaData[i * 4 + 1] = g;
      rgbaData[i * 4 + 2] = b;
      rgbaData[i * 4 + 3] = alpha;
    }

    await saveRgba(path, rgbaData, width, height);
  }

  /// Salva um buffer ARGB (32-bit integer array) como PNG
  static Future<void> saveArgb(
    String path,
    Uint32List argbData,
    int width,
    int height,
  ) async {
    final rgbaData = Uint8List(width * height * 4);

    for (int i = 0; i < width * height; i++) {
      final pixel = argbData[i];
      rgbaData[i * 4] = (pixel >> 16) & 0xFF; // R
      rgbaData[i * 4 + 1] = (pixel >> 8) & 0xFF; // G
      rgbaData[i * 4 + 2] = pixel & 0xFF; // B
      rgbaData[i * 4 + 3] = (pixel >> 24) & 0xFF; // A
    }

    await saveRgba(path, rgbaData, width, height);
  }

  /// Codifica RGBA para PNG
  static Uint8List encodeRgba(Uint8List rgbaData, int width, int height) {
    // PNG signature
    final signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    // IHDR chunk
    final ihdr = ByteData(13);
    ihdr.setInt32(0, width, Endian.big);
    ihdr.setInt32(4, height, Endian.big);
    ihdr.setInt8(8, 8); // bit depth
    ihdr.setInt8(9, 6); // color type (RGBA)
    ihdr.setInt8(10, 0); // compression method
    ihdr.setInt8(11, 0); // filter method
    ihdr.setInt8(12, 0); // interlace method

    // Preparar dados da imagem com filtro
    final rawData = BytesBuilder();
    for (int y = 0; y < height; y++) {
      rawData.addByte(0); // Filter type: None
      for (int x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        rawData.addByte(rgbaData[i]); // R
        rawData.addByte(rgbaData[i + 1]); // G
        rawData.addByte(rgbaData[i + 2]); // B
        rawData.addByte(rgbaData[i + 3]); // A
      }
    }

    // Comprimir dados usando zlib
    final compressed = ZLibEncoder().encode(rawData.toBytes());

    // Construir PNG
    final output = BytesBuilder();
    output.add(signature);
    output.add(_makeChunk('IHDR', ihdr.buffer.asUint8List()));
    output.add(_makeChunk('IDAT', Uint8List.fromList(compressed)));
    output.add(_makeChunk('IEND', Uint8List(0)));

    return output.toBytes();
  }

  /// Cria um chunk PNG
  static Uint8List _makeChunk(String type, Uint8List data) {
    final typeBytes = type.codeUnits;
    final chunk = BytesBuilder();

    // Length
    final lengthBytes = ByteData(4);
    lengthBytes.setInt32(0, data.length, Endian.big);
    chunk.add(lengthBytes.buffer.asUint8List());

    // Type
    chunk.add(typeBytes);

    // Data
    chunk.add(data);

    // CRC
    final crcData = BytesBuilder();
    crcData.add(typeBytes);
    crcData.add(data);
    final crc = _crc32(crcData.toBytes());
    final crcBytes = ByteData(4);
    crcBytes.setInt32(0, crc, Endian.big);
    chunk.add(crcBytes.buffer.asUint8List());

    return chunk.toBytes();
  }

  /// Calcula CRC32 para PNG
  static int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;

    for (int i = 0; i < data.length; i++) {
      crc ^= data[i];
      for (int j = 0; j < 8; j++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xEDB88320;
        } else {
          crc >>= 1;
        }
      }
    }

    return crc ^ 0xFFFFFFFF;
  }
}
