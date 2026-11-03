import { bootstrapApplication } from '@angular/platform-browser';

import { Root } from './app/app';
import { startApp } from './app/wasm';

bootstrapApplication(Root)
  .then(startApp)
  .catch((error) => console.error(error));
