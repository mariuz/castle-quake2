// Smoke test of the browser (WebAssembly) build: load the page in headless
// Chromium (software WebGL), start a game from the menu like a player
// (Enter on "Single Player", Enter on the skill), wait until the map is loaded and the game
// view is drawing, and fail on shader compile errors, wasm / JS exceptions or a
// timeout.
//
//   node tests/web/smoke.js <dist folder or URL> [screenshot.png] [timeout s]
//
// A folder is served on a local port (the PAK is downloaded from it).
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const target = process.argv[2] || 'castle-engine-output/web/dist';
const shot = process.argv[3] || 'web-smoke.png';
const timeoutS = Number(process.argv[4] || 240);

const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
  '.json': 'application/json', '.png': 'image/png', '.css': 'text/css' };

function serve(dir) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const rel = decodeURIComponent(req.url.split('?')[0]);
      let file = path.join(dir, rel.endsWith('/') ? rel + 'index.html' : rel);
      if (!file.startsWith(path.resolve(dir))) { res.writeHead(403); return res.end(); }
      fs.readFile(file, (err, data) => {
        if (err) { res.writeHead(404); return res.end(); }
        res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
        res.end(data);
      });
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

(async () => {
  let server = null;
  let url = target;
  if (!/^https?:/.test(target)) {
    server = await serve(path.resolve(target));
    url = `http://127.0.0.1:${server.address().port}/`;
  }
  const browser = await chromium.launch({
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  const errors = [];
  let loaded = false;
  let ready = false;
  let loadedAt = '';
  const started = Date.now();
  page.on('console', (msg) => {
    const text = msg.text();
    if (/WebAssembly library finished initialization/.test(text) && !ready) {
      ready = true;
      console.log(`[${((Date.now() - started) / 1000).toFixed(1)} s] game initialized`);
    }
    if (/Initialized map|Loaded map "maps\//.test(text) && !loaded) {
      loaded = true;
      loadedAt = ((Date.now() - started) / 1000).toFixed(1);
      console.log(`[${((Date.now() - started) / 1000).toFixed(1)} s] ${text}`);
    }
    if (/GLSL: Fragment shader not compiled|GLSL: Vertex shader not compiled|Exception|RuntimeError/.test(text))
      errors.push(text);
  });
  page.on('pageerror', (err) => errors.push('page error: ' + err.message));
  console.log('Opening ' + url);
  await page.goto(url, { waitUntil: 'load' });
  const deadline = started + timeoutS * 1000;
  while (!ready && errors.length === 0 && Date.now() < deadline)
    await page.waitForTimeout(500);
  if (ready) {
    // The menu: focus the canvas (in a corner: a click on a menu row selects
    // that row), Enter on "Single Player", Enter on the skill (Medium)
    await page.waitForTimeout(1000);
    await page.click('#castle-canvas', { position: { x: 5, y: 5 } });
    await page.waitForTimeout(500);
    await page.keyboard.press('Enter');
    await page.waitForTimeout(1000);
    await page.keyboard.press('Enter');
  }
  while (!loaded && errors.length === 0 && Date.now() < deadline)
    await page.waitForTimeout(500);
  // Let the level settle, then count the browser's frames for 5 s (the game
  // draws one per requestAnimationFrame), then a picture of the canvas
  let fps = 0;
  if (loaded) {
    await page.waitForTimeout(3000);
    fps = await page.evaluate(() => new Promise((resolve) => {
      let frames = 0;
      const start = performance.now();
      function tick() {
        frames++;
        if (performance.now() - start < 5000) requestAnimationFrame(tick);
        else resolve(frames * 1000 / (performance.now() - start));
      }
      requestAnimationFrame(tick);
    }));
  }
  await page.screenshot({ path: shot });
  await browser.close();
  if (server) server.close();
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  if (errors.length > 0) {
    console.log('FAILED: ' + errors.slice(0, 5).join('\n'));
    process.exit(1);
  }
  if (!loaded) {
    console.log(`FAILED: no map loaded within ${timeoutS} s`);
    process.exit(1);
  }
  console.log(`OK: map loaded at ${loadedAt} s, ${fps.toFixed(1)} frames per second in the browser, screenshot ${shot}`);
})();
