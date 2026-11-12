/// One model-facing tool and the Capability it dispatches to. Tool descriptions are local, not model text.
class AgentTool {
  const AgentTool(
    this.name,
    this.capability,
    this.description, {
    this.readOnly = false,
    this.hostFields = const [],
    this.approval = true,
  });

  final String name, capability, description;

  /// Interrupted calls of read-only tools restore as interrupted rather than an unknown remote outcome.
  final bool readOnly;

  /// Argument keys carrying HostId values that must be inside the conversation scope.
  final List<String> hostFields;

  /// Whether a non-query action needs local approval in observe/confirm/review modes.
  final bool approval;
}

/// The single catalog behind the model tools, dispatcher IDs, descriptions and restored states.
const agentTools = <AgentTool>[
  AgentTool(
    'host_list',
    'agent.hosts',
    'List all saved host IDs and aliases. Listing grants no operation permission; another host needs local conversation approval before any connection.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'terminal_list',
    'agent.terminals',
    'List open connected terminal sessions, including background tabs and splits, with their tabId and paneId for layout actions. Page through nextOffset; listing contains no commands or results and grants no read permission.',
    readOnly: true,
  ),
  AgentTool(
    'terminal_history_read',
    'agent.terminalHistory',
    'Read known directory, prompt status and recent commands with bounded paired results from one existing terminal. Omit sessionId for the current window frozen when the user sent the message. Every other window needs explicit local approval in all modes. Does not connect or execute.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'terminal_screen_read',
    'agent.terminalScreen',
    'Read the visible text of one terminal, at most 200 lines and 32 KiB. Omit sessionId for the current window. Always needs explicit local approval; it never reads scrollback and does not connect or execute.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'diagnostics_collect',
    'agent.diagnose',
    'Collect a fixed Linux system, storage, process, listening-port or service-state template. Local read approval includes use of its bounded whitelisted result.',
    readOnly: true,
    approval: false,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'command_execute',
    'agent.execute',
    'Propose one exact remote POSIX command under the locally selected permission mode. Approval includes use of its bounded output.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'output_read',
    'agent.output',
    'Read only a previously shared bounded output projection by its evidence handle.',
    readOnly: true,
    approval: false,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'job_start',
    'agent.jobs.start',
    'Start one exact remote POSIX command in the background. Approval matches command_execute; the job ends with this turn.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'job_read',
    'agent.jobs.read',
    'Read new bounded output of one job by jobId and byte offset; use nextOffset to continue.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'job_status',
    'agent.jobs.status',
    'Read one job state, exit code, byte count and truncation.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'job_stop',
    'agent.jobs.stop',
    'Stop one background job. A command already sent may have had effects.',
    approval: false,
  ),
  AgentTool(
    'files_list',
    'file.list',
    'List one remote directory with bounded entries and nextOffset. Remote only; no local filesystem access.',
    readOnly: true,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_stat',
    'file.stat',
    'Read metadata for one remote file or directory. Remote only.',
    readOnly: true,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_read',
    'file.read',
    'Read a bounded UTF-8 page of one remote text file. Use nextOffset to continue; binary and oversized files are refused. Remote only.',
    readOnly: true,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_write',
    'file.write',
    'Write bounded UTF-8 text to one remote file. Creating needs no overwrite; replacing an existing file needs overwrite=true and an atomic-rename target. Remote only.',
    hostFields: ['hostId'],
  ),
  AgentTool('files_mkdir', 'file.mkdir', 'Create one remote directory. Remote only.', hostFields: ['hostId']),
  AgentTool(
    'files_rename',
    'file.rename',
    'Rename one remote path without replacing an existing target. Remote only.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_delete',
    'file.delete',
    'Delete one remote file, link or directory tree. Remote only; there is no undo.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'transfer_list',
    'transfer.list',
    'List current file transfers with state and progress.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'transfer_enqueue',
    'transfer.enqueue',
    'Queue a remote-to-remote copy between two authorized hosts. Local paths are not available to the agent.',
    hostFields: ['fromHostId', 'toHostId'],
  ),
  AgentTool('transfer_cancel', 'transfer.cancel', 'Cancel one queued or running transfer by ID.', approval: false),
  AgentTool(
    'session_open',
    'session.open',
    'Open a terminal tab for one saved host. Trust and authentication still use the normal user flow.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'session_close',
    'session.close',
    'Close the focused pane or one tab. Transport and forwarding leases follow their own owners.',
    approval: true,
  ),
  AgentTool(
    'session_reconnect',
    'session.reconnect',
    'Reconnect the focused pane of a tab, or the active tab. Never replays old input or commands.',
    approval: true,
  ),
  AgentTool(
    'workspace_focus',
    'workspace.focus',
    'Switch to one tab, the host vault or the files page.',
    approval: false,
  ),
  AgentTool(
    'workspace_split',
    'workspace.split',
    'Split one pane horizontally or vertically, duplicating its terminal session. Omit tabId and paneId for the focused pane.',
    approval: false,
  ),
  AgentTool(
    'workspace_rename',
    'workspace.renameTab',
    'Rename one tab, or clear the custom title to show the host name again.',
    approval: true,
  ),
  AgentTool(
    'workspace_close_tabs',
    'workspace.closeTabs',
    'Close tabs left of, right of, or around one tab that stays open.',
    approval: true,
  ),
  AgentTool(
    'settings_get',
    'settings.get',
    'Read the agent-visible application settings and their revision.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'settings_patch',
    'settings.patch',
    'Change agent-visible application settings. Secret, model, shortcut and translation settings stay hidden.',
    approval: true,
  ),
  AgentTool(
    'hosts_create',
    'host.create',
    'Create a saved host from connection fields; secrets are never accepted or returned.',
  ),
  AgentTool(
    'hosts_update',
    'host.update',
    'Update one saved host; omitted fields keep their value and secrets are never accepted or returned.',
    approval: true,
  ),
  AgentTool(
    'hosts_move',
    'host.move',
    'Move saved hosts to a group; creating the group path is allowed.',
    approval: true,
  ),
  AgentTool('hosts_delete', 'host.delete', 'Delete one saved host after checking references. No undo.', approval: true),
  AgentTool(
    'forwards_list',
    'forward.list',
    'List saved forwarding rules and their runtime state.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'forwards_save',
    'forward.save',
    'Create or update one forwarding rule; non-loopback exposure needs confirmExposed.',
    hostFields: ['hostId'],
  ),
  AgentTool('forwards_delete', 'forward.delete', 'Delete one forwarding rule.', approval: true),
  AgentTool(
    'forwards_start',
    'forward.start',
    'Start one forwarding listener. The rule must already exist; hostId must match its saved host.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'forwards_stop',
    'forward.stop',
    'Stop one forwarding listener and close its accepted connections.',
    approval: false,
  ),
];
