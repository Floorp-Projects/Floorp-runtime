/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/* global process, require */

const fs = require("fs");
const vm = require("vm");

const sourcePath = process.argv[2];
const source = fs
  .readFileSync(sourcePath, "utf8")
  .replace("export class TPSFxAAutofillChild", "class TPSFxAAutofillChild")
  .concat("\nthis.TPSFxAAutofillChild = TPSFxAAutofillChild;\n");

const context = {
  JSWindowActorChild: class {},
  console: { warn() {}, error() {} },
};
vm.createContext(context);
vm.runInContext(source, context, { filename: sourcePath });

function makeInput(name, type, onInput) {
  return {
    name,
    type,
    value: "",
    // Headless Firefox may report null for the active FxA form field.
    offsetParent: null,
    focus() {},
    dispatchEvent(event) {
      if (event.type === "input") {
        onInput();
      }
    },
  };
}

function makeActor({
  emailVisible,
  passwordVisible,
  initiallyDisabled,
  enableOnInput = true,
}) {
  let clicks = 0;
  let distractorClicks = 0;
  const button = {
    type: "submit",
    disabled: initiallyDisabled,
    click() {
      clicks += 1;
    },
  };
  const distractor = {
    type: "submit",
    disabled: false,
    click() {
      distractorClicks += 1;
    },
  };
  const enable = () => {
    if (enableOnInput) {
      button.disabled = false;
    }
  };
  const email = emailVisible ? makeInput("email", "email", enable) : null;
  const password = passwordVisible
    ? makeInput("password", "password", enable)
    : null;
  const form = {
    querySelector(selector) {
      if (selector.includes('button[type="submit"]')) {
        return button.disabled ? null : button;
      }
      return null;
    },
  };
  if (email) {
    email.form = form;
  }
  if (password) {
    password.form = form;
  }
  const doc = {
    querySelector(selector) {
      if (selector.includes('input[name="email"]')) {
        return email;
      }
      if (selector.includes('input[name="password"]')) {
        return password;
      }
      if (selector.includes("button")) {
        // A password-recovery button appears before the true form submit.
        return distractor;
      }
      return null;
    },
  };
  const actor = new context.TPSFxAAutofillChild();
  actor.contentWindow = {
    document: doc,
    Event: class {
      constructor(type) {
        this.type = type;
      }
    },
  };
  actor._email = "qa@example.test";
  actor._password = "secret";
  return {
    actor,
    email,
    password,
    clicks: () => clicks,
    distractorClicks: () => distractorClicks,
  };
}

const emailStep = makeActor({
  emailVisible: true,
  passwordVisible: false,
  initiallyDisabled: true,
});
const emailDone = emailStep.actor._fillAndSubmit();
if (emailStep.email.value !== "qa@example.test" || emailStep.clicks() !== 1) {
  throw new Error(
    "email step was not filled and submitted after enabling button"
  );
}
if (emailStep.distractorClicks() !== 0) {
  throw new Error("email step clicked a non-submit distractor");
}
if (emailDone !== false) {
  throw new Error("email-only step must keep polling for the password step");
}
emailStep.actor._lastSubmit = 0;
const emailRepeatDone = emailStep.actor._fillAndSubmit();
if (emailStep.clicks() !== 1) {
  throw new Error("email step must be submitted at most once per document");
}
if (emailRepeatDone !== false) {
  throw new Error("submitted email step must keep polling for password");
}

const passwordStep = makeActor({
  emailVisible: false,
  passwordVisible: true,
  initiallyDisabled: true,
});
const passwordDone = passwordStep.actor._fillAndSubmit();
if (passwordStep.password.value !== "secret" || passwordStep.clicks() !== 1) {
  throw new Error("password step was not filled and submitted");
}
if (passwordStep.distractorClicks() !== 0) {
  throw new Error("password step clicked a password-recovery distractor");
}
if (passwordDone !== true) {
  throw new Error("password step must stop polling after submission");
}
passwordStep.actor._lastSubmit = 0;
const passwordRepeatDone = passwordStep.actor._fillAndSubmit();
if (passwordStep.clicks() !== 1) {
  throw new Error("password step must be submitted at most once per document");
}
if (passwordRepeatDone !== true) {
  throw new Error("submitted password step must remain complete");
}

const disabledScopedSubmit = makeActor({
  emailVisible: true,
  passwordVisible: false,
  initiallyDisabled: true,
  enableOnInput: false,
});
const disabledDone = disabledScopedSubmit.actor._fillAndSubmit();
if (
  disabledScopedSubmit.clicks() !== 0 ||
  disabledScopedSubmit.distractorClicks() !== 0
) {
  throw new Error(
    "disabled scoped submit must not fall back to an out-of-form submit"
  );
}
if (disabledDone !== false) {
  throw new Error("disabled scoped submit must keep polling");
}

console.log("actor two-step form tests passed");
