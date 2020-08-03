//
//  AutoThread.m
//  AutoDB
//
//  Created by Olof Thorén on 2018-09-10.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "AutoThread.h"

@implementation NSThread (AutoThread)

+ (instancetype) newThread:(NSString*)name
{
	AutoThread *thread = [AutoThread new];
	thread.name = name;
	thread.qualityOfService = NSQualityOfServiceUserInitiated;
	return thread;
}

+ (void)runBlock:(dispatch_block_t)block
{
	block();
}

- (void) syncPerformBlock:(dispatch_block_t)block
{
	if ([[NSThread currentThread] isEqual:self])
	{
		block();
	}
	else
	{
		[NSThread performSelector:@selector(runBlock:) onThread:self withObject:block waitUntilDone:YES];
	}
}

- (void)asyncExecuteBlock:(dispatch_block_t)block
{
	[NSThread performSelector:@selector(runBlock:) onThread:self withObject:block waitUntilDone:NO];
}

- (void)afterDelay:(NSTimeInterval)delay performBlock:(dispatch_block_t)block
{	
	[self performSelector:@selector(syncPerformBlock:) withObject:block afterDelay:delay];
}

@end


@implementation AutoThread

- (void)main
{
	//you can't restart threads, so this will need to run forever, HOWEVER since it's a runLoop it sleeps while waiting for input.
	while (self.isCancelled == NO)
	{
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
	}
	
	//during normal usage this should never happen, perhaps we should allow to cancel and start a new thread. But it seems unclear if needed.
	//TODO: join them together after db-creation - if we notice they are not used much. (nope, can deadlock, but we can go to queues instead). 
	NSDate *date = [NSDate dateWithTimeIntervalSinceNow:1];
	while ([date timeIntervalSinceNow] >= 0)
	{
		[[NSRunLoop currentRunLoop] runUntilDate:date];
	}
	NSLog(@"thread is dead: %@", self.name);
}

@end
