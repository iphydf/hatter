// Browser test: drives the demo page (browser/demo) in headless Chromium
// through buttons, typing, the lazy list, dark mode, Back, storage and a
// second tab.
//
// Usage: node test.mjs CHROME PAGE_DIR
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import puppeteer from 'puppeteer-core';

const [chrome, pageDir] = process.argv.slice(2);

// The page under /demo/, as a site would have it.
const types = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.wasm': 'application/wasm',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.svg': 'image/svg+xml',
};
const server = createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  if (!path.startsWith('/demo/')) {
    response.writeHead(404).end();
    return;
  }
  const file = normalize(path.slice('/demo/'.length) || 'index.html');
  try {
    const data = await readFile(join(pageDir, file));
    response.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' }).end(data);
  } catch {
    response.writeHead(404).end();
  }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/demo/`;

let failures = 0;
function check(ok, what) {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${what}`);
  if (!ok) failures++;
}

const browser = await puppeteer.launch({
  executablePath: chrome,
  headless: true,
  // CI runners don't allow Chromium's own sandbox.
  args: ['--no-sandbox'],
});

/** A new tab, with what goes wrong in it counted as failures. */
async function open(errors = true) {
  const page = await browser.newPage();
  await page.setViewport({ width: 420, height: 760 });
  if (errors) {
    page.on('pageerror', (error) => check(false, `no page error (${error.message})`));
    page.on('console', (message) => {
      if (message.type() === 'error') check(false, `no console error (${message.text()})`);
    });
  }
  return page;
}

/** Waits for the app to show its counter. */
const started = (page) => page.waitForFunction(
  () => document.querySelector('hatter-text')?.textContent?.startsWith('Count:'),
  { timeout: 60000 },
);

const counter = (page) => page.$eval('hatter-text', (e) => e.textContent);
const notes = (page) => page.$$eval('hatter-lazy-column hatter-text', (es) => es.map((e) => e.textContent));
const button = async (page, label) => {
  for (const b of await page.$$('hatter-button button')) {
    if ((await b.evaluate((e) => e.textContent.trim())) === label) return b;
  }
  throw new Error(`no button ${label}`);
};
const tap = async (page, label) => (await button(page, label)).click();
const settled = (page, f, value) => page.waitForFunction(f, { timeout: 5000 }, value).then(() => true, () => false);

const page = await open();
await page.goto('about:blank');
await page.goto(url);
await started(page);
check(await counter(page) === 'Count: 0', 'Counter: 0 at start');
check(await page.evaluate(() => document.activeElement?.closest('hatter-text-input') !== null),
  'the text field has the focus at start');

// The same taps as the Android buttons test.
let expected = 0;
for (const [label, step] of [['+', 1], ['+', 1], ['-', -1], ['-', -1], ['-', -1]]) {
  await tap(page, label);
  expected += step;
  check(await settled(page, (n) => document.querySelector('hatter-text').textContent === `Count: ${n}`, expected),
    `Counter: ${expected} after ${label}`);
}

const typed = 'héllo ✓ 你好';
await page.type('hatter-text-input input', typed);
await tap(page, 'Add');
check(await settled(page, (t) => [...document.querySelectorAll('hatter-lazy-column hatter-text')]
  .some((e) => e.textContent === t), typed), 'a typed note shows in the list');
check(await page.$eval('hatter-text-input input', (e) => e.value) === '', 'the text field is empty after Add');

// Enough notes to scroll: the list keeps its last one in view.
const many = 40;
for (let i = 1; i <= many; i++) {
  await page.type('hatter-text-input input', `note ${i}`);
  await tap(page, 'Add');
}
check(await settled(page, (n) => document.querySelectorAll('hatter-lazy-column hatter-text').length === n, many + 1),
  `${many + 1} notes in the list`);
check(await settled(page, (t) => {
  const list = document.querySelector('hatter-lazy-column').getBoundingClientRect();
  const last = [...document.querySelectorAll('hatter-lazy-column hatter-text')].pop();
  const shown = last.getBoundingClientRect();
  return last.textContent === t && shown.bottom <= list.bottom + 1 && shown.top >= list.top;
}, `note ${many}`), 'the last note is in view');

// Saved soon after the change, then there again after a reload.
await new Promise((resolve) => setTimeout(resolve, 2000));
await page.reload();
await started(page);
const kept = await notes(page);
check(kept.length === many + 1 && kept[0] === typed && kept[many] === `note ${many}`, 'the notes are there after a reload');

// One tab at a time.
const second = await open(false);
await second.goto(url);
check(await settled(second, () => document.querySelector('hatter-root')?.textContent?.includes('open in another tab')),
  'a second tab is turned away');
await second.close();

// Back, which the demo doesn't handle, leaves the page.
await page.goBack();
check(await settled(page, () => location.href === 'about:blank'), 'Back leaves the app');

// Dark when the system is.
const dark = await open();
await dark.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
await page.close();
await dark.goto(url);
await started(dark);
const light = (colour) => {
  const [r, g, b] = colour.match(/\d+/g).map(Number);
  return (r + g + b) / 3;
};
check(light(await dark.evaluate(() => getComputedStyle(document.body).backgroundColor)) < 64, 'dark background in dark mode');
check(light(await dark.$eval('hatter-text', (e) => getComputedStyle(e).color)) > 192, 'light text in dark mode');

await browser.close();
server.close();
console.log(failures ? `${failures} failed` : 'All browser tests passed.');
process.exit(failures ? 1 : 0);
