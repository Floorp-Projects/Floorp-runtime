// |reftest| shell-option(--enable-temporal) skip-if(!this.hasOwnProperty('Temporal')||!xulRuntime.shell) -- Temporal is not enabled unconditionally, requires shell-options
// Copyright (C) 2023 Igalia, S.L. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
esid: sec-temporal.plaintime.prototype.equals
description: >
  More than one calendar annotation is not syntactical if any have the criical
  flag
features: [Temporal]
---*/

const invalidStrings = [
  "00:00[u-ca=iso8601][!u-ca=iso8601]",
  "00:00[!u-ca=iso8601][u-ca=iso8601]",
  "00:00[UTC][u-ca=iso8601][!u-ca=iso8601]",
  "00:00[u-ca=iso8601][foo=bar][!u-ca=iso8601]",
  "1970-01-01T00:00[u-ca=iso8601][!u-ca=iso8601]",
  "1970-01-01T00:00[!u-ca=iso8601][u-ca=iso8601]",
  "1970-01-01T00:00[UTC][u-ca=iso8601][!u-ca=iso8601]",
  "1970-01-01T00:00[u-ca=iso8601][foo=bar][!u-ca=iso8601]",
];
const instance = new Temporal.PlainTime(12, 34, 56, 987, 654, 321);
invalidStrings.forEach((arg) => {
  assert.throws(
    RangeError,
    () => instance.equals(arg),
    `reject more than one calendar annotation if any critical: ${arg}`
  );
});

reportCompare(0, 0);
