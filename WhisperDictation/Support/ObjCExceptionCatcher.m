#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:exception.name
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        }
        return NO;
    }
}

@end
