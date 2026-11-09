import 'package:path/path.dart' as p;

class IdeFile {
  const IdeFile(this.path, this.name, {required this.isDirectory});

  final String path;
  final String name;
  final bool isDirectory;
}

/// A save refused because the file changed since it was read or last saved.
class IdeFileConflictException implements Exception {
  const IdeFileConflictException(this.path);

  final String path;

  @override
  String toString() =>
      'The file changed on disk. Reopen it before saving: $path';
}

/// A read of a file that does not exist.
class IdeFileNotFoundException implements Exception {
  const IdeFileNotFoundException(this.path);

  final String path;

  @override
  String toString() => 'File not found: $path';
}

/// A read refused because the file looks binary, or is not UTF-8.
class IdeBinaryFileException implements Exception {
  const IdeBinaryFileException(this.path);

  final String path;

  @override
  String toString() => 'Binary files cannot be edited: $path';
}

/// A read refused because the file is over the editor's size limit.
class IdeFileTooLargeException implements Exception {
  const IdeFileTooLargeException(this.path, this.size);

  final String path;

  /// In bytes.
  final int size;

  @override
  String toString() => 'Files over 5 MB cannot be edited: $path';
}

/// A file or folder the system will not let this user read or change.
class IdeFileAccessDeniedException implements Exception {
  const IdeFileAccessDeniedException(this.path);

  final String path;

  @override
  String toString() => 'Permission denied: $path';
}

/// A file operation's target is taken.
class IdeFileExistsException implements Exception {
  const IdeFileExistsException(this.path);

  final String path;

  @override
  String toString() =>
      'A file or folder ${p.basename(path)} already exists at this location.';
}

/// Directory names never indexed for Quick Open: VCS metadata, dependency
/// caches and build outputs.
const ideIndexExcludedDirectories = <String>{
  '.git',
  '.hg',
  '.svn',
  '.dart_tool',
  '.idea',
  '.gradle',
  '.next',
  '.nuxt',
  '.cache',
  '.venv',
  '.pub-cache',
  '__pycache__',
  'build',
  'node_modules',
  'bower_components',
  'Pods',
  'DerivedData',
  'venv',
};

/// Files under a project root, as found by [listProjectFiles].
class IdeFileListing {
  IdeFileListing(List<String> paths, {this.truncated = false})
    : paths = List.unmodifiable(paths);

  /// Absolute paths joined onto the root as given (symlinks not resolved).
  final List<String> paths;

  /// Whether the listing stopped at its limit.
  final bool truncated;
}

/// A name as [ideCompareFileNames] compares it: its runs of digits and of
/// other characters, lowercased, the digits' values; for sorting many names,
/// each split once.
class IdeFileNameKey implements Comparable<IdeFileNameKey> {
  IdeFileNameKey(this.name) {
    // Its runs of ASCII digits and of anything else (`\d+|\D+`).
    final lower = name.toLowerCase();
    var start = 0;
    while (start < lower.length) {
      final digits = _isDigit(lower.codeUnitAt(start));
      var end = start + 1;
      while (end < lower.length && _isDigit(lower.codeUnitAt(end)) == digits) {
        end++;
      }
      final part = lower.substring(start, end);
      parts.add(part);
      numbers.add(digits ? int.tryParse(part) : null);
      start = end;
    }
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  final String name;
  final List<String> parts = [];
  final List<int?> numbers = [];

  static int _compareDigits(String a, String b, int? numA, int? numB) {
    if (numA != null && numB != null) {
      final order = numA.compareTo(numB);
      if (order != 0) return order;
    } else {
      // If either number overflows 64-bit int, compare by numeric value
      // without leading zeros.
      var startA = 0;
      while (startA < a.length - 1 && a.codeUnitAt(startA) == 0x30) {
        startA++;
      }
      var startB = 0;
      while (startB < b.length - 1 && b.codeUnitAt(startB) == 0x30) {
        startB++;
      }
      final lenA = a.length - startA;
      final lenB = b.length - startB;
      if (lenA != lenB) return lenA < lenB ? -1 : 1;
      for (var i = 0; i < lenA; i++) {
        final diff = a.codeUnitAt(startA + i) - b.codeUnitAt(startB + i);
        if (diff != 0) return diff < 0 ? -1 : 1;
      }
    }
    // If numeric values are equal, fewer leading zeros / shorter length first.
    return a.length.compareTo(b.length);
  }

  @override
  int compareTo(IdeFileNameKey other) {
    for (var i = 0; i < parts.length && i < other.parts.length; i++) {
      final isDigitA =
          numbers[i] != null ||
          (parts[i].isNotEmpty && _isDigit(parts[i].codeUnitAt(0)));
      final isDigitB =
          other.numbers[i] != null ||
          (other.parts[i].isNotEmpty && _isDigit(other.parts[i].codeUnitAt(0)));
      final order = isDigitA && isDigitB
          ? _compareDigits(parts[i], other.parts[i], numbers[i], other.numbers[i])
          : parts[i].compareTo(other.parts[i]);
      if (order != 0) return order;
    }
    final order = parts.length.compareTo(other.parts.length);
    return order != 0 ? order : name.compareTo(other.name);
  }
}

/// `compareFileNames`: case-insensitive, numbers by value (`file2` before
/// `file10`), then by case.
int ideCompareFileNames(String a, String b) =>
    IdeFileNameKey(a).compareTo(IdeFileNameKey(b));

/// Compare two [IdeFile] entries for explorer listing: folders first,
/// then by name using [ideCompareFileNames].
int ideCompareFiles(IdeFile a, IdeFile b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return ideCompareFileNames(a.name, b.name);
}
