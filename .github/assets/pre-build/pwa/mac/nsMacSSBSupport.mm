/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include "nsMacSSBSupport.h"

#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <ImageIO/ImageIO.h>

#include "imgIContainer.h"
#include "mozilla/ArrayUtils.h"
#include "mozilla/Sprintf.h"
#include "mozilla/ResultExtensions.h"
#include "nsAppDirectoryServiceDefs.h"
#include "nsCocoaUtils.h"
#include "nsCOMPtr.h"
#include "nsDirectoryServiceDefs.h"
#include "nsDirectoryServiceUtils.h"
#include "nsIFile.h"
#include "nsIMacDockSupport.h"
#include "nsISimpleEnumerator.h"
#include "nsDebug.h"
#include "nsNetUtil.h"
#include "nsObjCExceptions.h"
#include "nsServiceManagerUtils.h"

#include "prenv.h"

#include <unistd.h>

using namespace mozilla;

namespace {

constexpr auto kInstallRelativePath = u"Applications"_ns;
constexpr auto kInstallContainerLeaf = u"Floorp SSBs"_ns;
constexpr auto kContentsLeaf = u"Contents"_ns;
constexpr auto kMacOSLeaf = u"MacOS"_ns;
constexpr auto kResourcesLeaf = u"Resources"_ns;
constexpr auto kExecutableLeaf = u"floorp-ssb"_ns;
constexpr auto kIconLeaf = u"icon.icns"_ns;

const CGFloat kIconSizes[] = {16, 32, 64, 128, 256, 512, 1024};

nsresult WriteUTF8File(nsIFile* aFile, const nsACString& aData,
                       int32_t aPermissions) {
  nsCOMPtr<nsIOutputStream> output;
  nsresult rv = NS_NewLocalFileOutputStream(getter_AddRefs(output), aFile,
                                            PR_WRONLY | PR_CREATE_FILE |
                                                PR_TRUNCATE,
                                            aPermissions);
  NS_ENSURE_SUCCESS(rv, rv);

  uint32_t written = 0;
  rv = output->Write(aData.BeginReading(), aData.Length(), &written);
  NS_ENSURE_SUCCESS(rv, rv);
  if (written != aData.Length()) {
    return NS_ERROR_UNEXPECTED;
  }

  return output->Close();
}

nsresult RemoveIfExists(nsIFile* aFile) {
  bool exists = false;
  nsresult rv = aFile->Exists(&exists);
  NS_ENSURE_SUCCESS(rv, rv);
  if (exists) {
    rv = aFile->Remove(false);
    NS_ENSURE_SUCCESS(rv, rv);
  }
  return NS_OK;
}

}  // namespace

NS_IMPL_ISUPPORTS(nsMacSSBSupport, nsIMacSSBSupport)

nsMacSSBSupport::nsMacSSBSupport() = default;

nsMacSSBSupport::~nsMacSSBSupport() = default;

NS_IMETHODIMP
nsMacSSBSupport::Install(const nsAString& aId, const nsAString& aName,
                         imgIContainer* aIcon) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;

  nsAutoString sanitizedLeaf;
  nsCOMPtr<nsIFile> bundleRoot;
  MOZ_TRY(GetBundleRoot(aId, aName, getter_AddRefs(bundleRoot), sanitizedLeaf));

  MOZ_TRY(EnsureDirectory(bundleRoot));

  nsCOMPtr<nsIFile> contentsDir;
  nsCOMPtr<nsIFile> macOSDir;
  nsCOMPtr<nsIFile> resourcesDir;
  MOZ_TRY(EnsureAncillaryDirectories(bundleRoot, getter_AddRefs(contentsDir),
                                     getter_AddRefs(macOSDir),
                                     getter_AddRefs(resourcesDir)));

  MOZ_TRY(WriteExecutable(macOSDir, aId, aName));
  MOZ_TRY(WriteIcon(resourcesDir, aIcon));
  MOZ_TRY(WriteInfoPlist(contentsDir, aId, aName, aIcon != nullptr));
  MOZ_TRY(RegisterBundle(bundleRoot));

  return NS_OK;

  NS_OBJC_END_TRY_BLOCK_RETURN(NS_ERROR_FAILURE);
}

