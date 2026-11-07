import Foundation

/// An empty, offline page. Words arrive only as JavaScript arguments and enter textContent, never HTML or storage.
public enum LiveWordsPage {
    public static func html(fonts: String = "") -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src data:; script-src 'unsafe-inline'">
        <style>\(fonts)
        :root { color-scheme: dark; --text: #f6f4f1; --mid: #d1ceca; --dim: #a6a29c; --red: #ff5a4a; }
        * { box-sizing: border-box; } html, body { margin: 0; height: 100%; background: #1c1c1c; color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, sans-serif; -webkit-font-smoothing: antialiased; }
        body { display: flex; flex-direction: column; }
        header { display: flex; gap: 10px; align-items: center; padding: 18px 24px 14px; flex-shrink: 0; }
        .dot { width: 7px; height: 7px; border-radius: 2px; background: var(--red); }
        .paused .dot { background: transparent; border: 1px solid var(--dim); }
        h1 { font-size: 15px; font-weight: 600; margin: 0; } #clock { margin-left: auto; color: var(--dim); font-size: 13px; font-variant-numeric: tabular-nums; }
        #status { color: var(--dim); font-size: 13px; line-height: 1.5; padding: 0 24px 14px; margin: 0; flex-shrink: 0; }
        #body { overflow-y: auto; flex: 1; padding: 4px 24px 36px; overflow-anchor: none; }
        #lines { max-width: 660px; margin: 0 auto; }
        .line { display: grid; grid-template-columns: 48px minmax(0,1fr); column-gap: 14px; padding: 9px 0; }
        .line time { font-size: 12px; font-variant-numeric: tabular-nums; color: var(--dim); padding-top: 6px; }
        .speaker { color: var(--dim); font-size: 11px; margin-bottom: 5px; }
        .words { font-family: Newsreader, Georgia, serif; font-size: clamp(21px, 3vw, 24px); line-height: 1.45; color: var(--mid);
          white-space: pre-wrap; overflow-wrap: anywhere; }
        .line:last-child .words { color: var(--text); }
        .draft .words::after { content: ''; display: inline-block; background: var(--red); width: 2px; height: 1em; margin-left: 3px; vertical-align: -2px; }
        .paused .draft .words::after { display: none; }
        @media (max-width: 480px) { header { padding: 16px 16px 12px; } #status { padding: 0 16px 12px; }
          #body { padding: 0 16px 28px; } .line { grid-template-columns: 40px minmax(0,1fr); column-gap: 10px; } }
        </style></head><body><header><span class="dot" aria-hidden="true"></span><h1>Live words</h1><time id="clock">0:00</time></header>
        <p id="status" role="status">Listening…</p><main id="body" aria-label="This meeting's live words"><div id="lines" role="log" aria-live="polite" aria-relevant="additions text"></div></main>
        <script>
        window.liveWords = (lines, elapsed, status, paused, onCall) => {
          const body = document.getElementById('body'), list = document.getElementById('lines');
          const atEnd = body.scrollTop + body.clientHeight >= body.scrollHeight - 30;
          const top = body.scrollTop;
          document.body.classList.toggle('paused', paused);
          const clock = s => { s = Math.max(0, Math.floor(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
          document.getElementById('clock').textContent = clock(elapsed);
          document.getElementById('status').textContent = status;
          if (lines === null) return;
          const keys = new Set(lines.map(l => l.track + '-' + l.id));
          const existing = new Map([...list.children].map(r => [r.dataset.key, r]));
          for (const row of [...list.children]) if (!keys.has(row.dataset.key)) row.remove();
          lines.forEach((l, i) => {
            const key = l.track + '-' + l.id;
            let row = existing.get(key);
            if (!row) {
              row = document.createElement('article'); row.dataset.key = key;
              row.append(document.createElement('time'));
              const content = document.createElement('div'), who = document.createElement('div'), words = document.createElement('div');
              who.className = 'speaker'; words.className = 'words'; content.append(who, words); row.append(content);
            }
            row.className = 'line' + (l.final ? '' : ' draft');
            row.children[0].textContent = clock(l.start);
            const who = row.querySelector('.speaker'), words = row.querySelector('.words');
            who.hidden = !onCall; who.textContent = onCall ? (l.track === 'me' ? 'You' : 'Others') : '';
            if (words.textContent !== l.text) words.textContent = l.text;
            if (list.children[i] !== row) list.insertBefore(row, list.children[i] || null);
          });
          body.scrollTop = atEnd ? body.scrollHeight : top;
        };
        </script></body></html>
        """
    }
}
