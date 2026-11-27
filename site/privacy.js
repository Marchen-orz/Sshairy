// Shared theme, dark-mode and language switching for privacy.html and zh/privacy.html.
(() => {
  const THEMES = ['blue', 'green', 'violet', 'orange', 'deepSea', 'pink'];
  const NAMES = {
    en: ['Ice Blue / Mint', 'Mint Green', 'Violet', 'Sunset Orange', 'Deep Sea Blue', 'Sakura Pink'],
    zh: ['冰蓝薄荷', '薄荷绿', '紫罗兰', '落日橙', '深海蓝', '樱花粉'],
  };
  const root = document.documentElement;
  const BASE = root.dataset.root || '';
  const ASSETS = BASE + 'assets';
  const lang = root.dataset.lang === 'zh' ? 'zh' : 'en';
  const $ = (sel, el = document) => el.querySelector(sel), $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
  const store = (key, value) => { try { if (value === undefined) return localStorage.getItem(key); localStorage.setItem(key, value); } catch { return null; } };
  const night = matchMedia('(prefers-color-scheme: dark)');
  let theme = THEMES.includes(store('theme')) ? store('theme') : 'blue';
  let scheme = root.dataset.scheme === 'dark' ? 'dark' : 'light';
  root.dataset.theme = theme;

  function paint() {
    $$('img[data-brand^="wordmark"]').forEach((img) => (img.dataset.brand = scheme === 'dark' ? 'wordmark-dark' : 'wordmark'));
    $$('img[data-brand]').forEach((img) => { img.src = `${ASSETS}/brand/${theme}/${img.dataset.brand}.webp`; });
    $('meta[name="theme-color"]').content = scheme === 'dark' ? '#0B0E13' : '#F1F7FF';
    $('#scheme').setAttribute('aria-pressed', scheme === 'dark');
    $$('#dots button').forEach((b) => b.setAttribute('aria-pressed', b.dataset.theme === theme));
  }

  $('#dots').innerHTML = THEMES.map((name, i) => `<button type="button" data-theme="${name}" aria-pressed="${name === theme}" aria-label="${NAMES[lang][i]}" title="${NAMES[lang][i]}"></button>`).join('');
  $('#dots').addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (!button || button.dataset.theme === theme) return;
    theme = button.dataset.theme;
    root.dataset.theme = theme;
    store('theme', theme);
    paint();
  });
  $('#scheme').onclick = () => {
    scheme = scheme === 'dark' ? 'light' : 'dark';
    root.dataset.scheme = scheme;
    try { (scheme === 'dark') === night.matches ? localStorage.removeItem('scheme') : localStorage.setItem('scheme', scheme); } catch {}
    paint();
  };
  night.addEventListener('change', () => {
    if (store('scheme')) return;
    scheme = night.matches ? 'dark' : 'light';
    root.dataset.scheme = scheme;
    paint();
  });
  $('#buddy').onclick = () => {
    theme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
    root.dataset.theme = theme;
    store('theme', theme);
    paint();
  };
  paint();
})();
