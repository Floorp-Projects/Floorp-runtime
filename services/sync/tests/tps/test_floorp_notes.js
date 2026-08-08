/* Any copyright is dedicated to the Public Domain.
   http://creativecommons.org/publicdomain/zero/1.0/ */

/*
 * Floorp Notes cross-profile prefs-engine TPS scenario.
 *
 * The Desktop client persists Notes as a JSON parallel-array payload in the
 * `floorp.browser.note.memos` preference and syncs it through the standard
 * Firefox prefs engine. This scenario verifies the exact shared fixture
 * aggregate (digest 2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd)
 * survives a real end-to-end sync byte-identically in both directions and
 * that edits propagate to the other profile.
 */

EnableEngines(["prefs"]);

/*
 * The list of phases mapped to their corresponding profiles. The object
 * here must be in JSON format as it will get parsed by the Python
 * testrunner.
 */
var phases = { phase1: "profile1", phase2: "profile2", phase3: "profile1" };

/*
 * Desktop parallel-array payload for the shared fixture's first merge case
 * (concurrent-edits-preserve-deterministic-loser, expected notes).
 */
var notesInitial = JSON.stringify({
  ids: ["shared", "floorp-sync-conflict-849e5b5e55c59272fed3c2f1260cf5f4c3a18380b592baab01f9a13e2eef3a7e"],
  titles: ["Remote", "Local (Conflict)"],
  contents: ["remote", "local"],
  createdAts: [1, 1],
  updatedAts: [30, 20],
});

var notesEdited = JSON.stringify({
  ids: ["shared"],
  titles: ["Remote edited"],
  contents: ["remote edited"],
  createdAts: [1],
  updatedAts: [40],
});

// The prefs engine only syncs preferences that have a control pref. The
// Floorp Notes preference has no default control pref in this tree, so the
// scenario installs one and seeds the preference before the first phase.
Services.prefs.setBoolPref(
  "services.sync.prefs.sync.floorp.browser.note.memos",
  true
);
// Seed the preference only on first load (each phase reloads this file into
// a fresh profile context; never overwrite a value synced by a later phase).
if (
  Services.prefs.getPrefType("floorp.browser.note.memos") ===
  Ci.nsIPrefBranch.PREF_INVALID
) {
  Services.prefs.setStringPref("floorp.browser.note.memos", notesInitial);
}

Phase("phase1", [
  [Prefs.verify, [{ name: "floorp.browser.note.memos", value: notesInitial }]],
  [Sync],
]);

Phase("phase2", [
  [Sync],
  [
    Prefs.verify,
    [{ name: "floorp.browser.note.memos", value: notesInitial }],
  ],
  [
    Prefs.modify,
    [{ name: "floorp.browser.note.memos", value: notesEdited }],
  ],
  [Prefs.verify, [{ name: "floorp.browser.note.memos", value: notesEdited }]],
  [Sync],
]);

Phase("phase3", [
  [Sync],
  [Prefs.verify, [{ name: "floorp.browser.note.memos", value: notesEdited }]],
]);
