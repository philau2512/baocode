import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/file_service.dart';

void main() {
  group('ideCompareFileNames', () {
    test('sorts numeric prefixes in natural order (09 -> 10 -> 100)', () {
      final names = [
        'V2_100__Increase_cost_name_length.sql',
        'V2_09__Update_Table_Quotation.sql',
        'V2_10__Add_Column_Status.sql',
        'V2_11__Add_Index.sql',
        'V2_99__Fix_Typos.sql',
      ];

      names.sort(ideCompareFileNames);

      expect(names, [
        'V2_09__Update_Table_Quotation.sql',
        'V2_10__Add_Column_Status.sql',
        'V2_11__Add_Index.sql',
        'V2_99__Fix_Typos.sql',
        'V2_100__Increase_cost_name_length.sql',
      ]);
    });

    test('sorts file numbers by value (file2 before file10)', () {
      final names = ['file10.txt', 'file2.txt', 'file1.txt', 'file20.txt'];
      names.sort(ideCompareFileNames);
      expect(names, ['file1.txt', 'file2.txt', 'file10.txt', 'file20.txt']);
    });

    test('handles leading zeros gracefully', () {
      final names = ['item1.txt', 'item01.txt', 'item02.txt', 'item2.txt'];
      names.sort(ideCompareFileNames);
      expect(names, ['item1.txt', 'item01.txt', 'item2.txt', 'item02.txt']);
    });

    test('handles very large numbers exceeding 64-bit int', () {
      final names = [
        'data_1000000000000000000000000000.txt',
        'data_999999999999999999999999999.txt',
        'data_1.txt',
      ];
      names.sort(ideCompareFileNames);
      expect(names, [
        'data_1.txt',
        'data_999999999999999999999999999.txt',
        'data_1000000000000000000000000000.txt',
      ]);
    });

    test('case-insensitive comparison with case preservation as tie-breaker', () {
      expect(ideCompareFileNames('a.txt', 'B.txt') < 0, isTrue);
      expect(ideCompareFileNames('A.txt', 'b.txt') < 0, isTrue);
      // When names differ only by case
      expect(ideCompareFileNames('file.txt', 'FILE.txt') != 0, isTrue);
    });
  });

  group('ideCompareFiles', () {
    test('places folders before files, then sorts naturally', () {
      final files = [
        const IdeFile('/path/file100.txt', 'file100.txt', isDirectory: false),
        const IdeFile('/path/folder2', 'folder2', isDirectory: true),
        const IdeFile('/path/file10.txt', 'file10.txt', isDirectory: false),
        const IdeFile('/path/folder10', 'folder10', isDirectory: true),
        const IdeFile('/path/file09.txt', 'file09.txt', isDirectory: false),
      ];

      files.sort(ideCompareFiles);

      expect(files.map((f) => f.name).toList(), [
        'folder2',
        'folder10',
        'file09.txt',
        'file10.txt',
        'file100.txt',
      ]);
    });
  });
}
