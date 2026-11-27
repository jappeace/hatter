import { bootstrapApplication } from '@angular/platform-browser';

import { Root } from './app/app';
import { say, startApp } from './app/wasm';

bootstrapApplication(Root)
  .then(startApp)
  .catch((error) => {
    console.error(error);
    say("This didn't load. Reload the page to try again.");
  });
