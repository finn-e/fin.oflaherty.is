+++
title = "Service Status"
date = "2026-07-10"
description = "Status of homelab services running on the Mimisbrunnr cluster (with a 24-hour security delay)."
+++

<div id="status-root">
  <p class="status-loading">Loading status&hellip;</p>
</div>

<style>
  .status-loading {
    color: var(--text-muted, #888);
    font-style: italic;
  }
  .status-offline-notice {
    padding: 1rem 1.25rem;
    border: 1px solid var(--border-color, #444);
    border-radius: 6px;
    color: var(--text-muted, #888);
    font-style: italic;
  }
  .status-meta {
    font-size: 0.8rem;
    color: var(--text-muted, #888);
    margin-bottom: 1.5rem;
  }
  .status-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 1rem;
    margin-top: 1rem;
  }
  .status-card {
    border: 1px solid var(--border-color, #333);
    border-radius: 8px;
    padding: 1rem 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }
  .status-card-header {
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }
  .status-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .status-dot.up   { background: #22c55e; box-shadow: 0 0 6px #22c55e88; }
  .status-dot.down { background: #ef4444; box-shadow: 0 0 6px #ef444488; }
  .status-name {
    font-weight: 600;
    font-size: 0.95rem;
  }
  .status-desc {
    font-size: 0.78rem;
    color: var(--text-muted, #888);
  }
  .status-uptime {
    font-size: 0.8rem;
    color: var(--text-muted, #aaa);
    margin-top: 0.2rem;
  }
  .status-uptime span {
    font-weight: 600;
    color: var(--text-primary, #e2e8f0);
  }
</style>

<script>
(function () {
  // Primary: GitHub raw — always current, since a cluster CronJob pushes
  // status.json to the repo every 30 min but site deploys are manual.
  // Fallback: the copy bundled with the last deploy.
  var STATUS_URL = 'https://raw.githubusercontent.com/finn-e/fin.oflaherty.is/trunk/static/status.json';
  var FALLBACK_URL = '/status.json';
  var STALE_HOURS = 2;
  var root = document.getElementById('status-root');

  function showOffline(reason) {
    root.innerHTML = '<p class="status-offline-notice">&#x26A0;&#xFE0F; Status feed offline' +
      (reason ? ' &mdash; ' + reason : '') + '.</p>';
  }

  function render(data) {
    var updated = new Date(data.updated);
    var now = new Date();
    var ageHours = (now - updated) / 3600000;

    if (ageHours > STALE_HOURS) {
      showOffline('last update was ' + Math.round(ageHours) + ' hours ago');
      return;
    }

    var metaEl = document.createElement('p');
    metaEl.className = 'status-meta';
    var delayedTime = new Date(updated.getTime() - 24 * 60 * 60 * 1000);
    metaEl.innerHTML = 'Last checked: ' + updated.toLocaleString() + ' <span style="opacity: 0.7;">(Showing status as of ' + delayedTime.toLocaleString() + ' &mdash; 24h security delay)</span>';

    var grid = document.createElement('div');
    grid.className = 'status-grid';

    (data.services || []).forEach(function (svc) {
      var card = document.createElement('div');
      card.className = 'status-card';

      var dotClass = svc.up ? 'up' : 'down';
      var statusLabel = svc.up ? 'Operational' : 'Down';
      var uptime = typeof svc.uptime_30d === 'number'
        ? svc.uptime_30d.toFixed(1) + '%'
        : 'N/A';

      card.innerHTML =
        '<div class="status-card-header">' +
          '<span class="status-dot ' + dotClass + '" title="' + statusLabel + '"></span>' +
          '<span class="status-name">' + escHtml(svc.name) + '</span>' +
        '</div>' +
        '<div class="status-desc">' + escHtml(svc.description || '') + '</div>' +
        '<div class="status-uptime">30d uptime: <span>' + uptime + '</span></div>';

      grid.appendChild(card);
    });

    root.innerHTML = '';
    root.appendChild(metaEl);
    root.appendChild(grid);
  }

  function escHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function load(url) {
    return fetch(url).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.json();
    });
  }

  load(STATUS_URL)
    .catch(function () { return load(FALLBACK_URL); })
    .then(render)
    .catch(function (err) {
      showOffline('could not load status.json');
    });
})();
</script>
