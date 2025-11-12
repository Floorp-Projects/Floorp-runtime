#import "AppShimDelegate.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface AppShimDelegate ()
@property(strong, nonatomic) NSTask* floorpTask;
@end

@interface AppShimLaunchOptions : NSObject
@property(copy, nonatomic) NSString* configurationPath;
@property(copy, nonatomic) NSString* binaryOverride;
@property(strong, nonatomic) NSIndexSet* argumentIndexesToSkip;
@end

@implementation AppShimLaunchOptions
@end

static NSString* const kDefaultConfigResourceName = @"appshim-config";
static NSString* const kDefaultConfigResourceExtension = @"json";
static NSString* const kDefaultConfigFileName = @"appshim-config.json";
static NSString* const kFloorpBundleIdentifier = @"one.ablaze.floorp";
static NSString* const kSymlinkExecutableName = @"floorp-bin";
static NSString* const kBundleToken = @"@bundle/";
static NSString* const kExecutableDirToken = @"@executable_dir/";
static NSString* const kResourcesToken = @"@resources/";

@implementation AppShimDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  (void)notification;

  NSBundle* bundle = [NSBundle mainBundle];
  NSString* bundleIdentifier = bundle.bundleIdentifier;
  NSLog(@"[AppShim] Launched for bundle id: %@", bundleIdentifier);

  NSArray<NSString*>* arguments = [[NSProcessInfo processInfo] arguments];
  NSDictionary<NSString*, NSString*>* environment =
      [[NSProcessInfo processInfo] environment];

  [self launchFloorpWithArguments:arguments environment:environment];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
  (void)notification;

  if (self.floorpTask.running) {
    [self.floorpTask terminate];
  }
  self.floorpTask = nil;
}

- (void)launchFloorpWithArguments:(NSArray<NSString*>*)arguments
                      environment:(NSDictionary<NSString*, NSString*>*)env {
  NSBundle* bundle = [NSBundle mainBundle];
  AppShimLaunchOptions* options = [self parseLaunchOptionsFromArguments:arguments];
  NSDictionary<NSString*, id>* configuration =
      [self loadConfigurationWithBundle:bundle options:options];

  NSString* floorpPath =
      [self resolveFloorpBinaryPathWithArguments:arguments
                                     environment:env
                                   configuration:configuration
                                         options:options
                                          bundle:bundle];
  if (!floorpPath) {
    NSLog(@"[AppShim] Failed to resolve Floorp binary path.");
    [NSApp terminate:nil];
    return;
  }

  NSMutableArray<NSString*>* floorpArgs = [NSMutableArray array];
  [self appendConfigurationArguments:configuration toArray:floorpArgs bundle:bundle];
  [self appendPassthroughArgumentsFrom:arguments
                           skipIndexes:options.argumentIndexesToSkip
                               toArray:floorpArgs];

  NSTask* task = [[NSTask alloc] init];
  task.launchPath = floorpPath;
  task.arguments = floorpArgs;

  NSDictionary<NSString*, NSString*>* additionalEnv =
      [self configurationEnvironmentFromConfig:configuration bundle:bundle];
  NSMutableDictionary<NSString*, NSString*>* combinedEnv =
      env ? [env mutableCopy] : [NSMutableDictionary dictionary];
  if (additionalEnv.count > 0) {
    [combinedEnv addEntriesFromDictionary:additionalEnv];
  }
  task.environment = combinedEnv;

  task.terminationHandler = ^(NSTask* t) {
    NSLog(@"[AppShim] Floorp task ended with status %d", t.terminationStatus);
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp terminate:nil];
    });
  };

  @try {
    [task launch];
    self.floorpTask = task;
  } @catch (NSException* exception) {
    NSLog(@"[AppShim] Failed to launch Floorp: %@", exception);
    [NSApp terminate:nil];
  }
}

- (AppShimLaunchOptions*)parseLaunchOptionsFromArguments:
    (NSArray<NSString*>*)arguments {
  AppShimLaunchOptions* options = [[AppShimLaunchOptions alloc] init];
  NSMutableIndexSet* skip = [NSMutableIndexSet indexSet];

  for (NSUInteger index = 1; index < arguments.count; ++index) {
    NSString* token = arguments[index];
    if ([token isEqualToString:@"--app-shim"]) {
      [skip addIndex:index];
      continue;
    }
    if ([token hasPrefix:@"--app-shim="]) {
      [skip addIndex:index];
      continue;
    }
    if ([token hasPrefix:@"--app-shim-config="]) {
      static NSString* const kConfigPrefix = @"--app-shim-config=";
      NSString* value = [token substringFromIndex:kConfigPrefix.length];
      options.configurationPath = value;
      [skip addIndex:index];
      continue;
    }
    if ([token isEqualToString:@"--app-shim-config"]) {
      [skip addIndex:index];
      if (index + 1 < arguments.count) {
        options.configurationPath = arguments[index + 1];
        [skip addIndex:index + 1];
        ++index;
      }
      continue;
    }
    if ([token hasPrefix:@"--floorp-binary="]) {
      static NSString* const kBinaryPrefix = @"--floorp-binary=";
      NSString* value = [token substringFromIndex:kBinaryPrefix.length];
      options.binaryOverride = value;
      [skip addIndex:index];
      continue;
    }
    if ([token isEqualToString:@"--floorp-binary"]) {
      [skip addIndex:index];
      if (index + 1 < arguments.count) {
        options.binaryOverride = arguments[index + 1];
        [skip addIndex:index + 1];
        ++index;
      }
      continue;
    }
  }

  options.argumentIndexesToSkip = [skip copy];
  return options;
}

