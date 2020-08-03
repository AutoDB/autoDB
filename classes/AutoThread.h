//
//  AutoThread.h
//  AutoDB
//
//  Created by Olof Thorén on 2018-09-10.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AutoThread : NSThread
@end

@interface NSThread (AutoThread)

+ (instancetype) newThread:(nullable NSString*)name;

///Execute block asynchronously, if already on this thread we enqueue the block for later.
- (void)asyncExecuteBlock:(dispatch_block_t)block;
///Synchronously run block, waiting until complete. Does not deadlock if recursively run on the same thread multiple times.
- (void) syncPerformBlock:(dispatch_block_t)block;
///Run a block after delay (so you may cancel execution)
- (void) afterDelay:(NSTimeInterval)delay performBlock:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
