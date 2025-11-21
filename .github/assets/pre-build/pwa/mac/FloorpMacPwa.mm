/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include "FloorpMacPwa.h"

#include "MacStringHelpers.h"
#include "mozilla/Logging.h"
#include "mozilla/ScopeExit.h"
#include "nsCOMPtr.h"
#include "nsPrintfCString.h"
#include "nsString.h"

#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>

#include <errno.h>
#include <sys/stat.h>
#include <sys/xattr.h>

namespace mozilla {

namespace {

LazyLogModule gMacPwaLog("FloorpMacPwa");

NSString* ToNSString(const nsAString& aValue) {
  return XPCOMStringToNSString(aValue);
}

bool EnsureDirectory(NSString* aPath) {
  if (!aPath.length) {
    return false;
  }

  NSError* error = nil;
  NSDictionary* attributes = @{
    NSFilePosixPermissions : @(0755)
  };
  bool ok = [[NSFileManager defaultManager]
      createDirectoryAtPath:aPath
 withIntermediateDirectories:YES
                  attributes:attributes
                       error:&error];
  if (!ok && error) {
    MOZ_LOG(gMacPwaLog, LogLevel::Error,
            ("[FloorpMacPwa] Failed to create directory %s: %s",
             aPath.fileSystemRepresentation,
             error.localizedDescription.UTF8String));
  }
  return ok;
}

void RemoveQuarantineAttribute(NSString* aPath) {
  if (!aPath.length) {
    return;
  }
  const char* filePath = aPath.fileSystemRepresentation;
  if (!filePath) {
    return;
  }

  int result =
      removexattr(filePath, "com.apple.quarantine", XATTR_NOFOLLOW);
  if (result == -1 && errno != ENOATTR) {
    MOZ_LOG(gMacPwaLog, LogLevel::Warning,
            ("[FloorpMacPwa] Failed to remove quarantine from %s: %s",
             filePath, strerror(errno)));
  }
}

void RemoveQuarantineRecursively(NSString* aRootPath) {
  RemoveQuarantineAttribute(aRootPath);

  NSFileManager* fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator<NSString*>* enumerator =
      [fm enumeratorAtPath:aRootPath];
  for (NSString* relativePath in enumerator) {
    NSString* fullPath =
        [aRootPath stringByAppendingPathComponent:relativePath];
    RemoveQuarantineAttribute(fullPath);
  }
}

bool WriteCStringToFile(NSString* aPath, const nsACString& aData) {
  auto str = [[NSString alloc]
      initWithBytes:aData.BeginReading()
             length:aData.Length()
           encoding:NSUTF8StringEncoding];
  if (!str) {
    MOZ_LOG(gMacPwaLog, LogLevel::Error,
            ("[FloorpMacPwa] Failed to convert data to NSString for %s",
             aPath.fileSystemRepresentation));
    return false;
  }

  NSError* error = nil;
  const bool ok = [str writeToFile:aPath
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:&error];
  if (!ok && error) {
    MOZ_LOG(gMacPwaLog, LogLevel::Error,
            ("[FloorpMacPwa] Failed to write file %s: %s",
             aPath.fileSystemRepresentation,
             error.localizedDescription.UTF8String));
  }
  return ok;
}

bool WriteDataToFile(NSString* aPath, NSData* aData) {
  if (!aData) {
    return false;
  }
  NSError* error = nil;
  const bool ok =
      [aData writeToFile:aPath options:NSDataWritingAtomic error:&error];
  if (!ok && error) {
    MOZ_LOG(gMacPwaLog, LogLevel::Error,
            ("[FloorpMacPwa] Failed to write binary file %s: %s",
             aPath.fileSystemRepresentation,
             error.localizedDescription.UTF8String));
  }
  return ok;
}

bool SetPosixPermissions(NSString* aPath, uint16_t aPermissions) {
  NSError* error = nil;
  NSDictionary* attributes = @{
    NSFilePosixPermissions : @(aPermissions)
  };
  const bool ok = [[NSFileManager defaultManager]
      setAttributes:attributes
        ofItemAtPath:aPath
               error:&error];
  if (!ok && error) {
    MOZ_LOG(gMacPwaLog, LogLevel::Warning,
            ("[FloorpMacPwa] Failed to set permissions on %s: %s",
             aPath.fileSystemRepresentation,
             error.localizedDescription.UTF8String));
  }
  return ok;
}

nsCString QuoteForShell(const nsAString& aInput) {
  nsCString result("\"");

  NS_ConvertUTF16toUTF8 utf8(aInput);
  const char* cur = utf8.BeginReading();
  const char* end = utf8.EndReading();
  for (; cur < end; ++cur) {
    char ch = *cur;
    if (ch == '"' || ch == '\\' || ch == '$' || ch == '`') {
      result.Append('\\');
    }
    result.Append(ch);
  }

  result.Append('"');
  return result;
}

void AppendEscapedXML(const nsACString& aValue, nsCString& aOut) {
  const char* cur = aValue.BeginReading();
  const char* end = aValue.EndReading();
  for (; cur < end; ++cur) {
    char c = *cur;
    switch (c) {
      case '&':
        aOut.AppendLiteral("&amp;");
        break;
      case '<':
        aOut.AppendLiteral("&lt;");
        break;
      case '>':
        aOut.AppendLiteral("&gt;");
        break;
      case '"':
        aOut.AppendLiteral("&quot;");
        break;
      case '\'':
        aOut.AppendLiteral("&apos;");
        break;
      default:
        aOut.Append(c);
        break;
    }
  }
}

void AppendPlistString(const char* aKey, const nsAString& aValue,
                       nsCString& aOut) {
  aOut.AppendLiteral("<key>");
  aOut.Append(aKey);
  aOut.AppendLiteral("</key>\n<string>");
  AppendEscapedXML(NS_ConvertUTF16toUTF8(aValue), aOut);
  aOut.AppendLiteral("</string>\n");
}

void AppendBooleanKey(const char* aKey, bool aValue, nsCString& aOut) {
  aOut.AppendLiteral("<key>");
  aOut.Append(aKey);
  aOut.AppendLiteral("</key>\n");
  aOut.Append(aValue ? "<true/>\n" : "<false/>\n");
}

nsCString BuildInfoPlist(const nsAString& aAppName,
                         const nsAString& aBundleIdentifier,
                         const nsAString& aAppId,
                         const nsAString& aStartUrl,
                         const nsAString& aProfileDir,
                         const nsAString& aProfileName,
                         const nsAString& aVersionString) {
  nsCString plist;
  plist.AppendLiteral(
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
      "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
      "<plist version=\"1.0\">\n"
      "<dict>\n");

  AppendPlistString("CFBundleName", aAppName, plist);
  AppendPlistString("CFBundleDisplayName", aAppName, plist);
  AppendPlistString("CFBundleIdentifier", aBundleIdentifier, plist);
  AppendPlistString("CFBundleExecutable", u"app_shim"_ns, plist);
  AppendPlistString("CFBundleIconFile", u"app.icns"_ns, plist);
  AppendPlistString("CFBundleVersion", aVersionString, plist);
  AppendPlistString("CFBundleShortVersionString", aVersionString, plist);
  AppendPlistString("CFBundlePackageType", u"APPL"_ns, plist);
  AppendBooleanKey("LSHasLocalizedDisplayName", false, plist);
  AppendBooleanKey("NSHighResolutionCapable", true, plist);

  AppendPlistString("FloorpSSBId", aAppId, plist);
  AppendPlistString("FloorpStartURL", aStartUrl, plist);
  AppendPlistString("FloorpProfileDir", aProfileDir, plist);
  AppendPlistString("FloorpProfileName", aProfileName, plist);

  plist.AppendLiteral("</dict>\n</plist>\n");
  return plist;
}

bool ConvertIconToIcns(NSString* aSourcePath, NSString* aDestinationPath) {
  if (!aSourcePath.length || !aDestinationPath.length) {
    return false;
  }

  NSImage* image =
      [[NSImage alloc] initWithContentsOfFile:aSourcePath];
  if (!image) {
    MOZ_LOG(gMacPwaLog, LogLevel::Warning,
            ("[FloorpMacPwa] Failed to load icon at %s",
             aSourcePath.fileSystemRepresentation));
    return false;
  }

  NSData* tiffData = [image TIFFRepresentation];
  if (!tiffData) {
    return false;
  }
  NSBitmapImageRep* bitmap =
      [NSBitmapImageRep imageRepWithData:tiffData];
  if (!bitmap) {
    return false;
  }

  // NSBitmapImageFileTypeIcon is not available in recent SDKs or standard headers.
  // We need to use a different method (e.g. iconutil) to generate ICNS files.
  // For now, fail the conversion.
  MOZ_LOG(gMacPwaLog, LogLevel::Warning,
          ("[FloorpMacPwa] ICNS generation via NSBitmapImageRep is not supported."));
  return false;
  /*
  NSData* icnsData = [bitmap representationUsingType:NSBitmapImageFileTypeIcon
                                           properties:properties];
  if (!icnsData) {
    MOZ_LOG(gMacPwaLog, LogLevel::Warning,
            ("[FloorpMacPwa] Failed to convert icon to ICNS"));
    return false;
  }

  return WriteDataToFile(aDestinationPath, icnsData);
  */
}

void RegisterBundleWithLaunchServices(NSString* aBundlePath) {
  if (!aBundlePath.length) {
    return;
  }
  NSURL* bundleURL =
      [NSURL fileURLWithPath:aBundlePath isDirectory:YES];
  if (!bundleURL) {
    return;
  }
  LSRegisterURL((__bridge CFURLRef)bundleURL, true);
}

bool RunAdHocCodeSign(NSString* aBundlePath) {
  if (!aBundlePath.length) {
    return false;
  }

  NSString* codesignPath = @"/usr/bin/codesign";
  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm isExecutableFileAtPath:codesignPath]) {
    MOZ_LOG(gMacPwaLog, LogLevel::Warning,
            ("[FloorpMacPwa] codesign tool missing at %s",
             codesignPath.fileSystemRepresentation));
    return false;
  }