- (NSDictionary<NSString*, id>*)loadConfigurationWithBundle:(NSBundle*)bundle
                                                    options:(AppShimLaunchOptions*)options {
  NSString* configPath = options.configurationPath;
  NSString* executableDir =
      [[[bundle executablePath] stringByStandardizingPath] stringByDeletingLastPathComponent];
  if (configPath.length == 0) {
    NSString* executableConfig =
        [executableDir stringByAppendingPathComponent:kDefaultConfigFileName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:executableConfig]) {
      configPath = [executableConfig stringByStandardizingPath];
    } else {
      configPath = [bundle pathForResource:kDefaultConfigResourceName
                                    ofType:kDefaultConfigResourceExtension];
    }
  } else {
    configPath = [self resolveCandidate:configPath
                 relativeToExecutableDir:executableDir
                                  bundle:bundle];
  }

  if (configPath.length == 0) {
    return nil;
  }

  NSData* data = [NSData dataWithContentsOfFile:configPath options:0 error:nil];
  if (!data) {
    NSLog(@"[AppShim] Configuration file not found or unreadable at %@", configPath);
    return nil;
  }

  NSError* error = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data
                                            options:0
                                              error:&error];
  if (error) {
    NSLog(@"[AppShim] Failed to parse configuration: %@", error);
    return nil;
  }

  if (![json isKindOfClass:[NSDictionary class]]) {
    NSLog(@"[AppShim] Configuration root is not a dictionary.");
    return nil;
  }

  options.configurationPath = configPath;
  return json;
}

- (NSString*)resolveFloorpBinaryPathWithArguments:(NSArray<NSString*>*)arguments
                                      environment:(NSDictionary<NSString*, NSString*>*)env
                                    configuration:(NSDictionary<NSString*, id>*)config
                                          options:(AppShimLaunchOptions*)options
                                           bundle:(NSBundle*)bundle {
  (void)arguments;

  NSString* executableDir =
      [[[bundle executablePath] stringByStandardizingPath] stringByDeletingLastPathComponent];
  NSMutableOrderedSet<NSString*>* candidatePaths =
      [NSMutableOrderedSet orderedSet];

  if (options.binaryOverride.length > 0) {
    NSString* resolved = [self resolveCandidate:options.binaryOverride
                         relativeToExecutableDir:executableDir
                                          bundle:bundle];
    if (resolved.length > 0) {
      [candidatePaths addObject:resolved];
    }
  }

  NSString* envOverride = env[@"FLOORP_BINARY"];
  if (envOverride.length > 0) {
    NSString* resolved = [self resolveCandidate:envOverride
                         relativeToExecutableDir:executableDir
                                          bundle:bundle];
    if (resolved.length > 0) {
      [candidatePaths addObject:resolved];
    }
  }

  for (NSString* entry in [self candidatePathsFromConfig:config]) {
    NSString* resolved = [self resolveCandidate:entry
                         relativeToExecutableDir:executableDir
                                          bundle:bundle];
    if (resolved.length > 0) {
      [candidatePaths addObject:resolved];
    }
  }

  NSString* symlinkCandidate =
      [executableDir stringByAppendingPathComponent:kSymlinkExecutableName];
  [candidatePaths addObject:symlinkCandidate];

  NSString* defaultApplicationsPath =
      @"/Applications/Floorp.app/Contents/MacOS/floorp";
  [candidatePaths addObject:defaultApplicationsPath];

  NSURL* floorpURL =
      [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kFloorpBundleIdentifier];
  if (floorpURL) {
    NSString* bundlePath = [[floorpURL path] stringByStandardizingPath];
    NSString* binaryPath =
        [bundlePath stringByAppendingPathComponent:@"Contents/MacOS/floorp"];
    [candidatePaths addObject:binaryPath];
  }

  NSFileManager* fileManager = [NSFileManager defaultManager];
  for (NSString* candidate in candidatePaths) {
    if (candidate.length == 0) {
      continue;
    }
    if ([fileManager isExecutableFileAtPath:candidate]) {
      return candidate;
    }
  }

  NSLog(@"[AppShim] No executable Floorp binary found among candidates: %@",
        candidatePaths.array);
  return nil;
}