NS_IMETHODIMP
nsMacSSBSupport::Uninstall(const nsAString& aId, const nsAString& aName) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;

  MOZ_TRY(RemoveBundle(aId, aName));
  return NS_OK;

  NS_OBJC_END_TRY_BLOCK_RETURN(NS_ERROR_FAILURE);
}

NS_IMETHODIMP
nsMacSSBSupport::ApplyDockIntegration(const nsAString& aId,
                                      const nsAString& aName,
                                      imgIContainer* aIcon) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;

  nsCOMPtr<nsIMacDockSupport> dock =
      do_GetService("@mozilla.org/widget/macdocksupport;1");
  if (dock) {
    nsCOMPtr<nsIFile> bundleRoot;
    nsAutoString leaf;
    if (NS_SUCCEEDED(GetBundleRoot(aId, aName, getter_AddRefs(bundleRoot),
                                   leaf)) && bundleRoot) {
      nsAutoString bundlePath;
      if (NS_SUCCEEDED(bundleRoot->GetPath(bundlePath))) {
        bool isPinned = false;
        dock->EnsureAppIsPinnedToDock(bundlePath, EmptyString(), &isPinned);
        (void)isPinned;
      }
    }

    if (aIcon) {
      dock->SetBadgeImage(aIcon, nullptr);
    } else {
      dock->SetBadgeImage(nullptr, nullptr);
    }
  }

  if (aIcon) {
    nsAutoString dummyLeaf;
    nsCOMPtr<nsIFile> bundleRoot;
    if (NS_SUCCEEDED(GetBundleRoot(aId, aName, getter_AddRefs(bundleRoot),
                                   dummyLeaf)) && bundleRoot) {
      @autoreleasepool {
        NSSize preferredSize = NSMakeSize(512.0, 512.0);
        NSImage* iconImage = nil;
        bool isEntirelyBlack = false;
        if (NS_SUCCEEDED(nsCocoaUtils::CreateDualRepresentationNSImageFromImageContainer(
                aIcon, imgIContainer::FRAME_CURRENT, nullptr, preferredSize,
                &iconImage, &isEntirelyBlack)) && iconImage) {
          [[NSApp sharedApplication] setApplicationIconImage:iconImage];
        }
      }
    }
  }

  return NS_OK;

  NS_OBJC_END_TRY_BLOCK_RETURN(NS_ERROR_FAILURE);
}

nsresult nsMacSSBSupport::GetBundleInfoInternal(const nsAString& aId,
                                                const nsAString& aName,
                                                nsIFile** aBundleRoot,
                                                nsACString& aBundleId) {
  if (!aBundleRoot) {
    return NS_ERROR_INVALID_ARG;
  }
  *aBundleRoot = nullptr;

  nsCOMPtr<nsIFile> bundleRoot;
  nsAutoString leaf;
  MOZ_TRY(GetBundleRoot(aId, aName, getter_AddRefs(bundleRoot), leaf));

  bool exists = false;
  if (bundleRoot) {
    MOZ_TRY(bundleRoot->Exists(&exists));
  }

  if (!exists) {
    bundleRoot = nullptr;
  }

  BuildBundleIdentifier(aId, aBundleId);

  if (bundleRoot) {
    bundleRoot.forget(aBundleRoot);
  }

  return NS_OK;
}

NS_IMETHODIMP
nsMacSSBSupport::GetBundleInfo(const nsAString& aId, const nsAString& aName,
                               nsAString& aBundlePath,
                               nsAString& aBundleIdentifier) {
  NS_OBJC_BEGIN_TRY_BLOCK_RETURN;

  nsCOMPtr<nsIFile> bundleRoot;
  nsAutoCString bundleId;
  MOZ_TRY(GetBundleInfoInternal(aId, aName, getter_AddRefs(bundleRoot),
                                bundleId));

  if (bundleRoot) {
    nsAutoString path;
    MOZ_TRY(bundleRoot->GetPath(path));
    aBundlePath = path;
  } else {
    aBundlePath.Truncate();
  }

  aBundleIdentifier = NS_ConvertUTF8toUTF16(bundleId);

  return NS_OK;

  NS_OBJC_END_TRY_BLOCK_RETURN(NS_ERROR_FAILURE);
}

