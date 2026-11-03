// What the app and the user hand each other as files: files and pictures
// the user picks, files the app saves for them or shows them, as Hatter's
// Android platform does with them.

import { Disk } from './disk';

/** A file the user picked, where the app can read it. */
export interface Picked {
  path: string;
  name: string;
  size: number;
}

/**
 * The types a browser tab shows without running anything in it. Other
 * files are saved instead: an SVG or HTML page would run its scripts as
 * this site, with every app's files.
 */
const shown: Record<string, string> = {
  avif: 'image/avif',
  gif: 'image/gif',
  jpeg: 'image/jpeg',
  jpg: 'image/jpeg',
  m4a: 'audio/mp4',
  mp3: 'audio/mpeg',
  mp4: 'video/mp4',
  oga: 'audio/ogg',
  ogg: 'audio/ogg',
  opus: 'audio/ogg',
  pdf: 'application/pdf',
  png: 'image/png',
  txt: 'text/plain; charset=utf-8',
  wav: 'audio/wav',
  webm: 'video/webm',
  webp: 'image/webp',
};

/** Where picked files go, which the page doesn't keep. */
export const cacheDir = '/cache';

let picks = 0;

/** What the user picks with the browser's file picker, none if they don't. */
function choose(accept: string, multiple: boolean, camera = false): Promise<File[]> {
  const input = document.createElement('input');
  input.type = 'file';
  // Any type is no filter.
  input.accept = accept === '*/*' ? '' : accept;
  input.multiple = multiple;
  if (camera) input.capture = 'environment';
  return new Promise((resolve) => {
    input.addEventListener('change', () => resolve([...(input.files ?? [])]));
    input.addEventListener('cancel', () => resolve([]));
    input.click();
  });
}

/**
 * Files the user picks, each copied into the cache. Their paths stay ASCII,
 * for C code that doesn't know the encoding.
 */
export async function pickFiles(disk: Disk, accept: string, multiple: boolean, camera = false): Promise<Picked[]> {
  const picked: Picked[] = [];
  for (const file of await choose(accept, multiple, camera)) {
    const path = `${cacheDir}/picked/${picks++}/${file.name.replace(/[^A-Za-z0-9._-]/g, '_') || 'file'}`;
    disk.add(path, new Uint8Array(await file.arrayBuffer()));
    picked.push({ path, name: file.name, size: file.size });
  }
  return picked;
}

/**
 * A picture the user picks, cut to its middle square and scaled to the
 * first of the sides whose PNG has at most limit bytes, turned the way its
 * camera says. None if they pick none, it isn't one, or no side fits.
 */
export async function pickPicture(sides: Int32Array, limit: number): Promise<Uint8Array | undefined> {
  const [file] = await choose('image/*', false);
  if (!file) return undefined;
  const picture = await createImageBitmap(file).catch(() => undefined);
  if (!picture) return undefined;
  const square = Math.min(picture.width, picture.height);
  const left = Math.floor((picture.width - square) / 2);
  const top = Math.floor((picture.height - square) / 2);
  try {
    for (const side of sides) {
      const canvas = new OffscreenCanvas(side, side);
      const context = canvas.getContext('2d')!;
      context.imageSmoothingQuality = 'high';
      context.drawImage(picture, left, top, square, square, 0, 0, side, side);
      const png = await canvas.convertToBlob({ type: 'image/png' });
      if (png.size <= limit) return new Uint8Array(await png.arrayBuffer());
    }
    return undefined;
  } finally {
    picture.close();
  }
}

/** Gives the user one of the app's files as a download, then deletes it. */
export function saveFile(disk: Disk, path: string, name: string, type: string): void {
  const file = disk.file(path);
  if (!file) return;
  download(new Blob([file.data as Uint8Array<ArrayBuffer>], { type }), name);
  disk.remove(path);
}

/** Shows one of the app's files in a tab of its own, if it's safe to, or else gives it as a download. */
export function openFile(disk: Disk, path: string): void {
  const file = disk.file(path);
  if (!file) return;
  const name = path.slice(path.lastIndexOf('/') + 1);
  const type = shown[name.slice(name.lastIndexOf('.') + 1).toLowerCase()];
  const blob = new Blob([file.data as Uint8Array<ArrayBuffer>], { type: type ?? 'application/octet-stream' });
  if (!type) return download(blob, name);
  const url = URL.createObjectURL(blob);
  window.open(url, '_blank', 'noopener');
  // The tab has it once it's open.
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

function download(blob: Blob, name: string): void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/**
 * The width and height a PNG, JPEG, GIF or WebP picture shows at, turned
 * the way its camera says, from its header alone.
 */
export function imageSize(data: Uint8Array): [number, number] | undefined {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const text = (at: number, length: number) => String.fromCharCode(...data.subarray(at, at + length));
  try {
    if (text(1, 3) === 'PNG') return [view.getUint32(16), view.getUint32(20)];
    if (text(0, 4) === 'GIF8') return [view.getUint16(6, true), view.getUint16(8, true)];
    if (text(0, 4) === 'RIFF' && text(8, 4) === 'WEBP') return webpSize(data, view, text(12, 4));
    if (view.getUint16(0) === 0xffd8) return jpegSize(data, view);
  } catch {
    // Too short for its header.
  }
  return undefined;
}

function webpSize(data: Uint8Array, view: DataView, chunk: string): [number, number] | undefined {
  switch (chunk) {
    case 'VP8 ':
      return [view.getUint16(26, true) & 0x3fff, view.getUint16(28, true) & 0x3fff];
    case 'VP8L': {
      const bits = view.getUint32(21, true);
      return [(bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1];
    }
    case 'VP8X':
      return [(view.getUint32(24, true) & 0xffffff) + 1, (view.getUint32(26, true) >>> 8) + 1];
  }
  return undefined;
}

function jpegSize(data: Uint8Array, view: DataView): [number, number] | undefined {
  let turned = false;
  for (let at = 2; at + 4 <= data.length; ) {
    const marker = view.getUint16(at);
    const length = view.getUint16(at + 2);
    if (marker === 0xffe1) turned ||= exifTurned(data.subarray(at + 4, at + 2 + length));
    // Start of frame, but not a Huffman (C4), arithmetic coding (CC) or JPG extension (C8) table.
    if (marker >= 0xffc0 && marker <= 0xffcf && ![0xffc4, 0xffc8, 0xffcc].includes(marker)) {
      const size: [number, number] = [view.getUint16(at + 7), view.getUint16(at + 5)];
      return turned ? [size[1], size[0]] : size;
    }
    at += 2 + length;
  }
  return undefined;
}

/** Whether an EXIF block says to turn its picture a quarter turn. */
function exifTurned(exif: Uint8Array): boolean {
  if (String.fromCharCode(...exif.subarray(0, 4)) !== 'Exif') return false;
  const tiff = new DataView(exif.buffer, exif.byteOffset + 6, exif.byteLength - 6);
  const little = tiff.getUint16(0) === 0x4949;
  const first = tiff.getUint32(4, little);
  const entries = tiff.getUint16(first, little);
  for (let i = 0; i < entries; i++) {
    const entry = first + 2 + i * 12;
    // Orientations 5 to 8 turn it.
    if (tiff.getUint16(entry, little) === 0x0112) return tiff.getUint16(entry + 8, little) >= 5;
  }
  return false;
}