- (NSArray<NSString*>*)candidatePathsFromConfig:
    (NSDictionary<NSString*, id>*)config {
  if (![config isKindOfClass:[NSDictionary class]]) {
    return @[];
  }

  NSMutableArray<NSString*>* results = [NSMutableArray array];
  id directValue = config[@"floorpBinary"];
  if ([directValue isKindOfClass:[NSString class]]) {
    [results addObject:directValue];
  } else if ([directValue isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray*)directValue) {
      if ([item isKindOfClass:[NSString class]]) {
        [results addObject:item];
      }
    }
  }

  id candidateArray = config[@"floorpBinaryCandidates"];
  if ([candidateArray isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray*)candidateArray) {
      if ([item isKindOfClass:[NSString class]]) {
        [results addObject:item];
      }
    }
  }

  id bundleValue = config[@"floorpBundle"];
  if ([bundleValue isKindOfClass:[NSString class]]) {
    NSString* path =
        [(NSString*)bundleValue stringByAppendingPathComponent:@"Contents/MacOS/floorp"];
    [results addObject:path];
  }

  return results;
}

- (NSString*)resolveCandidate:(NSString*)candidate
      relativeToExecutableDir:(NSString*)executableDir
                       bundle:(NSBundle*)bundle {
  if (candidate.length == 0) {
    return @"";
  }

  NSString* expanded = [candidate stringByExpandingTildeInPath];
  if ([expanded hasPrefix:kBundleToken]) {
    NSString* remainder = [expanded substringFromIndex:kBundleToken.length];
    expanded = [[bundle bundlePath] stringByAppendingPathComponent:remainder];
  } else if ([expanded hasPrefix:kExecutableDirToken]) {
    NSString* remainder = [expanded substringFromIndex:kExecutableDirToken.length];
    expanded =
        [executableDir stringByAppendingPathComponent:remainder];
  } else if ([expanded hasPrefix:kResourcesToken]) {
    NSString* remainder = [expanded substringFromIndex:kResourcesToken.length];
    expanded = [[bundle resourcePath] stringByAppendingPathComponent:remainder];
  } else if (![expanded isAbsolutePath]) {
    expanded = [executableDir stringByAppendingPathComponent:expanded];
  }
  return [expanded stringByStandardizingPath];
}

- (void)appendConfigurationArguments:(NSDictionary<NSString*, id>*)config
                              toArray:(NSMutableArray<NSString*>*)outArgs
                               bundle:(NSBundle*)bundle {
  if (![config isKindOfClass:[NSDictionary class]]) {
    return;
  }

  id argumentsValue = config[@"arguments"];
  if ([argumentsValue isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray*)argumentsValue) {
      if ([item isKindOfClass:[NSString class]]) {
        [outArgs addObject:(NSString*)item];
      }
    }
  } else if ([argumentsValue isKindOfClass:[NSString class]]) {
    [outArgs addObject:(NSString*)argumentsValue];
  }

  id appendValue = config[@"appendArguments"];
  if ([appendValue isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray*)appendValue) {
      if ([item isKindOfClass:[NSString class]]) {
        [outArgs addObject:(NSString*)item];
      }
    }
  }

  (void)bundle;
}

- (void)appendPassthroughArgumentsFrom:(NSArray<NSString*>*)shimArgs
                           skipIndexes:(NSIndexSet*)skipIndexes
                               toArray:(NSMutableArray<NSString*>*)outArgs {
  if (shimArgs.count <= 1) {
    return;
  }

  for (NSUInteger index = 1; index < shimArgs.count; ++index) {
    if ([skipIndexes containsIndex:index]) {
      continue;
    }
    NSString* token = shimArgs[index];
    if (token.length > 0) {
      [outArgs addObject:token];
    }
  }
}

- (NSDictionary<NSString*, NSString*>*)configurationEnvironmentFromConfig:
    (NSDictionary<NSString*, id>*)config
                                                                  bundle:(NSBundle*)bundle {
  if (![config isKindOfClass:[NSDictionary class]]) {
    return @{};
  }

  id envValue = config[@"environment"];
  if (![envValue isKindOfClass:[NSDictionary class]]) {
    return @{};
  }

  NSString* executableDir =
      [[[bundle executablePath] stringByStandardizingPath] stringByDeletingLastPathComponent];
  NSMutableDictionary<NSString*, NSString*>* result =
      [NSMutableDictionary dictionary];
  [((NSDictionary*)envValue) enumerateKeysAndObjectsUsingBlock:^(
                       id key, id obj, BOOL* stop) {
    (void)stop;
    if (![key isKindOfClass:[NSString class]] || ![obj isKindOfClass:[NSString class]]) {
      return;
    }
    NSString* value = (NSString*)obj;
    NSString* resolved = [value stringByExpandingTildeInPath];
    if ([value hasPrefix:kBundleToken] || [value hasPrefix:kExecutableDirToken] ||
        [value hasPrefix:kResourcesToken]) {
      resolved = [self resolveCandidate:value
              relativeToExecutableDir:executableDir
                               bundle:bundle];
    }
    if (resolved) {
      result[(NSString*)key] = resolved;
    }
  }];
  return result;
}

@end