nsresult nsMacSSBSupport::GetBundleRoot(const nsAString& aId,
                                        const nsAString& aName,
                                        nsIFile** aFile,
                                        nsAString& aLeafName) {
  nsCOMPtr<nsIFile> homeDir;
  MOZ_TRY(NS_GetSpecialDirectory(NS_OS_HOME_DIR, getter_AddRefs(homeDir)));

  MOZ_TRY(homeDir->Append(kInstallRelativePath));
  MOZ_TRY(EnsureDirectory(homeDir));
  MOZ_TRY(homeDir->Append(kInstallContainerLeaf));
  MOZ_TRY(EnsureDirectory(homeDir));

  nsAutoString leaf;
  SanitizeLeafName(aId, aName, leaf);
  aLeafName = leaf;

  nsCOMPtr<nsIFile> bundleRoot;
  MOZ_TRY(homeDir->Clone(getter_AddRefs(bundleRoot)));
  MOZ_TRY(bundleRoot->Append(leaf));

  bundleRoot.forget(aFile);
  return NS_OK;
}

nsresult nsMacSSBSupport::EnsureDirectory(nsIFile* aDir) {
  bool exists = false;
  nsresult rv = aDir->Exists(&exists);
  NS_ENSURE_SUCCESS(rv, rv);
  if (exists) {
    return NS_OK;
  }
  rv = aDir->Create(nsIFile::DIRECTORY_TYPE, 0755);
  if (rv == NS_ERROR_FILE_ALREADY_EXISTS) {
    return NS_OK;
  }
  return rv;
}

nsresult nsMacSSBSupport::EnsureAncillaryDirectories(nsIFile* aBundleRoot,
                                                     nsIFile** aContents,
                                                     nsIFile** aMacOS,
                                                     nsIFile** aResources) {
  nsCOMPtr<nsIFile> contents;
  MOZ_TRY(aBundleRoot->Clone(getter_AddRefs(contents)));
  MOZ_TRY(contents->Append(kContentsLeaf));
  MOZ_TRY(EnsureDirectory(contents));

  nsCOMPtr<nsIFile> macOS;
  MOZ_TRY(contents->Clone(getter_AddRefs(macOS)));
  MOZ_TRY(macOS->Append(kMacOSLeaf));
  MOZ_TRY(EnsureDirectory(macOS));

  nsCOMPtr<nsIFile> resources;
  MOZ_TRY(contents->Clone(getter_AddRefs(resources)));
  MOZ_TRY(resources->Append(kResourcesLeaf));
  MOZ_TRY(EnsureDirectory(resources));

  contents.forget(aContents);
  macOS.forget(aMacOS);
  resources.forget(aResources);
  return NS_OK;
}

nsresult nsMacSSBSupport::EnsureFloorpBinarySymlink(nsIFile* aMacOSDir,
                                                    nsIFile* aExecutable) {
  nsCOMPtr<nsIFile> linkFile;
  MOZ_TRY(aMacOSDir->Clone(getter_AddRefs(linkFile)));
  MOZ_TRY(linkFile->Append(u"floorp-bin"_ns));

  bool exists = false;
  if (NS_SUCCEEDED(linkFile->Exists(&exists)) && exists) {
    MOZ_TRY(linkFile->Remove(false));
  }

  nsAutoString targetPath;
  MOZ_TRY(aExecutable->GetPath(targetPath));
  nsAutoString linkPath;
  MOZ_TRY(linkFile->GetPath(linkPath));

  nsAutoCString targetUTF8 = NS_ConvertUTF16toUTF8(targetPath);
  nsAutoCString linkUTF8 = NS_ConvertUTF16toUTF8(linkPath);
  if (::symlink(targetUTF8.get(), linkUTF8.get()) != 0) {
    return NS_ERROR_FAILURE;
  }
  return NS_OK;
}

