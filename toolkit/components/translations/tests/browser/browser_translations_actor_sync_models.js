/* Any copyright is dedicated to the Public Domain.
   http://creativecommons.org/publicdomain/zero/1.0/ */

"use strict";

/**
 * An actor unit test for testing RemoteSettings update behavior. This uses the
 * recommendations from:
 *
 * https://firefox-source-docs.mozilla.org/services/settings/index.html#unit-tests
 */
add_task(async function test_translations_actor_sync_update_models() {
  const { remoteClients, cleanup } = await setupActorTest({
    autoDownloadFromRemoteSettings: true,
    languagePairs: [
      { fromLang: "en", toLang: "es" },
      { fromLang: "es", toLang: "en" },
    ],
  });

  const decoder = new TextDecoder();
  const modelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "es"
  );

  const { languageModelFiles: oldModels } = await modelsPromise;

  is(
    decoder.decode(oldModels.model.buffer),
    `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
  );

  const useLexicalShortlist = Services.prefs.getBoolPref(
    "browser.translations.useLexicalShortlist"
  );
  const recordsToCreate = createRecordsForLanguagePair("en", "es").filter(
    ({ fileType }) => useLexicalShortlist || fileType !== "lex"
  );
  for (const newModelRecord of recordsToCreate) {
    newModelRecord.id = oldModels[newModelRecord.fileType].record.id;
    newModelRecord.version = `${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`;
  }

  await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
    recordsToCreate,
    expectedUpdatedRecordsCount: downloadedFilesPerLanguagePair(),
  });

  const updatedModelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "es"
  );

  const { languageModelFiles } = await updatedModelsPromise;
  const { model: updatedModel } = languageModelFiles;

  is(
    decoder.decode(updatedModel.buffer),
    `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
    `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 model is downloaded.`
  );

  return cleanup();
});

/**
 * An actor unit test for testing RemoteSettings delete behavior.
 */
