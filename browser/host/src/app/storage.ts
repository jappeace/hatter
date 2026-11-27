// The app's files, kept in the browser's private storage (OPFS) between
// visits. The app works on them in memory: SQLite reads and writes its files
// as it goes, and a page can only do that with storage in a worker. Each
// change is saved soon after, and when the page is hidden.
//
// A save is all or nothing: each changed file goes into a new blob, then one
// manifest names the blobs of every file, so a database and its journal are
// always saved as they were at the same moment.
//
// A browser may keep no files for the page, as Firefox in a private window:
// then the app still gets its files, but they last only as long as the page.

import { Directory, File, Inode, OpenFile, WASI } from '@bjorn3/browser_wasi_shim';

/** Which blob holds each file, by its path, and the directories there are. */
interface Manifest {
  next: number;
  files: Record<string, string>;
  dirs: string[];
}

/** What a save last wrote for a path. */
interface Saved {
  file: File;
  size: number;
  blob: string;
}

/** Milliseconds from a change to saving it. */
const saveDelay = 1000;

// WASI calls that change a file's contents, by their file descriptor.
const fileWrites = ['fd_write', 'fd_pwrite', 'fd_allocate', 'fd_filestat_set_size'];

// WASI calls that may add, remove, move or empty files.
const treeChanges = [
  'path_open',
  'path_unlink_file',
  'path_remove_directory',
  'path_rename',
  'path_create_directory',
  'path_link',
  'path_symlink',
];

export class Files {
  /** The files' tree, for the WASI directory the app gets. */
  readonly root = new Map<string, Inode>();
  private readonly changed = new Set<File>();
  private saved = new Map<string, Saved>();
  private next = 0;
  private timer?: ReturnType<typeof setTimeout>;
  private saving: Promise<void> = Promise.resolve();

  private constructor(private readonly dir?: FileSystemDirectoryHandle) {}

  /** Whether the files are kept after the page closes. */
  get kept(): boolean {
    return this.dir !== undefined;
  }

  /** The files an app last saved, in a directory of its own. */
  static async open(app: string): Promise<Files> {
    let storage: FileSystemDirectoryHandle;
    try {
      storage = await navigator.storage.getDirectory();
    } catch (error) {
      console.warn('The browser keeps no files for this page:', error);
      return new Files();
    }
    const hatter = await storage.getDirectoryHandle('hatter', { create: true });
    const files = new Files(await hatter.getDirectoryHandle(app, { create: true }));
    await files.load();
    // So the browser doesn't clear them when its disk fills.
    void navigator.storage.persist?.();
    return files;
  }

