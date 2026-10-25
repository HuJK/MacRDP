/*
 *  ObjCTry.m
 *  MacRDP
 */

#import "ObjCTry.h"

NSException *macrdp_catch_objc(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e;
    }
}
