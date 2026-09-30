import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/new_workspace/creation_commands.dart';
import 'package:haro_app/shortcuts/app_commands.dart';

import '../creation_harness.dart';

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => registerCreationCommands(ref, () => context),
    );
  }

  @override
  Widget build(BuildContext context) => const Text('host');
}

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('registers the three commands on the app command bus', (
    tester,
  ) async {
    final b = MockBackend({
      'GET /projects/p2/branches': (_) => jsonRes({
        'branches': ['origin/trunk'],
        'default': 'origin/trunk',
      }),
      'GET /projects/p1/todo': (_) => jsonRes({'files': [], 'orphaned': []}),
      'GET /fs': (_) => jsonRes({
        'root': '/r',
        'path': '/r',
        'parent': null,
        'is_git_repo': false,
        'entries': [],
      }),
    });
    final h = await pumpCreation(
      tester,
      backend: b,
      open: (c) => showDialog<void>(context: c, builder: (_) => const _Host()),
    );
    final commands = h.container.read(appCommandsProvider);

    commands.openNewWorkspace('p2');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('nw-project')),
        matching: find.text('sandbox'),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    commands.openAddProject();
    await tester.pumpAndSettle();
    expect(find.text('Add a project'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    commands.openBacklog();
    await tester.pumpAndSettle();
    expect(find.text('Backlog'), findsOneWidget);
  });
}
