// |reftest| shell-option(--enable-temporal) skip-if(!this.hasOwnProperty('Temporal')||!xulRuntime.shell) -- Temporal is not enabled unconditionally, requires shell-options
// Copyright (C) 2024 Igalia, S.L. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
esid: sec-temporal.plainyearmonth
description: Calendar ID is canonicalized
features: [Temporal]
---*/

const result = new Temporal.PlainYearMonth(2024, 6, "islamicc", 8);
assert.sameValue(result.calendarId, "islamic-civil", "calendar ID is canonicalized");

reportCompare(0, 0);
