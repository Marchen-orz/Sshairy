// Drawn interface panels shared by the landing page, README spreads and film. They are illustrations in the
// app's shipped colors, not screenshots: every host, path and log line is fictional (RFC 5737 / example.com).
(() => {
  const P = {
    server: '<rect x="4" y="5" width="16" height="6" rx="1.5"/><rect x="4" y="13" width="16" height="6" rx="1.5"/><path d="M7.5 8h2M7.5 16h2"/>',
    files: '<path d="M8 7V5.5A1.5 1.5 0 0 1 9.5 4h3l2 2h4A1.5 1.5 0 0 1 20 7.5v7a1.5 1.5 0 0 1-1.5 1.5H17"/><rect x="4" y="8" width="13" height="11" rx="1.5"/>',
    spark: '<path d="M10 4l1.7 4.3L16 10l-4.3 1.7L10 16l-1.7-4.3L4 10l4.3-1.7zM18 14l.8 2.2L21 17l-2.2.8L18 20l-.8-2.2L15 17l2.2-.8z"/>',
    key: '<circle cx="8" cy="12" r="3.5"/><path d="M11.5 12H20M17 12v3M14.5 12v2"/>',
    net: '<rect x="9.5" y="4" width="5" height="4.5" rx="1"/><rect x="4" y="15.5" width="5" height="4.5" rx="1"/><rect x="15" y="15.5" width="5" height="4.5" rx="1"/><path d="M12 8.5V12M6.5 15.5V12h11v3.5"/>',
    route: '<circle cx="6.5" cy="6.5" r="2"/><circle cx="17.5" cy="17.5" r="2"/><path d="M6.5 8.5v6a3 3 0 0 0 3 3h0a3 3 0 0 0 3-3v-5a3 3 0 0 1 3-3h0a3 3 0 0 1 2 .8"/>',
    code: '<path d="M9 8l-4 4 4 4M15 8l4 4-4 4"/>',
    shield: '<path d="M12 4l7 2.5v5c0 4.2-2.9 7.3-7 8.5-4.1-1.2-7-4.3-7-8.5v-5z"/><path d="M9 12l2.2 2.2L15 10.5"/>',
    log: '<path d="M7 4h10v16H7zM10 8h4M10 11.5h4M10 15h2.5M4.5 17.5H7"/>',
    more: '<path d="M7 7l5 5-5 5M13 7l5 5-5 5"/>',
    search: '<circle cx="10.5" cy="10.5" r="5.5"/><path d="M15 15l5 5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>',
    folder: '<path d="M4 7.5A1.5 1.5 0 0 1 5.5 6h4l2 2h7A1.5 1.5 0 0 1 20 9.5v8a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z"/>',
    file: '<path d="M7 4h7l4 4v12H7zM14 4v4h4"/>',
    pin: '<path d="M9 4h6l-1 6 3 3H7l3-3zM12 13v7"/>',
    ok: '<circle cx="12" cy="12" r="8"/><path d="M8.5 12.2l2.4 2.4 4.6-4.9"/>',
    right: '<path d="M9 6l6 6-6 6"/>',
    dots: '<path d="M6 12h.01M12 12h.01M18 12h.01"/>',
    term: '<rect x="3.5" y="5" width="17" height="14" rx="2"/><path d="M7.5 10l3 2.5-3 2.5M13 15h3.5"/>',
    history: '<path d="M4.5 12a7.5 7.5 0 1 0 2.3-5.4M4.5 5v3.5H8M12 8v4.5l3 1.8"/>',
    chat: '<path d="M5 5h14v11H10l-5 4z"/><path d="M12 8v5M9.5 10.5h5"/>',
    tune: '<path d="M4 7h9M17 7h3M4 12h3M11 12h9M4 17h10M18 17h2"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="16" cy="17" r="2"/>',
    clip: '<path d="M16 8.5l-6 6a2 2 0 0 0 2.8 2.8l6.2-6.2a4 4 0 0 0-5.7-5.7L7 11.700a5.500 5.500 0 0 0 7.800 7.800L19 15"/>',
    up: '<path d="M12 19V5M6 11l6-6 6 6"/>',
    down: '<path d="M12 5v14M6 13l6 6 6-6"/>',
    swap: '<path d="M8 5v14M5 8l3-3 3 3M16 19V5M13 16l3 3 3-3"/>',
    list: '<path d="M5 7h14M5 12h14M5 17h14"/>',
    panel: '<rect x="4" y="5" width="16" height="14" rx="2"/><path d="M14 5v14"/>',
    min: '<path d="M6 12h12"/>',
    max: '<rect x="6.5" y="6.5" width="11" height="11" rx="1"/>',
    refresh: '<path d="M19 12a7 7 0 1 1-2.2-5.100M19 5v4h-4"/>',
    arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  };
  const cog = Array.from({ length: 16 }, (_, i) => {
    const r = i % 2 ? 6.4 : 8.6, a = (i * Math.PI) / 8 + Math.PI / 16;
    return `${(12 + r * Math.sin(a)).toFixed(1)} ${(12 - r * Math.cos(a)).toFixed(1)}`;
  }).join('L');
  P.gear = `<path d="M${cog}Z"/><circle cx="12" cy="12" r="2.7"/>`;
  const I = (name, size = 18) =>
    `<svg class="sa-i" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${P[name]}</svg>`;

  const T = {
    en: {
      search: 'Search hosts or user@host', newHost: 'New host', all: 'All', goal: 'Describe what you want to check or do…',
      ask: 'Why does /api/reports return 502?', diag: 'Collect diagnostics', exec: 'Execute command',
      found: 'The <code>reports-api</code> container was stopped by the kernel after reaching its 256 MiB memory limit. Restarting it brings the endpoint back.',
      approve: 'Approve action', once: 'Approve once', reject: 'Reject', timeout: '30 s',
      hint: 'Let Airy perform this action and use its bounded result for this turn.',
      done: 'Restarted. <code>/api/reports</code> answers 200 again.',
      next: ['Memory limit is still 256 MiB', 'The weekly report peaks near 240 MiB'],
      confirm: 'Confirm', name: 'Name', size: 'Size', modified: 'Modified', transfers: 'Transfers',
      cpu: 'CPU', memory: 'Memory', disks: 'Disks', network: 'Network', processes: 'Processes', load: 'Load', cores: '4 cores',
      palette: 'Hosts, sessions, actions', pal: ['Split pane right', 'Open settings', 'Toggle Agent panel'],
      inline: 'find the 5 largest files under /var/log', fill: 'Insert', regen: 'Regenerate',
      cmp: [['restart', 'Restart one or more units'], ['reload', 'Reload one or more units'], ['status', 'Show runtime status'], ['enable', 'Enable one or more unit files']],
      ai: 'restart reports-api', fwd: ['Local', 'Remote', 'Dynamic'], running: 'Running', stopped: 'Stopped',
    },
    zh: {
      search: '搜索主机或 user@host', newHost: '新建主机', all: '全部', goal: '描述你想检查或处理的问题…',
      ask: '/api/reports 为什么返回 502？', diag: '收集诊断', exec: '执行命令',
      found: '<code>reports-api</code> 容器达到 256 MiB 内存上限后被内核终止。重启它即可恢复这个接口。',
      approve: '确认操作', once: '仅批准此次', reject: '拒绝', timeout: '30 秒',
      hint: '允许 Airy 执行此操作，并在本轮使用其有界结果。',
      done: '已重启，<code>/api/reports</code> 恢复返回 200。',
      next: ['内存上限仍为 256 MiB', '周报生成时峰值接近 240 MiB'],
      confirm: '确认', name: '名称', size: '大小', modified: '修改时间', transfers: '传输',
      cpu: 'CPU', memory: '内存', disks: '磁盘', network: '网络', processes: '进程', load: '负载', cores: '4 核',
      palette: '主机、会话、操作', pal: ['向右分屏', '打开设置', '开合 Agent 侧栏'],
      inline: '找出 /var/log 下最大的 5 个文件', fill: '填入', regen: '重新生成',
      cmp: [['restart', '重启一个或多个单元'], ['reload', '重新加载一个或多个单元'], ['status', '显示运行状态'], ['enable', '启用一个或多个单元文件']],
      ai: 'restart reports-api', fwd: ['本地', '远程', '动态'], running: '运行中', stopped: '已停止',
    },
  };

  const HOSTS = [
    ['db-primary', 'postgres@192.0.2.21', 1], ['web-01', 'deploy@192.0.2.11', 1], ['bastion', 'ops@bastion.example.com:2222'],
    ['ci-runner', 'runner@198.51.100.7'], ['db-replica', 'postgres@192.0.2.22'], ['gpu-box', 'ml@203.0.113.40'],
    ['raspberry-pi', 'pi@203.0.113.52'], ['staging', 'ubuntu@staging.example.com'], ['web-02', 'deploy@192.0.2.12'],
  ];
  const GROUPS = [['Lab', 3], ['Production', 4], ['Staging', 2]];

  // Terminal text: {n|text} colors with ANSI n, {b|text} is bold.
  const line = (text) =>
    text.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c])
      .replace(/\{(\w+)\|([^}]*)\}/g, (_, k, body) => (k === 'cur' ? '<i class="sa-cur"></i>' : k === 'ai' ? `<i class="sa-aibtn">${I('spark', 12)}</i>` : `<span class="a${k}">${body}</span>`));
  const prompt = (user, host, dir = '~') => `{2|${user}@${host}}:{4|${dir}}$ `;
  const CUR = '{cur|}';
  const term = (lines, tail = '') => `<div class="sa-term">${lines.map((l) => `<div>${line(l)}</div>`).join('')}${tail}</div>`;
  const web = prompt('deploy', 'web-01');
  const db = prompt('postgres', 'db-primary');
  const SESSIONS = {
    status: [
      web + 'systemctl status nginx',
      '{2|●} nginx.service - A high performance web server and a reverse proxy',
      '     Loaded: loaded (/lib/systemd/system/nginx.service; {2|enabled})',
      '     Active: {2|active (running)} since Mon 2026-11-09 08:14:02 UTC; 4 days ago',
      '   Main PID: 812 (nginx)',
      '      Tasks: 5 (limit: 4613)',
      '     Memory: 18.4M',
      '',
      web + 'curl -s -o /dev/null -w "%{http_code}" localhost/api/reports',
      '{1|502}',
      web + 'git -C /var/www/app log --oneline -4',
      '{3|9f3c2ab} Cache the weekly report query',
      '{3|41d07e5} Add /api/health',
      '{3|c8b61f0} Bump nginx worker connections',
      '{3|2a94d13} Rotate access logs daily',
    ],
    logs: [
      web + 'tail -f /var/log/nginx/access.log',
      '{8|13:42:07} {2|200} GET  /api/health          {8|2 ms}',
      '{8|13:42:09} {2|200} GET  /assets/app.9f3c.js  {8|4 ms}',
      '{8|13:42:11} {3|304} GET  /                    {8|1 ms}',
      '{8|13:42:12} {2|201} POST /api/orders          {8|38 ms}',
      '{8|13:42:15} {1|502} GET  /api/reports/weekly  {8|3001 ms}',
      '{8|13:42:16} {2|200} GET  /api/health          {8|2 ms}',
      '{8|13:42:19} {2|200} GET  /api/orders/1842     {8|11 ms}',
    ],
    docker: [
      db + 'docker ps',
      '{b|NAMES        IMAGE              STATUS}',
      'postgres     postgres:17        {2|Up 4 days (healthy)}',
      'pgbouncer    pgbouncer:1.23     {2|Up 4 days}',
      'exporter     pg-exporter:0.15   {3|Up 2 hours}',
      db + 'df -h /var/lib/postgresql',
      'Filesystem      Size  Used Avail Use%',
      '/dev/nvme0n1p2  196G  121G   66G  {3|65%}',
    ],
  };
  const pane = (host, key, o = {}) =>
    `<div class="sa-pane${o.focus ? ' focus' : ''}" style="${o.area ? `grid-area:${o.area}` : ''}">${o.bare ? '' : `<div class="sa-ph"><i></i><b>${host}</b></div>`}${term(
      SESSIONS[key].concat(o.extra || []), o.tail || '')}</div>`;

  const q = (icon, name, pct, note, ok) => `<div class="sa-q">${I(icon, 15)}<span>${name}</span><u><i style="width:${pct}%"></i></u><small class="${ok ? 'ok' : ''}">${note}</small></div>`;
  const S = {
    hosts(lang, o = {}) {
      const t = T[lang];
      const cards = HOSTS.slice(0, o.count || 9)
        .map(([name, at, pinned], i) => `<div class="sa-card${o.on === i ? ' on' : ''}"><span>${I('server', 17)}</span><div><strong>${name}${pinned ? I('pin', 12) : ''}</strong><small>${at}</small></div></div>`)
        .join('');
      const chips = GROUPS.map(([name, n]) => `<div class="sa-chip">${I('folder', 14)}${name}<em>${n}</em></div>`).join('');
      return `<div class="sa-hosts" style="--cols:${o.cols || 4}"><div class="sa-search"><div class="sa-field">${I('search', 16)}${t.search}</div><span class="ib">${I('list')}</span><span class="ib">${I('tune')}</span><div class="sa-btn">${I('plus', 16)}${t.newHost}</div></div><div class="sa-chips"><div class="sa-chip on">${t.all}<em>9</em></div>${chips}</div><div class="sa-cards">${cards}</div>${o.mascot === false ? '' : `<img class="sa-water" data-pose="${o.pose || 'speed'}" alt="">`}</div>`;
    },
    terminal(lang, o = {}) {
      if (o.single) return `<div class="sa-split">${pane('web-01', 'status', { bare: 1, extra: [web + (o.typed || '') + CUR + (o.ai ? '{ai|}' : '')], tail: o.tail || '' })}</div>`;
      return `<div class="sa-split" style="grid-template:'a b' 1.25fr 'a c' 1fr / 1.15fr 1fr">${pane('web-01', 'status', { focus: 1, area: 'a', extra: [web + CUR], tail: o.tail || '' })}${pane('web-01', 'logs', { area: 'b' })}${pane('db-primary', 'docker', { area: 'c' })}</div>`;
    },
    airy(lang, o = {}) {
      const t = T[lang];
      const tool = (label, code, state = 'ok') => `<div class="sa-tool">${I('right', 14)}<span>${label}</span><code>${code || ''}</code><span class="${state}">${I(state === 'ok' ? 'ok' : 'dots', 16)}</span></div>`;
      const steps = [
        `<div class="sa-me">${t.ask}</div>`,
        tool(t.diag),
        tool(t.exec, 'docker logs --tail 40 reports-api'),
        `<div class="sa-say">${t.found}</div>`,
      ];
      if (o.state === 'done')
        steps.push(tool(t.exec, 'docker restart reports-api'), `<div class="sa-say">${t.done}<ul>${t.next.map((n) => `<li>${n}</li>`).join('')}</ul></div>`);
      else if (o.state !== 'idle')
        steps.push(`<div class="sa-ok"><h6>${I('term', 17)}${t.approve}<em>${t.timeout}</em></h6><b>web-01</b><pre>docker restart reports-api</pre><p>${t.hint}</p><footer><div class="sa-btn ghost">${t.reject}</div><div class="sa-btn">${t.once}</div></footer></div>`);
      const shown = o.state === 'idle' ? [] : steps.slice(0, o.steps || steps.length);
      return `<div class="sa-airy" style="${o.width ? `width:${o.width}px` : ''}"><div class="sa-ah">${I('spark', 18)}<strong>Airy</strong><em>web-01</em><span class="ib">${I('history', 16)}</span><span class="ib">${I('chat', 16)}</span><span class="ib">${I('tune', 16)}</span><span class="ib">${I('x', 16)}</span></div><div class="sa-chat">${shown.join('')}</div><div class="sa-compose"><span>${t.goal}</span><div>${I('clip', 15)}${I('spark', 14)}demo-model<span class="sp"></span><i class="sa-ring"></i>6%${I('shield', 15)}${t.confirm}<span class="sa-send idle">${I('up', 15)}</span></div></div></div>`;
    },
    files(lang) {
      const t = T[lang];
      const rows = (list, on) => list.map(([name, size, when, dir], i) => `<div class="sa-fr${dir ? ' dir' : ''}${on === i ? ' on' : ''}"><span>${I(dir ? 'folder' : 'file', 15)}${name}</span><span>${size}</span><span>${when}</span></div>`).join('');
      const side = (host, path, list, on) => `<div class="sa-fp"><div class="sa-fbar">${I('server', 16)}<div class="sa-path"><b>${host}</b><s>${path}</s></div>${I('refresh', 16)}</div><div class="sa-fh"><span>${t.name}</span><span>${t.size}</span><span>${t.modified}</span></div>${rows(list, on)}</div>`;
      const left = [['releases', '', '11-13 09:20', 1], ['shared', '', '11-02 17:41', 1], ['app.9f3c.js', '412 KiB', '11-13 09:18'], ['app.css', '58 KiB', '11-13 09:18'], ['index.html', '3 KiB', '11-13 09:18'], ['nginx.conf', '2 KiB', '11-09 08:12'], ['reports-2026-45.csv', '18.2 MiB', '11-10 00:05'], ['robots.txt', '1 KiB', '10-21 11:30']];
      const right = [['releases', '', '11-12 22:04', 1], ['shared', '', '10-28 10:02', 1], ['app.8e21.js', '409 KiB', '11-12 22:01'], ['app.css', '57 KiB', '11-12 22:01'], ['index.html', '3 KiB', '11-12 22:01'], ['nginx.conf', '2 KiB', '11-05 14:47']];
      return `<div class="sa-col"><div class="sa-files">${side('web-01', '/var/www/app', left, 6)}${side('staging', '/var/www/app', right)}</div>${S.queue(lang)}</div>`;
    },
    monitor(lang, o = {}) {
      const t = T[lang];
      const spark = (points) => `<svg class="spark" viewBox="0 0 120 34" preserveAspectRatio="none"><path d="M0 34 L${points.map((y, i) => `${(i * 120) / (points.length - 1)} ${34 - y * 0.3}`).join(' L')} L120 34Z" fill="currentColor" opacity=".12"/><path d="M${points.map((y, i) => `${(i * 120) / (points.length - 1)} ${34 - y * 0.3}`).join(' L')}" fill="none" stroke="currentColor" stroke-width="1.5" vector-effect="non-scaling-stroke"/></svg>`;
      const box = (title, value, body) => `<div class="sa-box"><h6>${title}<b>${value}</b></h6>${body}</div>`;
      const bar = (pct, warn) => `<div class="sa-bar${warn ? ' warn' : ''}"><i style="width:${pct}%"></i></div>`;
      const procs = [['postgres', '21.4', '11.2'], ['nginx', '6.1', '0.9'], ['node', '4.8', '6.3'], ['dockerd', '1.2', '2.4']];
      return `<div class="sa-mon">${box(t.cpu, '34%', spark([22, 30, 26, 41, 38, 52, 47, 36, 44, 61, 48, 39, 34]) + `<div class="sa-kv"><span>${t.cores}</span><span>${t.load} <b>1.36</b></span></div>`)}${box(t.memory, '5.1 / 7.7 GiB', bar(66))}${box(t.disks, '', `<div class="sa-kv"><span>/</span><b>38%</b></div>${bar(38)}<div class="sa-kv"><span>/var/lib/postgresql</span><b>65%</b></div>${bar(65)}`)}${box(t.network, '', `<div class="sa-kv"><span>↓ <b>2.4 MiB/s</b></span><span>↑ <b>412 KiB/s</b></span></div>` + spark([12, 18, 30, 24, 44, 40, 28, 36, 58, 42, 30, 26, 34]))}${box(t.processes, '', `<div class="sa-proc"><span class="h"></span><span class="h">CPU</span><span class="h">MEM</span>${procs.map((p) => p.map((v) => `<span>${v}</span>`).join('')).join('')}</div>`)}</div>`.replace('class="sa-mon"', `class="sa-mon" data-count="${o.count || 5}"`);
    },
    queue(lang) {
      return `<div class="sa-queue">${q('arrow', 'reports-2026-45.csv', 64, '11.6 / 18.2 MiB')}${q('arrow', 'app.9f3c.js', 100, '412 KiB', 1)}</div>`;
    },
    forwards(lang) {
      const t = T[lang];
      const row = (kind, a, b, on) => `<div class="sa-fw${on ? '' : ' off'}"><span>${I('route', 16)}</span><em>${kind}</em><code>${a}</code>${I('arrow', 15).replace('sa-i', 'sa-i arr')}<code>${b}</code><small><i></i>${on ? t.running : t.stopped}</small></div>`;
      return `<div class="sa-fwd">${row(t.fwd[0], '127.0.0.1:5432', 'db-primary:5432', 1)}${row(t.fwd[1], 'web-01:8080', '127.0.0.1:3000', 1)}${row(t.fwd[2], '127.0.0.1:1080', 'SOCKS5 · bastion', 0)}</div>`;
    },
    palette(lang) {
      const t = T[lang];
      const hosts = HOSTS.slice(1, 3).map(([name, at], i) => `<div class="${i ? '' : 'on'}">${I('server', 16)}${name}<small>${at}</small></div>`).join('');
      const keys = ['Ctrl+D', 'Ctrl+,', 'Ctrl+L'];
      return `<div class="sa-dim"></div><div class="sa-pal"><header>${I('search', 17)}<b>we</b><span>${t.palette}</span></header>${hosts}${t.pal.map((label, i) => `<div>${I(['panel', 'gear', 'spark'][i], 16)}${label}<small><kbd>${keys[i]}</kbd></small></div>`).join('')}</div>`;
    },
    inline(lang, o = {}) {
      const t = T[lang];
      return `<div class="sa-pop sa-inl" style="${o.style || 'left:150px;top:344px'}"><header>${I('spark', 16)}<span>${t.inline}</span>${I('x', 14)}</header><pre>find /var/log -type f -printf '%s %p\\n' | sort -nr | head -5</pre><footer><div class="sa-btn ghost">${t.regen}</div><div class="sa-btn">${t.fill}</div></footer></div>`;
    },
    completion(lang, o = {}) {
      const t = T[lang];
      const rows = t.cmp.map(([word, hint], i) => `<div class="${i ? '' : 'on'}"><b>${word}</b><span>${hint}</span></div>`).join('');
      return `<div class="sa-pop sa-cmp" style="${o.style || 'left:216px;top:338px'}"><div class="ai">${I('spark', 14)}<b>${t.ai}</b></div>${rows}</div>`;
    },
  };

  const RAIL = ['server', 'files', null, 'spark', 'key', 'net', 'route', 'code', 'shield', 'log'];
  // o: { mode, w, h, rail, tabs: [[title, active]], main: html, overlay: html, panels: [icon names shown active] }
  function app(o = {}) {
    const rail = RAIL.map((name) => (name ? `<b class="${name === (o.rail || 'server') ? 'on' : ''}">${I(name)}</b>` : '<hr>')).join('');
    const tabs = (o.tabs || []).map(([title, on]) => `<div class="sa-tab ${on ? 'on' : 'off'}"><i></i>${title}${on ? I('x', 13) : ''}</div>`).join('');
    const tools = (o.panels || []).map((name) => `<span class="ib on">${I(name, 17)}</span>`).join('');
    const size = (o.w ? `width:${o.w}px;` : '') + (o.h ? `height:${o.h}px` : '');
    return `<div class="sa" data-mode="${o.mode || 'light'}" style="${size}"><div class="sa-rail"><img data-mark alt=""> ${rail}<span class="sp"></span><b>${I('more')}</b><b>${I('search')}</b><b>${I('gear')}</b></div><div class="sa-top">${tabs}<span class="ib">${I('plus', 17)}</span><span class="sp"></span>${tools}<span class="ib">${I('swap', 17)}</span><div class="sa-win"><span>${I('min', 15)}</span><span>${I('max', 14)}</span><span>${I('x', 15)}</span></div></div><div class="sa-main">${o.main || ''}${o.overlay || ''}</div></div>`;
  }

  const TABS = [['web-01', 1], ['db-primary', 0]];
  const SCENES = {
    hosts: (lang, o) => app({ ...o, main: S.hosts(lang, o) }),
    terminal: (lang, o) => app({ ...o, rail: 'none', tabs: TABS, main: S.terminal(lang, o) }),
    airy: (lang, o) => app({ ...o, rail: 'spark', tabs: TABS, panels: ['spark'], main: S.terminal(lang, { single: 1 }) + S.airy(lang, o) }),
    files: (lang, o) => app({ ...o, rail: 'files', tabs: TABS, main: S.files(lang) }),
    monitor: (lang, o) => app({ ...o, rail: 'none', tabs: TABS, panels: ['panel'], main: S.monitor(lang) + S.terminal(lang, { single: 1 }) }),
    palette: (lang, o) => app({ ...o, main: S.hosts(lang, o), overlay: S.palette(lang) }),
    inline: (lang, o) => app({ ...o, rail: 'none', tabs: TABS, main: S.terminal(lang, { single: 1, ai: 1, typed: T[lang].inline, tail: S.inline(lang) }) }),
    completion: (lang, o) => app({ ...o, rail: 'none', tabs: TABS, main: S.terminal(lang, { single: 1, typed: 'systemctl ', tail: S.completion(lang) }) }),
    forwards: (lang, o) => app({ ...o, rail: 'route', main: S.forwards(lang) }),
  };

  // Brand images follow the nearest [data-theme]; `base` is the path to site/assets from the page.
  function paint(root, base = 'assets') {
    root.querySelectorAll('img[data-mark],img[data-pose],img[data-brand]').forEach((img) => {
      const theme = img.closest('[data-theme]')?.dataset.theme || 'blue';
      img.src = `${base}/brand/${theme}/${img.dataset.brand || img.dataset.pose || 'mark'}.webp`;
    });
  }

  window.SshairyMock = {
    scene: (name, lang = 'en', o = {}) => SCENES[name](lang, o),
    part: (name, lang = 'en', o = {}) => S[name](lang, o),
    mount(root = document, base = 'assets') {
      root.querySelectorAll('[data-scene]').forEach((el) => {
        const o = el.dataset.opts ? JSON.parse(el.dataset.opts) : {};
        el.innerHTML = SCENES[el.dataset.scene](el.dataset.lang || document.documentElement.lang.slice(0, 2) || 'en', o);
      });
      root.querySelectorAll('[data-part]').forEach((el) => {
        const o = el.dataset.opts ? JSON.parse(el.dataset.opts) : {};
        el.innerHTML = S[el.dataset.part](el.dataset.lang || document.documentElement.lang.slice(0, 2) || 'en', o);
      });
      paint(root, base);
    },
    paint, icon: I, text: T, term, prompt,
  };
})();
