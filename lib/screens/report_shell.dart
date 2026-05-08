// Static HTML/CSS/JS shell for the DryRun report viewer.
// index.html is regenerated each run; only the <script src> list changes.
// Each report's data lives in a separate .js file (JSONP), loadable via file://.

// ignore_for_file: prefer_single_quotes
const kReportShellHtml = r'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>DryRun Reports</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Segoe UI',system-ui,Arial,sans-serif;background:#f1f5f9;color:#0f172a;font-size:13px;display:flex;flex-direction:column;height:100vh;overflow:hidden}

    /* ── top bar ── */
    #topbar{background:#0f172a;color:#f8fafc;padding:0 20px;height:44px;display:flex;align-items:center;flex-shrink:0;gap:12px}
    .topbar-title{font-size:15px;font-weight:700;letter-spacing:.02em}

    /* ── layout ── */
    #body-area{display:flex;flex:1;overflow:hidden}

    /* ── sidebar ── */
    #sidebar{width:268px;flex-shrink:0;background:#1e293b;overflow-y:auto;border-right:1px solid #0f172a;display:flex;flex-direction:column}
    .sb-section{padding:10px 14px 4px;font-size:10px;font-weight:700;color:#64748b;letter-spacing:.08em;text-transform:uppercase;flex-shrink:0}
    .sb-item{padding:9px 14px;cursor:pointer;border-bottom:1px solid #162032;transition:background .1s}
    .sb-item:hover{background:#334155}
    .sb-active{background:#1d4ed8 !important;border-left:3px solid #60a5fa}
    .sb-name{font-size:12px;font-weight:600;color:#e2e8f0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .sb-time{font-size:10.5px;color:#94a3b8;margin-top:2px}
    .sb-pills{display:flex;gap:4px;margin-top:4px}
    .sb-pill{font-size:10px;font-weight:700;padding:1px 7px;border-radius:999px}
    .sb-pass{background:#166534;color:#dcfce7}
    .sb-fail{background:#991b1b;color:#fee2e2}

    /* ── main ── */
    #main{flex:1;overflow-y:auto;padding:20px 24px}
    .placeholder{color:#94a3b8;font-size:13px;padding:40px 20px}

    /* ── report header ── */
    .rpt-header{background:#eef3fb;border-radius:10px;border:1.5px solid #c7d8f0;padding:14px 18px;margin-bottom:16px;display:flex;align-items:flex-start;flex-wrap:wrap;gap:8px}
    .rpt-title{font-size:14px;font-weight:700;color:#0f172a;flex:1;min-width:200px;word-break:break-all}
    .rpt-meta{font-size:11.5px;color:#64748b;flex-basis:100%;order:3}
    .summary-pills{display:flex;gap:8px;flex-shrink:0}
    .pill{display:inline-flex;align-items:center;gap:5px;padding:4px 12px;border-radius:999px;font-size:12px;font-weight:700}
    .pill-pass{background:#166534;color:#dcfce7}
    .pill-fail{background:#991b1b;color:#fee2e2}
    .pill-num{font-size:15px}

    /* ── target card ── */
    .target-card{background:#fff;border-radius:10px;border:1.5px solid #e2e8f0;margin-bottom:12px;overflow:hidden}
    .tc-pass{border-left:5px solid #22c55e}
    .tc-fail{border-left:5px solid #ef4444}
    .tc-summary{display:flex;align-items:center;gap:10px;padding:11px 16px;cursor:pointer;list-style:none;user-select:none}
    .tc-summary::-webkit-details-marker{display:none}
    .tc-summary:hover{background:#f8fafc}
    .tc-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
    .tc-pass>.tc-summary .tc-dot{background:#22c55e}
    .tc-fail>.tc-summary .tc-dot{background:#ef4444}
    .tc-title-group{flex:1;min-width:0;overflow:hidden}
    .tc-name{font-weight:600;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .tc-sub{display:flex;flex-wrap:wrap;gap:4px;flex-shrink:0}
    .tc-tag{font-size:10px;color:#475569;font-family:'Consolas','Cascadia Code',monospace;background:#f1f5f9;border:1px solid #cbd5e1;border-radius:4px;padding:1px 6px;white-space:nowrap}
    .tc-badge{padding:2px 9px;border-radius:999px;font-size:11px;font-weight:700;flex-shrink:0}
    .b-pass{background:#dcfce7;color:#166534}
    .b-fail{background:#fee2e2;color:#991b1b}
    .tc-code{color:#64748b;font-size:12px;flex-shrink:0}
    .tc-body{padding:0 16px 12px}

    /* ── run table ── */
    .run-table{width:100%;border-collapse:collapse;margin-top:6px}
    .run-table th{background:#f8fafc;text-align:left;font-weight:700;color:#334155;padding:6px 10px;border-bottom:1.5px solid #e2e8f0;font-size:11.5px}
    .run-table td{padding:6px 10px;border-bottom:1px solid #f1f5f9;vertical-align:top;font-size:11.5px}
    .run-row:last-child td{border-bottom:none}
    .r-pass .run-status{color:#166534;font-weight:700}
    .r-fail .run-status{color:#991b1b;font-weight:700}
    .r-fail{background:#fff8f8}
    .run-key{font-family:'Consolas','Cascadia Code',monospace;color:#334155;white-space:nowrap}
    .run-code{color:#64748b;white-space:nowrap}
    .run-out{width:100%}

    /* ── MPTool output ── */
    details.out-toggle{margin:2px 0}
    summary.out-toggle{cursor:pointer;font-size:11.5px;color:#64748b;padding:2px 0;user-select:none;list-style:none}
    summary.out-toggle::-webkit-details-marker{display:none}
    summary.out-toggle::before{content:'▶ ';font-size:9px}
    details[open]>summary.out-toggle::before{content:'▼ '}
    .mptool-out{margin:6px 0 0 0;padding:10px 12px;background:#0d1117;color:#cbd5e1;font-family:'Consolas','Cascadia Code','Courier New',monospace;font-size:11.5px;border-radius:6px;white-space:pre-wrap;word-break:break-all;max-height:420px;overflow-y:auto;border:1px solid #1e293b;line-height:1.55}

    /* ── Card Registers ── */
    .cr-wrap{margin:6px 0 0 0}
    .cr-section{margin-bottom:10px}
    .cr-title{font-size:11.5px;font-weight:700;color:#1e40af;background:#eff6ff;border-left:3px solid #3b82f6;padding:3px 8px;margin-bottom:4px;border-radius:0 4px 4px 0}
    .cr-hex{font-family:'Consolas','Cascadia Code','Courier New',monospace;font-size:11px;color:#4f46e5;background:#eef2ff;padding:4px 8px;border-radius:4px;margin-bottom:5px;letter-spacing:.04em}
    .cr-table{width:100%;border-collapse:collapse;font-size:11.5px}
    .cr-table td{padding:2px 6px;vertical-align:top;border-bottom:1px solid #f1f5f9}
    .cr-table tr:last-child td{border-bottom:none}
    .cr-key{color:#475569;white-space:nowrap;padding-right:12px;min-width:180px}
    .cr-val{color:#0f172a;font-weight:500}
    .cr-list{color:#64748b;padding-left:16px}

    /* ── footer ── */
    .rpt-footer{color:#94a3b8;font-size:11px;margin-top:16px;padding-bottom:24px}
  </style>
</head>
<body>
  <div id="topbar">
    <span class="topbar-title">DryRun Reports</span>
  </div>
  <div id="body-area">
    <div id="sidebar">
      <div class="sb-section">Reports</div>
      <div id="sidebar-list"></div>
    </div>
    <div id="main"><div class="placeholder">Select a report from the sidebar.</div></div>
  </div>

  <script>window.DRYRUN_REPORTS = window.DRYRUN_REPORTS || {};</script>
<!-- REPORT_SCRIPTS -->
  <script>
(function () {
  'use strict';

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function renderCardRegisters(sections) {
    if (!sections || !sections.length) return '';
    let h = '<div class="cr-wrap">';
    for (const sec of sections) {
      h += '<div class="cr-section">';
      if (sec.title) h += '<div class="cr-title">' + esc(sec.title) + '</div>';
      for (const hx of (sec.hex || [])) h += '<div class="cr-hex">' + esc(hx) + '</div>';
      if (sec.fields && sec.fields.length) {
        h += '<table class="cr-table">';
        for (const f of sec.fields) {
          if (f.type === 'kv')
            h += '<tr><td class="cr-key">' + esc(f.key) + '</td><td class="cr-val">' + esc(f.value) + '</td></tr>';
          else if (f.type === 'subheader')
            h += '<tr><td class="cr-key" colspan="2">' + esc(f.key) + '</td></tr>';
          else
            h += '<tr><td class="cr-list" colspan="2">&#8226;&nbsp;' + esc(f.value) + '</td></tr>';
        }
        h += '</table>';
      }
      h += '</div>';
    }
    return h + '</div>';
  }

  function renderReport(key) {
    const data = window.DRYRUN_REPORTS[key];
    if (!data) return;
    const targets = data.targets || [];
    const pass = targets.filter(t => t.exitCode === 0).length;
    const fail = targets.length - pass;
    const sorted = [...targets].sort((a, b) => (a.exitCode === 0 ? 1 : 0) - (b.exitCode === 0 ? 1 : 0));

    let html = '<div class="rpt-header">'
      + '<div class="rpt-title">' + esc(data.archive) + '</div>'
      + '<div class="summary-pills">'
      + '<div class="pill pill-pass"><span class="pill-num">' + pass + '</span>&nbsp;PASS</div>'
      + '<div class="pill pill-fail"><span class="pill-num">' + fail + '</span>&nbsp;FAIL</div>'
      + '</div>'
      + '<div class="rpt-meta">' + esc((data.time || '').substring(0, 19))
      + '&nbsp;&middot;&nbsp;Module:&nbsp;<b>' + esc(data.module) + '</b>'
      + '&nbsp;&middot;&nbsp;CType:&nbsp;<b>' + esc(data.ctype) + '</b></div>'
      + '</div>';

    for (const target of sorted) {
      const ok = target.exitCode === 0;
      const runs = target.runs || [];
      let runRows = '';
      for (const run of runs) {
        const rok = run.exitCode === 0;
        const outLines = (run.output || []).filter(l => l.trim());
        const outBlock = outLines.length
          ? '<details' + (rok ? '' : ' open') + '><summary class="out-toggle">'
            + (rok ? 'Output' : 'MPTool Output')
            + '</summary><pre class="mptool-out">' + esc(outLines.join('\n')) + '</pre></details>'
          : '';
        const crBlock = run.cardRegisters && run.cardRegisters.length
          ? '<details' + (rok ? '' : ' open') + '><summary class="out-toggle">Card Registers</summary>'
            + renderCardRegisters(run.cardRegisters) + '</details>'
          : '';
        runRows += '<tr class="run-row ' + (rok ? 'r-pass' : 'r-fail') + '">'
          + '<td class="run-key">' + esc(run.key) + '</td>'
          + '<td class="run-status">' + (rok ? 'PASS' : 'FAIL') + '</td>'
          + '<td class="run-code">' + run.exitCode + '</td>'
          + '<td class="run-out">' + outBlock + crBlock + '</td>'
          + '</tr>';
      }
      const table = runRows
        ? '<table class="run-table"><thead><tr>'
          + '<th>Device + Config</th><th>Status</th><th>Exit&nbsp;Code</th><th>Output / Registers</th>'
          + '</tr></thead><tbody>' + runRows + '</tbody></table>'
        : '';
      const CELL_TYPES = {'0': 'SLC', '1': 'MLC', '2': 'TLC'};
      const subParts = [];
      if (target.flashId)  subParts.push(target.flashId);
      if (target.die)      subParts.push(target.die + ' Die');
      if (target.cellType != null && target.cellType !== '') subParts.push(CELL_TYPES[String(target.cellType)] || target.cellType);
      if (target.plane)    subParts.push(target.plane + 'P');
      if (target.alias)    subParts.push(target.alias);
      const subtitle = subParts.map(p => '<span class="tc-tag">' + esc(p) + '</span>').join('');

      html += '<details class="target-card ' + (ok ? 'tc-pass' : 'tc-fail') + '"' + (ok ? '' : ' open') + '>'
        + '<summary class="tc-summary">'
        + '<span class="tc-dot"></span>'
        + '<div class="tc-title-group">'
        + '<span class="tc-name">' + esc(target.name) + '</span>'
        + '</div>'
        + (subtitle ? '<div class="tc-sub">' + subtitle + '</div>' : '')
        + '<span class="tc-badge ' + (ok ? 'b-pass' : 'b-fail') + '">' + (ok ? 'PASS' : 'FAIL') + '</span>'
        + '<span class="tc-code">exit&nbsp;' + target.exitCode + '</span>'
        + '</summary>'
        + '<div class="tc-body">' + table + '</div>'
        + '</details>';
    }

    html += '<div class="rpt-footer">Dump:&nbsp;' + esc(data.dumpBase) + '</div>';
    document.getElementById('main').innerHTML = html;
  }

  function buildSidebar() {
    const rpts = window.DRYRUN_REPORTS || {};
    const keys = Object.keys(rpts).sort((a, b) => {
      const ta = rpts[a] && rpts[a].time ? rpts[a].time : '';
      const tb = rpts[b] && rpts[b].time ? rpts[b].time : '';
      return tb.localeCompare(ta);
    });
    const list = document.getElementById('sidebar-list');
    list.innerHTML = '';
    for (const k of keys) {
      const r = rpts[k] || {};
      const targets = r.targets || [];
      const pass = targets.filter(t => t.exitCode === 0).length;
      const fail = targets.length - pass;
      const el = document.createElement('div');
      el.className = 'sb-item';
      el.dataset.key = k;
      el.innerHTML = '<div class="sb-name">' + esc(k) + '</div>'
        + '<div class="sb-time">' + esc((r.time || '').substring(0, 19)) + '</div>'
        + '<div class="sb-pills">'
        + '<span class="sb-pill sb-pass">' + pass + ' PASS</span>'
        + '<span class="sb-pill sb-fail">' + fail + ' FAIL</span>'
        + '</div>';
      el.addEventListener('click', () => selectReport(k));
      list.appendChild(el);
    }
    const requested = new URLSearchParams(location.search).get('report');
    const initial = (requested && keys.includes(requested)) ? requested : (keys.length ? keys[0] : null);
    if (initial) selectReport(initial);
  }

  window.selectReport = function (key) {
    document.querySelectorAll('.sb-item').forEach(function (el) {
      el.classList.toggle('sb-active', el.dataset.key === key);
    });
    history.replaceState(null, '', '?report=' + encodeURIComponent(key));
    renderReport(key);
  };

  document.addEventListener('DOMContentLoaded', buildSidebar);
}());
  </script>
</body>
</html>
''';
