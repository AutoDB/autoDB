//
//  CompareFunctionTests.m
//  AutoDBTests
//
//  Created by Olof Thorén on 2018-09-14.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "AutoModel.h"
#import "ConcurrencyModel.h"
#import "SecondModel.h"
#import "AutoParent.h"
#import "AutoDB.h"

/*
 
 We have tested fetching with ids, first without checking tableCache - it was slow: ~0.85 sec for 4000 objects
 We then had half of the objects in the cache and checked it first - wow! half the time!
 We then took all objects in the cache, and yes 0.006 sec (no-time).
 BUT when hitting 2 or less than 5% of the objects it was slower than not checking at all. So we check if cache has at least 5% objects before trying. HOWEVER, weak objects does not release its key (the count doesn't change), so this won't matter much.
 We also checked missing 100% of objects (nothing in cache) - this actualy did not matter much.
 */

@interface CompareFunctionTests : XCTestCase
{
	XCTestExpectation *expect;
}
@end

@implementation CompareFunctionTests

static NSUInteger testObjects = 4000;
static NSMutableArray *idArray;
+ (void)setUp
{
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	//NSString *standard = [supportPath stringByAppendingPathComponent:@"auto_database.sqlite3"];
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:@{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]} migrateBlock:^(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray *errors) {
		
		[self printMigrateState:state willMigrateTables:willMigrateTables errors:errors];
	}];
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {}];
	NSLog(@"creating objects...");
	NSMutableArray *models = [NSMutableArray new];
	idArray = [NSMutableArray new];
	for (NSInteger index = 1; index < testObjects + 1; index++)
	{
		SecondModel *model = [SecondModel createInstanceWithId:index];
		if (!model.string)
		{
			model.string = [NSString stringWithFormat:@"Object %i", (int)index];
			[models addObject:model];
		}
		[idArray addObject:model.idValue];
	}
	[SecondModel save:models];
}

+ (void)tearDown
{
	[[AutoDB sharedInstance] destroyDatabase];
}

- (void)setUp
{
	//expect = [self expectationWithDescription:@"Testing dude!"];
	
	[SecondModel inDatabase:^(AFMDatabase * _Nonnull db) {}];	//just wait until cache exists
	SecondModel *model = [SecondModel.tableCache objectForKey:@1];
	XCTAssertNil(model, @"Object deleted still in cache!");
}

+ (void) printMigrateState:(MigrationState) state willMigrateTables:(NSMutableSet * _Nullable) willMigrateTables errors:(NSArray *)errors
{
	NSArray <NSString*> *stateStrings = @[@"MigrationStateError", @"MigrationStateStart", @"MigrationStateComplete"];
	NSMutableString *logString = stateStrings[state].mutableCopy;
	if (willMigrateTables)
		[logString appendFormat:@" tables: %@", willMigrateTables];
	if (errors)
		[logString appendFormat:@" errors: %@", errors];
	NSLog(@"%@", logString);
}

//find out if using cache can be faster than fetching from db - also: move this to another class
- (void) testFetchIdsRegular
{
	[self measureBlock:^{
		
		NSArray *rows = [SecondModel fetchIds:idArray].rows;
		XCTAssertEqual(rows.count, testObjects);
	}];
}

//So if we have a cache but it always misses, what is the penalty - almost nothing.
- (void) testFetchIdsCacheMiss
{
	[self measureBlock:^{
		
		NSArray *rows = [self fetchIds:idArray forClass:[SecondModel class]].rows;
		XCTAssertEqual(rows.count, testObjects);
	}];
}

//and when we get half from cache, what then? - fetching from db is linear so this is almost double the speed.
- (void) testFetchIdsCacheHitHalf
{
	NSArray *objects = [SecondModel fetchIds:[idArray subarrayWithRange:NSMakeRange(0, idArray.count / 2)]].rows;
	XCTAssertNotNil(objects);
	
	[self measureBlock:^{
		
		NSArray *rows = [self fetchIds:idArray forClass:[SecondModel class]].rows;
		XCTAssertEqual(rows.count, testObjects);
	}];
}

//if only a few objects are hit - is it still worth it?
- (void) testFetchIdsXCacheHitSome
{
	NSArray *objects = [SecondModel fetchIds:[idArray subarrayWithRange:NSMakeRange(0, testObjects * 0.05)]].rows;
	XCTAssertNotNil(objects);
	
	[self measureBlock:^{
		
		NSArray *rows = [self fetchIds:idArray forClass:[SecondModel class]].rows;
		XCTAssertEqual(rows.count, testObjects);
	}];
}