nsresult nsMacSSBSupport::WriteLegacyLauncherScript(
    nsIFile* aMacOSDir, const nsACString& aProfilePath,
    const nsACString& aId) {
  nsCOMPtr<nsIFile> scriptFile;
  MOZ_TRY(aMacOSDir->Clone(getter_AddRefs(scriptFile)));
  MOZ_TRY(scriptFile->Append(kExecutableLeaf));

  bool exists = false;
  if (NS_SUCCEEDED(scriptFile->Exists(&exists)) && exists) {
    MOZ_TRY(scriptFile->Remove(false));
  }

  nsCString script;
  script.AppendLiteral("#!/bin/sh\n");
  script.AppendLiteral("DIR=\"$(dirname \"$0\")\"\n");
  script.AppendLiteral("exec \"$DIR/floorp-bin\" -profile \"");
  script.Append(aProfilePath);
  script.AppendLiteral("\" -start-ssb \"");
  script.Append(aId);
  script.AppendLiteral("\" \"$@\"\n");

  MOZ_TRY(WriteUTF8File(scriptFile, script, 0755));
  MOZ_TRY(scriptFile->SetPermissions(0755));
  return NS_OK;
}

nsresult nsMacSSBSupport::GetAppShimTemplate(nsIFile** aFile) {
  if (!aFile) {
    return NS_ERROR_INVALID_ARG;
  }
  *aFile = nullptr;

  if (const char* envPath = PR_GetEnv("FLOORP_APPSHIM_TEMPLATE")) {
    if (*envPath) {
      nsCOMPtr<nsIFile> fromEnv;
      if (NS_SUCCEEDED(
              NS_NewLocalFile(NS_ConvertUTF8toUTF16(envPath),
                              getter_AddRefs(fromEnv)))) {
        bool exists = false;
        bool isExecutable = false;
        if (NS_SUCCEEDED(fromEnv->Exists(&exists)) && exists &&
            NS_SUCCEEDED(fromEnv->IsExecutable(&isExecutable)) &&
            isExecutable) {
          fromEnv.forget(aFile);
          return NS_OK;
        }
      }
    }
  }

  nsCOMPtr<nsIProperties> directoryService =
      do_GetService(NS_DIRECTORY_SERVICE_CONTRACTID);
  NS_ENSURE_TRUE(directoryService, NS_ERROR_NOT_AVAILABLE);

  nsCOMPtr<nsIFile> executable;
  MOZ_TRY(directoryService->Get("XREExeF", NS_GET_IID(nsIFile),
                                getter_AddRefs(executable)));

  nsCOMPtr<nsIFile> macOSDir;
  MOZ_TRY(executable->GetParent(getter_AddRefs(macOSDir)));

  auto CandidateMatches = [](nsIFile* file) -> bool {
    if (!file) {
      return false;
    }
    bool exists = false;
    if (NS_FAILED(file->Exists(&exists)) || !exists) {
      return false;
    }
    bool isDirectory = false;
    if (NS_SUCCEEDED(file->IsDirectory(&isDirectory)) && isDirectory) {
      return false;
    }
    bool isExecutable = false;
    if (NS_FAILED(file->IsExecutable(&isExecutable)) || !isExecutable) {
      return false;
    }
    return true;
  };

  if (macOSDir) {
    nsCOMPtr<nsIFile> candidate;
    if (NS_SUCCEEDED(macOSDir->Clone(getter_AddRefs(candidate))) &&
        NS_SUCCEEDED(candidate->Append(u"appshim"_ns)) &&
        NS_SUCCEEDED(candidate->Append(kExecutableLeaf)) &&
        CandidateMatches(candidate)) {
      candidate.forget(aFile);
      return NS_OK;
    }
  }

  nsCOMPtr<nsIFile> contentsDir;
  if (macOSDir) {
    macOSDir->GetParent(getter_AddRefs(contentsDir));
  }

  if (contentsDir) {
    nsCOMPtr<nsIFile> resources;
    if (NS_SUCCEEDED(contentsDir->Clone(getter_AddRefs(resources))) &&
        NS_SUCCEEDED(resources->Append(kResourcesLeaf))) {
      nsCOMPtr<nsIFile> appShim;
      if (NS_SUCCEEDED(resources->Clone(getter_AddRefs(appShim))) &&
          NS_SUCCEEDED(appShim->Append(u"appshim"_ns)) &&
          NS_SUCCEEDED(appShim->Append(kExecutableLeaf)) &&
          CandidateMatches(appShim)) {
        appShim.forget(aFile);
        return NS_OK;
      }

      nsCOMPtr<nsIFile> pwaAppShim;
      if (NS_SUCCEEDED(resources->Clone(getter_AddRefs(pwaAppShim))) &&
          NS_SUCCEEDED(pwaAppShim->Append(u"pwa"_ns)) &&
          NS_SUCCEEDED(pwaAppShim->Append(u"appshim"_ns)) &&
          NS_SUCCEEDED(pwaAppShim->Append(kExecutableLeaf)) &&
          CandidateMatches(pwaAppShim)) {
        pwaAppShim.forget(aFile);
        return NS_OK;
      }
    }
  }

  return NS_OK;
}

