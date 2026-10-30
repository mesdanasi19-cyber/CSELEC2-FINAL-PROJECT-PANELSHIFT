import 'dart:io';
import 'dart:typed_data'; // <-- ADD THIS IMPORT
import 'package:archive/archive.dart';

class ComicParserService {
  /// Extracts image files from a .cbz (ZIP) comic archive
  /// Returns a sorted list of file byte arrays representing the comic pages.
  static Future<List<Uint8List>> extractCbzPages(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    // Decode the archive container
    final archive = ZipDecoder().decodeBytes(bytes);

    List<Uint8List> pageImages = [];

    // Filter and sort valid image entries from the comic archive
    final imageFiles = archive.files.where((file) {
      final name = file.name.toLowerCase();
      return (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png')) &&
          !name.startsWith('__macosx') && !name.contains('/.');
    }).toList();

    // Sort alphabetically to maintain correct reading order
    imageFiles.sort((a, b) => a.name.compareTo(b.name));

    for (var file in imageFiles) {
      if (file.isFile) {
        pageImages.add(Uint8List.fromList(file.content as List<int>));
      }
    }

    return pageImages;
  }
}