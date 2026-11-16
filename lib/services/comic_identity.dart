import 'dart:io';

import 'package:crypto/crypto.dart';

/// Stable identity of a comic file, used as the key for saved reading
/// progress and for naming its temporary extraction folder.
///
/// The id is `<md5 of the first 64 KB>_<file size in bytes>`, so:
///  * renaming or moving the file keeps the saved position,
///  * re-picking the same comic later (even from a different cache copy)
///    still finds it,
///  * hashing stays cheap even for multi-hundred-MB archives.
/// The id only contains [0-9a-f_], so it is also safe as a folder name.
class ComicIdentity {
  final String id;
  final String title;
  final String sourcePath;

  const ComicIdentity({
    required this.id,
    required this.title,
    required this.sourcePath,
  });

  static const int _fingerprintBytes = 64 * 1024;

  static Future<ComicIdentity> fromFile(String path) async {
    final file = File(path);
    final int length = await file.length();
    final RandomAccessFile raf = await file.open();
    try {
      final head = await raf.read(
        length < _fingerprintBytes ? length : _fingerprintBytes,
      );
      return ComicIdentity(
        id: '${md5.convert(head)}_$length',
        title: _titleOf(path),
        sourcePath: path,
      );
    } finally {
      await raf.close();
    }
  }

  static String _titleOf(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
