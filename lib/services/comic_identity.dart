import 'dart:io';

import 'package:crypto/crypto.dart';

/// Stable identity of a comic file, used as the key for saved reading
/// progress and for naming its temporary extraction folder.
///
/// The id is `<md5 of the first 64 KB>_<file size in bytes>`, so:
///  * renaming or moving the file keeps the saved position,
///  * re-picking the same comic later (even from a different location or a
///    legacy cache copy) still finds it,
///  * hashing stays cheap even for multi-hundred-MB archives.
/// The id only contains [0-9a-f_], so it is also safe as a folder name.
class ComicIdentity {
  final String id;
  final String title;
  final String sourcePath;

  /// Folder-import group this comic belongs to (one shared id per imported
  /// folder), or null for a comic that was imported on its own. Ungrouped
  /// comics live on the topmost shelf section of the library.
  final String? groupId;

  /// Cleaned display name of the folder the comic was imported with. Always
  /// null when [groupId] is null.
  final String? groupName;

  const ComicIdentity({
    required this.id,
    required this.title,
    required this.sourcePath,
    this.groupId,
    this.groupName,
  });

  /// True when the comic came from a folder import.
  bool get isGrouped => groupId != null && groupId!.isNotEmpty;

  /// Copy with some fields replaced. A null argument keeps the current value
  /// (there is no way to clear a group through this helper, by design: a comic
  /// never leaves its folder shelf except by being removed).
  ComicIdentity copyWith({
    String? id,
    String? title,
    String? sourcePath,
    String? groupId,
    String? groupName,
  }) => ComicIdentity(
    id: id ?? this.id,
    title: title ?? this.title,
    sourcePath: sourcePath ?? this.sourcePath,
    groupId: groupId ?? this.groupId,
    groupName: groupName ?? this.groupName,
  );

  /// True when the comic is read in place through an Android SAF URI.
  bool get isContentUri => sourcePath.startsWith('content://');

  static const int _fingerprintBytes = 64 * 1024;

  /// Identity of a comic behind a `content://` [uri], built from what the
  /// native `statAndHashUri` call returned (MD5 of the first 64 KB and the byte
  /// size). Produces exactly the same `id` and extension-stripped `title` as
  /// [fromFile] would for the same bytes, so reading progress, covers and
  /// index caches stay compatible with comics imported the old way.
  factory ComicIdentity.fromUri({
    required String uri,
    required String fileName,
    required int fileSize,
    required String md5Prefix,
  }) => ComicIdentity(
    id: '${md5Prefix.toLowerCase()}_$fileSize',
    title: _titleOf(fileName),
    sourcePath: uri,
  );

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