nsresult nsMacSSBSupport::CopyAppShimExecutable(nsIFile* aMacOSDir,
                                                bool* aDidCopy) {
  if (!aDidCopy) {
    return NS_ERROR_INVALID_ARG;
  }
  *aDidCopy = false;

  nsCOMPtr<nsIFile> templateFile;
  MOZ_TRY(GetAppShimTemplate(getter_AddRefs(templateFile)));
  if (!templateFile) {
    return NS_OK;
  }

  nsCOMPtr<nsIFile> destination;
  MOZ_TRY(aMacOSDir->Clone(getter_AddRefs(destination)));
  MOZ_TRY(destination->Append(kExecutableLeaf));

  bool exists = false;
  if (NS_SUCCEEDED(destination->Exists(&exists)) && exists) {
    MOZ_TRY(destination->Remove(false));
  }

  MOZ_TRY(templateFile->CopyToFollowingLinks(aMacOSDir, kExecutableLeaf));

  nsCOMPtr<nsIFile> copied;
  MOZ_TRY(aMacOSDir->Clone(getter_AddRefs(copied)));
  MOZ_TRY(copied->Append(kExecutableLeaf));
  MOZ_TRY(copied->SetPermissions(0755));

  *aDidCopy = true;
  return NS_OK;
}

nsresult nsMacSSBSupport::WriteAppShimConfiguration(
    nsIFile* aMacOSDir, const nsAString& aId, const nsAString& aName,
    const nsACString& aProfilePath, const nsACString& aBinaryPath) {
  nsCOMPtr<nsIFile> configFile;
  MOZ_TRY(aMacOSDir->Clone(getter_AddRefs(configFile)));
  MOZ_TRY(configFile->Append(u"appshim-config.json"_ns));

  nsAutoCString escapedProfile;
  EscapeForJSON(aProfilePath, escapedProfile);

  nsAutoCString escapedBinary;
  EscapeForJSON(aBinaryPath, escapedBinary);

  nsAutoCString idUTF8 = NS_ConvertUTF16toUTF8(aId);
  nsAutoCString escapedId;
  EscapeForJSON(idUTF8, escapedId);

  nsAutoCString nameUTF8 = NS_ConvertUTF16toUTF8(aName);
  nsAutoCString escapedName;
  EscapeForJSON(nameUTF8, escapedName);

  nsCString json;
  json.AppendLiteral("{\n");
  json.AppendLiteral("  \"schemaVersion\": 1,\n");
  json.AppendLiteral("  \"floorpBinaryCandidates\": [\n");
  json.AppendLiteral("    \"@executable_dir/floorp-bin\"");
  if (!escapedBinary.IsEmpty()) {
    json.AppendLiteral(",\n    \"");
    json.Append(escapedBinary);
    json.AppendLiteral("\"");
  }
  json.AppendLiteral("\n  ],\n");
  json.AppendLiteral("  \"appendArguments\": [\n");
  json.AppendLiteral("    \"-profile\",\n");
  json.AppendLiteral("    \"");
  json.Append(escapedProfile);
  json.AppendLiteral("\",\n");
  json.AppendLiteral("    \"-start-ssb\",\n");
  json.AppendLiteral("    \"");
  json.Append(escapedId);
  json.AppendLiteral("\"\n");
  json.AppendLiteral("  ],\n");
  json.AppendLiteral("  \"environment\": {\n");
  json.AppendLiteral("    \"FLOORP_SSB_ID\": \"");
  json.Append(escapedId);
  json.AppendLiteral("\"");
  if (!escapedName.IsEmpty()) {
    json.AppendLiteral(",\n    \"FLOORP_SSB_NAME\": \"");
    json.Append(escapedName);
    json.AppendLiteral("\"");
  }
  json.AppendLiteral("\n  },\n");
  json.AppendLiteral("  \"metadata\": {\n");
  json.AppendLiteral("    \"ssbId\": \"");
  json.Append(escapedId);
  json.AppendLiteral("\"");
  if (!escapedName.IsEmpty()) {
    json.AppendLiteral(",\n    \"ssbName\": \"");
    json.Append(escapedName);
    json.AppendLiteral("\"");
  }
  json.AppendLiteral("\n  }\n");
  json.AppendLiteral("}\n");

  MOZ_TRY(WriteUTF8File(configFile, json, 0644));
  return NS_OK;
}

