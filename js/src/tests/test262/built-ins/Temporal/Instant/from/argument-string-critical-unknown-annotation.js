// |reftest| shell-option(--enable-temporal) skip-if(!this.hasOwnProperty('Temporal')||!xulRuntime.shell) -- Temporal is not enabled unconditionally, requires shell-options
// Copyright (C) 2022 Igalia, S.L. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
esid: sec-temporal.instant.from
description: Unknown annotations with critical flag are rejected
features: [Temporal]
---*/

const invalidStrings = [
  "1970-01-01T00:00Z[!foo=bar]",
  "1970-01-01T00:00Z[UTC][!foo=bar]",
  "1970-01-01T00:00Z[u-ca=iso8601][!foo=bar]",
  "1970-01-01T00:00Z[UTC][!foo=bar][u-ca=iso8601]",
  "1970-01-01T00:00Z[foo=bar][!_foo-bar0=Dont-Ignore-This-99999999999]",
];

invalidStrings.forEach((arg) => {
  assert.throws(
    RangeError,
    () => Temporal.Instant.from(arg),
    `reject unknown annotation with critical flag: ${arg}`
  );
});

reportCompare(0, 0);
