//
//  AutoCloseDB.m
//  AutoDBFrameworkTests
//
//  Created by Olof Thorén on 2020-09-28.
//  Copyright © 2020 Aggressive Development AB. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "AutoModel.h"
#import "SecondModel.h"
#import "AutoDB.h"

@interface AutoCloseDB : XCTestCase
{
	XCTestExpectation *expect;
}
@end

@implementation AutoCloseDB

+ (void)setUp
{
	[[AutoDB sharedInstance] destroyDatabase];
	[[AutoDB sharedInstance] createDatabaseMigrateBlock:nil];
}

- (void)setUp
{
	expect = [self expectationWithDescription:@"Testing dude!"];
}

- (void)tearDown
{
	[[AutoDB sharedInstance] destroyDatabase];
}

- (void)testAutoClose
{
	[[AutoDB sharedInstance] autoClose:YES tables:nil];
	
	AFMDatabaseQueue *queue = [SecondModel databaseQueue];
	XCTAssertTrue(queue.isClosed, "Not closed!");
	
	NSString *testString = @"testString";
	@autoreleasepool
	{
		SecondModel *model = [SecondModel createInstanceWithId:1];
		model.string = testString;
		[model save];
		model = nil;
	}
	XCTAssertTrue(queue.isClosed, "Not closed after save!");
	
	id value = [SecondModel valueQuery:@"SELECT id FROM SecondModel WHERE string = ?" arguments:@[testString]];
	XCTAssertEqualObjects(value, @1, @"Closing db causes fail to save!");
	
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {
		
		NSLog(@"in queue!");
	}];
	XCTAssertTrue(queue.isClosed, "Not closed after inDatabase method!");
	
	NSLog(@"opening again");
	[[AutoDB sharedInstance] autoClose:NO tables:nil];
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {
		
		NSLog(@"opening queue!");
	}];
	XCTAssertFalse(queue.isClosed, "Closed after opening!");
	
	
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void)
	{
		[self->expect fulfill];
	});
	[self waitForExpectationsWithTimeout:1.0 handler:nil];
}

@end
