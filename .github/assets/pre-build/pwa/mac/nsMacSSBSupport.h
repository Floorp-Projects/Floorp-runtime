/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef nsMacSSBSupport_h_
#define nsMacSSBSupport_h_

#include "nsIMacSSBSupport.h"

#include "mozilla/Attributes.h"
#include "nsCOMPtr.h"
#include "nsString.h"

class nsIFile;

class nsMacSSBSupport final : public nsIMacSSBSupport {
 public:
  NS_DECL_ISUPPORTS
  NS_DECL_NSIMACSSBSUPPORT

  nsMacSSBSupport();

 private:
  ~nsMacSSBSupport();

  nsresult GetBundleRoot(const nsAString& aId, const nsAString& aName,
                         nsIFile** aFile, nsAString& aLeafName);
  nsresult EnsureDirectory(nsIFile* aDir);
  nsresult EnsureAncillaryDirectories(nsIFile* aBundleRoot, nsIFile** aContents,
                                      nsIFile** aMacOS, nsIFile** aResources);
  nsresult WriteExecutable(nsIFile* aMacOSDir, const nsAString& aId,
                           const nsAString& aName);
  nsresult WriteInfoPlist(nsIFile* aContentsDir, const nsAString& aId,
                          const nsAString& aName, bool aHasIcon);
  nsresult WriteIcon(nsIFile* aResourcesDir, imgIContainer* aIcon);
  nsresult RegisterBundle(nsIFile* aBundleRoot);
  nsresult RemoveBundle(const nsAString& aId, const nsAString& aName);
  nsresult GetProfileDirectory(nsIFile** aFile);
  nsresult GetExecutable(nsIFile** aFile);

  void BuildBundleIdentifier(const nsAString& aId, nsACString& aResult);
  void SanitizeLeafName(const nsAString& aId, const nsAString& aName,
                        nsAString& aResult);
  void EscapeForPlist(const nsACString& aInput, nsACString& aOutput);
  void EscapeForJSON(const nsACString& aInput, nsACString& aOutput);
  nsresult EnsureFloorpBinarySymlink(nsIFile* aMacOSDir, nsIFile* aExecutable);
  nsresult WriteLegacyLauncherScript(nsIFile* aMacOSDir,
                                     const nsACString& aProfilePath,
                                     const nsACString& aId);
  nsresult GetAppShimTemplate(nsIFile** aFile);
  nsresult CopyAppShimExecutable(nsIFile* aMacOSDir, bool* aDidCopy);
  nsresult WriteAppShimConfiguration(nsIFile* aMacOSDir, const nsAString& aId,
                                     const nsAString& aName,
                                     const nsACString& aProfilePath,
                                     const nsACString& aBinaryPath);
};

#endif  // nsMacSSBSupport_h_
