/*
 *  ObjCTry.h
 *  MacRDP
 *
 *  Swift can't catch Objective-C exceptions: one unwinding through Swift
 *  frames leaves them half-run (and AppKit swallows it on the main thread,
 *  so nothing even crashes). Run calls into APIs that raise, such as
 *  -[AVAudioPlayerNode play], through this.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`; returns the Objective-C exception it raised, or nil.
NSException *_Nullable macrdp_catch_objc(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
