import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agy/agy_output_parser.dart';

void main() {
  test('extracts clickable path results', () {
    final parsed = AgyOutputParser.parse('lib/main.dart:42: match\nno match');
    expect(parsed.results, ['lib/main.dart:42: match']);
  });

  test('extracts inline base64 image', () {
    final parsed = AgyOutputParser.parse(
      'data:image/png;base64,AA==',
    );
    expect(parsed.images, hasLength(1));
    expect(parsed.images.single.mediaType, 'image/png');
  });
}
