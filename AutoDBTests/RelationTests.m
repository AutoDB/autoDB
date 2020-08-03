//
//  RelationTests.m
//  AutoDBTests
//
//  Created by Olof Thorén on 2018-09-12.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "AutoModel.h"
#import "ConcurrencyModel.h"
#import "SecondModel.h"
#import "AutoParent.h"
#import "AutoDB.h"

@interface RelationTests : XCTestCase

@end

@implementation RelationTests

+ (void) setUp
{
	[[AutoDB sharedInstance] destroyDatabase];
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	NSString *standard = [supportPath stringByAppendingPathComponent:@"standard.sqlite3"];
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:@{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"], standard: @[@"AutoManyChild"]} migrateBlock:nil];
}

- (void)setUp
{
	[super setUp];
	// Put setup code here. This method is called before the invocation of each test method in the class.
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {
		[db executeUpdate:@"DELETE FROM SecondModel"];
	}];
	[ConcurrencyModel inDatabase:^(AFMDatabase * _Nonnull db) {
		[db executeUpdate:@"DELETE FROM ConcurrencyModel"];
	}];
	[AutoParent inDatabase:^(AFMDatabase * _Nonnull db) {
		[db executeUpdate:@"DELETE FROM AutoParent"];
	}];
	[AutoChild inDatabase:^(AFMDatabase * _Nonnull db) {
		[db executeUpdate:@"DELETE FROM AutoChild"];
	}];
	[AutoManyChild inDatabase:^(AFMDatabase * _Nonnull db) {
		[db executeUpdate:@"DELETE FROM AutoManyChild"];
	}];
}

- (void)tearDown
{
	// Put teardown code here. This method is called after the invocation of each test method in the class.
	[super tearDown];
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {
		[db executeUpdate:@"DELETE FROM SecondModel"];
	}];
	[ConcurrencyModel inDatabase:^(AFMDatabase * _Nonnull db) {
		[db executeUpdate:@"DELETE FROM ConcurrencyModel"];
	}];
}

- (void)testCreationConcurrently
{
	//NSError *error = [AutoModel createDatabaseDeferBlock:nil];
	dispatch_async(dispatch_get_global_queue(0, 0), ^(void)
				   {
					   [[ConcurrencyModel newSpecialModel] save];
				   });
	dispatch_async(dispatch_get_global_queue(0, 0), ^(void)
				   {
					   [[ConcurrencyModel createInstanceWithId:2] save];
				   });
	
	[NSThread sleepForTimeInterval:0.2];
	
	// Use XCTAssert and related functions to verify your tests produce the correct results.
	NSArray *all = [ConcurrencyModel fetchQuery:nil arguments:nil].rows;
	for (ConcurrencyModel *obj in all)
	{
		NSLog(@"Got obj %@", obj.idValue);
	}
	[ConcurrencyModel delete:all];
	XCTAssert(all.count >= 2, @"Could not create all objects, only %i", (int)all.count);
	
}

/*
 Build the following tests:
 create several objects with the same id (concurrently), see that they are identical.
 change objects (concurrently) while saving (concurrently), see that there are no conflicts
 Exhaust memory so we cause cache eviction (or simlulate it), while fetching - make sure we don't crash.
 AutoIncrement: Test that the order always i correct (so we don't se the wrong id and insert them as such into the cache)
 Check the difference in speed when caching a query, e.g. fetchAllWithIds:
 */


