// A component for each kind of Hatter node. The host sets their properties,
// lays them out and puts their children in their slot.

import { TextFieldModule } from '@angular/cdk/text-field';
import { Component, ElementRef, Injector, afterNextRender, inject, signal, viewChild } from '@angular/core';
import { DomSanitizer, SafeHtml, SafeResourceUrl } from '@angular/platform-browser';
import { MatButton } from '@angular/material/button';
import { MatFormField } from '@angular/material/form-field';
import { MatInput } from '@angular/material/input';
import { MatSlideToggle } from '@angular/material/slide-toggle';

/** The node types of Hatter's UIBridge.h. */
export const enum NodeType {
  Text = 0,
  Button = 1,
  Column = 2,
  Row = 3,
  TextInput = 4,
  ScrollView = 5,
  Image = 6,
  MapView = 7,
  WebView = 8,
  Stack = 9,
  HorizontalScrollView = 10,
  LazyColumn = 11,
  Switch = 12,
}

export abstract class HatterNode {
  readonly element: HTMLElement = inject(ElementRef).nativeElement;
  /** Where the node's children go. */
  slot: HTMLElement = this.element;
  /** Text, for those that show it. */
  readonly text = signal('');
}

@Component({
  selector: 'hatter-text',
  template: '{{ text() }}',
  // A line as tall as its font makes it, as Android's, whatever the page's is.
  styles: ':host { display: block; white-space: pre-wrap; overflow-wrap: anywhere; line-height: normal; }',
})
export class TextNode extends HatterNode {}

@Component({
  selector: 'hatter-button',
  imports: [MatButton],
  template: '<button matButton="filled">{{ text() }}</button>',
  styles: ':host { display: block; } button { width: 100%; }',
})
export class ButtonNode extends HatterNode {}

/** On or off as the app says; a flip tells the app. */
@Component({
  selector: 'hatter-switch',
  imports: [MatSlideToggle],
  // Its own taps, not those of what it's in.
  template: '<mat-slide-toggle [checked]="checked()" (change)="onFlip()" (click)="$event.stopPropagation()" />',
  styles: ':host { display: block; }',
})
export class SwitchNode extends HatterNode {
  readonly checked = signal(false);
  /** Called as the user flips it. */
  onFlip: () => void = () => {};
}

/**
 * Text the app sets back to what the user typed doesn't overwrite what they
 * typed since.
 */
@Component({
  selector: 'hatter-text-input',
  imports: [MatFormField, MatInput, TextFieldModule],
  template: `
    <mat-form-field appearance="outline" subscriptSizing="dynamic">
      @if (inputType() === 2) {
        <textarea #field matInput cdkTextareaAutosize [value]="text()" [placeholder]="hint()" (input)="typed($event)"></textarea>
      } @else {
        <input #field matInput [type]="inputType() === 3 ? 'password' : 'text'"
               [attr.inputmode]="inputType() === 1 ? 'decimal' : null"
               [value]="text()" [placeholder]="hint()" (input)="typed($event)" />
      }
    </mat-form-field>`,
  styles: ':host { display: block; } mat-form-field { width: 100%; }',
})
export class TextInputNode extends HatterNode {
  readonly hint = signal('');
  readonly inputType = signal(0);
  /** Called with what the user typed. */
  onText: (value: string) => void = () => {};
  private readonly sent: string[] = [];

  setText(value: string): void {
    const echo = this.sent.indexOf(value);
    if (echo >= 0) {
      this.sent.splice(0, echo + 1);
      return;
    }
    this.sent.length = 0;
    const field = this.field()?.nativeElement;
    if (field && field.value !== value) field.value = value;
    this.text.set(value);
  }

  focus(): void {
    afterNextRender(() => this.field()?.nativeElement.focus(), { injector: this.injector });
  }

  protected typed(event: Event): void {
    const value = (event.target as HTMLInputElement).value;
    this.sent.push(value);
    this.onText(value);
  }

  private readonly injector = inject(Injector);
  private readonly field = viewChild<ElementRef<HTMLInputElement | HTMLTextAreaElement>>('field');
}

/** The app's resources by name, as SVG markup. */
const resources = new Map<string, Promise<string>>();

/**
 * A picture, or one of the app's resources (res/<name>.svg), drawn inline
 * so that it takes the colour of the text around it, as Android tints them.
 * A resource is 24 pixels square, centred, unless the app sizes the node
 * (the host marks it sized), and padding goes around it. A stream's frames
 * are drawn on a canvas.
 */
