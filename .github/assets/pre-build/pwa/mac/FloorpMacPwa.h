/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef mozilla_FloorpMacPwa_h
#define mozilla_FloorpMacPwa_h

#include "nsIFloorpMacPwa.h"

namespace mozilla {

class FloorpMacPwa final : public nsIFloorpMacPwa {
 public:
  NS_DECL_THREADSAFE_ISUPPORTS
  NS_DECL_NSIFLOORPMACPWA

  FloorpMacPwa();

 private:
  ~FloorpMacPwa();
};

}  // namespace mozilla

#endif  // mozilla_FloorpMacPwa_h

