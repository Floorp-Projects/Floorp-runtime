/* -*- Mode: C++; tab-width: 8; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* vim: set ts=8 sts=2 et sw=2 tw=80: */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
#ifndef _include_mozilla_gfx_ipc_CompositorOptions_h_
#define _include_mozilla_gfx_ipc_CompositorOptions_h_

namespace IPC {
template <typename>
struct ParamTraits;
}  // namespace IPC

namespace mozilla {
namespace layers {

/**
 * This class holds options that are "per compositor" - that is, these options
 * affect a particular CompositorBridgeParent and all the content that it
 * renders.
 *
 * This class is intended to be created by a platform widget (but NOT
 * PuppetWidget) and passed to the graphics code during initialization of the
 * top level compositor associated with that widget. The options are immutable
 * after creation. The CompositorBridgeParent holds the canonical version of
 * the options, but they may be accessed by other parts of the code as needed,
 * and are accessible to content processes over PCompositorBridge as well.
 */
class CompositorOptions {
 public:
  // This constructor needed for IPDL purposes, don't use it anywhere else.
  CompositorOptions() = default;

  CompositorOptions(bool aUseAPZ, bool aUseSoftwareWebRender)
      : mUseAPZ(aUseAPZ), mUseSoftwareWebRender(aUseSoftwareWebRender) {}

  bool UseAPZ() const { return mUseAPZ; }
  bool UseSoftwareWebRender() const { return mUseSoftwareWebRender; }
  bool AllowSoftwareWebRenderD3D11() const {
    return mAllowSoftwareWebRenderD3D11;
  }
  bool AllowSoftwareWebRenderOGL() const { return mAllowSoftwareWebRenderOGL; }
  bool InitiallyPaused() const { return mInitiallyPaused; }
  bool NeedFastSnaphot() const { return mNeedFastSnaphot; }
  bool AllowNativeCompositor() const { return mAllowNativeCompositor; }

  void SetUseAPZ(bool aUseAPZ) { mUseAPZ = aUseAPZ; }

  void SetAllowSoftwareWebRenderD3D11(bool aAllowSoftwareWebRenderD3D11) {
    mAllowSoftwareWebRenderD3D11 = aAllowSoftwareWebRenderD3D11;
  }

  void SetAllowSoftwareWebRenderOGL(bool aAllowSoftwareWebRenderOGL) {
    mAllowSoftwareWebRenderOGL = aAllowSoftwareWebRenderOGL;
  }

  void SetInitiallyPaused(bool aPauseAtStartup) {
    mInitiallyPaused = aPauseAtStartup;
  }

  void SetNeedFastSnaphot(bool aNeedFastSnaphot) {
    mNeedFastSnaphot = aNeedFastSnaphot;
  }

  void SetAllowNativeCompositor(bool aAllowNativeCompositor) {
    mAllowNativeCompositor = aAllowNativeCompositor;
  }

  bool EqualsIgnoringApzEnablement(const CompositorOptions& aOther) const {
    return mUseSoftwareWebRender == aOther.mUseSoftwareWebRender &&
           mAllowSoftwareWebRenderD3D11 ==
               aOther.mAllowSoftwareWebRenderD3D11 &&
           mAllowSoftwareWebRenderOGL == aOther.mAllowSoftwareWebRenderOGL &&
           mInitiallyPaused == aOther.mInitiallyPaused &&
           mNeedFastSnaphot == aOther.mNeedFastSnaphot &&
           mAllowNativeCompositor == aOther.mAllowNativeCompositor;
  }

  bool operator==(const CompositorOptions& aOther) const {
    return mUseAPZ == aOther.mUseAPZ && EqualsIgnoringApzEnablement(aOther);
  }

  friend struct IPC::ParamTraits<CompositorOptions>;

 private:
  bool mUseAPZ = false;
  bool mUseSoftwareWebRender = false;
  bool mAllowSoftwareWebRenderD3D11 = false;
  bool mAllowSoftwareWebRenderOGL = false;
  bool mInitiallyPaused = false;
  bool mNeedFastSnaphot = false;
  bool mAllowNativeCompositor = true;

  // Make sure to add new fields to the ParamTraits implementation
  // in LayersMessageUtils.h
};

}  // namespace layers
}  // namespace mozilla

#endif  // _include_mozilla_gfx_ipc_CompositorOptions_h_
