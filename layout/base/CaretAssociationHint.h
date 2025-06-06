/* -*- Mode: C++; tab-width: 8; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* vim: set ts=8 sts=2 et sw=2 tw=80: */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef mozilla_CaretAssociationHint_h
#define mozilla_CaretAssociationHint_h

namespace mozilla {

template <typename PT, typename CT>
class RangeBoundaryBase;

namespace intl {
class BidiEmbeddingLevel;
};

/**
 * Hint whether a caret is associated with the content before a
 * given character offset (Before), or with the content after a given
 * character offset (After).
 */
enum class CaretAssociationHint { Before, After };

/**
 * Return better caret association hint for aCaretPoint than aDefault.
 * This computes the result from layout.  Therefore, you should flush pending
 * layout before calling this.
 */
template <typename PT, typename CT>
CaretAssociationHint ComputeCaretAssociationHint(
    CaretAssociationHint aDefault, intl::BidiEmbeddingLevel aBidiLevel,
    const RangeBoundaryBase<PT, CT>& aCaretPoint);

}  // namespace mozilla

#endif
