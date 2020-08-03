//
//  ThreadTests.m
//  AutoDBTests
//
//  Created by Olof Thorén on 2018-09-10.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "AutoThread.h"
#import "AutoConcurrentMapTable.h"
#import "AutoDB.h"

@interface ThreadTests : XCTestCase
{
	NSThread *thread;
	XCTestExpectation *expect;
	
	dispatch_queue_t _readWriteQueue;
	int _value;
}
@end

@implementation ThreadTests


+ (void)setUp
{
	[[AutoDB sharedInstance] destroyDatabase];
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:@{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]} migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors) {
		
		if (willMigrateTables)
		{
			if (state == MigrationStateStart)
				NSLog(@"Will migrate: %@", willMigrateTables);
			else
			{
				NSLog(@"Did migrate: %@", willMigrateTables);
			}
		}
		else
			NSLog(@"NO migration!");
	}];
}

+ (void) tearDown
{
	[[AutoDB sharedInstance] destroyDatabase];
}

- (void)setUp
{
	thread = [NSThread newThread:@"Testing thread"];
	[thread start];
	expect = [self expectationWithDescription:@"Testing threads waiter"];
}

- (void)tearDown
{
	thread = nil;
}

/*
 Here is an example of when dispatch_barrier_async always deadlocks. Think of it as 800 images are downloaded in the background - then when the app awakes you create one thread for each image to process them - all run at the same time. Deadlock.

- (void)testBarrierSync
{
	dispatch_queue_t _workQueue = dispatch_queue_create("com.work", DISPATCH_QUEUE_CONCURRENT);
	_readWriteQueue = dispatch_queue_create("com.readwrite", DISPATCH_QUEUE_CONCURRENT);	//
	_value = 0;
	for(int i = 0; i < 800; i++)
	{
		dispatch_async(_workQueue, ^{
			
			if(arc4random() % 4 == 0)
			{
				[self write];
			}
			else
			{
				[self read];
			}
		});
	}
	
	[self waitForExpectationsWithTimeout:16.0 handler:nil];
}

- (void)read
{
	dispatch_sync(_readWriteQueue, ^{
		NSLog(@"read:%d", _value);
		
	});
}

- (void)write
{
	dispatch_barrier_async(_readWriteQueue, ^{
		_value++;
		NSLog(@"write:%d", _value);
		if (_value == 200)
			[expect fulfill];
	});
}
*/

- (void)testRunLoopNotActive
{
	expect.expectedFulfillmentCount = 3;
	[thread syncPerformBlock:^{
		NSLog(@"exec running loop");
		[self->expect fulfill];
	}];
	
	[thread syncPerformBlock:^{
		
		NSLog(@"syncing on thread!");
		
		[self->thread afterDelay:1 performBlock:^{
			NSLog(@"testing delay from sync!");
			[self->expect fulfill];
		}];
	}];
	
	[thread syncPerformBlock:^{
		
		NSLog(@"executing block!");
		
		[self->thread afterDelay:1 performBlock:^{
			NSLog(@"testing delay from execute!");
			[self->expect fulfill];
		}];
		
		//Here we test that enqueued blocks actually executes in FIFO order
		__block NSUInteger counter = 0;
		[self->thread asyncExecuteBlock:^{
			NSLog(@"async 1");
			XCTAssertEqual(counter, 1);
			counter++;
		}];
		
		[self->thread asyncExecuteBlock:^{
			NSLog(@"async 2");
			XCTAssertEqual(counter, 2);
			counter++;
		}];
		
		[self->thread asyncExecuteBlock:^{
			NSLog(@"async 3");
			XCTAssertEqual(counter, 3);
			counter++;
		}];
		
		[self->thread asyncExecuteBlock:^{
			NSLog(@"async 4");
			XCTAssertEqual(counter, 4);
			counter++;
		}];
		[self->thread asyncExecuteBlock:^{
			NSLog(@"async 5");
			XCTAssertEqual(counter, 5);
			counter++;
		}];
		
		
		//this gets in before the other blocks since we should already be inside that queue.
		[self->thread syncPerformBlock:^{
			XCTAssertEqual(counter, 0);
			counter++;
			NSLog(@"inside!");
		}];
		
		NSLog(@"all async is enqueued");
		XCTAssertEqual(counter, 1);
		counter = 1;
	}];
	
	[self waitForExpectationsWithTimeout:9999999 handler:^(NSError * _Nullable error) {
		if (error) NSLog(@"error was %@", error);
	}];
	
	sleep(1);
	[thread syncPerformBlock:^{
		
		NSLog(@"testing loop without work");
	}];
	
	
}

@end