//I also want to test the difference between not having a query cache. This must be run first.
- (void) test1FetchIdsRegularNoQueryCache
{
	[self measureBlock:^{
		
		NSArray *rows = [self fetchIdsNoCache:idArray forClass:[SecondModel class]].rows;
		XCTAssertEqual(rows.count, testObjects);
	}];
}

+ (NSCache*) queryCache { return  nil; }
+ (NSString*) questionMarks:(NSUInteger)count { return  nil; }
- (AutoResult*) fetchIds:(NSArray*)ids forClass:(Class)classObject
{
	if (!ids || ids.count == 0)
		return nil;
	
	__block NSMutableArray <AutoModel*>*cachedObjects = nil;
	if (ids.count > 1)
	{
		//Don't go here if we only are looking for one - then this is already done.
		__block NSMutableArray <NSNumber*>*removeIds = nil;
		AutoConcurrentMapTable *cache = [classObject tableCache];
		[cache syncPerformBlock:^(NSMapTable * _Nonnull table) {
			
			if (table.count <= ids.count * 0.05)
			{
				//we don't gain any performance unless we hit more than 5% of our objects in the cache.
				//TODO: to bad that strongToWeakObjectsMapTable does not resize count after object been released... oh, well - its still good!
				return;
			}
			for (NSNumber *idValue in ids)
			{
				AutoModel* object = [table objectForKey:idValue];
				if (object)
				{
					if (!cachedObjects)
					{
						cachedObjects = [NSMutableArray new];
						removeIds = [NSMutableArray new];
					}
					[cachedObjects addObject:object];
					[removeIds addObject:idValue];
				}
			}
		}];
		if (removeIds)
		{
			NSMutableArray *mutableIds = ids.mutableCopy;
			[mutableIds removeObjectsInArray:removeIds];
			ids = mutableIds;
			if (ids.count == 0)
			{
				AutoResult* fetchedObjects = [AutoResult new];
				for (AutoModel *object in cachedObjects)
				{
					[fetchedObjects.mutableRows addObject:object];
					if (fetchedObjects.hasCreatedDict)
						fetchedObjects.mutableDictionary[object.idValue] = object;
				}
				return fetchedObjects;
			}
		}
	}
	
	NSString *fetchAllKey = [AutoModelCacheHandler.sharedInstance keyForFunction:@"fetchAllIds" objects:ids.count class:classObject];
	
	__block NSString *query;
	FMStatement *cachedStatement = [[classObject queryCache] objectForKey:fetchAllKey];
	if (!cachedStatement)
	{
		NSString *questionMarks = [classObject questionMarks:ids.count];
		query = [NSString stringWithFormat:@"%@ WHERE %@ IN (%@) AND is_deleted = 0", [AutoDB.sharedInstance selectQuery:classObject], primaryKeyName, questionMarks];
	}
	
	__block AutoResult* fetchedObjects = nil;
	[classObject inDatabase:^void(AFMDatabase* db)
	{
		 if (cachedStatement)
		 {
			 query = cachedStatement.query;
		 }
		 else if (ids.count < 100)   //when should we cache this query?
		 {
			 FMStatement *statement = [db cacheStatementForQuery:query];
			 if (statement) [classObject.queryCache setObject:statement forKey:fetchAllKey];
		 }
		 
		 AFMResultSet *resultSet = [db executeQuery:query withArgumentsInArray:ids];
		 if (resultSet) fetchedObjects = [classObject handleFetchResult:resultSet];
	}];
	
	if (fetchedObjects && cachedObjects)
	{
		for (AutoModel *object in cachedObjects)
		{
			[fetchedObjects.mutableRows addObject:object];
			if (fetchedObjects.hasCreatedDict)
				fetchedObjects.mutableDictionary[object.idValue] = object;
		}
	}
	
	return fetchedObjects;
}

- (AutoResult*) fetchIdsNoCache:(NSArray*)ids forClass:(Class)classObject
{
	if (!ids || ids.count == 0)
		return nil;
	
	//basically no difference.
	//TODO: first we must evict cached objects from this one:
	//NSString *fetchAllKey = [AutoModelCacheHandler.sharedInstance keyForFunction:@"fetchAllIds" objects:ids.count class:classObject];
	
	NSString *questionMarks = [classObject questionMarks:ids.count];
	__block NSString *query = [NSString stringWithFormat:@"%@ WHERE %@ IN (%@) AND is_deleted = 0", [AutoDB.sharedInstance selectQuery:classObject], primaryKeyName, questionMarks];
	
	__block AutoResult* fetchedObjects = nil;
	[classObject inDatabase:^void(AFMDatabase* db)
	{
		 AFMResultSet *resultSet = [db executeQuery:query withArgumentsInArray:ids];
		 if (resultSet) fetchedObjects = [classObject handleFetchResult:resultSet];
	}];
	
	return fetchedObjects;
}

@end
