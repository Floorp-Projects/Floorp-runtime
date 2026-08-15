/* Any copyright is dedicated to the Public Domain.
   http://creativecommons.org/publicdomain/zero/1.0/ */

/*
 * Floorp Notes prefs-engine contract coverage.
 *
 * The Desktop client persists Notes as a JSON parallel-array payload in the
 * `floorp.browser.note.memos` preference and syncs it through the standard
 * Firefox prefs engine. These tests prove the prefs engine preserves the
 * exact shared fixture (digest 2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd),
 * advances the successful base only after a successful upload, resets
 * cleanly, and retries idempotently after an upload failure.
 */

const { getPrefsGUIDForTest } = ChromeUtils.importESModule(
  "resource://services-sync/engines/prefs.sys.mjs"
);
const PREFS_GUID = getPrefsGUIDForTest();
const { Service } = ChromeUtils.importESModule(
  "resource://services-sync/service.sys.mjs"
);
// IOUtils is provided globally by the xpcshell harness (testing/xpcshell/head.js).

const NOTES_PREF = "floorp.browser.note.memos";
const CONTROL_PREF = `services.sync.prefs.sync.${NOTES_PREF}`;
const FIXTURE_SHA256 =
  "2597e5311c7c4ea4bb9d6a806ffa183aae3b3bd7380893b664b02ac829d665fd";

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), b =>
    b.toString(16).padStart(2, "0")
  ).join("");
}

/** Converts a note list into the Desktop parallel-array wire payload. */
function notesToPayload(notes) {
  return JSON.stringify({
    ids: notes.map(n => n.id),
    titles: notes.map(n => n.title),
    contents: notes.map(n => n.content),
    createdAts: notes.map(n => n.createdAt),
    updatedAts: notes.map(n => n.updatedAt),
  });
}

async function cleanup(engine, server) {
  await engine._tracker.stop();
  await engine.wipeClient();
  for (const pref of Svc.PrefBranch.getChildList("")) {
    Svc.PrefBranch.clearUserPref(pref);
  }
  Service.recordManager.clearCache();
  await promiseStopServer(server);
}

add_task(async function test_fixture_digest_and_shape() {
  const file = do_get_file("floorp-notes-merge-v1.json");
  const bytes = await IOUtils.read(file.path);
  const digest = await sha256Hex(bytes);
  equal(
    digest,
    FIXTURE_SHA256,
    "Shared fixture must match the pinned contract digest"
  );

  const fixture = JSON.parse(new TextDecoder().decode(bytes));
  equal(fixture.fixtureSchemaVersion, 2, "Fixture schema version");
  equal(fixture.contractVersion, "floorp-notes-merge-v1", "Contract version");
  equal(fixture.mergeCases.length, 10, "Merge case count");
  equal(fixture.sequenceCases.length, 1, "Sequence case count");
  equal(fixture.errorCases.length, 1, "Error case count");
});

add_task(async function test_aggregate_map_preservation() {
  const file = do_get_file("floorp-notes-merge-v1.json");
  const bytes = await IOUtils.read(file.path);
  const fixture = JSON.parse(new TextDecoder().decode(bytes));
  const expectedNotes =
    fixture.mergeCases[0].expectedNotes;
  const payload = notesToPayload(expectedNotes);

  let engine = Service.engineManager.get("prefs");
  let server = await serverForFoo(engine);
  await SyncTestingInfrastructure(server);

  try {
    Services.prefs.setBoolPref(CONTROL_PREF, true);
    Services.prefs.setStringPref(NOTES_PREF, payload);

    await sync_engine_and_validate_telem(engine, false);

    const collection = server.user("foo").collection("prefs");
    const uploaded = collection.cleartext(PREFS_GUID).value[NOTES_PREF];
    equal(
      uploaded,
      payload,
      "Aggregate map must be uploaded byte-identically"
    );
    ok(
      !engine._tracker.modified,
      "Tracker shouldn't be modified after a successful sync"
    );
  } finally {
    await cleanup(engine, server);
  }
});

