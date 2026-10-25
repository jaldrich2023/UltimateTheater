//
//  RemotePage.swift
//  Ultimate Theater
//
//  The phone remote: one self-contained page (no external files, fonts, or scripts), styled
//  like the app. Every piece of library text is set with textContent, and attributes only
//  through DOM properties; nothing is ever parsed as HTML (no innerHTML at all).
//

import Foundation

nonisolated enum RemotePage {
    private static let head = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="color-scheme" content="dark">
    <meta name="theme-color" content="#0A0A0F">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Theater">
    <title>Ultimate Theater Remote</title>
    <style>
    :root { --bg:#0A0A0F; --accent:#FF3D5A; --glass:rgba(255,255,255,.08); --glass-strong:rgba(255,255,255,.14);
            --line:rgba(255,255,255,.14); --muted:rgba(255,255,255,.62); }
    * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
    html, body { margin:0; background:var(--bg); color:#fff;
                 font:16px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
    body { min-height:100vh; padding:max(18px, env(safe-area-inset-top)) 18px max(28px, env(safe-area-inset-bottom));
           background:radial-gradient(120% 55% at 50% -12%, rgba(255,61,90,.24), transparent 62%), var(--bg); }
    main { max-width:520px; margin:0 auto; }
    header { display:flex; justify-content:space-between; align-items:center; margin-bottom:18px; }
    .brand { font-size:12px; font-weight:800; letter-spacing:.16em; color:var(--accent); }
    .muted { color:var(--muted); }
    .small { font-size:13px; }
    h1 { font-size:28px; margin:8px 0; }
    h2 { font-size:17px; margin:22px 0 10px; }
    button, select, input[type=search], input[inputmode] { font:inherit; color:inherit; }
    button { border:1px solid var(--line); background:var(--glass); border-radius:999px; padding:12px 18px; cursor:pointer;
             -webkit-backdrop-filter:blur(20px); backdrop-filter:blur(20px); transition:transform .12s, opacity .12s; }
    button:active { transform:scale(.95); }
    button:disabled { opacity:.32; }
    button.primary { background:#fff; color:#000; border:none; font-weight:700; }
    .round { width:58px; height:58px; padding:0; display:grid; place-items:center; font-weight:700; }
    .play { width:80px; height:80px; padding:0; display:grid; place-items:center; background:#fff; color:#000; border:none; }
    .pill { background:var(--accent); border:none; font-weight:700; }
    .wide { width:100%; }
    svg { width:28px; height:28px; fill:currentColor; }
    .card-art { width:100%; max-width:260px; aspect-ratio:2/3; margin:4px auto 16px; border-radius:16px; overflow:hidden;
                background:var(--glass); box-shadow:0 18px 50px rgba(0,0,0,.55); }
    .card-art img { width:100%; height:100%; object-fit:cover; display:block; }
    .title { font-size:24px; font-weight:800; text-align:center; }
    .subtitle { text-align:center; margin-top:2px; }
    .badge { display:block; width:max-content; margin:10px auto 0; padding:4px 12px; border-radius:999px; font-size:12px;
             font-weight:700; background:rgba(255,61,90,.18); color:var(--accent); }
    .panel { background:var(--glass); border:1px solid var(--line); border-radius:22px; padding:16px; margin-top:16px;
             -webkit-backdrop-filter:blur(24px); backdrop-filter:blur(24px); }
    input[type=range] { width:100%; accent-color:var(--accent); margin:0; }
    .times { display:flex; justify-content:space-between; font-size:13px; color:var(--muted); margin-top:6px;
             font-variant-numeric:tabular-nums; }
    .transport { display:flex; justify-content:space-between; align-items:center; margin-top:18px; }
    .skips { display:flex; gap:10px; justify-content:center; margin-top:14px; }
    .skips:empty { display:none; }
    .row { display:flex; align-items:center; gap:12px; }
    .row svg { width:22px; height:22px; flex:none; opacity:.8; }
    .tracks { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    label { font-size:12px; font-weight:700; letter-spacing:.06em; text-transform:uppercase; color:var(--muted); }
    select { display:block; width:100%; margin-top:6px; padding:11px 12px; border-radius:14px; border:1px solid var(--line);
             background:var(--glass-strong); -webkit-appearance:none; appearance:none; text-transform:none; letter-spacing:0; }
    input[type=search], input[inputmode] { width:100%; padding:13px 16px; border-radius:16px; border:1px solid var(--line);
             background:var(--glass-strong); outline:none; -webkit-appearance:none; appearance:none; }
    input:focus, select:focus { border-color:var(--accent); }
    .list { display:flex; flex-direction:column; gap:10px; }
    .item { display:flex; gap:12px; align-items:center; text-align:left; border-radius:18px; padding:8px; width:100%; }
    .item img, .item .noart { width:52px; height:78px; border-radius:10px; object-fit:cover; flex:none; background:var(--glass-strong); }
    .item .name { font-weight:700; }
    .bar { height:4px; border-radius:2px; background:rgba(255,255,255,.18); margin-top:8px; overflow:hidden; }
    .bar i { display:block; height:100%; background:var(--accent); }
    .error { color:var(--accent); min-height:1.4em; }
    .toast { position:fixed; left:50%; bottom:max(24px, env(safe-area-inset-bottom)); transform:translateX(-50%);
             background:rgba(20,20,28,.92); border:1px solid var(--line); padding:10px 16px; border-radius:999px; font-size:14px; }
    [hidden] { display:none !important; }
    .pair form { display:flex; gap:10px; margin-top:22px; }
    .pair input { font-size:24px; letter-spacing:.3em; text-align:center; }
    </style>
    </head>
    """#

    static let pairing = head + #"""
    <body>
    <main class="pair">
      <div class="brand">ULTIMATE THEATER</div>
      <h1>Pair this phone</h1>
      <p class="muted">On your Mac, open Ultimate Theater › Settings › Remote, then scan the QR code or type the six-digit code shown there.</p>
      <form id="form">
        <input id="code" inputmode="numeric" pattern="[0-9]*" maxlength="6" autocomplete="one-time-code" placeholder="000000" aria-label="Pairing code">
        <button class="primary" type="submit">Pair</button>
      </form>
      <p id="message" class="error" role="alert"></p>
    </main>
    <script>
    const message = document.getElementById('message');
    if (new URLSearchParams(location.search).get('pair') === 'failed') {
      message.textContent = 'That link didn’t work. Codes work once and expire after 10 minutes — scan the new one on the Mac.';
    }
    document.getElementById('form').addEventListener('submit', async (event) => {
      event.preventDefault();
      const code = document.getElementById('code').value.trim();
      if (!/^\d{6}$/.test(code)) { message.textContent = 'Enter the six-digit code.'; return; }
      try {
        const response = await fetch('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Remote': '1' },
                                                body: JSON.stringify({ code }) });
        if (response.ok) { location.replace('/'); return; }
        const body = await response.json().catch(() => ({}));
        message.textContent = body.error || 'Pairing didn’t work.';
      } catch (error) {
        message.textContent = 'Can’t reach the Mac. Make sure the phone is on the same Wi-Fi.';
      }
    });
    </script>
    </body>
    </html>
    """#

    static let remote = head + #"""
    <body>
    <main>
      <header><span class="brand">ULTIMATE THEATER</span><span id="profile" class="muted small"></span></header>

      <section id="now" hidden>
        <div class="card-art"><img id="poster" alt=""></div>
        <div id="title" class="title"></div>
        <div id="subtitle" class="subtitle muted"></div>
        <span id="external" class="badge" hidden>Playing on Apple TV</span>

        <div class="panel">
          <input id="scrub" type="range" min="0" max="1" step="1" value="0" aria-label="Position">
          <div class="times"><span id="elapsed">0:00</span><span id="remaining">-0:00</span></div>
          <div class="transport">
            <button id="previous" class="round" aria-label="Previous episode"><svg viewBox="0 0 24 24"><path d="M6 5h2.2v14H6zM9.6 12 20 5v14z"/></svg></button>
            <button id="back" class="round" aria-label="Back 10 seconds">−10</button>
            <button id="play" class="play" aria-label="Play or pause"><svg id="iconPlay" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg><svg id="iconPause" viewBox="0 0 24 24" hidden><path d="M6.5 5h4v14h-4zM13.5 5h4v14h-4z"/></svg></button>
            <button id="forward" class="round" aria-label="Forward 10 seconds">+10</button>
            <button id="next" class="round" aria-label="Next episode"><svg viewBox="0 0 24 24"><path d="M15.8 5H18v14h-2.2zM4 5l10.4 7L4 19z"/></svg></button>
          </div>
          <div class="skips"><button id="skipIntro" class="pill" hidden>Skip Intro</button><button id="skipCredits" class="pill" hidden>Skip Credits</button></div>
        </div>

        <div class="panel">
          <div class="row">
            <svg viewBox="0 0 24 24"><path d="M4 9v6h4l5 5V4L8 9zm12.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z"/></svg>
            <input id="volume" type="range" min="0" max="1" step="0.05" aria-label="Volume">
          </div>
        </div>

        <div class="panel tracks">
          <label>Audio<select id="audio"></select></label>
          <label>Subtitles<select id="subtitles"></select></label>
        </div>

        <div class="panel" style="padding:0;border:none;background:none">
          <button id="stop" class="wide">Stop</button>
        </div>
      </section>

      <section id="browse" hidden>
        <input id="search" type="search" placeholder="Search movies & shows" autocomplete="off" enterkeyhint="search" aria-label="Search">
        <h2 id="continueHeading">Continue Watching</h2>
        <div id="continue" class="list"></div>
        <h2 id="resultsHeading" hidden>Results</h2>
        <div id="results" class="list"></div>
        <p id="empty" class="muted"></p>
      </section>

      <section id="unpaired" hidden>
        <h1>Not paired</h1>
        <p class="muted">This phone is no longer paired with the Mac.</p>
        <button class="primary" id="repair">Pair Again</button>
      </section>
    </main>
    <div id="toast" class="toast" hidden role="status"></div>

    <script>
    const $ = (id) => document.getElementById(id);
    let state = null, scrubbing = false, browseShown = false, searchTimer = null, toastTimer = null, events = null;

    function format(seconds) {
      const total = Math.max(0, Math.floor(seconds || 0));
      const h = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60;
      return (h ? h + ':' + String(m).padStart(2, '0') : String(m)) + ':' + String(s).padStart(2, '0');
    }

    function toast(text) {
      const t = $('toast'); t.textContent = text; t.hidden = false;
      clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
    }

    function unpaired() {
      if (events) { events.close(); events = null; }
      $('now').hidden = true; $('browse').hidden = true; $('unpaired').hidden = false;
    }

    async function api(path, options = {}) {
      const response = await fetch(path, { ...options, headers: { 'X-Remote': '1', 'Content-Type': 'application/json' } });
      if (response.status === 401) { unpaired(); throw new Error('unpaired'); }
      const body = await response.json().catch(() => null);
      if (!response.ok) throw new Error((body && body.error) || 'That didn’t work.');
      return body;
    }

    async function send(action, value) {
      try {
        const body = await api('/api/command', { method: 'POST', body: JSON.stringify(value === undefined ? { action } : { action, value }) });
        if (body) render(body);
      } catch (error) {
        if (error.message !== 'unpaired') toast(error instanceof TypeError ? 'Can’t reach the Mac.' : error.message);
      }
    }

    function fill(select, options, selected, offLabel) {
      if (document.activeElement === select) return;
      const key = JSON.stringify([options, selected]);
      if (select.dataset.key === key) return;
      select.dataset.key = key;
      select.replaceChildren();
      if (offLabel) select.append(new Option(offLabel, ''));
      for (const option of options || []) {
        const element = new Option(option.label || 'Track', option.id);
        element.disabled = !option.supported;
        select.append(element);
      }
      select.value = selected == null ? '' : selected;
      select.disabled = (options || []).length < (offLabel ? 1 : 2);
    }

    function render(s) {
      state = s;
      $('unpaired').hidden = true;
      $('profile').textContent = s.profile || '';
      if (!s.playing) {
        $('now').hidden = true; $('browse').hidden = false;
        if (!browseShown) { browseShown = true; loadBrowse($('search').value.trim()); }
        return;
      }
      browseShown = false;
      $('now').hidden = false; $('browse').hidden = true;
      const item = s.item || {};
      $('title').textContent = item.title || '';
      $('subtitle').textContent = item.subtitle || '';
      const poster = $('poster');
      if (item.poster) { if (poster.getAttribute('src') !== item.poster) poster.src = item.poster; poster.hidden = false; }
      else { poster.removeAttribute('src'); poster.hidden = true; }
      $('external').hidden = !s.external;

      const scrub = $('scrub');
      if (!scrubbing) { scrub.max = Math.max(1, s.duration || 0); scrub.value = s.position || 0; }
      const shown = scrubbing ? Number(scrub.value) : (s.position || 0);
      $('elapsed').textContent = format(shown);
      $('remaining').textContent = '-' + format((s.duration || 0) - shown);

      $('iconPlay').toggleAttribute('hidden', !!s.isPlaying); // SVG elements have no .hidden property.
      $('iconPause').toggleAttribute('hidden', !s.isPlaying);
      $('previous').hidden = $('next').hidden = !s.isEpisode;
      $('previous').disabled = !s.canPrevious;
      $('next').disabled = !s.canNext;
      $('skipIntro').hidden = !s.canSkipIntro;
      $('skipCredits').hidden = !s.canSkipCredits;
      if (document.activeElement !== $('volume')) $('volume').value = s.muted ? 0 : s.volume;
      fill($('audio'), s.audio, s.audioID, null);
      fill($('subtitles'), s.subtitles, s.subtitleID, 'Off');
    }

    function row(item) {
      const button = document.createElement('button');
      button.className = 'item';
      button.disabled = !item.playable;
      if (item.poster) {
        const image = document.createElement('img');
        image.alt = ''; image.loading = 'lazy'; image.src = item.poster;
        button.append(image);
      } else {
        const blank = document.createElement('div'); blank.className = 'noart'; button.append(blank);
      }
      const text = document.createElement('div');
      text.style.flex = '1';
      const name = document.createElement('div'); name.className = 'name'; name.textContent = item.title;
      const detail = document.createElement('div'); detail.className = 'muted small'; detail.textContent = item.detail || '';
      text.append(name, detail);
      if (item.progress != null) {
        const bar = document.createElement('div'); bar.className = 'bar';
        const fillBar = document.createElement('i'); fillBar.style.width = Math.round(item.progress * 100) + '%';
        bar.append(fillBar); text.append(bar);
      }
      button.append(text);
      button.addEventListener('click', () => send('playTitle', item.id));
      return button;
    }

    async function loadBrowse(query) {
      try {
        const body = await api('/api/browse' + (query ? '?q=' + encodeURIComponent(query) : ''));
        if (!body.profile) {
          $('continueHeading').hidden = true; $('resultsHeading').hidden = true;
          $('continue').replaceChildren(); $('results').replaceChildren();
          $('empty').textContent = 'Choose a profile on the Mac to browse from here.';
          return;
        }
        $('continue').replaceChildren(...body.continue.map(row));
        $('results').replaceChildren(...body.results.map(row));
        $('continueHeading').hidden = query !== '' || body.continue.length === 0;
        $('continue').hidden = query !== '';
        $('resultsHeading').hidden = query === '';
        $('empty').textContent = query !== '' && body.results.length === 0 ? 'No matches.'
          : (query === '' && body.continue.length === 0 ? 'Nothing in progress. Search to start something.' : '');
      } catch (error) {
        if (error.message !== 'unpaired') toast('Can’t reach the Mac.');
      }
    }

    function connect() {
      if (events) return;
      events = new EventSource('/api/events');
      events.onmessage = (event) => { try { render(JSON.parse(event.data)); } catch (error) {} };
      events.onerror = async () => {
        if (events) { events.close(); events = null; }
        try { await api('/api/state'); } catch (error) { if (error.message === 'unpaired') return; }
        setTimeout(connect, 2000);
      };
    }

    $('play').addEventListener('click', () => send('togglePlayback'));
    $('back').addEventListener('click', () => send('skip', -10));
    $('forward').addEventListener('click', () => send('skip', 10));
    $('previous').addEventListener('click', () => send('previousEpisode'));
    $('next').addEventListener('click', () => send('nextEpisode'));
    $('skipIntro').addEventListener('click', () => send('skipIntro'));
    $('skipCredits').addEventListener('click', () => send('skipCredits'));
    $('stop').addEventListener('click', () => send('stop'));
    $('repair').addEventListener('click', () => location.replace('/'));
    const scrub = $('scrub');
    scrub.addEventListener('input', () => {
      scrubbing = true;
      $('elapsed').textContent = format(Number(scrub.value));
      if (state) $('remaining').textContent = '-' + format((state.duration || 0) - Number(scrub.value));
    });
    scrub.addEventListener('change', () => { scrubbing = false; send('seek', Number(scrub.value)); });
    $('volume').addEventListener('change', (event) => send('volume', Number(event.target.value)));
    $('audio').addEventListener('change', (event) => send('audio', event.target.value));
    $('subtitles').addEventListener('change', (event) => send('subtitle', event.target.value || null));
    $('search').addEventListener('input', (event) => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => loadBrowse(event.target.value.trim()), 300);
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden && !events) connect(); });
    connect();
    </script>
    </body>
    </html>
    """#
}