@Component({
  selector: 'hatter-image',
  template: `
    @if (svg(); as markup) {
      <span [innerHTML]="markup"></span>
    } @else if (source()) {
      <img [src]="source()" [style.object-fit]="fit()" alt="" />
    } @else if (streaming()) {
      <canvas #canvas [style.object-fit]="fit()"></canvas>
    }`,
  styles: `
    :host { display: block; }
    img, canvas, span, span ::ng-deep svg { display: block; width: 100%; height: 100%; }
    :host(.resource:not(.sized)) span { width: 24px; height: 24px; margin: 0 auto; }`,
  host: { '[class.resource]': 'svg() !== null' },
})
export class ImageNode extends HatterNode {
  private readonly sanitizer = inject(DomSanitizer);
  readonly source = signal('');
  readonly fit = signal('contain');
  readonly svg = signal<SafeHtml | null>(null);
  readonly streaming = signal(false);
  private readonly canvas = viewChild<ElementRef<HTMLCanvasElement>>('canvas');
  private shown = '';
  /** The stream it shows, if it shows one. */
  stream?: string;

  showResource(name: string): void {
    this.stopStream();
    this.shown = name;
    if (!resources.has(name)) {
      resources.set(name, fetch(`res/${name}.svg`).then((r) => (r.ok ? r.text() : '')));
    }
    void resources.get(name)!.then((markup) => {
      // The app's own files.
      if (this.shown === name) this.svg.set(markup ? this.sanitizer.bypassSecurityTrustHtml(markup) : null);
    });
  }

  showPicture(url: string): void {
    this.stopStream();
    this.shown = '';
    this.svg.set(null);
    this.source.set(url);
  }

  showStream(key: string): void {
    this.shown = '';
    this.svg.set(null);
    this.source.set('');
    this.stream = key;
    this.streaming.set(true);
  }

  /** A stream's frame, in place of the last. */
  draw(frame: VideoFrame): void {
    const canvas = this.canvas()?.nativeElement;
    if (!canvas) return;
    if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
      canvas.width = frame.displayWidth;
      canvas.height = frame.displayHeight;
    }
    canvas.getContext('2d')?.drawImage(frame, 0, 0);
  }

  /** Stops showing a stream, which then lets go of it. */
  stopStream(): void {
    this.stream = undefined;
    this.streaming.set(false);
  }
}

@Component({
  selector: 'hatter-web-view',
  template: '<iframe [src]="url()"></iframe>',
  styles: ':host { display: block; } iframe { width: 100%; height: 100%; border: 0; }',
})
export class WebViewNode extends HatterNode {
  private readonly sanitizer = inject(DomSanitizer);
  readonly url = signal<SafeResourceUrl>('');

  /** The app chose the page. */
  load(url: string): void {
    this.url.set(this.sanitizer.bypassSecurityTrustResourceUrl(url));
  }
}

@Component({ selector: 'hatter-column', template: '', styles: ':host { display: flex; flex-direction: column; }' })
export class ColumnNode extends HatterNode {}

@Component({ selector: 'hatter-row', template: '', styles: ':host { display: flex; flex-direction: row; align-items: flex-start; }' })
export class RowNode extends HatterNode {}

@Component({ selector: 'hatter-stack', template: '', styles: ':host { display: grid; }' })
export class StackNode extends HatterNode {}

/** A scrolling view, with its children in a column or row inside. */
abstract class ScrollingNode extends HatterNode {
  constructor(direction: 'column' | 'row') {
    super();
    this.slot = document.createElement('div');
    this.slot.style.display = 'flex';
    this.slot.style.flexDirection = direction;
    this.element.appendChild(this.slot);
  }
}

@Component({ selector: 'hatter-scroll-view', template: '', styles: ':host { display: block; overflow-y: auto; }' })
export class ScrollViewNode extends ScrollingNode {
  constructor() {
    super('column');
  }
}

@Component({ selector: 'hatter-horizontal-scroll-view', template: '', styles: ':host { display: block; overflow-x: auto; }' })
export class HorizontalScrollViewNode extends ScrollingNode {
  constructor() {
    super('row');
  }
}

@Component({ selector: 'hatter-lazy-column', template: '', styles: ':host { display: block; overflow-y: auto; }' })
export class LazyColumnNode extends ScrollingNode {
  constructor() {
    super('column');
  }
}

@Component({
  selector: 'hatter-map-view',
  template: 'Map',
  styles: ':host { display: grid; place-items: center; background: var(--mat-sys-surface-variant); }',
})
export class MapViewNode extends HatterNode {}

export const nodeComponents = {
  [NodeType.Text]: TextNode,
  [NodeType.Button]: ButtonNode,
  [NodeType.Column]: ColumnNode,
  [NodeType.Row]: RowNode,
  [NodeType.TextInput]: TextInputNode,
  [NodeType.ScrollView]: ScrollViewNode,
  [NodeType.Image]: ImageNode,
  [NodeType.MapView]: MapViewNode,
  [NodeType.WebView]: WebViewNode,
  [NodeType.Stack]: StackNode,
  [NodeType.HorizontalScrollView]: HorizontalScrollViewNode,
  [NodeType.LazyColumn]: LazyColumnNode,
  [NodeType.Switch]: SwitchNode,
} as const;
