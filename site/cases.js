// Live use-case players for cases.html. Every frame is computed directly from time t via seek(t).
(() => {
  const REPO = 'https://github.com/Marchen-orz/sshairy';
  const THEMES = ['blue', 'green', 'violet', 'orange', 'deepSea', 'pink'];
  const M = SshairyMock;
  const T = {
    en: {
      title: 'Use cases · Sshairy',
      nTour: 'Tour', nLink: 'Link', nCases: 'Use cases', nPerf: 'Performance', nDocs: 'Docs', nGet: 'Download',
      heroH: 'Use <span class="k-grad">cases</span>.',
      heroP: 'Five live walkthroughs of Airy and Device Link.',
      foot: 'Lightweight SSH. Powered by AI.', home: 'Home', rel: 'Releases', issues: 'Issues',
      scheme: 'Dark mode', theme: 'Theme', buddy: 'Next theme',
      play: 'Play', pause: 'Pause', replay: 'Replay', scrub: 'Timeline',
      names: ['Ice Blue / Mint', 'Mint Green', 'Violet', 'Sunset Orange', 'Deep Sea Blue', 'Sakura Pink'],
      chips: { task: 'Inline task', fix: 'Fix & complete', link: 'Phone approval', pair: 'Pair & sync', handoff: 'Session handoff' },
      cases: {
        task: ['Ask at the prompt', 'Type what you want at the prompt and click the Airy icon. Airy reads the logs, finds the stopped container and fills in each command; press Enter, or let the rest run automatically.'],
        fix: ['Fix it, finish it', 'A misspelled unit fails and gets a fix icon. One click fills in the corrected command; pause mid-command and ghost text completes the line.'],
        link: ['Approve from your phone', 'Away from your desk, your phone mirrors the desktop terminal. When Airy asks to restart a container, one tap approves it.'],
        pair: ['Scan once, bring your setup', 'Scan the desktop code to pair, then sync hosts, snippets and trusted keys. Saved passwords ask for confirmation on the desktop first.'],
        handoff: ['Desktop to phone, and back', 'Tap a pending desktop tab or long-press a host to open it on the desktop. Commands typed on the phone run on both screens.'],
      },
    },
    zh: {
      title: '使用案例 · Sshairy',
      nTour: '导览', nLink: '互联', nCases: '使用案例', nPerf: '性能', nDocs: '文档', nGet: '下载',
      heroH: '使用<span class="k-grad">案例</span>',
      heroP: '五个实时演示，看 Airy 与手机互联如何配合',
      foot: '轻量 SSH，AI 加持', home: '首页', rel: '发布', issues: '问题反馈',
      scheme: '深色模式', theme: '主题', buddy: '换个主题',
      play: '播放', pause: '暂停', replay: '重播', scrub: '播放进度',
      names: ['冰蓝薄荷', '薄荷绿', '紫罗兰', '落日橙', '深海蓝', '樱花粉'],
      chips: { task: '行内任务', fix: '修复与补全', link: '手机审批', pair: '扫码同步', handoff: '会话接力' },
      cases: {
        task: ['一句话，终端自己查', '在提示符里写下需求，点一下 Airy 图标。Airy 自己翻日志、找到停掉的容器并填好每条命令；逐条回车，或打开自动执行'],
        fix: ['打错了一键修，没打完帮你补', '服务名拼错失败后出现修复图标，一点即可纠正；输入时停顿片刻，AI 灰字把后半句接在光标后，按 → 接受'],
        link: ['不在电脑前，手机上批', '离开工位时，手机实时镜像电脑终端。Airy 请求重启容器，手机弹出审批，一点就批'],
        pair: ['扫一下，配置全带走', '扫码配对电脑，一键同步主机、命令片段与信任密钥；已保存的服务器密码需先在电脑上确认'],
        handoff: ['电脑上的会话，手机接着用', '点开待连接标签或长按主机在电脑上新开标签，电脑负责连接，手机实时镜像并直接输入'],
      },
    },
  };

  const ORDER = [
    { id: 'task', band: '', pose: 'coding-focus', heroAt: 8.8 },
    { id: 'fix', band: 'wash', pose: 'thinking-ai', heroAt: 8.6 },
    { id: 'link', band: '', pose: 'ssh-connected', heroAt: 5.0 },
    { id: 'pair', band: 'mint', pose: 'sftp-transfer', heroAt: 5.1 },
    { id: 'handoff', band: '', pose: 'success', heroAt: 8.5 },
  ];

  const root = document.documentElement;
  const $ = (sel, el = document) => el.querySelector(sel), $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const store = (key, value) => { try { if (value === undefined) return localStorage.getItem(key); localStorage.setItem(key, value); } catch { return null; } };
  const link = (path) => REPO + (!path ? '' : path[0] === '#' ? path : '/' + path);
  let lang = store('lang') || (navigator.language.startsWith('zh') ? 'zh' : 'en');
  let theme = THEMES.includes(store('theme')) ? store('theme') : 'blue';
  const night = matchMedia('(prefers-color-scheme: dark)');
  let scheme = root.dataset.scheme === 'dark' ? 'dark' : 'light';
  root.classList.add('js');
  root.dataset.theme = theme;

  const clamp = (x) => Math.min(1, Math.max(0, x));
  const out = (x) => 1 - (1 - clamp(x)) ** 4;
  const bump = (l, at) => Math.sin(Math.PI * clamp((l - at + 0.08) / 0.24));
  const typed = (s, at, dur, l) => [...s].slice(0, Math.round(clamp((l - at) / dur) * [...s].length)).join('');
  const rows = (lines) => lines.map((l) => `<div>${M.line(l)}</div>`).join('');
  const web = M.prompt('deploy', 'web-01');
  const spin = (l) => `<svg class="spin" width="14" height="14" viewBox="0 0 24 24" style="transform:rotate(${(l * 420) % 360}deg)"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-dasharray="38 100"/></svg>`;
  const tagged = (text, kind = '') => `<em class="sa-tag ${kind}">${text}</em>`;
  const enter = (el, at, l) => {
    const raw = clamp((l - at) / 0.3);
    el.style.display = l >= at ? '' : 'none';
    el.style.opacity = clamp(raw * 2.5);
    el.style.transform = `translateY(${(1 - out(raw)) * 14}px)`;
  };
  const revealChat = (box, times, l) => [...$('.sa-chat', box).children].forEach((step, i) => enter(step, times[i], l));
  const flip = (els, times, l) => els.forEach((el, i) => {
    el.style.display = l >= times[i] && (i + 1 === els.length || l < times[i + 1] + 0.25) ? '' : 'none';
    el.style.opacity = i ? clamp((l - times[i]) / 0.25) : 1;
  });
  const phones = (list) => `<div class="ph">${list.map(([cls, o]) => `<div class="${cls}">${M.part('phone', lang, { ...o, mode: scheme })}</div>`).join('')}</div>`;
  const fmt = (sec) => `0:${String(Math.floor(sec)).padStart(2, '0')}`;

  function createDef(id) {
    const t = M.text[lang];
    if (id === 'task') {
      return {
        len: 14,
        plan: [[3, 3.5], [4, 3.9, 0.45, 5.0], [5, 5.2], [6, 5.25], [7, 5.9], [8, 6.3, 0.45, 7.3], [9, 7.5], [10, 7.55], [11, 8.2],
          [12, 8.6, 0.4, 9.9], [13, 10.1], [14, 10.4, 0.45, 11.0], [15, 11.2], [16, 11.8], [17, 12.1]],
        keys: [{ at: 0, xy: [1720, 940] }, { at: 2.9, sel: '.sa-aibtn', click: 1 }, { at: 4.2, xy: [1500, 920] }, { at: 9.5, sel: '.sa-badge u', click: 1 }, { at: 10.6, xy: [1640, 940] }],
        presses: [[5.0, 'Enter ↵'], [7.3, 'Enter ↵']],
        build(ui) {
          ui.innerHTML = `<div class="win k-win">${M.scene('task', lang, { w: 920, h: 420, mode: scheme })}</div>`;
          this.term = $('.sa-term', ui);
        },
        draw(l) {
          const L = M.taskLines(lang), badge = `{${l >= 9.5 ? 'badgeon' : 'badge'}|${t.auto}}`, shown = [L[0], L[1]];
          if (l < 3) {
            const s = typed(t.task[0], 0.8, 1.6, l);
            shown.push(web + s + M.CUR + ([...s].length >= 6 ? '{ai|}' : ''));
          } else {
            shown.push(L[2]);
            for (const [i, from, fill, enterAt] of this.plan) {
              if (l < from) break;
              shown.push(fill ? web + typed(L[i].slice(web.length), from, fill, l) + (l < enterAt ? M.CUR + badge : '') : L[i]);
            }
          }
          this.term.innerHTML = rows(shown);
        },
      };
    }
    if (id === 'fix') {
      return {
        len: 12,
        keys: [{ at: 0, xy: [1720, 940] }, { at: 3.4, sel: '.sa-aibtn.fix', click: 1 }, { at: 4.5, xy: [1560, 920] }],
        presses: [[2.3, 'Enter ↵'], [5.6, 'Enter ↵'], [9.2, '→'], [10.0, 'Enter ↵']],
        build(ui) {
          ui.innerHTML = `<div class="win k-win">${M.scene('task', lang, { w: 860, h: 400, mode: scheme })}</div>`;
          this.term = $('.sa-term', ui);
          this.pane = $('.sa-pane', ui);
          this.pane.insertAdjacentHTML('beforeend', M.part('completion', lang, { style: 'left:0;top:0' }));
          this.pop = $('.sa-cmp', ui);
        },
        draw(l) {
          const dir = M.prompt('deploy', 'web-01', '/etc/nginx'), part = 'sudo systemctl re';
          const shown = [dir + 'sudo nginx -t', 'nginx: the configuration file /etc/nginx/nginx.conf syntax is ok', 'nginx: configuration file /etc/nginx/nginx.conf test is successful'];
          shown.push(dir + typed('sudo systemctl restart ngnix', 0.6, 1.2, l) + (l < 2.3 ? M.CUR : ''));
          if (l >= 2.45) shown.push('{1|Failed to restart ngnix.service: Unit ngnix.service not found.}');
          if (l >= 2.5 && l < 3.5) shown.push(dir + M.CUR + '{fix|}');
          if (l >= 3.5) shown.push(`{t|${t.fix[0]}}`);
          if (l >= 4.0) shown.push(`{t|${t.fix[1]}}`);
          if (l >= 4.4) shown.push(dir + typed('sudo systemctl restart nginx', 4.4, 0.4, l) + (l < 5.6 ? M.CUR + `{badge|${t.auto}}` : ''));
          if (l >= 6.0) shown.push(`{t|${t.fix[2]}}`);
          if (l >= 6.3) {
            const accepted = l >= 9.2;
            shown.push(dir + (accepted ? part + t.ghost : typed(part, 6.9, 0.8, l)) + (l < 10 ? M.CUR + (!accepted && l >= 8.3 ? `{g|${t.ghost}}` : '') : ''));
          }
          if (l >= 10.2) shown.push(dir + M.CUR);
          this.term.innerHTML = rows(shown);
          const open = l >= 7.85 && l < 9.2;
          this.pop.style.display = open ? '' : 'none';
          if (!open) return;
          const cur = $('.sa-cur', this.term);
          if (!cur) return;
          const p = this.pane.getBoundingClientRect(), c = cur.getBoundingClientRect();
          if (!p.width) return;
          const k = p.width / this.pane.offsetWidth;
          this.pop.style.left = `${(c.left - p.left - 2 * c.width) / k - 10}px`;
          this.pop.style.top = `${(c.bottom - p.top) / k + 6}px`;
        },
      };
    }
    if (id === 'link') {
      return {
        len: 10.5,
        keys: [{ at: 5.6, sel: '.sa-pap.banner .sa-btn:not(.ghost)', tap: 1 }],
        presses: [],
        build(ui) {
          ui.innerHTML = `<div class="win k-win">${M.scene('airy', lang, { w: 760, h: 560, mode: scheme })}</div><div class="ph">${M.part('phone', lang, { screen: 'term', banner: 1, mode: scheme })}</div>`;
          this.ask = $('.sa-airy', ui);
          this.ask.insertAdjacentHTML('afterend', M.part('airy', lang, { state: 'done' }));
          this.done = this.ask.nextElementSibling;
          this.terms = [$('.win .sa-term', ui), $('.ph .sa-term', ui)];
          this.banner = $('.sa-pap.banner', ui);
        },
        draw(l) {
          const lines = l < 1.3 ? M.MIRROR.slice(0, -4).concat(web + typed('free -h', 0.4, 0.5, l) + M.CUR) : M.MIRROR.concat(web + M.CUR);
          this.terms.forEach((el) => (el.innerHTML = rows(lines)));
          const on = l >= 5.9;
          this.ask.style.display = on ? 'none' : '';
          this.done.style.display = on ? '' : 'none';
          revealChat(this.ask, [1.8, 2.4, 2.9, 3.5, 4.1], l);
          revealChat(this.done, [0, 0, 0, 0, 6.2, 6.9], l);
          const inn = out((l - 4.3) / 0.45), gone = out((l - 5.85) / 0.35);
          this.banner.style.transform = `translateY(${(inn - 1 - gone) * 140}%)`;
          this.banner.style.opacity = l < 4.3 ? 0 : 1 - gone;
          $('.sa-btn:not(.ghost)', this.banner).style.transform = `scale(${1 - 0.08 * bump(l, 5.6)})`;
        },
      };
    }
    if (id === 'pair') {
      return {
        len: 10.5,
        keys: [{ at: 0, xy: [900, 920] }, { at: 1.0, sel: '.s-pair .sa-pqr', tap: 1 }, { at: 3.9, sel: '.s-link .sa-pact span', tap: 1 },
          { at: 5.6, sel: '.sa-pw .sa-btn:not(.ghost)', click: 1 }, { at: 7.4, sel: '.s-link .sa-pnav i', tap: 1 }],
        presses: [],
        build(ui) {
          ui.innerHTML = `<div class="win k-win">${M.scene('link', lang, { w: 760, h: 560, mode: scheme })}</div>`
            + phones([['s-pair', { screen: 'pair' }], ['s-scan', { screen: 'scan' }], ['s-link', { screen: 'link', notice: '' }], ['s-hosts', { screen: 'hosts', pill: false }]]);
          this.screens = [...$('.ph', ui).children];
          this.device = $('.sa-lkd', ui);
          this.device.insertAdjacentHTML('beforebegin', `<p class="lkn">${t.noPeers}</p>`);
          this.none = $('.lkn', ui);
          $('.sa-main', ui).insertAdjacentHTML('beforeend', `<div class="sa-dim"></div>${M.part('pwsync', lang)}`);
          this.dim = $('.sa-dim', ui);
          this.dialog = $('.sa-pw', ui);
          this.code = $('.s-scan .qr', ui);
          this.sync = $('.s-link .sa-pact span', ui);
          this.notice = $('.s-link .sa-pnt', ui);
          this.cards = [...ui.querySelectorAll('.s-hosts .sa-pcd')];
        },
        draw(l) {
          flip(this.screens, [0, 1.25, 3.0, 7.6], l);
          const aim = out((l - 1.4) / 0.9);
          this.code.style.opacity = 0.25 + 0.75 * aim;
          this.code.style.filter = `blur(${(1 - aim) * 3}px)`;
          this.code.style.transform = `translate(${(1 - aim) * 46}px,${(1 - aim) * -34}px) rotate(${(1 - aim) * -7}deg) scale(${0.8 + 0.2 * aim})`;
          this.none.style.display = l >= 3.0 ? 'none' : '';
          enter(this.device, 3.0, l);
          this.sync.innerHTML = (l >= 3.95 && l < 4.2 ? spin(l) : M.icon('sync', 16)) + t.sync;
          const done = l >= 5.9;
          this.notice.style.display = l >= 4.2 ? '' : 'none';
          this.notice.innerHTML = `<p>${t.synced}</p><p>${done ? M.icon('key', 14) + t.pwDone : spin(l) + t.pwWait}</p>`;
          const open = out((l - 4.3) / 0.25) * (1 - clamp((l - 5.75) / 0.15));
          this.dim.style.display = this.dialog.style.display = l >= 4.3 && l < 5.9 ? '' : 'none';
          this.dim.style.opacity = this.dialog.style.opacity = open;
          this.dialog.style.transform = `translate(-50%,-50%) scale(${0.94 + 0.06 * open})`;
          $('.sa-btn:not(.ghost)', this.dialog).style.transform = `scale(${1 - 0.08 * bump(l, 5.6)})`;
          this.cards.forEach((card, i) => enter(card, 7.8 + i * 0.12, l));
        },
      };
    }
    return {
      len: 12.5,
      keys: [{ at: 0.9, sel: '.s-link [data-name="db-primary"]', tap: 1 }, { at: 3.0, sel: '.s-db .sa-ptb svg', tap: 1 },
        { at: 4.0, sel: '.s-link2 [data-name="gpu-box"]', tap: 1, hold: 0.55 }, { at: 5.4, sel: '.s-link2 .sa-psheet div', tap: 1 },
        { at: 9.0, sel: '.s-gpu .sa-pdr i:last-child', tap: 1 }],
      presses: [],
      build(ui) {
        ui.innerHTML = `<div class="win k-win">${M.scene('link', lang, { w: 760, h: 560, mode: scheme })}</div>`
          + phones([['s-link', { screen: 'link' }], ['s-db', { screen: 'term', host: 'db-primary' }], ['s-link2', { screen: 'link', sheet: 1 }], ['s-gpu', { screen: 'term', host: 'gpu-box', draft: '' }]]);
        $('.sa-lk', ui).remove();
        const top = $('.sa-top', ui);
        top.querySelectorAll('.sa-tab').forEach((tab) => tab.remove());
        top.insertAdjacentHTML('afterbegin', ['web-01', 'db-primary', 'gpu-box'].map((host) => `<div class="sa-tab"><i></i>${host}${M.icon('x', 13)}</div>`).join(''));
        this.tabs = [...top.querySelectorAll('.sa-tab')];
        this.desk = $('.win .sa-term', ui);
        this.web = this.desk.innerHTML;
        this.screens = [...$('.ph', ui).children];
        ui.querySelectorAll('.sa-prow').forEach((row) => (row.dataset.name = $('b', row).textContent));
        this.ends = ['.s-link [data-name="db-primary"]', '.s-link2 [data-name="db-primary"]', '.s-link2 [data-name="gpu-box"]'].map((sel) => {
          const row = $(sel, ui);
          $('em', row)?.remove();
          row.insertAdjacentHTML('beforeend', '<span class="end"></span>');
          return $('.end', row);
        });
        this.held = $('.s-link2 [data-name="gpu-box"]', ui);
        this.shade = $('.s-link2 .sa-pshade', ui);
        this.sheet = $('.s-link2 .sa-psheet', ui);
        this.mirrors = [$('.s-db .sa-term', ui), $('.s-gpu .sa-term', ui)];
        this.draft = $('.s-gpu .sa-pdr span', ui);
      },
      draw(l) {
        flip(this.screens, [0, 1.9, 3.2, 6.6], l);
        const on = l < 1.6 ? 0 : l < 6.3 ? 1 : 2;
        this.tabs.forEach((tab, i) => {
          tab.className = `sa-tab ${i === on ? 'on' : 'off'}`;
          tab.style.display = i < 2 || l >= 6.3 ? '' : 'none';
        });
        const [pending, mirrored, proxied] = this.ends;
        pending.innerHTML = l >= 0.95 ? spin(l) : tagged(t.pending, 'wait');
        mirrored.innerHTML = tagged(t.mirror);
        proxied.innerHTML = l >= 5.5 ? spin(l) : '';
        this.held.classList.toggle('held', l >= 3.95 && l < 4.75);
        const up = out((l - 4.5) / 0.3) * (1 - clamp((l - 5.5) / 0.25));
        this.shade.style.display = this.sheet.style.display = l >= 4.5 && l < 5.75 ? '' : 'none';
        this.shade.style.opacity = up;
        this.sheet.style.transform = `translateY(${(1 - up) * 100}%)`;
        const login = (at, last) => ['Welcome to Ubuntu 24.04.1 LTS', 'Last login: Mon Nov 23 09:12 from 192.0.2.5', last].filter((_, i) => l >= at + i * 0.12);
        const cmd = 'tail -n 3 train.log', ml = M.prompt('ml', 'gpu-box'), sent = l >= 9.1;
        const db = login(1.6, M.prompt('postgres', 'db-primary') + M.CUR), gpu = login(6.3, ml + (sent ? cmd : M.CUR));
        if (sent) gpu.push(...['{8|epoch 12}  loss 0.412  acc 0.871', '{8|epoch 13}  loss 0.398  acc 0.876', '{8|epoch 14}  loss 0.391  acc 0.879', ml + M.CUR].filter((_, i) => l >= 9.35 + i * 0.1));
        this.desk.innerHTML = on === 2 ? rows(gpu) : on === 1 ? rows(db) : this.web;
        this.mirrors[0].innerHTML = rows(db);
        this.mirrors[1].innerHTML = rows(gpu);
        const draft = l < 9.05 ? typed(cmd, 7.4, 1.1, l) : '';
        this.draft.textContent = draft || t.draft;
        this.draft.className = draft ? 'on' : '';
      },
    };
  }

  // Create the five section shells once; rebuilds only touch the inner mockup and localized labels.
  const list = $('#casesList');
  list.innerHTML = ORDER.map(({ id, band, pose }) => `
    <section class="band case-band${band ? ' ' + band : ''}" id="${id}" data-pose="${pose}">
      <div class="wrap">
        <div class="case-head">
          <h2></h2>
          <p class="lede"></p>
        </div>
        <div class="case-player${still ? ' paused' : ''}" data-case="${id}">
          <div class="case-frame">
            <div class="case-stage">
              <div class="case-ui c-${id}"></div>
              <div class="case-key"></div>
              <svg class="case-ptr" viewBox="0 0 28 28" width="34" height="34" aria-hidden="true"><path d="M5 3l17 10.5-7.6 1.6L11 22z"/></svg>
              <i class="case-tap" aria-hidden="true"></i>
            </div>
          </div>
          <div class="case-bar">
            <button class="case-ctl" type="button" data-act="toggle"><svg class="ic-pause" width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="6" y="4" width="4.5" height="16" rx="1.2"/><rect x="13.5" y="4" width="4.5" height="16" rx="1.2"/></svg><svg class="ic-play" width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7 4.8v14.4a1 1 0 0 0 1.52.85l11.2-7.2a1 1 0 0 0 0-1.7L8.52 3.95A1 1 0 0 0 7 4.8z"/></svg></button>
            <input class="case-scrub" type="range" min="0" max="1000" value="0">
            <span class="case-time"></span>
            <button class="case-ctl" type="button" data-act="replay"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 12a7 7 0 1 1-2.2-5.1M19 5v4h-4"/></svg></button>
          </div>
        </div>
      </div>
    </section>`).join('');

  const players = ORDER.map((meta) => {
    const section = $(`#${meta.id}`);
    const rootEl = $('.case-player', section);
    const frame = $('.case-frame', rootEl);
    const stage = $('.case-stage', rootEl);
    const ui = $('.case-ui', rootEl);
    const keyEl = $('.case-key', rootEl);
    const ptrEl = $('.case-ptr', rootEl);
    const tapEl = $('.case-tap', rootEl);
    const toggleBtn = $('[data-act="toggle"]', rootEl);
    const replayBtn = $('[data-act="replay"]', rootEl);
    const scrub = $('.case-scrub', rootEl);
    const timeEl = $('.case-time', rootEl);

    const inst = {
      ...meta, section, rootEl, frame, stage, ui, keyEl, ptrEl, tapEl, toggleBtn, replayBtn, scrub, timeEl,
      def: null, time: still ? meta.heroAt : 0, paused: still, visible: false,
      fit() {
        const w = frame.clientWidth;
        if (w > 0) stage.style.transform = `scale(${w / 1920})`;
      },
      measure() {
        const s = stage.getBoundingClientRect();
        if (!s.width || !inst.def) return;
        const k = s.width / 1920;
        for (const item of inst.def.keys) {
          if (!item.sel) continue;
          inst.def.draw(item.at - 0.05);
          const el = $(item.sel, ui);
          if (!el) continue;
          const r = el.getBoundingClientRect();
          item.xy = [(r.left + r.width / 2 - s.left) / k, (r.top + r.height / 2 - s.top) / k];
        }
      },
      seek(l) {
        const C = inst.def;
        if (!C) return;
        inst.time = ((l % C.len) + C.len) % C.len;
        C.draw(inst.time);
        const tap = C.keys.find((k) => k.tap && k.xy && inst.time > k.at - 0.08 && inst.time < k.at + (k.hold || 0) + 0.16);
        const touch = !tap ? 0 : tap.hold ? clamp((inst.time - tap.at + 0.08) / 0.1) * clamp((tap.at + tap.hold + 0.16 - inst.time) / 0.12) : bump(inst.time, tap.at);
        tapEl.style.opacity = touch;
        if (tap) tapEl.style.transform = `translate(${tap.xy[0]}px,${tap.xy[1]}px) scale(${0.6 + 0.5 * touch + (tap.hold ? 0.3 * clamp((inst.time - tap.at) / tap.hold) : 0)})`;
        const keys = C.keys.filter((k) => !k.tap && k.xy);
        if (keys.length) {
          let i = 0;
          while (i + 1 < keys.length && inst.time >= keys[i + 1].at - 0.7) i++;
          const k = keys[i], from = keys[Math.max(0, i - 1)], p = i ? out((inst.time - k.at + 0.7) / 0.6) : 1;
          const x = from.xy[0] + (k.xy[0] - from.xy[0]) * p, y = from.xy[1] + (k.xy[1] - from.xy[1]) * p;
          const press = k.click ? bump(inst.time, k.at) : 0;
          ptrEl.style.opacity = 1;
          ptrEl.style.transform = `translate(${x - 6}px,${y - 4}px) scale(${1 - 0.14 * press})`;
        } else {
          ptrEl.style.opacity = 0;
        }
        const hit = C.presses.find(([when]) => inst.time >= when - 0.35 && inst.time < when + 0.5);
        keyEl.style.opacity = hit ? clamp((inst.time - hit[0] + 0.35) / 0.12) * clamp((hit[0] + 0.5 - inst.time) / 0.15) : 0;
        if (hit) {
          keyEl.textContent = hit[1];
          keyEl.style.transform = `translateY(${bump(inst.time, hit[0]) * 4}px) scale(${1 - 0.06 * bump(inst.time, hit[0])})`;
        }
        const pct = (inst.time / C.len) * 100;
        scrub.value = Math.round(pct * 10);
        scrub.style.setProperty('--p', `${pct.toFixed(2)}%`);
        timeEl.textContent = `${fmt(inst.time)} / ${fmt(C.len)}`;
      },
      setPaused(next) {
        inst.paused = next;
        rootEl.classList.toggle('paused', next);
        toggleBtn.setAttribute('aria-label', T[lang][next ? 'play' : 'pause']);
      },
      rebuild() {
        inst.def = createDef(meta.id);
        inst.def.build(ui);
        M.paint(section);
        inst.fit();
        inst.measure();
        inst.seek(inst.time);
      },
    };

    frame.addEventListener('click', () => inst.setPaused(!inst.paused));
    toggleBtn.addEventListener('click', () => inst.setPaused(!inst.paused));
    replayBtn.addEventListener('click', () => { inst.seek(0); inst.setPaused(false); });
    scrub.addEventListener('input', () => {
      if (!inst.def) return;
      inst.seek((+scrub.value / 1000) * inst.def.len);
    });
    return inst;
  });

  function spread(event, from, update) {
    if (still || !document.startViewTransition) return update();
    const box = from.getBoundingClientRect();
    const x = event.detail ? event.clientX : box.left + box.width / 2, y = event.detail ? event.clientY : box.top + box.height / 2;
    const r = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    const shown = () => {
      update();
      const loading = $$('img').filter((img) => !img.complete && img.getBoundingClientRect().bottom > 0 && img.getBoundingClientRect().top < innerHeight);
      return Promise.race([Promise.all(loading.map((img) => img.decode().catch(() => {}))), new Promise((done) => setTimeout(done, 400))]);
    };
    document.startViewTransition(shown).ready.then(() => root.animate(
      { clipPath: [`circle(0 at ${x}px ${y}px)`, `circle(${r}px at ${x}px ${y}px)`] },
      { duration: 680, easing: 'cubic-bezier(.4,0,.2,1)', pseudoElement: '::view-transition-new(root)' },
    )).catch(() => {});
  }

  function setTheme(next) {
    theme = next;
    root.dataset.theme = theme;
    store('theme', theme);
    $$('#dots button').forEach((b) => b.setAttribute('aria-pressed', b.dataset.theme === theme));
    M.paint(document);
  }

  function render() {
    const t = T[lang];
    root.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = t.title;
    $$('[data-i]').forEach((el) => (el.innerHTML = t[el.dataset.i]));
    $('#lang').textContent = lang === 'zh' ? 'EN' : '中文';
    $$('img[data-brand^="wordmark"]').forEach((img) => (img.dataset.brand = scheme === 'dark' ? 'wordmark-dark' : 'wordmark'));
    $('#scheme').setAttribute('aria-label', t.scheme);
    $('#scheme').setAttribute('aria-pressed', scheme === 'dark');
    $('meta[name="theme-color"]').content = scheme === 'dark' ? '#0B0E13' : '#F1F7FF';
    $('#dots').setAttribute('aria-label', t.theme);
    $('#dots').innerHTML = THEMES.map((name, i) => `<button type="button" data-theme="${name}" aria-pressed="${name === theme}" aria-label="${t.names[i]}" title="${t.names[i]}"></button>`).join('');
    $('#buddy').setAttribute('aria-label', t.buddy);
    $('#jump').innerHTML = ORDER.map(({ id }) => `<a href="#${id}">${t.chips[id]}</a>`).join('');
    $$('[data-href]').forEach((a) => (a.href = link(a.dataset.href)));
    players.forEach((p) => {
      const [heading, desc] = t.cases[p.id];
      $('h2', p.section).textContent = heading;
      $('.lede', p.section).textContent = desc;
      p.toggleBtn.setAttribute('aria-label', t[p.paused ? 'play' : 'pause']);
      p.replayBtn.setAttribute('aria-label', t.replay);
      p.scrub.setAttribute('aria-label', t.scrub);
      p.rebuild();
    });
    M.paint(document);
  }

  $('#dots').addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (button && button.dataset.theme !== theme) spread(event, button, () => setTheme(button.dataset.theme));
  });
  $('#lang').onclick = (event) => spread(event, event.currentTarget, () => { lang = lang === 'zh' ? 'en' : 'zh'; store('lang', lang); render(); });
  $('#buddy').onclick = (event) => spread(event, event.currentTarget, () => setTheme(THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length]));
  function setScheme(next) {
    scheme = next;
    root.dataset.scheme = next;
    try { (next === 'dark') === night.matches ? localStorage.removeItem('scheme') : localStorage.setItem('scheme', next); } catch {}
    render();
  }
  $('#scheme').onclick = (event) => spread(event, event.currentTarget, () => setScheme(scheme === 'dark' ? 'light' : 'dark'));
  night.addEventListener('change', () => { if (!store('scheme')) setScheme(night.matches ? 'dark' : 'light'); });

  addEventListener('resize', () => players.forEach((p) => p.fit()));
  document.fonts.ready.then(() => players.forEach((p) => { p.fit(); p.measure(); p.seek(p.time); }));

  // Play only cases currently on screen.
  const visibility = new IntersectionObserver((entries) => entries.forEach((entry) => {
    const p = players.find((item) => item.section === entry.target);
    if (p) p.visible = entry.isIntersecting;
  }), { threshold: 0.2 });
  players.forEach((p) => visibility.observe(p.section));

  const middle = new IntersectionObserver((entries) => entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    $$('#jump a').forEach((a) => (a.getAttribute('href') === '#' + entry.target.id ? a.setAttribute('aria-current', 'true') : a.removeAttribute('aria-current')));
    const buddy = $('#buddy'), img = $('img', buddy);
    if (img.dataset.brand === entry.target.dataset.pose) return;
    img.dataset.brand = entry.target.dataset.pose;
    M.paint(buddy);
    buddy.classList.remove('pop');
    void buddy.offsetWidth;
    buddy.classList.add('pop');
  }), { rootMargin: '-45% 0px -45% 0px' });
  $$('section[data-pose],footer[data-pose]').forEach((el) => middle.observe(el));

  render();

  let last = performance.now();
  function tick(now) {
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    if (!document.hidden) {
      for (const p of players) {
        if (p.visible && !p.paused) p.seek(p.time + dt);
      }
    }
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
})();