//you are here - build the new stuff while testing it!
- (void)test990SeveralDatabaseFiles
{
	NSString *testChangesString = @"two-three";
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
	{
		ConcurrencyModel *result = [ConcurrencyModel createInstance];
		XCTAssertNotNil(result, @"Could not createInstance:");
		result.name = testString;
		[result saveWithCompletion:^(NSError * _Nullable error) {
			
			XCTAssertNil(error, @"Could not createInstance:");
		}];
	});
	
	ConcurrencyModel *concObject = [ConcurrencyModel createInstance];
	concObject.name = testString;
	[concObject save];
	
	SecondModel *secondObject = [SecondModel createInstance];
	secondObject.string = testString;
	[secondObject save];
	
	XCTAssertFalse([[SecondModel databaseQueue] isEqual:[ConcurrencyModel databaseQueue]], @"Two different autoModel-files cannot have equal queues");
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {
		
		//test that one file does not hold the other's tables
		NSLog(@"now comes two errors:");
		[db executeQuery:@"SELECT * FROM ConcurrencyModel WHERE id = 1"];
		NSError *lastError = db.lastError;
		XCTAssertNotNil(lastError, @"SecondModel contains ConcurrencyModel!");
		
		//this should work:
		AFMResultSet *result = [db executeQuery:@"SELECT string FROM SecondModel WHERE id = 1"];
		while (result.next)
		{
			XCTAssertEqualObjects(testString, result[0], @"Error fetching what has been saved!");
		}
		
		//this will hang/crash if queues are the same (they should not block each others threads)
		[ConcurrencyModel inDatabase:^(AFMDatabase * _Nonnull db) {
			
			//also check the other way around
			[db executeQuery:@"SELECT string FROM SecondModel WHERE id = 1"];
			NSError *lastError = db.lastError;
			XCTAssertNotNil(lastError, @"ConcurrencyModel contains SecondModel!");
			
			//this should work:
			AFMResultSet *result = [db executeQuery:@"SELECT name FROM ConcurrencyModel WHERE id = 1"];
			while (result.next)
			{
				XCTAssertEqualObjects(testString, result[0], @"Error fetching what has been saved!");
			}
		}];
	}];
	NSLog(@"now we continue as normal");
	
	AutoResult *result = [ConcurrencyModel fetchQuery:@"WHERE name = ? LIMIT 1" arguments:@[testString]];
	XCTAssertTrue(result.rows.count == 1);
	XCTAssertTrue(result.dictionary.count == 1);
	XCTAssertEqualObjects(result.rows[0], result.dictionary[@1]);
	
	[ConcurrencyModel fetchQuery:@"WHERE name = ? LIMIT 1" arguments:@[testString] resultBlock:^(AutoResult * _Nullable result) {
		
		XCTAssertTrue(result.rows.count == 1);
		XCTAssertTrue(result.dictionary.count == 1);
		XCTAssertEqualObjects(result.rows[0], result.dictionary[@1]);
	}];
	
	[ConcurrencyModel fetchIds:@[@1, @2] resultBlock:^(AutoResult * _Nullable result) {
		
		XCTAssertTrue(result.rows.count == 2);
	}];
	
	///A blocking version of fetchIds:resultBlock: - it automatically detects if within db or not.
	result = [ConcurrencyModel fetchIds:@[@1, @2]];
	XCTAssertTrue(result.rows.count == 2);
	
	ConcurrencyModel *conc = [ConcurrencyModel fetchId:@1];
	XCTAssertEqualObjects(conc.name, testString);
	
	conc = [ConcurrencyModel fetchWithIdQuery:@"SELECT 5 - ?" arguments:@[@4]].rows.firstObject;
	XCTAssertEqual(conc.id, 1);
	[ConcurrencyModel fetchWithIdQuery:@"SELECT 5 - ?" arguments:@[@4] resultBlock:^(AutoResult<__kindof AutoModel *> * _Nullable resultSet) {
		
		XCTAssertEqual(resultSet.rows.lastObject.id, 1);
	}];
	
	//test changes
	sleep(1);
	XCTAssertFalse(secondObject.hasChanges, @"Second should not have changes at this point");
	secondObject.string = testChangesString;
	XCTAssertTrue(secondObject.hasChanges, @"Second should have changes at this point");
	[SecondModel saveAllWithChanges];
	XCTAssertFalse(secondObject.hasChanges, @"Second should not have changes at this point");
	
	[SecondModel saveAllWithChanges:^(NSError * _Nullable error) {
		
		NSLog(@"saved!");
		XCTAssertFalse(secondObject.hasChanges, @"after save all should Second not have changes at this point");
		XCTAssertNil(error);
	}];
	
	NSLog(@"hello we are done!");
}

static NSString *testString = @"testing one-two";
static NSString *testString2 = @"testing one-tre";
static int tests = 20000;

