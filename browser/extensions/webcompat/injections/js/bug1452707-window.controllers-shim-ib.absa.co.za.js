/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

"use strict";

/**
 * Bug 1452707 - Build site patch for ib.absa.co.za
 * WebCompat issue #16401 - https://webcompat.com/issues/16401
 *
 * The online banking at ib.absa.co.za detect if window.controllers is a
 * non-falsy value to detect if the current browser is Firefox or something
 * else. In bug 1448045, this shim has been disabled for Firefox Nightly 61+,
 * which breaks the UA detection on this site and results in a "Browser
 * unsuppored" error message.
 *
 * This site patch simply sets window.controllers to a string, resulting in
 * their check to work again.
 */

/* globals exportFunction */

console.info(
  "window.controllers has been shimmed for compatibility reasons. See https://webcompat.com/issues/16401 for details."
);

Object.getPrototypeOf(window).wrappedJSObject.controllers = exportFunction(
  () => true,
  window
);
