import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

class ComicParserService {
  static Future<List<Uint8List>> extractCbzPages(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    List<Uint8List> pageImages = [];

    final imageFiles = archive.files.where((file) {
      final name = file.name.toLowerCase();
      return (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png')) &&
          !name.startsWith('__macosx') && !name.contains('/.');
    }).toList();

    imageFiles.sort((a, b) => a.name.compareTo(b.name));

    for (var file in imageFiles) {
      if (file.isFile) {
        pageImages.add(Uint8List.fromList(file.content as List<int>));
      }
    }

    return pageImages;
  }
}