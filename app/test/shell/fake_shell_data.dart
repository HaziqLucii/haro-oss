import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/shell/shell_models.dart';

/// Sample data copied from the prototype, for shell widget tests.
const fakeShellData = ShellData(
  triageCount: 10,
  backlogOpen: 52,
  needYouCount: 3,
  projects: [
    SidebarProject(
      id: 'haro',
      name: 'haro',
      workspaces: [
        SidebarWorkspace(
          id: 'linux-attraction',
          name: 'linux attraction',
          state: DisplayState.plan,
        ),
        SidebarWorkspace(
          id: 'electron-optimization',
          name: 'electron optimization',
          state: DisplayState.green,
        ),
        SidebarWorkspace(
          id: 'mutation-gate',
          name: 'mutation gate',
          state: DisplayState.gate,
        ),
        SidebarWorkspace(
          id: 'verified-hunks',
          name: 'verified hunks',
          state: DisplayState.green,
        ),
        SidebarWorkspace(
          id: 'jev-research',
          name: 'jev-research',
          state: DisplayState.idle,
        ),
        SidebarWorkspace(
          id: 'kuro-theme',
          name: 'kuro theme',
          state: DisplayState.merged,
        ),
        SidebarWorkspace(
          id: 'live-gate',
          name: 'live gate',
          state: DisplayState.merged,
        ),
      ],
    ),
    SidebarProject(
      id: 'gate-sandbox',
      name: 'gate-sandbox',
      workspaces: [
        SidebarWorkspace(
          id: 'free-shipping-threshold',
          name: 'free shipping threshold',
          state: DisplayState.red,
        ),
        SidebarWorkspace(
          id: 'shipping-cost-calculator',
          name: 'shipping cost calculator',
          state: DisplayState.agent,
        ),
        SidebarWorkspace(
          id: 'agent-haro',
          name: 'agent-haro',
          state: DisplayState.idle,
        ),
      ],
    ),
  ],
);