add_task(async function test_translations_actor_sync_delete_models() {
  const { remoteClients, cleanup } = await setupActorTest({
    autoDownloadFromRemoteSettings: true,
    languagePairs: [
      { fromLang: "en", toLang: "es" },
      { fromLang: "es", toLang: "en" },
    ],
  });

  const decoder = new TextDecoder();
  const modelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "es"
  );

  const { languageModelFiles } = await modelsPromise;
  const { model } = languageModelFiles;

  is(
    decoder.decode(model.buffer),
    `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
  );

  info(
    `Removing record ${model.record.name} from mocked Remote Settings database.`
  );
  await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
    recordsToDelete: [model.record],
    expectedDeletedRecordsCount: 1,
  });

  let errorMessage;
  await TranslationsParent.getTranslationModelPayload("en", "es").catch(
    error => {
      errorMessage = error?.message;
    }
  );

  is(
    errorMessage,
    'No model file found for "en,es".',
    "The model was successfully removed."
  );

  return cleanup();
});

/**
 * An actor unit test for testing RemoteSettings creation behavior.
 */
add_task(async function test_translations_actor_sync_create_models() {
  const { remoteClients, cleanup } = await setupActorTest({
    autoDownloadFromRemoteSettings: true,
    languagePairs: [
      { fromLang: "en", toLang: "es" },
      { fromLang: "es", toLang: "en" },
    ],
  });

  const decoder = new TextDecoder();
  const modelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "es"
  );

  const { languageModelFiles: originalFiles } = await modelsPromise;
  is(
    decoder.decode(originalFiles.model.buffer),
    `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
  );

  const recordsToCreate = createRecordsForLanguagePair("en", "fr");

  await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
    recordsToCreate,
    expectedCreatedRecordsCount: RECORDS_PER_LANGUAGE_PAIR_SHARED_VOCAB,
  });

  const updatedModelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "fr"
  );

  const { languageModelFiles: updatedFiles } = await updatedModelsPromise;
  const { vocab, lex, model } = updatedFiles;

  is(
    decoder.decode(vocab.buffer),
    `Mocked download: test-translation-models vocab.enfr.spm ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    "The en to fr vocab is downloaded."
  );
  is(
    decoder.decode(model.buffer),
    `Mocked download: test-translation-models model.enfr.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    "The en to fr model is downloaded."
  );

  if (Services.prefs.getBoolPref(USE_LEXICAL_SHORTLIST_PREF)) {
    is(
      decoder.decode(lex.buffer),
      `Mocked download: test-translation-models lex.50.50.enfr.s2t.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
      "The en to fr lex is downloaded."
    );
  }

  return cleanup();
});

/**
 * An actor unit test for testing creating a new record has a higher minor version than an existing record of the same kind.
 */
add_task(
  async function test_translations_actor_sync_create_models_higher_minor_version() {
    const { remoteClients, cleanup } = await setupActorTest({
      autoDownloadFromRemoteSettings: true,
      languagePairs: [
        { fromLang: "en", toLang: "es" },
        { fromLang: "es", toLang: "en" },
      ],
    });

    const decoder = new TextDecoder();
    const modelsPromise = TranslationsParent.getTranslationModelPayload(
      "en",
      "es"
    );

    const { languageModelFiles: originalFiles } = await modelsPromise;
    is(
      decoder.decode(originalFiles.model.buffer),
      `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
      `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
    );

    const recordsToCreate = createRecordsForLanguagePair("en", "es");
    for (const newModelRecord of recordsToCreate) {
      newModelRecord.version = `${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`;
    }

    await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
      recordsToCreate,
      expectedCreatedRecordsCount: RECORDS_PER_LANGUAGE_PAIR_SHARED_VOCAB,
    });

    const updatedModelsPromise = TranslationsParent.getTranslationModelPayload(
      "en",
      "es"
    );

    const { languageModelFiles: updatedFiles } = await updatedModelsPromise;
    const { vocab, lex, model } = await updatedFiles;

    is(
      decoder.decode(vocab.buffer),
      `Mocked download: test-translation-models vocab.enes.spm ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 vocab is downloaded.`
    );
    is(
      decoder.decode(model.buffer),
      `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 model is downloaded.`
    );

    if (Services.prefs.getBoolPref(USE_LEXICAL_SHORTLIST_PREF)) {
      is(
        decoder.decode(lex.buffer),
        `Mocked download: test-translation-models lex.50.50.enes.s2t.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
        "The en to es lex is downloaded."
      );
    }

    return cleanup();
  }
);

/**
 * An actor unit test for testing creating a new record has a higher major version than an existing record of the same kind.
 */
add_task(
  async function test_translations_actor_sync_create_models_higher_major_version() {
    const { remoteClients, cleanup } = await setupActorTest({
      autoDownloadFromRemoteSettings: true,
      languagePairs: [
        { fromLang: "en", toLang: "es" },
        { fromLang: "es", toLang: "en" },
      ],
    });

    const decoder = new TextDecoder();
    const modelsPromise = TranslationsParent.getTranslationModelPayload(
      "en",
      "es"
    );

    const { languageModelFiles: originalFiles } = await modelsPromise;
    is(
      decoder.decode(originalFiles.model.buffer),
      `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
      `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
    );

    const recordsToCreate = createRecordsForLanguagePair("en", "es");
    for (const newModelRecord of recordsToCreate) {
      newModelRecord.version = "2.0";
    }

    await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
      recordsToCreate,
      expectedCreatedRecordsCount: RECORDS_PER_LANGUAGE_PAIR_SHARED_VOCAB,
    });

    const updatedModelsPromise = TranslationsParent.getTranslationModelPayload(
      "en",
      "es"
    );

    const { languageModelFiles: updatedFiles } = await updatedModelsPromise;
    const { vocab, lex, model } = updatedFiles;

    is(
      decoder.decode(vocab.buffer),
      `Mocked download: test-translation-models vocab.enes.spm ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 vocab is downloaded.`
    );
    is(
      decoder.decode(model.buffer),
      `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
    );

    if (Services.prefs.getBoolPref(USE_LEXICAL_SHORTLIST_PREF)) {
      is(
        decoder.decode(lex.buffer),
        `Mocked download: test-translation-models lex.50.50.enes.s2t.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
        "The en to es lex is downloaded."
      );
    }

    return cleanup();
  }
);