  NSTask* task = [[NSTask alloc] init];
  task.launchPath = codesignPath;
  task.arguments = @[
    @"--force",
    @"--sign",
    @"-",
    @"--deep",
    aBundlePath,
  ];

  NSPipe* stderrPipe = [NSPipe pipe];
  task.standardError = stderrPipe;

  NSError* error = nil;
  bool launched = false;
  if (@available(macOS 10.13, *)) {
    launched = [task launchAndReturnError:&error];
  } else {
    @try {
      [task launch];
      launched = true;
    } @catch (NSException* exception) {
      MOZ_LOG(gMacPwaLog, LogLevel::Warning,
              ("[FloorpMacPwa] Failed to launch codesign task: %s",
               exception.reason.UTF8String));
      launched = false;
    }
  }

  if (!launched) {
    if (error) {
      MOZ_LOG(gMacPwaLog, LogLevel::Warning,
              ("[FloorpMacPwa] Could not launch codesign: %s",
               error.localizedDescription.UTF8String));
    }
    return false;
  }

  [task waitUntilExit];
  if (task.terminationStatus != 0) {
    NSData* stderrData =
        [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    NSString* stderrString = [[NSString alloc]
        initWithData:stderrData
            encoding:NSUTF8StringEncoding];
    MOZ_LOG(gMacPwaLog, LogLevel::Warning,
            ("[FloorpMacPwa] codesign failed (%d): %s",
             task.terminationStatus,
             stderrString ? stderrString.UTF8String : "unknown error"));
    return false;
  }

  return true;
}

}  // namespace

