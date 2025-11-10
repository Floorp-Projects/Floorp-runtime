#import <Cocoa/Cocoa.h>

#import "AppShimDelegate.h"

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    AppShimDelegate* delegate = [[AppShimDelegate alloc] init];
    [NSApp setDelegate:delegate];
  }
  return NSApplicationMain(argc, argv);
}