nsresult nsMacSSBSupport::WriteExecutable(nsIFile* aMacOSDir,
                                          const nsAString& aId,
                                          const nsAString& aName) {
  nsCOMPtr<nsIFile> profileDir;
  MOZ_TRY(GetProfileDirectory(getter_AddRefs(profileDir)));
  nsAutoString profilePath;
  MOZ_TRY(profileDir->GetPath(profilePath));

  nsCOMPtr<nsIFile> binaryFile;
  MOZ_TRY(GetExecutable(getter_AddRefs(binaryFile)));
  nsAutoString binaryPath;
  MOZ_TRY(binaryFile->GetPath(binaryPath));

  MOZ_TRY(EnsureFloorpBinarySymlink(aMacOSDir, binaryFile));

  nsAutoCString profileUTF8 = NS_ConvertUTF16toUTF8(profilePath);
  nsAutoCString binaryUTF8 = NS_ConvertUTF16toUTF8(binaryPath);
  nsAutoCString idUTF8 = NS_ConvertUTF16toUTF8(aId);

  MOZ_TRY(WriteAppShimConfiguration(aMacOSDir, aId, aName, profileUTF8,
                                    binaryUTF8));

  bool didCopy = false;
  nsresult copyRv = CopyAppShimExecutable(aMacOSDir, &didCopy);
  if (NS_SUCCEEDED(copyRv) && didCopy) {
    return NS_OK;
  }

  if (NS_FAILED(copyRv)) {
    NS_WARNING(
        "nsMacSSBSupport::CopyAppShimExecutable failed; falling back to "
        "legacy launcher script.");
  }

  // Fallback to legacy shell script launcher when AppShim template is not
  // available.
  nsAutoCString sanitizedProfile(profileUTF8);
  nsAutoCString sanitizedId(idUTF8);
  sanitizedProfile.ReplaceSubstring("\"", "\\\"");
  sanitizedId.ReplaceSubstring("\"", "\\\"");

  MOZ_TRY(WriteLegacyLauncherScript(aMacOSDir, sanitizedProfile, sanitizedId));
  return NS_OK;
}