FloorpMacPwa::FloorpMacPwa() = default;

FloorpMacPwa::~FloorpMacPwa() = default;

NS_IMPL_ISUPPORTS(FloorpMacPwa, nsIFloorpMacPwa)

NS_IMETHODIMP
FloorpMacPwa::CreateOrUpdateApp(const nsAString& aBundlePath,
                                const nsAString& aAppName,
                                const nsAString& aBundleIdentifier,
                                const nsAString& aAppId,
                                const nsAString& aStartUrl,
                                const nsAString& aFloorpExecutablePath,
                                const nsAString& aProfileDir,
                                const nsAString& aProfileName,
                                const nsAString& aVersionString,
                                const nsAString& aIconSourcePath) {
  if (aBundlePath.IsEmpty() || aAppName.IsEmpty() ||
      aBundleIdentifier.IsEmpty() || aAppId.IsEmpty() ||
      aFloorpExecutablePath.IsEmpty()) {
    return NS_ERROR_INVALID_ARG;
  }

  @autoreleasepool {
    NSString* bundlePath = ToNSString(aBundlePath);
    NSString* contentsPath =
        [bundlePath stringByAppendingPathComponent:@"Contents"];
    NSString* macOSPath =
        [contentsPath stringByAppendingPathComponent:@"MacOS"];
    NSString* resourcesPath =
        [contentsPath stringByAppendingPathComponent:@"Resources"];

    NSFileManager* fm = [NSFileManager defaultManager];
    NSError* error = nil;
    if ([fm fileExistsAtPath:bundlePath]) {
      if (![fm removeItemAtPath:bundlePath error:&error]) {
        MOZ_LOG(gMacPwaLog, LogLevel::Error,
                ("[FloorpMacPwa] Failed to clean existing bundle %s: %s",
                 bundlePath.fileSystemRepresentation,
                 error.localizedDescription.UTF8String));
        return NS_ERROR_FAILURE;
      }
    }

    if (!EnsureDirectory(resourcesPath) ||
        !EnsureDirectory(macOSPath)) {
      return NS_ERROR_FAILURE;
    }

    nsCString launcherScript;
    nsCString quotedExe = QuoteForShell(aFloorpExecutablePath);
    nsCString quotedProfileDir = QuoteForShell(aProfileDir);
    nsCString quotedAppId = QuoteForShell(aAppId);

    launcherScript.Append("#!/bin/bash\n");
    launcherScript.Append("exec ");
    launcherScript.Append(quotedExe);
    launcherScript.Append(" --profile ");
    launcherScript.Append(quotedProfileDir);
    launcherScript.Append(" --start-ssb ");
    launcherScript.Append(quotedAppId);
    launcherScript.Append(" \"$@\"\n");

    NSString* launcherPath =
        [macOSPath stringByAppendingPathComponent:@"app_shim"];
    if (!WriteCStringToFile(launcherPath, launcherScript) ||
        !SetPosixPermissions(launcherPath, 0755)) {
      return NS_ERROR_FAILURE;
    }

    NSString* pkgInfoPath =
        [contentsPath stringByAppendingPathComponent:@"PkgInfo"];
    NSData* pkgInfoData =
        [NSData dataWithBytes:"APPL????" length:8];
    if (!WriteDataToFile(pkgInfoPath, pkgInfoData)) {
      return NS_ERROR_FAILURE;
    }

    const nsString version(aVersionString.IsEmpty() ? u"1.0"_ns : aVersionString);
    nsCString plist =
        BuildInfoPlist(aAppName, aBundleIdentifier, aAppId, aStartUrl,
                       aProfileDir, aProfileName, version);
    NSString* plistPath =
        [contentsPath stringByAppendingPathComponent:@"Info.plist"];
    if (!WriteCStringToFile(plistPath, plist)) {
      return NS_ERROR_FAILURE;
    }

    if (!aIconSourcePath.IsEmpty()) {
      NSString* iconSource = ToNSString(aIconSourcePath);
      if ([fm fileExistsAtPath:iconSource]) {
        NSString* iconDestination =
            [resourcesPath stringByAppendingPathComponent:@"app.icns"];
        [fm removeItemAtPath:iconDestination error:nil];
        if (!ConvertIconToIcns(iconSource, iconDestination)) {
          MOZ_LOG(gMacPwaLog, LogLevel::Warning,
                  ("[FloorpMacPwa] Icon conversion failed for %s",
                   iconSource.fileSystemRepresentation));
        }
      }
    }

    RemoveQuarantineRecursively(bundlePath);
    if (!RunAdHocCodeSign(bundlePath)) {
      MOZ_LOG(gMacPwaLog, LogLevel::Warning,
              ("[FloorpMacPwa] Ad-hoc code signing failed for %s",
               bundlePath.fileSystemRepresentation));
    }
    RegisterBundleWithLaunchServices(bundlePath);
  }

  return NS_OK;
}

NS_IMETHODIMP
FloorpMacPwa::RemoveApp(const nsAString& aBundlePath) {
  if (aBundlePath.IsEmpty()) {
    return NS_ERROR_INVALID_ARG;
  }

  @autoreleasepool {
    NSString* bundlePath = ToNSString(aBundlePath);
    NSFileManager* fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:bundlePath]) {
      NSError* error = nil;
      if (![fm removeItemAtPath:bundlePath error:&error]) {
        MOZ_LOG(gMacPwaLog, LogLevel::Warning,
                ("[FloorpMacPwa] Failed to remove bundle %s: %s",
                 bundlePath.fileSystemRepresentation,
                 error.localizedDescription.UTF8String));
        return NS_ERROR_FAILURE;
      }
    }
  }

  return NS_OK;
}

}  // namespace mozilla

