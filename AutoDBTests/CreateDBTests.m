//
//  CreateDBTests.m
//  AutoDB
//
//  Created by Olof Thorén on 2016-12-15.
//  Copyright © 2016 Aggressive Development AB. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "AutoModel.h"
#import "ConcurrencyModel.h"
#import "SecondModel.h"
#import "AutoParent.h"
#import "AutoDB.h"

@interface CreateDBTests : XCTestCase
{
	XCTestExpectation *expect;
}
@end

@implementation CreateDBTests

static NSString* testString = @"hello test string!";

- (void)setUp
{
	expect = [self expectationWithDescription:@"Testing dude!"];
}

- (void)tearDown
{
	[[AutoDB sharedInstance] destroyDatabase];
}

- (void) printMigrateState:(MigrationState) state willMigrateTables:(NSMutableSet * _Nullable) willMigrateTables errors:(NSArray *)errors
{
	NSArray <NSString*> *stateStrings = @[@"MigrationStateError", @"MigrationStateStart", @"MigrationStateComplete"];
	NSMutableString *logString = stateStrings[state].mutableCopy;
	if (willMigrateTables)
		[logString appendFormat:@" tables: %@", willMigrateTables];
	if (errors)
		[logString appendFormat:@" errors: %@", errors];
	NSLog(@"%@", logString);
}

//WAIT_FOR_SETUP has been removed since we have dedicated threads. Do the new system work?
- (void)testWaitForSetup
{
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	testString = @"testString WaitForSetup";
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	__block int counter = 0;
	[[AutoDB sharedInstance] destroyDatabase];
	
	NSDictionary *paths = @{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]};
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:paths migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors)
	{
		[self printMigrateState:state willMigrateTables:willMigrateTables errors:errors];
	}];
	[SecondModel createInstanceWithId:1 result:^(SecondModel* _Nullable result) {
		XCTAssertEqual(counter, 0);
		counter++;
		result.string = testString;
		//NSLog(@"setting");
		[result saveWithCompletion:^(NSError * _Nullable error) {
			dispatch_semaphore_signal(semaphore);
		}];
	}];
	
	dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
	
	//NSLog(@"asyncs are sent, waiting %@", testString);
	SecondModel *result = [SecondModel fetchIds:@[@1]].rows.firstObject;
	XCTAssertEqual(counter, 1);
	XCTAssertEqualObjects(result.string, testString, @"%@ should be equal to '%@'", result.string, testString);
	counter++;
	NSLog(@"fetching last: %@", result.string);
	
	[expect fulfill];
	[self waitForExpectationsWithTimeout:1.0 handler:nil];
}

- (void)testDestroyDatabase
{
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	
	NSDictionary *paths = @{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]};
	
	AutoDB *instance = [AutoDB sharedInstance];
	[instance createDatabaseWithPathsForClasses:paths migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors)
	{
		
		[self printMigrateState:state willMigrateTables:willMigrateTables errors:errors];
	}];
	XCTAssertNotNil([instance tableSyntaxForClass:@"SecondModel"], @"table syntax is empty !");
	
	[[AutoDB sharedInstance] destroyDatabase];
	
	sleep(1);
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:@{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]} migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors) {
		
		NSLog(@"Second setup complete");
		[self printMigrateState:state willMigrateTables:willMigrateTables errors:errors];
		if (state == MigrationStateError)
		{
			XCTAssertFalse(1, @"We have errors when nothing should happen");
		}
		if (state == MigrationStateComplete)
			[self->expect fulfill];
	}];
	XCTAssertNotNil([[AutoDB sharedInstance] tableSyntaxForClass:@"SecondModel"], @"table syntax is empty !");
	
	NSLog(@"waiting");
	[self waitForExpectationsWithTimeout:99916.0 handler:nil];
	
	[[AutoDB sharedInstance] destroyDatabase];
}

- (void) testMigrationMoveTable
{
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	NSString *standard = [supportPath stringByAppendingPathComponent:@"auto_database.sqlite3"];
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:@{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]} migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors) {
		
		[self printMigrateState:state willMigrateTables:willMigrateTables errors:errors];
	}];
	
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {
		
		[db executeUpdate:@"DELETE FROM SecondModel"];
	}];
	
	NSUInteger secondModelId = 2;
	SecondModel *model = [SecondModel createInstanceWithId:secondModelId];
	model.string = testString;
	[model saveWithCompletion:^(NSError * _Nullable error) {
		if (error)
		{
			XCTFail(@"error saving: %@", error);
		}
		[self->expect fulfill];
	}];
	model = nil;
	[[AutoDB sharedInstance] destroyDatabase];
	
	//Move it to "concurrency" file:
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:@{ standard: @[@"SecondModel"], concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"ValueHandling"]} migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors) {
		
		[self printMigrateState:state willMigrateTables:willMigrateTables errors:errors];
		
	}];
	
	//it has to be removed from cache in order for us to test this
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {}];	//just wait until cache exists
	model = [SecondModel.tableCache objectForKey:@(secondModelId)];
	XCTAssertNil(model, @"Object deleted still in cache!");
	
	//This should not deadlock
	[AutoChild inDatabase:^(AFMDatabase * _Nonnull db) {
		
		SecondModel* model = [SecondModel createInstanceWithId:secondModelId];
		XCTAssertEqualObjects(model.string, testString);
		model.string = @"testString";
		NSError *error = [model save];
		if (error)
		{
			XCTFail(@"error saving: %@", error);
		}
		NSLog(@"done testing!");
	}];
	
	[self waitForExpectationsWithTimeout:99916.0 handler:nil];
}

@end
