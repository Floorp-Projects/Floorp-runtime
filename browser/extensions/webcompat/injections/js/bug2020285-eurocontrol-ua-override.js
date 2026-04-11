/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

"use strict";

/**
 * Bug 2020285 - UA override for www.public.nm.eurocontrol.int
 *
 * The GWT-based portal checks navigator.userAgent in dynamically-created
 * about:blank subframes, so we need to override it there too.
 */
if (!navigator.userAgent.includes("Chrome")) {
  console.info(
    "The user agent has been overridden for compatibility reasons. See https://bugzilla.mozilla.org/show_bug.cgi?id=2020285 for details."
  );

  const CHROME_UA = `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36`;

  const nav = Object.getPrototypeOf(navigator);
  const ua = Object.getOwnPropertyDescriptor(nav, "userAgent");
  ua.get = () => CHROME_UA;
  Object.defineProperty(nav, "userAgent", ua);
}