nsresult nsMacSSBSupport::WriteInfoPlist(nsIFile* aContentsDir,
                                         const nsAString& aId,
                                         const nsAString& aName,
                                         bool aHasIcon) {
  nsCOMPtr<nsIFile> infoPlist;
  MOZ_TRY(aContentsDir->Clone(getter_AddRefs(infoPlist)));
  MOZ_TRY(infoPlist->Append(u"Info.plist"_ns));

  nsCString bundleId;
  BuildBundleIdentifier(aId, bundleId);

  nsCString displayName = NS_ConvertUTF16toUTF8(aName);
  if (displayName.IsEmpty()) {
    displayName.AssignLiteral("Floorp SSB");
  }

  nsCString escapedName;
  EscapeForPlist(displayName, escapedName);
  nsCString escapedIdentifier;
  EscapeForPlist(bundleId, escapedIdentifier);

  nsCString plist;
  plist.AppendLiteral("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
  plist.AppendLiteral("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
  plist.AppendLiteral("<plist version=\"1.0\">\n<dict>\n");
  plist.AppendLiteral("  <key>CFBundleName</key>\n  <string>");
  plist.Append(escapedName);
  plist.AppendLiteral("</string>\n  <key>CFBundleDisplayName</key>\n  <string>");
  plist.Append(escapedName);
  plist.AppendLiteral("</string>\n  <key>CFBundleIdentifier</key>\n  <string>");
  plist.Append(escapedIdentifier);
  plist.AppendLiteral("</string>\n  <key>CFBundleExecutable</key>\n  <string>floorp-ssb</string>\n  <key>CFBundlePackageType</key>\n  <string>APPL</string>\n  <key>LSBackgroundOnly</key>\n  <false/>\n  <key>LSMultipleInstancesProhibited</key>\n  <true/>\n  <key>LSApplicationCategoryType</key>\n  <string>public.app-category.productivity</string>\n  <key>LSMinimumSystemVersion</key>\n  <string>10.15</string>\n");
  if (aHasIcon) {
    plist.AppendLiteral("  <key>CFBundleIconFile</key>\n  <string>icon</string>\n  <key>CFBundleIconName</key>\n  <string>icon</string>\n");
  }
  plist.AppendLiteral("  <key>CFBundleShortVersionString</key>\n  <string>1.0</string>\n  <key>CFBundleVersion</key>\n  <string>1.0</string>\n  <key>NSHighResolutionCapable</key>\n  <true/>\n</dict>\n</plist>\n");

  MOZ_TRY(WriteUTF8File(infoPlist, plist, 0644));
  return NS_OK;
}

nsresult nsMacSSBSupport::WriteIcon(nsIFile* aResourcesDir,
                                    imgIContainer* aIcon) {
  nsCOMPtr<nsIFile> iconFile;
  MOZ_TRY(aResourcesDir->Clone(getter_AddRefs(iconFile)));
  MOZ_TRY(iconFile->Append(kIconLeaf));

  if (!aIcon) {
    return RemoveIfExists(iconFile);
  }

  nsAutoString iconPath;
  MOZ_TRY(iconFile->GetPath(iconPath));

  @autoreleasepool {
    NSSize preferredSize = NSMakeSize(1024.0, 1024.0);
    NSImage* sourceImage = nil;
    bool isEntirelyBlack = false;
    nsresult rv = nsCocoaUtils::CreateDualRepresentationNSImageFromImageContainer(
        aIcon, imgIContainer::FRAME_CURRENT, nullptr, preferredSize,
        &sourceImage, &isEntirelyBlack);
    if (NS_FAILED(rv) || !sourceImage) {
      return rv;
    }

    NSString* iconNSString = nsCocoaUtils::ToNSString(iconPath);
    NSURL* iconURL = [NSURL fileURLWithPath:iconNSString];

    const size_t representationCount =
        sizeof(kIconSizes) / sizeof(kIconSizes[0]);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)iconURL, kUTTypeAppleICNS, representationCount,
        nullptr);
    if (!destination) {
      return NS_ERROR_FAILURE;
    }

    bool wroteAtLeastOneImage = false;
    for (CGFloat size : kIconSizes) {
      NSSize targetSize = NSMakeSize(size, size);
      NSImage* scaledImage = [[[NSImage alloc] initWithSize:targetSize] autorelease];
      if (!scaledImage) {
        continue;
      }

      [scaledImage lockFocus];
      [sourceImage drawInRect:NSMakeRect(0, 0, targetSize.width, targetSize.height)
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationCopy
                     fraction:1.0
               respectFlipped:YES
                        hints:@{NSImageHintInterpolation : @(NSImageInterpolationHigh)}];
      [scaledImage unlockFocus];

      CGImageRef cgImage = [scaledImage CGImageForProposedRect:nullptr context:nil hints:nil];
      if (!cgImage) {
        continue;
      }

      CGImageDestinationAddImage(destination, cgImage, nullptr);
      wroteAtLeastOneImage = true;
    }

    bool success = wroteAtLeastOneImage && CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (!success) {
      return NS_ERROR_FAILURE;
    }
  }

  return NS_OK;
}

nsresult nsMacSSBSupport::RegisterBundle(nsIFile* aBundleRoot) {
  nsAutoString bundlePath;
  MOZ_TRY(aBundleRoot->GetPath(bundlePath));

  @autoreleasepool {
    NSURL* bundleURL = [NSURL fileURLWithPath:nsCocoaUtils::ToNSString(bundlePath)];
    if (!bundleURL) {
      return NS_ERROR_FAILURE;
    }
    OSStatus status = LSRegisterURL((__bridge CFURLRef)bundleURL, true);
    if (status != noErr) {
      return NS_ERROR_FAILURE;
    }
  }

  return NS_OK;
}

