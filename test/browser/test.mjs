// Browser test: drives the demo page (browser/demo) in headless Chromium
// through buttons, the keyboard, typing, the lazy list, a new size, dark
// mode, Back, storage and a save that fails, a second tab, an app that
// doesn't load, and a browser that keeps no files.
//
// Usage: node test.mjs CHROME PAGE_DIR
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import puppeteer from 'puppeteer-core';

const [chrome, pageDir] = process.argv.slice(2);

// The page under /demo/, as a site would have it, and under /broken/
// without its app.
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
  const [, site, rest] = path.match(/^\/(demo|broken)\/(.*)$/) ?? [];
  if (!site || (site === 'broken' && rest === 'app.wasm')) {
    response.writeHead(404).end();
    return;
  }
  const file = normalize(rest || 'index.html');
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

/** Set while a save is made to fail, which the page then logs. */
let failingSave = false;

/** A new tab, with what goes wrong in it counted as failures. */
async function open(errors = true) {
  const page = await browser.newPage();
  await page.setViewport({ width: 420, height: 760 });
  if (errors) {
    page.on('pageerror', (error) => check(false, `no page error (${error.message})`));
    page.on('console', (message) => {
      if (failingSave && message.text().startsWith('Saving files failed')) return;
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

// A tap by keyboard, on what isn't a button.
await page.focus('hatter-text');
await page.keyboard.press('Enter');
check(await settled(page, () => document.querySelector('hatter-text').textContent === 'Count: 0'),
  'Counter: 0 after Enter on it');

const says = (page, text) => settled(page, (t) => [...document.querySelectorAll('hatter-text')]
  .some((e) => e.textContent === t), text);

// What the app handles a press of can't be selected by it.
check(await page.$eval('hatter-text', (e) => getComputedStyle(e).userSelect) === 'none',
  'the counter\'s text can\'t be selected');

// The app hears whether its tab is shown.
check(await says(page, 'Resume'), 'the app is told it is shown');
const show = (page, state) => page.evaluate((s) => {
  Object.defineProperty(document, 'visibilityState', { value: s, configurable: true });
  document.dispatchEvent(new Event('visibilitychange', { bubbles: true }));
}, state);
await show(page, 'hidden');
await tap(page, '+');
check(await says(page, 'Stop'), 'the app is told its tab is hidden');
await show(page, 'visible');
await tap(page, '-');
check(await says(page, 'Resume'), 'the app is told its tab is shown again');

// The app hears of the page's new size.
const wide = (page, width) => says(page, `${width} wide`);
check(await wide(page, 420), 'the app has the page\'s width');
await page.setViewport({ width: 600, height: 760 });
check(await wide(page, 600), 'the app has the page\'s new width');
await page.setViewport({ width: 420, height: 760 });

const typed = 'héllo ✓ 你好';
await page.type('hatter-text-input input', typed);
await tap(page, 'Add');
check(await settled(page, (t) => [...document.querySelectorAll('hatter-lazy-column hatter-text')]
  .some((e) => e.textContent === t), typed), 'a typed note shows in the list');
check(await page.$eval('hatter-text-input input', (e) => e.value) === '', 'the text field is empty after Add');
check(await page.evaluate(() => document.activeElement?.closest('hatter-text-input') !== null),
  'the text field keeps the focus after Add');

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
const draft = 'half a note';
await page.type('hatter-text-input input', draft);
await new Promise((resolve) => setTimeout(resolve, 2000));
await page.reload();
await started(page);
const kept = await notes(page);
check(kept.length === many + 1 && kept[0] === typed && kept[many] === `note ${many}`, 'the notes are there after a reload');
check(await settled(page, (t) => document.querySelector('hatter-text-input input')?.value === t, draft),
  'the note being written is there after a reload');

// A save that fails is made again with the next: here a note of the same
// length, which the file's size doesn't show.
failingSave = true;
await page.evaluate(() => {
  const real = FileSystemFileHandle.prototype.createWritable;
  FileSystemFileHandle.prototype.createWritable = function () {
    FileSystemFileHandle.prototype.createWritable = real;
    return Promise.reject(new Error('disk full'));
  };
});
const again = draft.toUpperCase();
await page.$eval('hatter-text-input input', (e) => e.select());
await page.type('hatter-text-input input', again);
await new Promise((resolve) => setTimeout(resolve, 2000));
await page.evaluate(() => dispatchEvent(new Event('pagehide')));
await new Promise((resolve) => setTimeout(resolve, 1000));
failingSave = false;
await page.reload();
await started(page);
check(await settled(page, (t) => document.querySelector('hatter-text-input input')?.value === t, again),
  'a note whose save failed is there after the next save');

// One tab at a time.
const second = await open(false);
await second.goto(url);
check(await settled(second, () => document.querySelector('hatter-root')?.textContent?.includes('open in another tab')),
  'a second tab is turned away');
await second.close();

// An app that doesn't load says so.
const broken = await open(false);
await broken.goto(url.replace('/demo/', '/broken/'));
check(await settled(broken, () => document.querySelector('hatter-root')?.textContent?.includes('didn\'t load')),
  'a page whose app doesn\'t load says so');
await broken.close();

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
await dark.close();

// A browser that keeps no files still runs the app, and the app says so.
// Firefox refuses storage in private windows, and Web Locks too where site
// data is blocked.
for (const locks of [false, true]) {
  const what = locks ? 'storage and locks' : 'storage';
  const unkept = await open();
  await unkept.evaluateOnNewDocument((refuseLocks) => {
    const refused = () => Promise.reject(new DOMException('Security error when calling GetDirectory', 'SecurityError'));
    navigator.storage.getDirectory = refused;
    if (refuseLocks) navigator.locks.request = refused;
  }, locks);
  await unkept.goto(url);
  check(await started(unkept).then(() => true, () => false), `the app runs when the browser refuses ${what}`);
  check(await settled(unkept, () => document.querySelector('mat-snack-bar-container')?.textContent?.includes('Nothing here is kept')),
    `the app says nothing is kept when the browser refuses ${what}`);
  await unkept.close();
}

await browser.close();
server.close();
console.log(failures ? `${failures} failed` : 'All browser tests passed.');
process.exit(failures ? 1 : 0);