add_task(async function test_successful_base_timing() {
  let engine = Service.engineManager.get("prefs");
  let server = await serverForFoo(engine);
  await SyncTestingInfrastructure(server);

  try {
    Services.prefs.setBoolPref(CONTROL_PREF, true);
    Services.prefs.setStringPref(
      NOTES_PREF,
      notesToPayload([
        {
          id: "base-note",
          title: "Base",
          content: "base",
          createdAt: 1,
          updatedAt: 10,
        },
      ])
    );

    await sync_engine_and_validate_telem(engine, false);
    const firstBase = await engine.getLastSync();
    ok(firstBase > 0, "Base must advance after the first successful upload");

    // Force an upload failure: the base must NOT advance.
    const collection = server.user("foo").collection("prefs");
    Services.prefs.setStringPref(
      NOTES_PREF,
      notesToPayload([
        {
          id: "base-note",
          title: "Edited",
          content: "edited",
          createdAt: 1,
          updatedAt: 20,
        },
      ])
    );
    engine._tracker.modified = true;
    // Align the server collection timestamp so the batch POST passes the
    // x-if-unmodified-since precondition and reaches the injected failure.
    collection.timestamp = await engine.getLastSync();
    const oldPost = collection.post;
    collection.post = () => {
      throw new Error("Sync this!");
    };
    await Assert.rejects(
      sync_engine_and_validate_telem(engine, true),
      ex => ex.success === false
    );
    equal(
      await engine.getLastSync(),
      firstBase,
      "Base must not advance after a failed upload"
    );
    ok(engine._tracker.modified, "Tracker must remain modified after failure");

    // Retry succeeds and only then advances the base.
    collection.post = oldPost;
    await sync_engine_and_validate_telem(engine, false);
    ok(
      (await engine.getLastSync()) > firstBase,
      "Base must advance only after a successful upload"
    );
    ok(
      !engine._tracker.modified,
      "Tracker must clear after the successful retry"
    );
  } finally {
    await cleanup(engine, server);
  }
});

add_task(async function test_reset_client_resets_base_and_resyncs() {
  let engine = Service.engineManager.get("prefs");
  let server = await serverForFoo(engine);
  await SyncTestingInfrastructure(server);

  try {
    Services.prefs.setBoolPref(CONTROL_PREF, true);
    const payload = notesToPayload([
      {
        id: "reset-note",
        title: "Reset",
        content: "reset",
        createdAt: 1,
        updatedAt: 10,
      },
    ]);
    Services.prefs.setStringPref(NOTES_PREF, payload);
    await sync_engine_and_validate_telem(engine, false);

    const collection = server.user("foo").collection("prefs");
    ok(
      collection.cleartext(PREFS_GUID).value[NOTES_PREF],
      "Notes payload must be present on the server before reset"
    );

    await engine.resetClient();

    equal(
      await engine.getLastSync(),
      0,
      "Reset must clear the sync base"
    );
    ok(
      Services.prefs.prefHasUserValue(NOTES_PREF),
      "Reset keeps local data (prefs engine reset is metadata-only)"
    );

    // The next sync must re-upload the local aggregate after the reset.
    await sync_engine_and_validate_telem(engine, false);
    ok(
      (await engine.getLastSync()) > 0,
      "Base must advance again after re-sync following reset"
    );
    equal(
      collection.cleartext(PREFS_GUID).value[NOTES_PREF],
      payload,
      "Reset-then-sync must restore the aggregate on the server"
    );
  } finally {
    await cleanup(engine, server);
  }
});

add_task(async function test_retry_is_idempotent_after_failure() {
  let engine = Service.engineManager.get("prefs");
  let server = await serverForFoo(engine);
  await SyncTestingInfrastructure(server);

  try {
    Services.prefs.setBoolPref(CONTROL_PREF, true);
    const payload = notesToPayload([
      {
        id: "retry-note",
        title: "Retry",
        content: "retry",
        createdAt: 1,
        updatedAt: 10,
      },
    ]);
    Services.prefs.setStringPref(NOTES_PREF, payload);

    await sync_engine_and_validate_telem(engine, false);

    // Edit locally, fail the upload once, then retry.
    const collection = server.user("foo").collection("prefs");
    const editedPayload = notesToPayload([
      {
        id: "retry-note",
        title: "Retry edited",
        content: "retry edited",
        createdAt: 1,
        updatedAt: 20,
      },
    ]);
    Services.prefs.setStringPref(NOTES_PREF, editedPayload);
    engine._tracker.modified = true;
    // Align the server collection timestamp so the batch POST passes the
    // x-if-unmodified-since precondition and reaches the injected failure.
    collection.timestamp = await engine.getLastSync();
    const oldPost = collection.post;
    collection.post = () => {
      throw new Error("Sync this!");
    };
    await Assert.rejects(
      sync_engine_and_validate_telem(engine, true),
      ex => ex.success === false
    );

    collection.post = oldPost;
    await sync_engine_and_validate_telem(engine, false);
    equal(
      collection.cleartext(PREFS_GUID).value[NOTES_PREF],
      editedPayload,
      "Retry must upload the edited aggregate exactly once"
    );

    // A third sync must not change the server record (idempotent).
    await sync_engine_and_validate_telem(engine, false);
    equal(
      collection.cleartext(PREFS_GUID).value[NOTES_PREF],
      editedPayload,
      "Idempotent retry must not rewrite the server aggregate"
    );
  } finally {
    await cleanup(engine, server);
  }
});
