import 'package:flutter/material.dart';

import '../../widgets/agent_loader.dart';
import '../new_workspace/creation_widgets.dart';

/// What a list shows while it is being fetched: the theme's agent loader (the same marker the
/// agent stream uses, drawn per theme) and a short caption. It replaces the rows, so a refetch
/// (a different issue filter, a note search) never shows the previous answer under the new
/// question.
class ListLoading extends StatelessWidget {
  const ListLoading(this.caption, {super.key});

  /// `Loading issues`; shown in caps.
  final String caption;

  @override
  Widget build(BuildContext context) => Semantics(
    label: caption,
    child: Center(
      key: const Key('list-loading'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AgentLoader(size: 22),
            const SizedBox(height: 12),
            MonoCaption(caption),
          ],
        ),
      ),
    ),
  );
}
