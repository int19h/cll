/* Registers the offline reader (service worker) of this copy of the book. */
(function () {
  'use strict';
  if (!('serviceWorker' in navigator) || !window.isSecureContext) { return; }
  if (location.protocol !== 'https:' && location.protocol !== 'http:') { return; }
  var script = document.currentScript;
  if (!script || !script.src) { return; }
  // This file is <book folder>/assets/scripts/offline.js.
  var root = new URL('../../', script.src).href;
  // Pages outside the book folder (the comparison pages) load this file
  // too. They must not install the book.
  if (new URL('./', location.href).href !== root) { return; }
  if (navigator.connection && navigator.connection.saveData) { return; }
  function register() {
    navigator.serviceWorker.register(root + 'sw.js').then(function () {
      return navigator.serviceWorker.ready;
    }).then(function () {
      document.documentElement.setAttribute('data-offline', 'ready');
    }).catch(function () {});
  }
  if (document.readyState === 'complete') { register(); }
  else { window.addEventListener('load', register); }
}());
