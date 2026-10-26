/* The Glk library asks a path for the signature of the file it names, to find
 * the game's autosave folder. On macOS that category lives in the app's
 * NSString+Categories.m, which drags the Core Data model along. The
 * interpreter frameworks only need this one method. */

#import <Foundation/Foundation.h>

#import "FileSignature.h"
#import "NSString+Categories.h"

@implementation NSString (SignatureOnly)

- (NSString *)signatureFromFile {
    NSError *error = nil;
    NSData *theData = [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:self isDirectory:NO]
                                            options:NSDataReadingMappedAlways
                                              error:&error];
    if (theData == nil) {
        if (error != nil)
            NSLog(@"signatureFromFile: %@", error);
        return nil;
    }
    return [FileSignature signatureFromData:theData];
}

@end
