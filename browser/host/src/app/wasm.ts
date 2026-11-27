// Starts the app: app.wasm, with the JavaScript GHC made for it
// (ghc_wasm_jsffi.js), both next to the page.

import { ApplicationRef } from '@angular/core';
import { ConsoleStdout, File, Inode, OpenFile, PreopenDirectory, WASI } from '@bjorn3/browser_wasi_shim';

import { Disk } from './disk';
import { cacheDir } from './files';
import { Host } from './host';
import { Popups } from './popups';
import { Files } from './storage';

interface Exports {
  memory: WebAssembly.Memory;
  hs_init(argc: number, argv: number): void;
  start(): Promise<void>;
}

/** The app's name, from where the page is, so apps on one site keep their files apart. */
function appName(): string {
  return new URL(document.baseURI).pathname.split('/').filter(Boolean).pop() ?? 'app';
}

/**
 * Whether this tab may run the app, which it may until it closes. Two tabs
 * would each save their own copy of its files over the other's.
 */
function onlyTab(app: string): Promise<boolean> {
  return new Promise((resolve) => {
    navigator.locks
      .request(`hatter:${app}`, { ifAvailable: true }, (lock) => {
        resolve(lock !== null);
        return lock === null ? undefined : new Promise<never>(() => {});
      })
      // A browser that refuses locks keeps no files either, so no tab can save over another's.
      .catch(() => resolve(true));
  });
}

/** Tells the user why there is no app to see. */
export function say(text: string): void {
  const root = document.querySelector('hatter-root');
  if (root) root.textContent = text;
}

export async function startApp(appRef: ApplicationRef): Promise<void> {
  const app = appName();
  if (!(await onlyTab(app))) {
    say('This is open in another tab already. Use that one, or close it and reload this one.');
    return;
  }
  const files = await Files.open(app);
  if (!files.kept) {
    appRef.injector.get(Popups).notice(
      "Nothing here is kept after you close the page, because the browser doesn't let it store files.",
    );
  }
  const cache = new Map<string, Inode>();
  appRef.injector.get(Host).disk = new Disk(
    new Map([
      ['/data', files.root],
      [cacheDir, cache],
    ]),
    () => files.saveSoon(),
  );
  const wasi = new WASI([], [], [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => console.log(line)),
    ConsoleStdout.lineBuffered((line) => console.warn(line)),
    // The app's files (Hatter.Browser's filesDir).
    new PreopenDirectory('/data', files.root),
    // What the page doesn't keep, such as files the user picked.
    new PreopenDirectory(cacheDir, cache),
  ], { debug: false });
  files.watch(wasi);
  const jsffi = await import(/* @vite-ignore */ new URL('ghc_wasm_jsffi.js', document.baseURI).href);
  const exports = {} as Exports;
  const { instance } = await WebAssembly.instantiateStreaming(fetch('app.wasm'), {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: jsffi.default(exports),
  });
  Object.assign(exports, instance.exports);
  wasi.initialize(instance as { exports: { memory: WebAssembly.Memory; _initialize?: () => unknown } });
  exports.hs_init(0, 0);
  await exports.start();
}