- (void)test992MeasureSave
{
	/*Let's compare the diff of keeping track of changes, compared to manual handling
	 100000 iterations = 7.5
	 9.51037 s
	 7.2
	 */
	@autoreleasepool
	{
		CFTimeInterval startTime = CACurrentMediaTime();
		NSMutableArray *objects = [NSMutableArray new];
		for (NSUInteger index = 0; index < tests; index++)
		{
			SecondModel *secondObject = [SecondModel createInstance];
			secondObject.string = testString;
			[objects addObject:secondObject];
		}
		
		NSLog(@"saving!");
		[SecondModel save:objects];
		NSLog(@"saving done");
		
		CFTimeInterval endTime = CACurrentMediaTime();
		NSLog(@"Total Runtime: %0.3f s (2.01 s)", endTime - startTime);
	}
	//we need time to release objects!
	sleep(1);
}

- (void)test991MeasureSaveWithChanges
{
	/*
	 using saveAll is basically the same.
	 100000 iterations = 8.4 s
	 9.01428 s
	 12.1
	 without KVO we are basically down to the same levels!
	 1.07994 s
	 */
	@autoreleasepool
	{
		CFTimeInterval startTime = CACurrentMediaTime();
		NSMutableArray *objects = [NSMutableArray new];
		for (NSUInteger index = 0; index < tests; index++)
		{
			SecondModel *secondObject = [SecondModel createInstance];
			secondObject.string = testString2;
			[objects addObject:secondObject];
		}
		
		NSLog(@"saving changes");
		[SecondModel saveAllWithChanges];
		NSLog(@"saving done");
		
		CFTimeInterval endTime = CACurrentMediaTime();
		NSLog(@"Total Runtime: %0.3f s previous (2.00 s)", endTime - startTime);
		[objects removeAllObjects];
	}
	//we need time to release objects!
	sleep(1);
}

- (void)test993MeasureSaveManual
{
	/*
	 Now we have a class with automatic handling turned off.
	 100000 iterations = 1 s
	 1.02119 s
	 1.0629 s
	 */
	@autoreleasepool
	{
		CFTimeInterval startTime = CACurrentMediaTime();
		NSMutableArray *objects = [NSMutableArray new];
		for (NSUInteger index = 0; index < tests; index++)
		{
			ConcurrencyModel *secondObject = [ConcurrencyModel createInstance];
			secondObject.name = testString;
			[objects addObject:secondObject];
		}
		
		NSLog(@"saving!");
		[ConcurrencyModel save:objects];
		NSLog(@"saving done");
		
		CFTimeInterval endTime = CACurrentMediaTime();
		NSLog(@"Total Runtime: %g s (1.80)", endTime - startTime);
	}
	//we need time to release objects!
	sleep(1);
}

//we need to test that inserting a group without ids, actually get their correct ids.
- (void)test990GroupSavingCorrectIds
{
	[SecondModel delete:[SecondModel fetchQuery:@"where int_number > 0" arguments:nil].rows];
	NSMutableArray <SecondModel *>*objects = [NSMutableArray new];
	for (NSUInteger index = 1; index <= tests; index++)
	{
		SecondModel *secondObject = [SecondModel createInstance];
		secondObject.int_number = (int)index;
		[objects addObject:secondObject];
	}
	[SecondModel saveChanges];
	NSMutableDictionary<NSNumber*, NSNumber*> *mapping = [NSMutableDictionary new];
	for (SecondModel *object in objects)
	{
		mapping[object.idValue] = @(object.int_number);
	}
	objects = nil;
	
	NSArray <SecondModel*> *rows = [SecondModel fetchQuery:@"where int_number > 0 ORDER BY int_number" arguments:nil].rows;
	for (SecondModel *object in rows)
	{
		//NSLog(@"not work %i %i", (int)object.id, object.int_number);
		int reportedInt = mapping[object.idValue].intValue;
		
		XCTAssertTrue(object.int_number == reportedInt, @"error with setting group ids %i, int: %i reported: %i", (int)object.id, object.int_number, reportedInt);
	}
	NSLog(@"done");
}

