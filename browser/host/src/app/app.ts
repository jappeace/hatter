import { Component, ElementRef, inject } from '@angular/core';

import { Host } from './host';

/** Where the app shows. */
@Component({
  selector: 'hatter-root',
  template: '',
  styles: ':host { display: block; height: 100%; }',
})
export class Root {
  constructor() {
    inject(Host).rootElement = inject(ElementRef).nativeElement;
  }
}
