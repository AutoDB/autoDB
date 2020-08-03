//
//  PropertyTests.m
//  AutoDBTests
//
//  Created by Olof Thoren on 2018-08-21.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "ValueHandling.h"
#import "AutoModelRelation.h"
#import "AutoDB.h"

@interface PropertyTests : XCTestCase

@end

@implementation PropertyTests

+ (void) setUp
{
	[[AutoDB sharedInstance] destroyDatabase];
	NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
	NSString *concurrency = [supportPath stringByAppendingPathComponent:@"concurrency.sqlite3"];
	NSString *second = [supportPath stringByAppendingPathComponent:@"second.sqlite3"];
	
	[[AutoDB sharedInstance] createDatabaseWithPathsForClasses:@{ concurrency : @[@"AutoParent", @"ConcurrencyModel"], second : @[@"AutoChild", @"AutoStrongChild", @"SecondModel", @"ValueHandling"]} migrateBlock:nil];
}

- (void)setUp {
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
}

- (void)testPropertyChanges
{
	ValueHandling *item = [ValueHandling createInstanceWithId:1];
	NSUInteger integer = UINT64_MAX;
	double doubleValue = 12342134.9182379182735;
	NSDate* date = [NSDate dateWithTimeIntervalSinceNow:1.123];
	NSString *string = @"some longer äöå string";
	
	item.integer = integer;
	item.doubleValue = doubleValue;
	item.date = date.copy;
	item.string = string.copy;
	
	//first check that those are equal... not anymore. they always are.
	
	//Then let's see if they mark changes properly.
	item.hasChanges = NO;
	
	item.integer = integer;
	item.doubleValue = doubleValue;
	item.date = date;
	item.string = string;
	
	XCTAssertFalse(item.hasChanges, @"marking even though nothing changed!");
	
	item.integer = integer-1;
	XCTAssertTrue(item.hasChanges);
	item.hasChanges = NO;
	
	item.doubleValue = doubleValue * 1.1;
	XCTAssertTrue(item.hasChanges);
	item.hasChanges = NO;
	
	item.date = [NSDate dateWithTimeIntervalSinceNow:-12];
	XCTAssertTrue(item.hasChanges);
	item.hasChanges = NO;
	
	item.string = @"string";
	XCTAssertTrue(item.hasChanges);
	item.hasChanges = NO;
	
	//testing null
	item.string = nil;
	XCTAssertTrue(item.hasChanges);
	item.hasChanges = NO;
	
	item.string = nil;
	XCTAssertFalse(item.hasChanges);
	
	item.string = string;
	XCTAssertTrue(item.hasChanges);
}

- (void)testCollectionChanges
{
	
	AutoDBArray *array = [[AutoDBArray alloc] initWithArray:@[@9]];
	array[0] = @0;
	array[1] = @1;
	array[2] = @2;
	
	[array addObjectsFromArray:@[@4]];
	XCTAssertTrue(array.hasChanges); array.hasChanges = NO;
	
	[array removeObject:@4];
	XCTAssertTrue(array.hasChanges); array.hasChanges = NO;
	
	[array replaceObjectsInRange:NSMakeRange(2, 1) withObjectsFromArray:@[@9]];
	XCTAssertTrue(array.hasChanges); array.hasChanges = NO;
	
	[array setArray:@[@0, @1, @2, @3, @4]];
	XCTAssertTrue(array.hasChanges); array.hasChanges = NO;
	
	[array sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"integerValue" ascending:NO]]];
	XCTAssertTrue(array.hasChanges); array.hasChanges = NO;
	
	[array removeObjectsAtIndexes:[NSIndexSet indexSetWithIndex:0]];
	XCTAssertTrue(array.hasChanges); array.hasChanges = NO;
	
	[array setObject:@9 atIndexedSubscript:2];
	XCTAssertTrue(array.hasChanges); array.hasChanges = NO;
	
	
	AutoDBOrderedSet *orderedSet = [AutoDBOrderedSet orderedSetWithObject:@8];
	orderedSet[0] = @0;
	orderedSet[1] = @1;
	orderedSet[2] = @2;
	
	[orderedSet addObjectsFromArray:@[@4]];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet removeObject:@4];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet replaceObjectsAtIndexes:[NSIndexSet indexSetWithIndex:1] withObjects:@[@9]];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"integerValue" ascending:NO]]];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet removeObjectsAtIndexes:[NSIndexSet indexSetWithIndex:0]];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet setObject:@9 atIndexedSubscript:2];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet intersectSet:[NSSet setWithObjects:@1, @2, nil]];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet minusSet:[NSSet setWithObjects:@1, nil]];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	[orderedSet unionSet:[NSSet setWithObjects:@1, nil]];
	XCTAssertTrue(orderedSet.hasChanges); orderedSet.hasChanges = NO;
	
	
	AutoDBSet *set = [AutoDBSet setWithObjects:@2, nil];
	[set addObject:@0];
	XCTAssertTrue(set.hasChanges); set.hasChanges = NO;
	
	[set addObjectsFromArray:@[@4, @1, @2, @3]];
	XCTAssertTrue(set.hasChanges); set.hasChanges = NO;
	
	[set removeObject:@4];
	XCTAssertTrue(set.hasChanges); set.hasChanges = NO;
	
	XCTAssertNotNil([set member:@3]);
	
	[set intersectSet:[NSSet setWithObjects:@1, @2, nil]];
	XCTAssertTrue(set.hasChanges); set.hasChanges = NO;
	
	[set minusSet:[NSSet setWithObjects:@1, nil]];
	XCTAssertTrue(set.hasChanges); set.hasChanges = NO;
	
	[set unionSet:[NSSet setWithObjects:@1, nil]];
	XCTAssertTrue(set.hasChanges); set.hasChanges = NO;
}

//	- @warning If you have dependent properties you need to call keyPathsForValuesAffecting<property-name> to get automatic behaviour (like if you store a dictionary in the db under some other property).


@end
