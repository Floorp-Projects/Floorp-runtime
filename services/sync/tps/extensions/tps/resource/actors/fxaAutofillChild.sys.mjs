/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

const POLL_INTERVAL_MS = 500;
const MAX_ATTEMPTS = 120;

// Helper class to autofill the FxA OAuth page
export class TPSFxAAutofillChild extends JSWindowActorChild {
  constructor() {
    super();
    this._email = "";
    this._password = "";
    this._timerId = 0;
    this._lastSubmit = 0;
    this._submittedSteps = new Set();
  }

  didDestroy() {
    this._clearTimer();
  }

  handleEvent(event) {
    if (event.type === "DOMContentLoaded") {
      this._startAutofillLoop();
    }
  }

  receiveMessage(message) {
    if (message.name !== "TPSFxAAutofill:Configure") {
      return;
    }
    this._email = message.data.email || "";
    this._password = message.data.password || "";
    this._startAutofillLoop();
  }

  _clearTimer() {
    if (this._timerId) {
      this.contentWindow?.clearInterval(this._timerId);
      this._timerId = 0;
    }
  }

  _startAutofillLoop() {
    if (!this._email || !this._password) {
      return;
    }

    this._clearTimer();
    let attempts = 0;
    this._timerId = this.contentWindow.setInterval(() => {
      attempts += 1;
      if (this._fillAndSubmit() || attempts >= MAX_ATTEMPTS) {
        this._clearTimer();
      }
    }, POLL_INTERVAL_MS);
  }

  _setInputValue(input, value) {
    if (!input) {
      return false;
    }
    if (input.value === value) {
      console.warn(`[TPS Autofill] Field ${input.name} already filled`);
      return false;
    }
    const win = this.contentWindow;
    console.warn(`[TPS Autofill] Filling ${input.name} with value`);
    input.focus();
    input.value = value;
    input.dispatchEvent(new win.Event("input", { bubbles: true }));
    input.dispatchEvent(new win.Event("change", { bubbles: true }));
    input.dispatchEvent(new win.Event("blur", { bubbles: true }));
    console.warn(`[TPS Autofill] Field ${input.name} filled`);
    return true;
  }

  _isUsableInput(input) {
    return (
      input &&
      !input.disabled &&
      input.type !== "hidden" &&
      input.getAttribute?.("aria-hidden") !== "true"
    );
  }

  _fillAndSubmit() {
    const doc = this.contentWindow.document;
    const emailInput = doc.querySelector(
      'input[name="email"], input[type="email"]'
    );
    const passwordInput = doc.querySelector(
      'input[name="password"], input[type="password"]'
    );
    const emailUsable = this._isUsableInput(emailInput);
    const passwordUsable = this._isUsableInput(passwordInput);
    let activeStep = "";
    if (passwordUsable) {
      activeStep = "password";
    } else if (emailUsable) {
      activeStep = "email";
    }
    if (!activeStep) {
      return false;
    }
    if (this._submittedSteps.has(activeStep)) {
      return activeStep === "password";
    }

    // Fill email if present
    let emailFilled = false;
    if (emailUsable) {
      this._setInputValue(emailInput, this._email);
      emailFilled = emailInput.value.trim() === this._email.trim();
      console.warn(
        `[TPS Autofill] Email filled: ${emailFilled}, value matches: ${emailInput.value.trim() === this._email.trim()}`
      );
    }

    // Fill password if present
    let passwordFilled = false;
    if (passwordUsable) {
      this._setInputValue(passwordInput, this._password);
      passwordFilled = passwordInput.value === this._password;
      console.warn(
        `[TPS Autofill] Password filled: ${passwordFilled}, value matches: ${passwordInput.value === this._password}`
      );
    }

    // Ready to submit if we filled at least one field
    const readyToSubmit = emailFilled || passwordFilled;

    console.warn(
      `[TPS Autofill] Ready to submit: ${readyToSubmit} (email: ${emailFilled})`
    );

    if (!readyToSubmit) {
      return false;
    }

    // Scope submission to the active input's form. The password page also has
    // an enabled password-recovery button, which must never be selected as the
    // generic first button in the document.
    const activeInput = passwordFilled ? passwordInput : emailInput;
    const form = activeInput?.form || activeInput?.closest?.("form");
    if (!form) {
      return false;
    }
    const submitSelector =
      'button[type="submit"]:not([disabled]), input[type="submit"]:not([disabled])';
    const submitButton = form.querySelector(submitSelector);
    if (!submitButton) {
      return false;
    }

    // Wait a bit for the button to become enabled after input
    // Don't click too fast (debounce)
    const now = Date.now();
    if (now - this._lastSubmit < 500) {
      return false;
    }
    this._lastSubmit = now;

    // Try clicking the button
    try {
      submitButton.click();
      console.warn("[TPS Autofill] Clicked submit button");
      this._submittedSteps.add(activeStep);
    } catch (e) {
      console.error("[TPS Autofill] Failed to click button:", e);
      return false;
    }

    // The production FxA flow presents email and password as separate steps in
    // the same document. Keep polling after the email step and stop only after
    // the password step has been submitted.
    return activeStep === "password";
  }
}
