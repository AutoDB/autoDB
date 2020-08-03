//
//  AutoDBTests.m
//  AutoDBTests
//
//  Created by Olof Thorén on 2016-12-15.
//  Copyright © 2016 Aggressive Development AB. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "ConcurrencyModel.h"
#import "AutoDB.h"

@interface LastAutoDBTests : XCTestCase

@end

@implementation LastAutoDBTests

+ (void)setUp
{
	[[AutoDB sharedInstance] destroyDatabase];
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	NSDictionary *paths = @{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]};
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:paths migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors)
	{
		
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
	
	[AutoDB.sharedInstance createDatabaseMigrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray<NSError *> * _Nullable errors) {
		
		if (errors && errors.firstObject.code != 123731) NSLog(@"got errors %@", errors);
	}];
	
	NSArray *all = [ConcurrencyModel fetchQuery:nil arguments:nil].rows;
    [ConcurrencyModel delete:all];
}

+ (void)tearDown
{
	[[AutoDB sharedInstance] destroyDatabase];
}

- (void)setUp
{
    [super setUp];
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testConcurrentWheres
{
    //We want to insert and update items while selecting them with where queries, to see if we can brute-force them to break or deadlock.
    
    int iterations = 20;
    int cases = 3;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    //NSArray *names = @[@"hej", @"Då", @"eller", @"vad"];
    dispatch_apply(iterations * cases, queue, ^(size_t index)
    {
        int id_value = floor(index / cases) + 1;
        if (index % cases == 0)
        {
            //First create
            ConcurrencyModel *result = [ConcurrencyModel createInstanceWithId:id_value];
            result.name = @"name";
            result.last_update = [NSDate date];
            result.double_number = index + 0.4;
            result.int_number = (int)index;
			NSLog(@"%i creating obj %i", (int)index, id_value);
            [result save];
        }
        else
        {
            [NSThread sleepForTimeInterval:0.1];
            if (arc4random_uniform(3) == 0)
            {
                [NSThread sleepForTimeInterval:0.1];    //some random extra sleep
            }
            NSLog(@"%i fetching obj %i", (int)index, id_value);
            
            ConcurrencyModel *object = [ConcurrencyModel fetchId:@(id_value)];
			if (!object)
			{
				NSLog(@"no obj");
			}
            XCTAssert(object, @"Could not get object for id %i", id_value);
            NSLog(@"got obj %@ with number %i", object.name, object.int_number);
            
            if (index % cases == 1)
            {
                //update name
                object.name = [NSString stringWithFormat:@"name_%@", object.name];
                [object saveWithCompletion:nil];
            }
            else
            {
                //update int
                object.int_number += 1;
                [object saveWithCompletion:nil];
            }
        }
    });
    
	NSArray *all = [ConcurrencyModel fetchQuery:nil arguments:nil].rows;
    for (ConcurrencyModel *obj in all)
    {
        NSLog(@"result: obj id: %i %@ %i", (int)obj.id, obj.name, obj.int_number);
    }
    [ConcurrencyModel delete:all];
}

- (void)not_testPerformanceSingleCreation
{
    int createAmount = 100;
    [self measureBlock:^
    {
        for (NSInteger index = 0; index < createAmount; index++)
        {
            ConcurrencyModel *result = [ConcurrencyModel createInstance];
            result.name = @"hej";
            result.last_update = [NSDate date];
            result.double_number = index + 2.4;
            result.int_number = (int)index;
            [result save];
        }
        [[ConcurrencyModel databaseQueue] inDatabase:^(AFMDatabase *db)
        {
            NSNumber* value = [ConcurrencyModel valueQuery:@"SELECT count(*) FROM ConcurrencyModel" arguments:nil];
            XCTAssertEqual(value.integerValue, createAmount, @"Could not create all items! %@", value);
        }];
    
        NSDictionary *dic = [ConcurrencyModel fetchQuery:nil arguments:nil].dictionary;
        [ConcurrencyModel delete:dic.allValues];
    }];
}

- (void)not_testPerformanceMultipleCreation
{
    int createAmount = 10000;
    [self measureBlock:^
    {
        NSMutableArray *all = [NSMutableArray new];
        for (NSInteger index = 0; index < createAmount; index++)
        {
            ConcurrencyModel *result = [ConcurrencyModel createInstance];
            result.name = @"hej";
            result.last_update = [NSDate date];
            result.double_number = index + 2.4;
            result.int_number = (int)index;
            [all addObject:result];
        }
        
        [ConcurrencyModel save:all];
        
        [[ConcurrencyModel databaseQueue] inDatabase:^(AFMDatabase *db)
        {
            NSNumber* value = [ConcurrencyModel valueQuery:@"SELECT count(*) FROM ConcurrencyModel" arguments:nil];
            XCTAssertEqual(value.integerValue, createAmount, @"Could not create all items! %@", value);
        }];
        
        NSDictionary *dic = [ConcurrencyModel fetchQuery:nil arguments:nil].dictionary;
        [ConcurrencyModel delete:dic.allValues];
     }];
}

@end
