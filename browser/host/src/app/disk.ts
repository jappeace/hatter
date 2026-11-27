// The app's files by their paths, as the app names them: the WASI
// directories it gets, and what is in them.

import { Directory, File, Inode } from '@bjorn3/browser_wasi_shim';

export class Disk {
  /**
   * @param roots each directory the app gets, by its path
   * @param changed called when the page changes the app's files
   */
  constructor(
    private readonly roots: Map<string, Map<string, Inode>>,
    private readonly changed: () => void,
  ) {}

  /** The file at a path, if there is one. */
  file(path: string): File | undefined {
    const [contents, name] = this.place(path) ?? [];
    const inode = name === undefined ? undefined : contents?.get(name);
    return inode instanceof File ? inode : undefined;
  }

  /** Makes a file at a path, with the directories it's in. */
  add(path: string, data: Uint8Array): void {
    const [contents, name] = this.place(path, true) ?? [];
    if (!contents || name === undefined) throw new Error(`No directory for ${path}`);
    contents.set(name, new File(data));
    this.changed();
  }

  remove(path: string): void {
    const [contents, name] = this.place(path) ?? [];
    if (name !== undefined && contents?.delete(name)) this.changed();
  }

  /** The directory a path is in, made if asked, and its last part. */
  private place(path: string, make = false): [Map<string, Inode>, string] | undefined {
    for (const [root, top] of this.roots) {
      if (!path.startsWith(root + '/')) continue;
      const parts = path.slice(root.length + 1).split('/');
      const name = parts.pop()!;
      let contents = top;
      for (const part of parts) {
        let child = contents.get(part);
        if (!(child instanceof Directory) && make) {
          child = new Directory(new Map());
          contents.set(part, child);
        }
        if (!(child instanceof Directory)) return undefined;
        contents = child.contents;
      }
      return [contents, name];
    }
    return undefined;
  }
}
