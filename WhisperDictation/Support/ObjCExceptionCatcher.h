#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift can't catch Objective-C exceptions. AVFAudio raises one (instead of
/// returning an error) when `installTapOnBus:` gets an invalid format — e.g. a
/// 0 Hz / 0 ch input while the default mic is being hot-swapped — which would
/// otherwise abort the whole app. This runs a block and turns any NSException
/// into an NSError, so Swift sees a normal `throws`.
@interface ObjCExceptionCatcher : NSObject
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
