// |reftest| shell-option(--enable-temporal) skip-if(!this.hasOwnProperty('Temporal')||!xulRuntime.shell) -- Temporal is not enabled unconditionally, requires shell-options
// Copyright (C) 2021 Igalia, S.L. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
esid: sec-get-temporal.plaindatetime.prototype.erayear
description: Throw a TypeError if the receiver is invalid
features: [Symbol, Temporal]
---*/

const eraYear = Object.getOwnPropertyDescriptor(Temporal.PlainDateTime.prototype, "eraYear").get;

assert.sameValue(typeof eraYear, "function");

assert.throws(TypeError, () => eraYear.call(undefined), "undefined");
assert.throws(TypeError, () => eraYear.call(null), "null");
assert.throws(TypeError, () => eraYear.call(true), "true");
assert.throws(TypeError, () => eraYear.call(""), "empty string");
assert.throws(TypeError, () => eraYear.call(Symbol()), "symbol");
assert.throws(TypeError, () => eraYear.call(1), "1");
assert.throws(TypeError, () => eraYear.call({}), "plain object");
assert.throws(TypeError, () => eraYear.call(Temporal.PlainDateTime), "Temporal.PlainDateTime");
assert.throws(TypeError, () => eraYear.call(Temporal.PlainDateTime.prototype), "Temporal.PlainDateTime.prototype");

reportCompare(0, 0);
