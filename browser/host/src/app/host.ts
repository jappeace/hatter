// The page's side of Hatter's UI bridge (UIBridge.h), as Hatter.Browser
// calls it through globalThis.hatter. It follows what Hatter's Android
// platform does with each call.

import { ApplicationRef, ComponentRef, EnvironmentInjector, Injectable, createComponent, inject } from '@angular/core';

import { CallAudio } from './callaudio';
import { CallVideo } from './callvideo';
import { Disk } from './disk';
import { imageSize, openFile, pickFiles, pickPicture, saveFile } from './files';
import {
  HatterNode,
  ImageNode,
  LazyColumnNode,
  NodeType,
  SwitchNode,
  TextInputNode,
  WebViewNode,
  nodeComponents,
} from './nodes';
import { Popups } from './popups';

/** What Hatter.Browser gives the page to call. */
export interface App {
  render(): Promise<void>;
  event(callback: number): Promise<void>;
  text(callback: number, value: string): Promise<void>;
  scroll(callback: number, position: number): Promise<void>;
  back(): Promise<number>;
  dialog(request: number, action: number): Promise<void>;
  sheet(request: number, action: number): Promise<void>;
  picked(path: string, name: string, size: number): Promise<void>;
  picture(png: Uint8Array): Promise<void>;
  callFrame(samples: Int16Array): Promise<void>;
  cameraFrame(width: number, height: number, i420: Uint8Array): Promise<void>;
  size(width: number, height: number): Promise<void>;
  shown(shown: boolean): Promise<void>;
  bind(list: number, row: number, position: number): number;
  key(list: number, position: number): bigint;
}

const enum Prop {
  Text = 0,
  Color = 1,
  Hint = 2,
  BackgroundColor = 3,
  ImageResource = 4,
  ImageFile = 5,
  WebViewUrl = 6,
  ImageStream = 7,
}

const enum NumProp {
  FontSize = 0,
  Padding = 1,
  InputType = 2,
  Gravity = 3,
  ScaleType = 4,
  TranslateX = 9,
  TranslateY = 10,
  AutoFocus = 11,
  TouchPassthrough = 12,
  Width = 13,
  Height = 14,
  Weight = 15,
  AlignSelf = 16,
  Margin = 17,
  MaxWidth = 18,
  CornerRadius = 19,
  KeepAtEnd = 20,
  MaxLines = 21,
  ItemCount = 22,
  ScrollToEnd = 23,
  FontStyle = 24,
  PaddingY = 25,
  CornerTopLeft = 26,
  CornerTopRight = 27,
  CornerBottomRight = 28,
  CornerBottomLeft = 29,
  Checked = 30,
}

const enum EventType {
  Click = 0,
  TextChange = 1,
  LongPress = 2,
  Scrolled = 3,
}

/** Where a list is, as Hatter's ListPosition numbers it. */
const enum ListPosition {
  Start = 0,
  Middle = 1,
  End = 2,
}

/** The value Hatter sends for no limit. */
const unlimited = 2147483647;

/** Sizes the app gave a node, NaN where it gave none. */
interface Layout {
  width: number;
  height: number;
  weight: number;
  alignSelf: number;
  margin: number;
}

interface Node {
  type: NodeType;
  ref: ComponentRef<HatterNode>;
  parent?: Node;
  layout: Layout;
  handlers: Map<EventType, number>;
  /** Whether presses on it are set up. */
  pressable?: boolean;
  /** For a scrolling view kept at its end while at it. */
  pinned?: boolean;
  /** For a lazy column: its rows by item key, rows free for other items,
   * and how many items it has. */
  rows?: Map<bigint, number>;
  spare?: number[];
  count?: number;
  /** For a list whose position the app watches: the last it was told. */
  position?: ListPosition;
  /** An object URL this node shows, to let go of with it. */
  objectUrl?: string;
}

