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
	//[[AutoDB sharedInstance] ]
	
	//XCTAssertEqual
	
	//[expect fulfill];
	[self waitForExpectationsWithTimeout:1.0 handler:nil];
}

@end
