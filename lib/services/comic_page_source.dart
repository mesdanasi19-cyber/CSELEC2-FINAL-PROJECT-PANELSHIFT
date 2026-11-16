import 'dart:typed_data';

/// Pixel size of a page, read from the image header (no decoding).
class PageDimensions {
  const PageDimensions(this.width, this.height);
  final int width;
  final int height;
}

/// A comic whose pages are read one at a time, on demand.
///
/// The page list (count + reading order) is known as soon as the source is
/// opened; the bytes of a page are only read when [readPage] is called.
abstract class ComicPageSource {
  int get pageCount;

  /// Encoded image bytes (JPEG/PNG) of page [index], in reading order.
  Future<Uint8List> readPage(int index);

  /// Width/height of every page, taken from image headers in a background
  /// isolate. An entry is null when its header could not be parsed.
  Future<List<PageDimensions?>> readAllDimensions();

  /// Releases the worker isolate / file handles. Does NOT delete a CBR cache
  /// folder; that is [ComicCacheService.release].
  Future<void> dispose();
}

/// Keeps every page in memory. Only for callers that already hold the bytes.
class InMemoryPageSource implements ComicPageSource {
  InMemoryPageSource(List<Uint8List> pages) : _pages = pages;

  final List<Uint8List> _pages;

  @override
  int get pageCount => _pages.length;

  @override
  Future<Uint8List> readPage(int index) async => _pages[index];

  @override
  Future<List<PageDimensions?>> readAllDimensions() async =>
      _pages.map(ImageHeaderSniffer.sniff).toList(growable: false);

  @override
  Future<void> dispose() async {}
}

/// Reads width/height from PNG and JPEG headers without decoding pixels.
///
/// Note: the EXIF orientation tag is not applied (comic scans do not use it).
class ImageHeaderSniffer {
  ImageHeaderSniffer._();

  static PageDimensions? sniff(Uint8List b) {
    if (b.length >= 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return _png(b);
    }
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
      return _jpeg(b);
    }
    return null;
  }

  static PageDimensions? _png(Uint8List b) {
    // 8-byte signature, then the IHDR chunk: length(4) 'IHDR'(4) width(4) height(4)
    final int w = _be32(b, 16);
    final int h = _be32(b, 20);
    return (w > 0 && h > 0) ? PageDimensions(w, h) : null;
  }

  static PageDimensions? _jpeg(Uint8List b) {
    final int n = b.length;
    int i = 2;
    while (i + 3 < n) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final int marker = b[i + 1];
      if (marker == 0xFF) {
        i++; // fill byte
        continue;
      }
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2; // standalone markers carry no length
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA)
        return null; // EOI / SOS before any SOF

      final int segmentLength = (b[i + 2] << 8) | b[i + 3];
      final bool isStartOfFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 && // DHT
          marker != 0xC8 && // JPG
          marker != 0xCC; // DAC
      if (isStartOfFrame) {
        if (i + 8 >= n) return null;
        final int h = (b[i + 5] << 8) | b[i + 6];
        final int w = (b[i + 7] << 8) | b[i + 8];
        return (w > 0 && h > 0) ? PageDimensions(w, h) : null;
      }
      if (segmentLength < 2) return null;
      i += 2 + segmentLength;
    }
    return null;
  }

  static int _be32(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
}
