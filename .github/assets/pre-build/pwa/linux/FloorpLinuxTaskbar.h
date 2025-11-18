#ifndef mozilla_FloorpLinuxTaskbar_h
#define mozilla_FloorpLinuxTaskbar_h

#include "mozilla/AlreadyAddRefed.h"
#include "nsIFloorpLinuxTaskbar.h"

namespace mozilla {

class FloorpLinuxTaskbar final : public nsIFloorpLinuxTaskbar {
 public:
  NS_DECL_THREADSAFE_ISUPPORTS
  NS_DECL_NSIFLOORPLINUXTASKBAR

  FloorpLinuxTaskbar();

 private:
  ~FloorpLinuxTaskbar();
};

}  // namespace mozilla

#endif  // mozilla_FloorpLinuxTaskbar_h