static int children = 3000;
- (void)test808Relations
{
	XCTestExpectation* expectation = [self expectationWithDescription:@"wait."];
	@autoreleasepool
	{
		AutoParent *parent = [AutoParent createInstanceWithId:1];
		parent.strong_child = [AutoStrongChild createInstanceWithId:1];
		parent.strong_child_id = 1;
		parent.strong_child.name = @"child 1";
		parent.children = [NSMutableArray new];
		for (NSUInteger index = 1; index < children + 1; index++)
		{
			AutoChild *child = [AutoChild createInstanceWithId:index];
			child.name = [NSString stringWithFormat:@"child %i", (int)index];
			child.parent_id = 1;
			[parent.children addObject:child];
		}
		NSError *error = [AutoParent saveAllWithChanges];
		if (error)
			NSLog(@"error!! HELP %@", error);
		[parent.children removeAllObjects];
		parent = nil;
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
	{
		@autoreleasepool
		{
			AutoParent *parent = [[AutoParent tableCache] objectForKey:@1];
			XCTAssertNil(parent, @"Parent is already created!");
			parent = [AutoParent createInstanceWithId:1];
			XCTAssertTrue(parent.children.count == 0, @"Parent already has children!!");
			[parent fetchRelations];
			parent = nil;
		}
		
		[self measureBlock:^{
			
			@autoreleasepool
			{
				AutoParent *parent = [AutoParent createInstanceWithId:1];
				[parent fetchRelations];
				parent = nil;
			}
		}];
		
		//here nothing should be in the cache - check that!
		AutoParent *parent = [AutoParent createInstanceWithId:1];
		XCTAssertNil(parent.children, @"Parent is already created!");
		XCTAssertNil(parent.strong_child, @"Parent is already created, still has its strong child!");
		XCTAssertTrue(parent.children.count == 0, @"Parent already has children!!");
		[parent fetchRelations];
		XCTAssertTrue(parent.children.count == children, @"Parent did not get correct number of children! %i != %i", (int)parent.children.count, (int)children);
		XCTAssertEqualObjects(parent.strong_child.name, @"child 1");
		[expectation fulfill];
	});
	
	[self waitForExpectationsWithTimeout:90000 handler:^(NSError * _Nullable error) {
		if (error) NSLog(@"did? %@", error);
	}];
}

- (void)test820Relations
{
	@autoreleasepool
	{
		AutoParent *parent = [AutoParent createInstanceWithId:1];
		parent.children = [NSMutableArray new];
		for (NSUInteger index = 1; index < children + 1; index++)
		{
			AutoChild *child = [AutoChild createInstanceWithId:index];
			child.name = [NSString stringWithFormat:@"child %i", (int)index];
			child.parent_id = 1;
			[parent.children addObject:child];
		}
		NSError *error = [AutoParent saveAllWithChanges];
		if (error)
			NSLog(@"error!! HELP %@", error);
		[parent.children removeAllObjects];
		parent = nil;
	}
	
	//1.409 or 1.077 sec for 100000 children
	[self measureBlock:^{
		
		@autoreleasepool
		{
			AutoParent *parent = [AutoParent createInstanceWithId:1];
			XCTAssertNil(parent.children, @"Parent is already created!");
			XCTAssertTrue(parent.children.count == 0, @"Parent already has children!!");
			parent.children = [AutoChild fetchQuery:@"WHERE parent_id = ?" arguments:@[parent.idValue]].mutableRows;
			for (AutoChild *child in parent.children)
			{
				child.parent = parent;
			}
			parent = nil;
		}
	}];
	NSLog(@"done");
}

- (void)test809Relations
{
	//here we build many-to-many relations
	NSMutableArray *stringArray = [NSMutableArray new];
	@autoreleasepool
	{
		AutoParent *parent = [AutoParent createInstanceWithId:1];
		parent.manyChildren = [NSMutableArray new];
		//NSMutableSet *manyChildIdsContainer = [NSMutableSet new];
		for (NSUInteger index = 1; index < children + 1; index++)
		{
			AutoManyChild *child = [AutoManyChild createInstanceWithId:index];
			child.name = [NSString stringWithFormat:@"child %i", (int)index];
			[parent.manyChildren addObject:child];
			[stringArray addObject:child.idValue.stringValue];
		}
		parent.manyChildIds = [stringArray componentsJoinedByString:@","];
		[AutoParent saveAllWithChanges];
		parent = nil;
	}
	
	AutoParent *parent = [AutoParent createInstanceWithId:1];
	XCTAssertTrue(parent.manyChildren.count == 0, @"Many-to-many did not release parent!");
	[parent fetchRelations];
	XCTAssertTrue(parent.manyChildren.count == children, @"Many-to-many did not work! just %i children.", (int)parent.manyChildren.count);
	NSLog(@"working?");
}


/*
 TODO:
 test fetching one parent from many childern
 */
@end
