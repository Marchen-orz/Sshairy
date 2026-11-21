/// One model-facing tool and the Capability it dispatches to. Tool descriptions are local, not model text.
class AgentTool {
  const AgentTool(
    this.name,
    this.capability,
    this.description, {
    this.readOnly = false,
    this.hostFields = const [],
    this.localFields = const {},
    this.grantFields = const [],
    this.approval = true,
  });

  final String name, capability, description;

  /// Interrupted calls of read-only tools restore as interrupted rather than an unknown remote outcome.
  final bool readOnly;

  /// Argument keys carrying HostId values that must be inside the conversation scope.
  final List<String> hostFields;

  /// A host field that may be replaced by a local grant field naming this computer's end instead.
  final Map<String, String> localFields;

  /// Argument keys carrying local grant IDs that must exist in the conversation.
  final List<String> grantFields;

  /// Whether a non-query action needs local approval in observe/confirm/review modes.
  final bool approval;
}

/// The single catalog behind the model tools, dispatcher IDs, descriptions and restored states.
const agentTools = <AgentTool>[
  AgentTool(
    'host_list',
    'agent.hosts',
    'List saved host IDs and aliases in pages with hosts, total and nextOffset. Continue using offset=nextOffset to see all hosts. Listing grants no operation permission; another host needs local conversation approval before any connection.',
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
    'Propose one exact remote POSIX command under the locally selected permission mode. Include purpose, a short concrete phrase saying what the command checks or changes. Approval includes use of its bounded output.',
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
    'Start one exact remote POSIX command in the background. Include purpose, a short concrete phrase saying what the command checks or changes. Approval matches command_execute; the job ends with this turn.',
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
    'List one remote directory with bounded entries and nextOffset. Requires a saved hostId and an absolute remote POSIX path; there is no local filesystem access.',
    readOnly: true,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_stat',
    'file.stat',
    'Read metadata for one remote file or directory. Requires a saved hostId and an absolute remote POSIX path.',
    readOnly: true,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_read',
    'file.read',
    'Read a bounded UTF-8 page of one remote text file, returning the whole-file sha256 baseline. Requires a saved hostId and an absolute remote POSIX path. Use nextOffset to continue. Binary, malformed-UTF-8, oversized (>256 KiB), sensitive-location and credential-like files are refused; report a refusal and ask the user rather than reading the file through a shell command.',
    readOnly: true,
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_write',
    'file.write',
    'Write bounded UTF-8 text to one remote file. Requires a saved hostId and an absolute remote POSIX path. Creating needs no overwrite; replacing requires overwrite=true and expectedSha256 from files_read (64 lowercase hex characters), rechecked before atomic replacement. A changed baseline returns conflict. The server must support a private temporary file and atomic replace, otherwise the tool refuses; report the refusal instead of writing through a shell command.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_mkdir',
    'file.mkdir',
    'Create one remote directory. Requires a saved hostId and an absolute remote POSIX path.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_rename',
    'file.rename',
    'Rename one remote path without replacing an existing target. Requires a saved hostId and absolute remote POSIX paths.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'files_delete',
    'file.delete',
    'Delete one remote file, link or directory tree. Requires a saved hostId and an absolute remote POSIX path; there is no undo.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'local_request_access',
    'local.requestAccess',
    'Ask the user to choose one local folder or file for this conversation. Give purpose (why it is needed) and kind (directory or file); set write only to download remote files into it. The user picks the actual path; you receive a grantId, never the path. A cancelled request is final for this turn.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'local_list',
    'local.list',
    'List one directory inside a local grant with bounded entries and nextOffset. path is relative to the grant root using "/", empty for the root.',
    readOnly: true,
    approval: false,
    grantFields: ['grantId'],
  ),
  AgentTool(
    'local_stat',
    'local.stat',
    'Read metadata of one path inside a local grant; path is relative to the grant root, empty for the root itself.',
    readOnly: true,
    approval: false,
    grantFields: ['grantId'],
  ),
  AgentTool(
    'local_read',
    'local.read',
    'Read a bounded UTF-8 page of one text file inside a local grant (path relative to the grant root; empty for a file grant). Same limits and refusals as files_read; use nextOffset to continue.',
    readOnly: true,
    approval: false,
    grantFields: ['grantId'],
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
    'Queue a copy between authorized ends. A remote end uses fromHostId/toHostId with absolute POSIX paths; this computer uses fromGrantId/toGrantId with paths relative to that grant. At least one end must be remote; a local target needs a write grant. Use exclude for name patterns such as node_modules, .git or build when uploading a project; credential files are always left out.',
    hostFields: ['fromHostId', 'toHostId'],
    localFields: {'fromHostId': 'fromGrantId', 'toHostId': 'toGrantId'},
    grantFields: ['fromGrantId', 'toGrantId'],
  ),
  AgentTool(
    'transfer_cancel',
    'transfer.cancel',
    'Cancel one queued or running transfer by ID after approving its actual endpoints.',
  ),
  AgentTool(
    'session_open',
    'session.open',
    'Open a terminal tab for one saved host. Trust and authentication still use the normal user flow.',
    hostFields: ['hostId'],
  ),
  AgentTool(
    'session_close',
    'session.close',
    'Close an exact pane using tabId/paneId, or a whole tab using tabId alone; omitting both closes the focused pane. Invalid explicit panes are refused. Transport and forwarding leases follow their own owners.',
    approval: true,
  ),
  AgentTool(
    'session_reconnect',
    'session.reconnect',
    'Reconnect an exact SSH pane using tabId/paneId; omit paneId for the focused pane of the selected or active tab. Never replays old input or commands.',
    approval: true,
  ),
  AgentTool(
    'workspace_focus',
    'workspace.focus',
    'Focus an exact pane using tabId/paneId, switch to one tab, the host vault or the files page. Explicit pane targets must still exist in the specified tab.',
    approval: false,
  ),
  AgentTool(
    'workspace_split',
    'workspace.split',
    'Split one SSH pane horizontally or vertically, opening a fresh authorized remote shell and returning the new tabId/paneId. Omit tabId and paneId for the focused pane. Local shells cannot be duplicated by the agent.',
    approval: true,
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
    'Read agent-visible settings, revision, and localized setting/option labels matching the Settings UI. Match the user wording to these labels and use the returned stable IDs, never guess setting keys.',
    readOnly: true,
    approval: false,
  ),
  AgentTool(
    'settings_patch',
    'settings.patch',
    'First call settings_get to identify the localized setting and stable key. Then pass flat whitelist keys with the returned expectedRevision; do not nest a patch object. Conflicts require reading the latest settings again. Secret, model, shortcut and translation settings stay hidden.',
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
    'Stop one forwarding listener and close its accepted connections after approving the actual saved rule and host.',
    approval: true,
  ),
];
