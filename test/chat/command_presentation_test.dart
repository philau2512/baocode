import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/widgets/command_presentation.dart';
import 'package:baocode/theme/codicons.dart';

void main() {
  test('shows Git icon for Git commands', () {
    expect(commandPresentation('git status').icon, Codicons.gitBranch);
    expect(
      commandPresentation('cd repo && git diff --stat').icon,
      Codicons.gitBranch,
    );
  });

  test('classifies common development commands', () {
    expect(commandPresentation('flutter test').icon, isNot(Codicons.terminal));
    expect(commandPresentation('dart analyze').icon, isNot(Codicons.terminal));
    expect(commandPresentation('npm test').icon, isNot(Codicons.terminal));
    expect(
      commandPresentation('docker compose up').icon,
      isNot(Codicons.terminal),
    );
    expect(commandPresentation('rg TODO lib').icon, Codicons.search);
  });

  test('uses a terminal icon for an unclassified command', () {
    expect(commandPresentation('custom-tool check').icon, Codicons.terminal);
  });
}
