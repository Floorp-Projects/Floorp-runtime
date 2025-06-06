// |reftest| shell-option(--enable-temporal) skip-if(!this.hasOwnProperty('Temporal')||!xulRuntime.shell) -- Temporal is not enabled unconditionally, requires shell-options
// Copyright (C) 2020 Igalia, S.L. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
esid: sec-temporal.plainyearmonth.prototype.with
description: Properties on an object passed to with() are accessed in the correct order
includes: [compareArray.js, temporalHelpers.js]
features: [Temporal]
---*/

const expected = [
  // RejectObjectWithCalendarOrTimeZone
  "get fields.calendar",
  "get fields.timeZone",
  // PrepareTemporalFields on argument
  "get fields.month",
  "get fields.month.valueOf",
  "call fields.month.valueOf",
  "get fields.monthCode",
  "get fields.monthCode.toString",
  "call fields.monthCode.toString",
  "get fields.year",
  "get fields.year.valueOf",
  "call fields.year.valueOf",
  // GetTemporalOverflowOption
  "get options.overflow",
  "get options.overflow.toString",
  "call options.overflow.toString",
];
const actual = [];

const instance = new Temporal.PlainYearMonth(2000, 5);

const fields = TemporalHelpers.propertyBagObserver(actual, {
  year: 1.7,
  month: 1.7,
  monthCode: "M01",
}, "fields");

const options = TemporalHelpers.propertyBagObserver(actual, {
  overflow: "constrain",
  extra: "property",
}, "options");

instance.with(fields, options);
assert.compareArray(actual, expected, "order of operations");

reportCompare(0, 0);
