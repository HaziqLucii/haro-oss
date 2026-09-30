import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/first_run/first_run_page.dart';
import 'features/triage/triage_page.dart';
import 'features/workspace/workspace_page.dart';
import 'shell/shell_host.dart';
import 'theme/haro_theme.dart';
import 'theme/tokens.dart';

CustomTransitionPage<void> _fadePage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: HaroTokens.fade,
      reverseTransitionDuration: HaroTokens.fade,
      transitionsBuilder: (context, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: HaroTokens.curve),
        child: child,
      ),
    );

GoRouter buildRouter({String initialLocation = '/'}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    ShellRoute(
      builder: (context, state, child) => ShellHost(state: state, child: child),
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) => _fadePage(state, const TriagePage()),
        ),
        GoRoute(
          path: '/first-run',
          pageBuilder: (context, state) => _fadePage(
            state,
            FirstRunPage(
              key: ValueKey(
                'first-run-${state.uri.queryParameters['project']}',
              ),
              projectId: state.uri.queryParameters['project'],
            ),
          ),
        ),
        GoRoute(
          path: '/w/:id/:step',
          pageBuilder: (context, state) => _fadePage(
            state,
            WorkspacePage(
              // go_router keys pages by route pattern, so without this a sidebar switch
              // reuses A's page state (armed Archive, half-typed rename, dev log) for B.
              key: ValueKey('workspace-${state.pathParameters['id']}'),
              workspaceId: state.pathParameters['id']!,
              step: state.pathParameters['step'],
            ),
          ),
        ),
      ],
    ),
  ],
);

class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HaroText.mono(color: HaroTokens.ink42),
    ),
  );
}