/**
 * An actor unit test for testing removing a record that has a higher minor version than another record, ensuring
 * that the models roll back to the previous version.
 */
add_task(async function test_translations_actor_sync_rollback_models() {
  const { remoteClients, cleanup } = await setupActorTest({
    autoDownloadFromRemoteSettings: true,
    languagePairs: [
      { fromLang: "en", toLang: "es" },
      { fromLang: "es", toLang: "en" },
    ],
  });

  const newRecords = createRecordsForLanguagePair("en", "es");
  for (const newModelRecord of newRecords) {
    newModelRecord.version = `${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`;
  }

  await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
    recordsToCreate: newRecords,
    expectedCreatedRecordsCount: RECORDS_PER_LANGUAGE_PAIR_SHARED_VOCAB,
  });

  const decoder = new TextDecoder();
  const modelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "es"
  );

  const { languageModelFiles: originalFiles } = await modelsPromise;
  is(
    decoder.decode(originalFiles.model.buffer),
    `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
    `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 model is downloaded.`
  );

  await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
    recordsToDelete: newRecords,
    expectedDeletedRecordsCount: RECORDS_PER_LANGUAGE_PAIR_SHARED_VOCAB,
  });

  const rolledBackModelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "es"
  );

  const { languageModelFiles: rolledBackFiles } = await rolledBackModelsPromise;
  const { vocab, lex, model } = rolledBackFiles;

  is(
    decoder.decode(vocab.buffer),
    `Mocked download: test-translation-models vocab.enes.spm ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 vocab is downloaded.`
  );
  is(
    decoder.decode(model.buffer),
    `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
  );

  if (Services.prefs.getBoolPref(USE_LEXICAL_SHORTLIST_PREF)) {
    is(
      decoder.decode(lex.buffer),
      `Mocked download: test-translation-models lex.50.50.enes.s2t.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
      "The en to es lex is downloaded."
    );
  }

  return cleanup();
});

add_task(async function test_translations_parent_download_size() {
  const { cleanup } = await setupActorTest({
    languagePairs: [
      { fromLang: "en", toLang: "es" },
      { fromLang: "es", toLang: "en" },
      { fromLang: "en", toLang: "de" },
      { fromLang: "de", toLang: "en" },
    ],
  });

  const directSize =
    await TranslationsParent.getExpectedTranslationDownloadSize("en", "es");
  is(
    directSize,
    downloadedFilesPerLanguagePair() * 123,
    "Returned the expected download size for a direct translation."
  );

  const pivotSize = await TranslationsParent.getExpectedTranslationDownloadSize(
    "es",
    "de"
  );
  // Includes a pivot (x2), model, lex, and vocab files (x3), each mocked at 123 bytes.
  is(
    pivotSize,
    2 * downloadedFilesPerLanguagePair() * 123,
    "Returned the expected download size for a pivot."
  );

  const notApplicableSize =
    await TranslationsParent.getExpectedTranslationDownloadSize(
      "unknown",
      "unknown"
    );
  is(
    notApplicableSize,
    0,
    "Returned the expected download size for an unknown or not applicable model."
  );
  return cleanup();
});

/**
 * An actor unit test for testing the scenarios where we update a model via minor version bump to
 * either transition from a shared vocab to a split vocab configuration, or the converse transition
 * from a split vocab to a shared vocab configuration.
 */
add_task(async function test_transition_from_vocab_configurations() {
  const { remoteClients, cleanup } = await setupActorTest({
    autoDownloadFromRemoteSettings: true,
    languagePairs: [
      { fromLang: "en", toLang: "es" },
      { fromLang: "es", toLang: "en" },
    ],
  });

  const decoder = new TextDecoder();
  const modelsPromise = TranslationsParent.getTranslationModelPayload(
    "en",
    "es"
  );

  const { languageModelFiles: originalFiles } = await modelsPromise;
  is(
    decoder.decode(originalFiles.model.buffer),
    `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0`,
    `The version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.0 model is downloaded.`
  );

  {
    info(
      `Publishing a new split-vocab configuration as version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`
    );
    const recordsToCreate = createRecordsForLanguagePair(
      "en",
      "es",
      /* splitVocab */ true
    );
    for (const newModelRecord of recordsToCreate) {
      newModelRecord.version = `${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`;
    }

    await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
      recordsToCreate,
      expectedCreatedRecordsCount: RECORDS_PER_LANGUAGE_PAIR_SPLIT_VOCAB,
    });

    const updatedModelsPromise = TranslationsParent.getTranslationModelPayload(
      "en",
      "es"
    );

    const { languageModelFiles: updatedFiles } = await updatedModelsPromise;
    const { srcvocab, trgvocab, vocab, lex, model } = await updatedFiles;

    is(
      vocab,
      undefined,
      `The shared vocab is undefined after upgrading to split vocab.`
    );
    is(
      decoder.decode(srcvocab.buffer),
      `Mocked download: test-translation-models srcvocab.enes.spm ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 srcvocab is downloaded.`
    );
    is(
      decoder.decode(trgvocab.buffer),
      `Mocked download: test-translation-models trgvocab.enes.spm ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 trgvocab is downloaded.`
    );
    is(
      decoder.decode(model.buffer),
      `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 model is downloaded.`
    );

    if (Services.prefs.getBoolPref(USE_LEXICAL_SHORTLIST_PREF)) {
      is(
        decoder.decode(lex.buffer),
        `Mocked download: test-translation-models lex.50.50.enes.s2t.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1`,
        `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.1 lex is downloaded.`
      );
    }
  }

  {
    info(
      `Publishing a new shared-vocab configuration as version ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2`
    );
    const recordsToCreate = createRecordsForLanguagePair(
      "en",
      "es",
      /* splitVocab */ false
    );
    for (const newModelRecord of recordsToCreate) {
      newModelRecord.version = `${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2`;
    }

    await modifyRemoteSettingsRecords(remoteClients.translationModels.client, {
      recordsToCreate,
      expectedCreatedRecordsCount: RECORDS_PER_LANGUAGE_PAIR_SHARED_VOCAB,
    });

    const updatedModelsPromise = TranslationsParent.getTranslationModelPayload(
      "en",
      "es"
    );

    const { languageModelFiles: updatedFiles } = await updatedModelsPromise;
    const { srcvocab, trgvocab, vocab, lex, model } = await updatedFiles;

    is(
      srcvocab,
      undefined,
      `The source vocab is undefined after transitioning to a higher-version shared vocab.`
    );
    is(
      trgvocab,
      undefined,
      `The target vocab is undefined after transitioning to a higher-version shared vocab.`
    );

    is(
      decoder.decode(vocab.buffer),
      `Mocked download: test-translation-models vocab.enes.spm ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2 shared vocab is downloaded.`
    );
    is(
      decoder.decode(model.buffer),
      `Mocked download: test-translation-models model.enes.intgemm.alphas.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2`,
      `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2 model is downloaded.`
    );
    if (Services.prefs.getBoolPref(USE_LEXICAL_SHORTLIST_PREF)) {
      is(
        decoder.decode(lex.buffer),
        `Mocked download: test-translation-models lex.50.50.enes.s2t.bin ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2`,
        `The ${TranslationsParent.LANGUAGE_MODEL_MAJOR_VERSION_MAX}.2 lex is downloaded.`
      );
    }
  }

  return cleanup();
});