const parentLayouts = new Set([NodeType.Column, NodeType.ScrollView, NodeType.LazyColumn]);
const rowLayouts = new Set([NodeType.Row, NodeType.HorizontalScrollView]);
const scrolling = new Set([NodeType.ScrollView, NodeType.HorizontalScrollView, NodeType.LazyColumn]);

/** Hatter's #AARRGGBB (or #RGB, #RRGGBB) as CSS. */
function cssColor(value: string): string {
  return /^#[0-9a-fA-F]{8}$/.test(value) ? `#${value.slice(3)}${value.slice(1, 3)}` : value;
}

@Injectable({ providedIn: 'root' })
export class Host {
  private readonly appRef = inject(ApplicationRef);
  private readonly injector = inject(EnvironmentInjector);
  private readonly popups = inject(Popups);
  private readonly nodes = new Map<number, Node>();
  private nextId = 1;
  private root?: Node;
  private app?: App;
  private rendering = false;
  /** Where the app's root goes. */
  rootElement?: HTMLElement;
  /** The app's files. */
  disk?: Disk;
  private readonly callAudio = new CallAudio();
  private readonly callVideo = new CallVideo();

  constructor() {
    (globalThis as unknown as { hatter: Host }).hatter = this;
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => this.redraw());
  }

  start(app: App): void {
    this.app = app;
    // The browser's Back goes to the app first, as Android's does: an
    // entry of our own to come back to, kept while the app handles it.
    history.pushState(null, '');
    // A dialog or sheet closes first, as on Android.
    addEventListener('popstate', async () => {
      if (this.popups.close() || (await app.back())) history.pushState(null, '');
      else history.back();
    });
    // Shown while the tab is, as Android's activity between Start and Stop.
    addEventListener('visibilitychange', () => void app.shown(document.visibilityState === 'visible'));
    // The app lays out for the page's size, so it draws again for a new one.
    addEventListener('resize', () => void app.size(innerWidth, innerHeight).then(() => this.redraw()));
  }

  /** Renders on the next frame, once however often it's asked. */
  redraw(): void {
    if (this.rendering || !this.app) return;
    this.rendering = true;
    requestAnimationFrame(() => {
      this.rendering = false;
      void this.app?.render();
    });
  }

  /** A dialog with up to three buttons. A button the app doesn't give is empty. */
  dialog(request: number, title: string, message: string, button1: string, button2: string, button3: string): void {
    void this.popups.dialog(title, message, [button1, button2, button3]).then((action) => this.app?.dialog(request, action));
  }

  /** A bottom sheet of items, one a line. */
  sheet(request: number, title: string, items: string): void {
    void this.popups.sheet(title, items.split('\n')).then((action) => this.app?.sheet(request, action));
  }

  /** Files the user picks, of a MIME type, or a picture they take. */
  pickFiles(type: string, multiple: boolean, camera: boolean): void {
    if (!this.disk) return;
    void pickFiles(this.disk, type, multiple, camera).then(async (files) => {
      for (const { path, name, size } of files) await this.app?.picked(path, name, size);
    });
  }

  pickPicture(sides: Int32Array, limit: number): void {
    void pickPicture(sides, limit).then((png) => png && this.app?.picture(png));
  }

  saveFile(path: string, name: string, type: string): void {
    if (this.disk) saveFile(this.disk, path, name, type);
  }

  openFile(path: string): void {
    if (this.disk) openFile(this.disk, path);
  }

  /** A picture file's width and height, written where the app asks, or false if it isn't one. */
  imageSize(path: string, memory: DataView, width: number, height: number): boolean {
    const file = this.disk?.file(path);
    const size = file && imageSize(file.data);
    if (!size) return false;
    memory.setInt32(width, size[0], true);
    memory.setInt32(height, size[1], true);
    return true;
  }

  callAudioStart(rate: number, frameSamples: number): void {
    this.callAudio.start(rate, frameSamples, (frame) => void this.app?.callFrame(frame));
  }

  callAudioStop(): void {
    this.callAudio.stop();
  }

  callAudioPlay(rate: number, channels: number, samples: Int16Array): number {
    return this.callAudio.play(rate, channels, samples);
  }

  callAudioLatency(): number {
    return this.callAudio.latency();
  }

  callAudioTone(tone: number): void {
    this.callAudio.tone(tone);
  }

  cameraStart(front: boolean): void {
    this.callVideo.startCamera(front, (width, height, i420) => void this.app?.cameraFrame(width, height, i420));
  }

  cameraStop(): void {
    this.callVideo.stopCamera();
  }

  showFrame(key: string, width: number, height: number, i420: Uint8Array<ArrayBuffer>): void {
    this.callVideo.show(key, width, height, i420);
  }

  createNode(type: NodeType): number {
    const component = nodeComponents[type];
    if (!component) return 0;
    const ref: ComponentRef<HatterNode> = createComponent<HatterNode>(component, { environmentInjector: this.injector });
    this.appRef.attachView(ref.hostView);
    ref.location.nativeElement.style.boxSizing = 'border-box';
    const id = this.nextId++;
    const node: Node = {
      type,
      ref,
      layout: { width: NaN, height: NaN, weight: NaN, alignSelf: NaN, margin: NaN },
      handlers: new Map(),
    };
    this.nodes.set(id, node);
    if (type === NodeType.TextInput) {
      (ref.instance as TextInputNode).onText = (value) => {
        const callback = node.handlers.get(EventType.TextChange);
        if (callback !== undefined) void this.app?.text(callback, value);
      };
    }
    if (type === NodeType.Switch) {
      (ref.instance as SwitchNode).onFlip = () => {
        const callback = node.handlers.get(EventType.Click);
        if (callback !== undefined) void this.app?.event(callback);
      };
    }
    if (type === NodeType.LazyColumn) {
      node.rows = new Map();
      node.spare = [];
    }
    if (scrolling.has(type)) {
      ref.location.nativeElement.addEventListener('scroll', () => this.scrolled(node), { passive: true });
    }
    return id;
  }

  setStrProp(id: number, prop: Prop, value: string): void {
    const node = this.nodes.get(id);
    if (!node) return;
    const instance = node.ref.instance;
    const style = instance.element.style;
    switch (prop) {
      case Prop.Text:
        if (instance instanceof TextInputNode) instance.setText(value);
        else instance.text.set(value);
        break;
      case Prop.Color:
        style.color = cssColor(value);
        break;
      case Prop.Hint:
        if (instance instanceof TextInputNode) instance.hint.set(value);
        break;
      case Prop.BackgroundColor:
        style.backgroundColor = cssColor(value);
        break;
      case Prop.ImageResource:
        if (instance instanceof ImageNode) instance.showResource(value);
        break;
      case Prop.ImageFile: {
        const file = this.disk?.file(value);
        if (file) this.showBytes(node, file.data as Uint8Array<ArrayBuffer>);
        break;
      }
      case Prop.ImageStream:
        if (instance instanceof ImageNode) this.callVideo.watch(value, instance);
        break;
      case Prop.WebViewUrl:
        if (instance instanceof WebViewNode) instance.load(value);
        break;
      default:
        console.warn(`Hatter: no string property ${prop} in browsers`);
    }
  }

  setNumProp(id: number, prop: NumProp, value: number): void {
    const node = this.nodes.get(id);
    if (!node) return;
    const instance = node.ref.instance;
    const element = instance.element;
    const style = element.style;
    const px = (n: number) => `${n}px`;
    switch (prop) {
      case NumProp.FontSize:
        style.fontSize = px(value);
        break;
      case NumProp.FontStyle:
        style.fontWeight = value & 1 ? '700' : '';
        style.fontFamily = value & 2 ? 'monospace' : '';
        style.fontStyle = value & 4 ? 'italic' : '';
        break;
      case NumProp.Padding:
        style.padding = value ? px(value) : '';
        break;
      case NumProp.Checked:
        if (instance instanceof SwitchNode) instance.checked.set(value !== 0);
        break;
      case NumProp.PaddingY:
        style.paddingTop = style.paddingBottom = px(value);
        break;
      case NumProp.CornerTopLeft:
        style.borderTopLeftRadius = Number.isNaN(value) ? '' : px(value);
        break;
      case NumProp.CornerTopRight:
        style.borderTopRightRadius = Number.isNaN(value) ? '' : px(value);
        break;
      case NumProp.CornerBottomRight:
        style.borderBottomRightRadius = Number.isNaN(value) ? '' : px(value);
        break;
      case NumProp.CornerBottomLeft:
        style.borderBottomLeftRadius = Number.isNaN(value) ? '' : px(value);
        break;
      case NumProp.InputType:
        if (instance instanceof TextInputNode) instance.inputType.set(value);
        break;
      case NumProp.Gravity: {
        const align = ['', 'center', 'flex-end'][value] ?? '';
        if (node.type === NodeType.Column) style.alignItems = align;
        else if (node.type === NodeType.Row) style.justifyContent = align;
        else if (node.type !== NodeType.ScrollView && node.type !== NodeType.Stack) {
          style.textAlign = ['', 'center', 'end'][value] ?? '';
        }
        break;
      }
      case NumProp.ScaleType:
        if (instance instanceof ImageNode) instance.fit.set(['contain', 'cover', 'none'][value] ?? 'contain');
        break;
      case NumProp.TranslateX:
      case NumProp.TranslateY:
        style.setProperty(prop === NumProp.TranslateX ? '--hatter-x' : '--hatter-y', px(value));
        style.translate = 'var(--hatter-x, 0) var(--hatter-y, 0)';
        break;
      case NumProp.AutoFocus:
        if (instance instanceof TextInputNode) instance.focus();
        break;
      case NumProp.TouchPassthrough:
        style.pointerEvents = value === 1 ? 'none' : '';
        break;
      case NumProp.Width:
      case NumProp.Height:
      case NumProp.Weight:
      case NumProp.AlignSelf:
      case NumProp.Margin: {
        const field = (['width', 'height', 'weight', 'alignSelf', 'margin'] as const)[prop - NumProp.Width];
        node.layout[field] = value;
        this.applyLayout(node);
        break;
      }
      case NumProp.MaxWidth:
        style.maxWidth = value >= unlimited ? '' : px(value);
        break;
      case NumProp.CornerRadius:
        style.borderRadius = value > 0 ? px(value) : '';
        style.overflow = value > 0 ? 'hidden' : '';
        break;
      case NumProp.MaxLines:
        if (value >= unlimited) {
          style.display = style.webkitLineClamp = style.webkitBoxOrient = style.overflow = '';
        } else {
          style.display = '-webkit-box';
          style.webkitLineClamp = String(value);
          style.webkitBoxOrient = 'vertical';
          style.overflow = 'hidden';
        }
        break;
      case NumProp.KeepAtEnd:
        if (value === 1 && (node.type === NodeType.ScrollView || node.type === NodeType.LazyColumn)) this.keepAtEnd(node);
        break;
      case NumProp.ItemCount:
        if (node.type === NodeType.LazyColumn) {
          node.count = value;
          // Android binds the rows once it lays the list out, after the
          // render that set the count.
          queueMicrotask(() => this.bindRows(id, node));
        }
        break;
      case NumProp.ScrollToEnd:
        if (scrolling.has(node.type)) element.scrollTo({ top: element.scrollHeight, behavior: 'smooth' });
        break;
      default:
        console.warn(`Hatter: no number property ${prop} in browsers`);
    }
  }

  setImageData(id: number, bytes: Uint8Array<ArrayBuffer>): void {
    const node = this.nodes.get(id);
    if (node) this.showBytes(node, bytes);
  }

  private showBytes(node: Node, bytes: Uint8Array<ArrayBuffer>): void {
    if (!(node.ref.instance instanceof ImageNode)) return;
    if (node.objectUrl) URL.revokeObjectURL(node.objectUrl);
    node.objectUrl = URL.createObjectURL(new Blob([bytes]));
    node.ref.instance.showPicture(node.objectUrl);
  }

  setHandler(id: number, event: EventType, callback: number): void {
    const node = this.nodes.get(id);
    if (!node) return;
    const element = node.ref.instance.element;
    const first = !node.handlers.has(event);
    node.handlers.set(event, callback);
    if (!first) return;
    if (event === EventType.Click || event === EventType.LongPress) this.pressable(node);
    switch (event) {
      case EventType.Click:
        // A switch tells of its flips itself.
        if (node.type === NodeType.Switch) break;
        element.addEventListener('click', (e) => {
          e.stopPropagation();
          void this.app?.event(node.handlers.get(EventType.Click)!);
        });
        // A button takes the keyboard itself.
        if (node.type === NodeType.Button) break;
        element.style.cursor = 'pointer';
        element.tabIndex = 0;
        element.role = 'button';
        element.addEventListener('keydown', (e) => {
          // Keys typed into something inside it aren't taps.
          if (e.target !== element || (e.key !== 'Enter' && e.key !== ' ')) return;
          e.preventDefault();
          element.click();
        });
        break;
      case EventType.LongPress:
        // A long press on a touch screen, or the secondary button.
        element.addEventListener('contextmenu', (e) => {
          e.preventDefault();
          e.stopPropagation();
          void this.app?.event(node.handlers.get(EventType.LongPress)!);
        });
        break;
      case EventType.Scrolled:
        node.position = ListPosition.End;
        break;
    }
  }

  addChild(parentId: number, childId: number): void {
    const parent = this.nodes.get(parentId);
    const child = this.nodes.get(childId);
    if (!parent || !child) return;
    child.parent = parent;
    parent.ref.instance.slot.appendChild(child.ref.instance.element);
    this.applyLayout(child);
  }

  removeChild(_parentId: number, childId: number): void {
    const child = this.nodes.get(childId);
    if (!child) return;
    child.ref.instance.element.remove();
    child.parent = undefined;
  }

  destroyNode(id: number): void {
    const node = this.nodes.get(id);
    if (!node) return;
    this.nodes.delete(id);
    if (node.objectUrl) URL.revokeObjectURL(node.objectUrl);
    if (node.ref.instance instanceof ImageNode) node.ref.instance.stopStream();
    node.ref.instance.element.remove();
    node.ref.destroy();
  }

  setRoot(id: number): void {
    const node = this.nodes.get(id);
    if (!node || !this.rootElement) return;
    this.root?.ref.instance.element.remove();
    this.root = node;
    node.parent = undefined;
    const style = node.ref.instance.element.style;
    style.width = style.height = '100%';
    this.rootElement.replaceChildren(node.ref.instance.element);
  }

  clear(): void {
    for (const id of [...this.nodes.keys()]) this.destroyNode(id);
    this.root = undefined;
  }

  darkMode(): boolean {
    return matchMedia('(prefers-color-scheme: dark)').matches;
  }

  clock24(): boolean {
    const parts = new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).resolvedOptions();
    return parts.hourCycle === 'h23' || parts.hourCycle === 'h24';
  }

  copyText(text: string): void {
    // Said once it's done, as Android's system says so, and browsers don't.
    void navigator.clipboard?.writeText(text).then(() => this.popups.note('Copied'));
  }

  openUri(uri: string): void {
    window.open(uri, '_blank', 'noopener');
  }

  /**
   * A press on a node the app handles presses of is only that, as on
   * Android: it doesn't take the keyboard from a text field, or select text.
   */
  private pressable(node: Node): void {
    if (node.pressable) return;
    node.pressable = true;
    const element = node.ref.instance.element;
    element.style.userSelect = 'none';
    element.style.setProperty('-webkit-touch-callout', 'none');
    element.addEventListener('mousedown', (e) => {
      // A field inside it still takes the keyboard.
      if (!(e.target as Element).closest('input, textarea')) e.preventDefault();
    });
  }

  /**
   * As Android's LinearLayout and FrameLayout place a child: what its parent
   * gives it unless the app said otherwise.
   */
  private applyLayout(node: Node): void {
    const style = node.ref.instance.element.style;
    const { width, height, weight, alignSelf, margin } = node.layout;
    const parent = node.parent?.type;
    const px = (n: number) => (n === -1 ? '100%' : `${n}px`);
    style.width = isNaN(width) ? '' : px(width);
    style.height = isNaN(height) ? '' : px(height);
    node.ref.instance.element.classList.toggle('sized', !isNaN(width) || !isNaN(height));
    style.flexGrow = isNaN(weight) ? '' : String(weight);
    // Android takes space its children lack from the weighted ones first.
    style.flexShrink = isNaN(weight) ? '' : '1000';
    style.minWidth = style.minHeight = isNaN(weight) ? '' : '0';
    style.margin = isNaN(margin) ? '' : `${margin}px`;
    style.alignSelf = style.justifySelf = '';
    // A stack's children all take its one cell, over each other.
    style.gridArea = parent === NodeType.Stack ? '1 / 1' : '';
    const along = ['flex-start', 'center', 'flex-end', 'stretch'];
    if (parent !== undefined && parentLayouts.has(parent)) {
      // Children fill the column's width unless they say how wide.
      style.alignSelf = !isNaN(alignSelf) ? along[alignSelf] : isNaN(width) ? 'stretch' : '';
    } else if (parent !== undefined && rowLayouts.has(parent)) {
      style.alignSelf = isNaN(alignSelf) ? '' : along[alignSelf];
    } else if (parent === NodeType.Stack) {
      const both = isNaN(alignSelf) ? 'stretch' : ['start', 'center', 'end', 'stretch'][alignSelf];
      style.alignSelf = style.justifySelf = both;
    }
  }

  /** Keeps a scrolling view at its end while it's there. */
  private keepAtEnd(node: Node): void {
    if (node.pinned !== undefined) return;
    const element = node.ref.instance.element;
    const slot = node.ref.instance.slot;
    slot.style.minHeight = '100%';
    slot.style.justifyContent = 'flex-end';
    node.pinned = true;
    element.addEventListener('scroll', () => {
      node.pinned = element.scrollTop + element.clientHeight >= element.scrollHeight - 1;
    }, { passive: true });
    new ResizeObserver(() => {
      if (node.pinned) element.scrollTop = element.scrollHeight;
    }).observe(slot);
  }

  /** Tells the app where a list it watches is, when that changes. */
  private scrolled(node: Node): void {
    const callback = node.handlers.get(EventType.Scrolled);
    if (callback === undefined) return;
    const element = node.ref.instance.element;
    const position = element.scrollTop + element.clientHeight >= element.scrollHeight - 1
      ? ListPosition.End
      : element.scrollTop <= 0 ? ListPosition.Start : ListPosition.Middle;
    if (position === node.position) return;
    node.position = position;
    void this.app?.scroll(callback, position);
  }

  /**
   * Binds every item of a lazy column to a row: the same row for the same
   * item key, so items keep their place when others come before them, and
   * rows of items gone for new ones, as Android reuses a list's rows.
   */
  private bindRows(id: number, node: Node): void {
    const app = this.app;
    if (!app || !this.nodes.has(id) || node.count === undefined || !node.rows || !node.spare) return;
    const keys = Array.from({ length: node.count }, (_, position) => app.key(id, position));
    const kept = new Set(keys);
    const spare = [...node.spare, ...[...node.rows].filter(([key]) => !kept.has(key)).map(([, row]) => row)];
    const rows = new Map<bigint, number>();
    const elements: HTMLElement[] = [];
    keys.forEach((key, position) => {
      const row = app.bind(id, node.rows!.get(key) ?? spare.pop() ?? 0, position);
      const bound = this.nodes.get(row);
      if (!bound) return;
      rows.set(key, row);
      bound.parent = node;
      this.applyLayout(bound);
      elements.push(bound.ref.instance.element);
    });
    node.rows = rows;
    node.spare = spare;
    node.ref.instance.slot.replaceChildren(...elements);
  }
}