  /** Saves the app's changes, as its WASI calls make them. */
  watch(wasi: WASI): void {
    if (!this.kept) return;
    const imports = wasi.wasiImport as Record<string, (...args: never[]) => number>;
    for (const name of fileWrites) {
      const call = imports[name];
      imports[name] = (...args: never[]) => {
        const fd = wasi.fds[args[0] as unknown as number];
        if (fd instanceof OpenFile) this.changed.add(fd.file);
        this.saveSoon();
        return call(...args);
      };
    }
    for (const name of treeChanges) {
      const call = imports[name];
      imports[name] = (...args: never[]) => {
        this.saveSoon();
        return call(...args);
      };
    }
    addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this.now();
    });
    addEventListener('pagehide', () => this.now());
  }

  /** Saves the files a moment after their last change. */
  saveSoon(): void {
    if (this.kept) this.timer ??= setTimeout(() => this.now(), saveDelay);
  }

  private now(): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    // One save at a time, each after the last.
    this.saving = this.saving.then(() => this.save()).catch((error) => console.error('Saving files failed:', error));
  }

  private async load(): Promise<void> {
    const manifest = await this.readManifest();
    if (!manifest) return;
    this.next = manifest.next;
    for (const dir of manifest.dirs) this.directory(dir.split('/'));
    for (const [path, blob] of Object.entries(manifest.files)) {
      const handle = await this.store.getFileHandle(blob);
      const data = new Uint8Array(await (await handle.getFile()).arrayBuffer());
      const parts = path.split('/');
      const file = new File(data);
      this.directory(parts.slice(0, -1)).set(parts[parts.length - 1], file);
      this.saved.set(path, { file, size: data.length, blob });
    }
  }

  private async readManifest(): Promise<Manifest | undefined> {
    try {
      const handle = await this.store.getFileHandle('manifest.json');
      return JSON.parse(await (await handle.getFile()).text()) as Manifest;
    } catch {
      return undefined;
    }
  }

  /** Where the files are saved, which only kept files have. */
  private get store(): FileSystemDirectoryHandle {
    if (!this.dir) throw new Error('These files are not kept.');
    return this.dir;
  }

  /** The directory at a path, made if it isn't there. */
  private directory(parts: string[]): Map<string, Inode> {
    let contents = this.root;
    for (const part of parts) {
      let child = contents.get(part);
      if (!(child instanceof Directory)) {
        child = new Directory(new Map());
        contents.set(part, child);
      }
      contents = (child as Directory).contents;
    }
    return contents;
  }

  /** Every file and directory, by path. */
  private walk(): { files: Map<string, File>; dirs: string[] } {
    const files = new Map<string, File>();
    const dirs: string[] = [];
    const go = (contents: Map<string, Inode>, prefix: string) => {
      for (const [name, inode] of contents) {
        const path = prefix + name;
        if (inode instanceof File) files.set(path, inode);
        else if (inode instanceof Directory) {
          dirs.push(path);
          go(inode.contents, path + '/');
        }
      }
    };
    go(this.root, '');
    return { files, dirs };
  }

  private async save(): Promise<void> {
    // What the files hold now, before anything else can change them.
    const { files, dirs } = this.walk();
    const fresh: [string, File, Uint8Array][] = [];
    for (const [path, file] of files) {
      const last = this.saved.get(path);
      if (!last || last.file !== file || last.size !== file.data.length || this.changed.has(file)) {
        fresh.push([path, file, file.data.slice()]);
      }
    }
    this.changed.clear();
    try {
      await this.write(files, dirs, fresh);
    } catch (error) {
      // A change can leave a file's size as it was, so these stay marked.
      for (const [, file] of fresh) this.changed.add(file);
      throw error;
    }
  }

  /** Writes a save: the blobs of the files that changed, then the manifest. */
  private async write(files: Map<string, File>, dirs: string[], fresh: [string, File, Uint8Array][]): Promise<void> {
    const rewritten = new Set(fresh.map(([path]) => path));
    const saved = new Map<string, Saved>();
    for (const path of files.keys()) {
      const last = this.saved.get(path);
      if (last && !rewritten.has(path)) saved.set(path, last);
    }
    for (const [path, file, data] of fresh) {
      const blob = String(this.next++);
      await this.put(blob, data);
      saved.set(path, { file, size: data.length, blob });
    }
    const manifest: Manifest = {
      next: this.next,
      files: Object.fromEntries([...saved].map(([path, { blob }]) => [path, blob])),
      dirs,
    };
    await this.put('manifest.json', new TextEncoder().encode(JSON.stringify(manifest)));
    // Blobs no save names any more.
    const kept = new Set(Object.values(manifest.files));
    for (const { blob } of this.saved.values()) {
      if (!kept.has(blob)) await this.store.removeEntry(blob).catch(() => {});
    }
    this.saved = saved;
  }

  /** A file's whole contents, in place of what it had once written. */
  private async put(name: string, data: Uint8Array): Promise<void> {
    const handle = await this.store.getFileHandle(name, { create: true });
    const writable = await handle.createWritable();
    await writable.write(data as Uint8Array<ArrayBuffer>);
    await writable.close();
  }
}
