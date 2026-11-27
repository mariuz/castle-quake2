// Two games on one page (pages/duel.html, roadmap E.4 step 2): the left
// iframe hosts, the right one joins it through a BroadcastChannel. Serves
// the page with the web build under play/, runs a demo script in each game
// and reads both consoles (the iframes' messages reach the page's console
// event): the joiner loads the host's map, sees the host's player, walks
// (its origin changes) and predicts without errors; the host gets the
// joiner as player 2 and sees it.
//
//   node tests/web/duel.js <dist folder> [screenshot.png] [timeout s]
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const dist = path.resolve(process.argv[2] || 'castle-engine-output/web/dist');
const shot = process.argv[3] || 'web-duel.png';
const timeoutS = Number(process.argv[4] || 400);
const duelPage = path.resolve(__dirname, '../../pages/duel.html');

const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
  '.json': 'application/json', '.png': 'image/png', '.css': 'text/css' };

function serve() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const rel = decodeURIComponent(req.url.split('?')[0]);
      let file;
      if (rel === '/' || rel === '/duel.html')
        file = duelPage;
      else if (rel.startsWith('/play/')) {
        const sub = rel.slice('/play'.length);
        file = path.join(dist, sub.endsWith('/') ? sub + 'index.html' : sub);
        if (!file.startsWith(dist)) { res.writeHead(403); return res.end(); }
      } else { res.writeHead(404); return res.end(); }
      fs.readFile(file, (err, data) => {
        if (err) { res.writeHead(404); return res.end(); }
        res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
        res.end(data);
      });
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// The host stays (no Q) and logs its clients; the joiner waits for the
// host's map, logs, walks forward with the virtual stick, logs again
const hostScript = 'W:1,O:notarget,W:20,V,W:20,V,W:20,V,W:20,V,W:20,V';
const joinScript = 'W:20,V,GP:0 1 0 0 0 0,W:1,GP:,W:0.5,V,W:5,V';

(async () => {
  const server = await serve();
  const base = `http://127.0.0.1:${server.address().port}/duel.html`;
  const url = base + '?host=' + encodeURIComponent('map=demo1&deathmatch=1&demo=' + hostScript) +
    '&join=' + encodeURIComponent('demo=' + joinScript);
  const browser = await chromium.launch({
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
  const errors = [];
  const lines = [];
  const started = Date.now();
  const at = () => `[${((Date.now() - started) / 1000).toFixed(1)} s]`;
  page.on('console', (msg) => {
    const text = msg.text();
    lines.push(text);
    if (/Hosting as page|Joining .* as page|Remote client|Host map|Duel:|Join:|Host:|Remote player|Loaded map "maps\//.test(text))
      console.log(`${at()} ${text}`);
    if (/GLSL: Fragment shader not compiled|GLSL: Vertex shader not compiled|Exception|RuntimeError/.test(text))
      errors.push(text);
  });
  page.on('pageerror', (err) => errors.push('page error: ' + err.message));
  console.log('Opening ' + url);
  await page.goto(url, { waitUntil: 'load' });

  function check() {
    const join = lines.filter((l) => /Join: host duel /.test(l));
    const seeing = join.filter((l) => /the view sees 1 other players/.test(l) && /\(0 bad\)/.test(l) &&
      / 0 off by more than 1\/8/.test(l));
    const origins = new Set(join.map((l) => (/origin ([-0-9. ]+)/.exec(l) || [])[1]).filter(Boolean));
    const joined = lines.some((l) => /Remote client page-[a-z0-9]+ is player 2/.test(l));
    const seen = lines.some((l) => /Remote player 2 at/.test(l));
    return { join: join.length, seeing: seeing.length, origins: origins.size, joined, seen,
      ok: seeing.length >= 2 && origins.size >= 2 && joined && seen };
  }

  const deadline = started + timeoutS * 1000;
  let state = check();
  while (!state.ok && errors.length === 0 && Date.now() < deadline) {
    await page.waitForTimeout(1000);
    state = check();
  }
  await page.screenshot({ path: shot });
  fs.writeFileSync(shot.replace(/\.png$/, '') + '-console.log', lines.join('\n') + '\n');
  await browser.close();
  server.close();
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  if (errors.length > 0) {
    console.log('FAILED: ' + errors.slice(0, 5).join('\n'));
    process.exit(1);
  }
  if (!state.ok) {
    console.log(`FAILED after ${seconds} s: ${JSON.stringify(state)}`);
    process.exit(1);
  }
  console.log(`OK: duel joined in ${seconds} s (${state.join} join reports, ${state.origins} joiner positions), screenshot ${shot}`);
})();
