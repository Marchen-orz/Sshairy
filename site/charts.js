// Bar charts from assets/data.js. <div class="k-bars" data-chart="startup" data-unit="s" data-digits="2">
(() => {
  function render(el, lang = 'en') {
    const rows = window.SSHAIRY_DATA[el.dataset.chart];
    const digits = Number(el.dataset.digits || 1);
    const unit = el.dataset.unit === 's' ? (lang === 'zh' ? '秒' : 's') : el.dataset.unit || '';
    const max = Math.max(...rows.map((row) => row[1]));
    const mine = rows.find((row) => row[0] === 'Sshairy')[1];
    el.innerHTML = rows
      .map(([name, value]) => {
        const ratio = value / mine;
        const versus = name === 'Sshairy' ? '' : `<span class="x">${ratio >= 1 ? ratio.toFixed(1) + '×' : '−' + Math.round((1 - ratio) * 100) + '%'}</span>`;
        return `<div class="k-bar${name === 'Sshairy' ? ' me' : ''}" style="--v:${(value / max).toFixed(4)}"><span class="n">${name}</span><span class="t"><i></i><b>${value.toFixed(digits)}<small>${unit}</small></b></span>${versus}</div>`;
      })
      .join('');
  }
  window.SshairyCharts = { render, mount: (root = document, lang = 'en') => root.querySelectorAll('[data-chart]').forEach((el) => render(el, lang)) };
})();