nsresult nsMacSSBSupport::RemoveBundle(const nsAString& aId,
                                       const nsAString& aName) {
  nsCOMPtr<nsIFile> bundleRoot;
  nsAutoString leaf;
  MOZ_TRY(GetBundleRoot(aId, aName, getter_AddRefs(bundleRoot), leaf));

  bool exists = false;
  MOZ_TRY(bundleRoot->Exists(&exists));
  if (!exists) {
    return NS_OK;
  }

  return bundleRoot->Remove(true);
}

nsresult nsMacSSBSupport::GetProfileDirectory(nsIFile** aFile) {
  nsCOMPtr<nsIFile> profileDir;
  MOZ_TRY(NS_GetSpecialDirectory(NS_APP_PROFILE_DIR_STARTUP,
                                 getter_AddRefs(profileDir)));
  profileDir.forget(aFile);
  return NS_OK;
}

nsresult nsMacSSBSupport::GetExecutable(nsIFile** aFile) {
  nsCOMPtr<nsIProperties> directoryService =
      do_GetService(NS_DIRECTORY_SERVICE_CONTRACTID);
  NS_ENSURE_TRUE(directoryService, NS_ERROR_NOT_AVAILABLE);

  nsCOMPtr<nsIFile> executable;
  MOZ_TRY(directoryService->Get("XREExeF", NS_GET_IID(nsIFile),
                                getter_AddRefs(executable)));
  executable.forget(aFile);
  return NS_OK;
}

void nsMacSSBSupport::BuildBundleIdentifier(const nsAString& aId,
                                            nsACString& aResult) {
  aResult.AssignLiteral("one.ablaze.floorp.ssb.");
  nsAutoCString utf8Id = NS_ConvertUTF16toUTF8(aId);
  for (uint32_t i = 0; i < utf8Id.Length(); ++i) {
    const char ch = utf8Id[i];
    if ((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= 'a' && ch <= 'z') || ch == '-' || ch == '.') {
      aResult.Append(ch);
    } else {
      aResult.Append('-');
    }
  }
}

void nsMacSSBSupport::SanitizeLeafName(const nsAString& aId,
                                       const nsAString& aName,
                                       nsAString& aResult) {
  nsAutoString base;
  if (aName.IsEmpty()) {
    base.AssignLiteral("FloorpSSB");
  } else {
    base.Assign(aName);
  }
  base.AppendLiteral("-");
  base.Append(aId);

  aResult.Truncate();
  for (uint32_t i = 0; i < base.Length(); ++i) {
    const char16_t ch = base[i];
    if ((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= 'a' && ch <= 'z') || ch == u'-' || ch == u'_' || ch == u'.') {
      aResult.Append(ch);
    } else {
      aResult.Append(u'-');
    }
  }
  aResult.AppendLiteral(".app");
}

void nsMacSSBSupport::EscapeForPlist(const nsACString& aInput,
                                     nsACString& aOutput) {
  aOutput.Assign(aInput);
  aOutput.ReplaceSubstring("&", "&amp;");
  aOutput.ReplaceSubstring("<", "&lt;");
  aOutput.ReplaceSubstring(">", "&gt;");
  aOutput.ReplaceSubstring("\"", "&quot;");
  aOutput.ReplaceSubstring("'", "&apos;");
}

void nsMacSSBSupport::EscapeForJSON(const nsACString& aInput,
                                    nsACString& aOutput) {
  aOutput.Truncate();
  for (uint32_t i = 0; i < aInput.Length(); ++i) {
    const char ch = aInput[i];
    switch (ch) {
      case '\\':
        aOutput.AppendLiteral("\\\\");
        break;
      case '"':
        aOutput.AppendLiteral("\\\"");
        break;
      case '\b':
        aOutput.AppendLiteral("\\b");
        break;
      case '\f':
        aOutput.AppendLiteral("\\f");
        break;
      case '\n':
        aOutput.AppendLiteral("\\n");
        break;
      case '\r':
        aOutput.AppendLiteral("\\r");
        break;
      case '\t':
        aOutput.AppendLiteral("\\t");
        break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20) {
          char buffer[7];
          SprintfLiteral(buffer, "\\u%04X",
                         static_cast<unsigned char>(ch));
          aOutput.Append(buffer);
        } else {
          aOutput.Append(ch);
        }
        break;
    }
  }
}
