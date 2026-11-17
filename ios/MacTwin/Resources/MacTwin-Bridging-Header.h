//
//  MacTwin-Bridging-Header.h
//  ObjC ↔ Swift 桥接
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/mman.h>
#import <dlfcn.h>
#import <errno.h>

// AppKit 兼容层（P5 起实现）
// #import "AppKitShim.h"
