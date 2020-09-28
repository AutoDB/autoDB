//
//	AutoModel.m
//	Simulator
//
//	Created by Olof Thorén on 2014-03-17.
//	Copyright (c) 2014 Aggressive Development. All rights reserved.
//

#import "AutoModel.h"
#import "AutoModelRelation.h"
#import "AutoDB.h"
#import "AFMResultSet.h"

@import ObjectiveC;

#ifndef DEBUG
	#define DEBUG 0
#endif

NSString *const primaryKeyName = @"id";
NSString *const AutoModelPrimaryKeyChangeNotification = @"AutoModelPrimaryKeyChangeNotification";  //sent when the primary key changes
NSString *const AutoModelUpdateNotification = @"AutoModelUpdateNotification";	//sent when at least one object have been updated, created or deleted

@implementation AutoModel
{
	BOOL hasFetchedRelations, toBeInserted, isAwake;
}

#pragma mark - deprication 
//find these and remove

+ (void) fetchAllWithOffset:(NSUInteger)offset limit:(NSUInteger)limit resultBlock:(AutoModelResultBlock)resultBlock
{
	NSLog(@"error! use fetchQuery:arguments: instead!");
}

+ (NSMutableDictionary*) fetchAllWithOffset:(NSUInteger)offset limit:(NSUInteger)limit
{
    NSLog(@"error! use fetchQuery:arguments: instead!");
    
    return nil;
}

#pragma mark - class variables and accessor methods

+ (AutoConcurrentMapTable *) tableCache
{
    AutoConcurrentMapTable *tableCache = objc_getAssociatedObject(self, @selector(tableCache));
    if (!tableCache)
    {
		//tableCache is not setup, we need to wait for DB.
		[self inDatabase:^(AFMDatabase * _Nonnull db) {}];
		tableCache = objc_getAssociatedObject(self, @selector(tableCache));
    }
    return tableCache;
}

//These must be global, so we leave them static for now.
static dispatch_queue_t tablesWithChangesQueue;
static NSMutableDictionary *tablesWithChanges;

+ (void) setupWithChangesQueue:(dispatch_queue_t)queue changesDictionary:(NSMutableDictionary*)tablesWithChanges_
{
	tablesWithChanges = tablesWithChanges_;
	tablesWithChangesQueue = queue;
}

+ (NSCache*) queryCache
{
    static char key;
    NSCache *queryCache = objc_getAssociatedObject(self, &key);
    if (!queryCache)
    {
        NSCache *queryCache = [NSCache new];
        objc_setAssociatedObject(self, &key, queryCache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
	return queryCache;
}

+ (AFMDatabaseQueue *) databaseQueue
{
	AFMDatabaseQueue *queue = objc_getAssociatedObject(self, @selector(databaseQueue));
	if (!queue)
	{
		NSLog(@"error no queue for class %@ %p", self, self);
		assert(NO);
	}
	return queue;
}

+ (void) inDatabase:(DatabaseBlock)block
{
    [self.databaseQueue inDatabase:block];
}

+ (void) executeInDatabase:(void (^)(AFMDatabase *db))block
{
    [[self databaseQueue] asyncExecuteDatabase:block];
}

#pragma mark - create instances

- (void) insertIntoDB
{
	if (self.isToBeInserted)
		return;
	self.hasFetchedRelations = YES;
	if (!self.class.useAutoIncrement)
	{
		[self generateNewId];
	}
	self.isToBeInserted = YES;
}

+ (instancetype) createInstance
{
	return [self newInstancePrivate:0];
}

+ (void) createInstanceWithId:(u_int64_t)id_value result:(AutoModelSingleResultBlock)resultBlock
{
	NSNumber *id_field = @(id_value);
	
	//We must do this inside a queue/lock, otherwise there might be some other thread also creating this object at the same time.
	//Since we can't use the cache queue (will deadlock when fetching ids), we must use our db-thread.
	[self executeInDatabase:^(AFMDatabase * _Nonnull db) {
		
		AutoModel *newInstance = [self.tableCache objectForKey:id_field];
		if (newInstance == nil)
		{
			newInstance = [self fetchIds:@[id_field]].rows.lastObject;
		}
		if (newInstance == nil)
		{
			newInstance = [self newInstancePrivate:id_value];
		}
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void) { resultBlock(newInstance); });
	}];
}

+ (instancetype) createInstanceWithId:(u_int64_t)id_value
{
	NSNumber *id_field = @(id_value);
	
	//We must do this inside a queue/lock, otherwise there might be some other thread also creating this object at the same time.
	//Since we can't use the cache queue (will deadlock when fetching ids), we must use our db-thread.
	__block AutoModel *newInstance;
	[self inDatabase:^(AFMDatabase * _Nonnull db) {
		
		newInstance = [self.tableCache objectForKey:id_field];
		if (newInstance == nil)
		{
			newInstance = [self fetchIds:@[id_field]].rows.lastObject;
		}
		if (newInstance == nil)
		{
			newInstance = [self newInstancePrivate:id_value];
		}
	}];
	return newInstance;
}

///private method to create a new instance when you already have the lock - or if id = 0, you don't need the lock.
+ (instancetype) newInstancePrivate:(u_int64_t)id_value
{
	//instance did not exist, create it and set a new id.
	AutoModel *newInstance = [self new];
	if (id_value)
	{
		newInstance.id = id_value;
		[self.tableCache setObject:newInstance forKey:newInstance.idValue];
	}
	else if (!self.useAutoIncrement)
	{
		//Never assume a newly created item exists before touching db - that is wrong! BUT, we must have an ID when inserting in order not to get autoIncrement.
		[newInstance generateNewId];
	}
	//sync needs id first
	newInstance.isToBeInserted = YES;
	newInstance.hasFetchedRelations = YES;
	
	if (self.preventObservingProperties == NO)
	{
		newInstance.hasChanges = YES;
	}
	if (!newInstance.isAwake)
	{
		[newInstance awakeFromFetch];
		newInstance->isAwake = YES;
	}
	//we don't save here - allow for temporary objects
	return newInstance;
}

- (void) setIsToBeInserted:(BOOL)_isToBeInserted
{
	toBeInserted = _isToBeInserted;
}

- (BOOL) isToBeInserted
{
	return toBeInserted;
}

- (void) generateNewId
{
	self.id = generateRandomAutoId();
}

u_int64_t generateRandomAutoId()
{
	//4294967295 = 32 bits.
	u_int64_t bit29_60 = arc4random();
	bit29_60 = bit29_60 << 29;	//left shift to cover bit 29 to 60
	u_int64_t bit0_28 = arc4random() >> 3; //right shift to cover the first 28 bits.
	
	return bit0_28 | bit29_60;
}

#pragma mark - create and migrate databases

+ (NSDictionary*) defaultValues
{
	return nil;
}

+ (NSDictionary <NSString*, NSArray <NSString*>*>* _Nullable) columnIndex
{
	return nil;
}

+ (NSArray<NSArray<NSString *> *> *)uniqueConstraints
{
	return nil;
}

+ (BOOL) useAutoIncrement
{
	return YES;
}

- (void) registerChange:(NSString*)columnName oldValue:(id)oldValue newValue:(id)newValue
{
	/*
	 Here we can start working on building smarter saves, that only sends changed columns to db. BUT - please don't do deltas, that is pointless.
	//to do deltas we have old value here:
	//id oldValue = [self valueForKey:columnName];
	if (!_modifiedColumns) _modifiedColumns = [NSMutableDictionary new];
	if (!_modifiedColumns[columnName])
		_modifiedColumns[columnName] = oldValue;
	 */
}

+ (void) migrateTable:(NSString*)table column:(NSString*)column oldType:(AutoFieldType)oldType newType:(AutoFieldType)newType values:(NSMutableArray <NSMutableArray*>*)arrayOfTuples
{
	//Default implementation keeps old values.
	[arrayOfTuples removeAllObjects];
}

#pragma mark - define tables

/*
- (u_int64_t)id
{
	return _id;
}
- (void)setId:(u_int64_t)id
{
	_id = id;
}*/

+ (NSSet*) excludeParametersFromTable
{
	return nil;
}

+ (NSDictionary*) migrateParameters
{
	return nil;
	//return @{@"oldParameterName": @"newer_parameter_name"};	//we cannot switch these around unless we want to avoid database versioning.
}

/*not used
+ (NSDictionary*) parameterSettings
{
	if (0)
	{
		NSString *settings = @"{'param1' : { 'DEFAULT' : 10, 'NONE_NULL' : 1 } }";
		settings = [settings stringByReplacingOccurrencesOfString:@"'" withString:@"\""];
		NSError *error = nil;
		NSDictionary *parameters = [NSJSONSerialization JSONObjectWithData:[settings dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
		NSLog(@"parameters %@", error);
		return parameters;
	}
	
	//return @{@"INDEX" : @[@"param1", @"param2"], @"NONE_NULL" : @[@"param1", @"param2"], @"DEFAULT" : ;
	return nil;
}
*/

#pragma mark - relations

+ (NSDictionary*) relations
{
	//defaults to no relations.
	return nil;
	
	/*
	 NSDictionary* relations =
	 @{
	 AUTO_RELATIONS_PARENT_ID_KEY : @{ @"AutoParent" : @"parent_id"},
	 AUTO_RELATIONS_PARENT_OBJECT_KEY : @{ @"AutoParent" : @"parent" }
	 };
	 
	 and in the parent:
	 
	 NSDictionary* relations =
	 @{
	 AUTO_RELATIONS_CHILD_CONTAINER_KEY : @{ @"AutoChild" : @"children" }
	 };
	 
	 For one-one relations we need one class who has the strong relation and a receiver who has the weak. The weak reference is optional.
	 
	 NSDictionary* relations =
	 @{
	 	AUTO_RELATIONS_STRONG_ID_KEY : @{ @"AutoChild" : @"this_child_id" },
	 	AUTO_RELATIONS_STRONG_OBJECT_KEY : @{ @"AutoChild" : @"this_child" }
	 };
	 
	 */
}

//List all columns containing an id to a relation
+ (NSSet*) relationsIdColumns
{
	NSMutableSet *idColumns = [NSMutableSet new];
	NSDictionary *relations = [self relations];
	for (NSString *column in [relations[AUTO_RELATIONS_PARENT_ID_KEY] allValues])
	{
		[idColumns addObject:column];
	}
	for (NSString *column in [relations[AUTO_RELATIONS_STRONG_ID_KEY] allValues])
	{
		[idColumns addObject:column];
	}
	
	return idColumns;
}

+ (NSArray*) relationPropertyNamesOfType:(BOOL)fetchableRelations
{
	NSMutableArray *propertyNames = [NSMutableArray new];
	NSDictionary *relations = self.relations;
	
	NSArray *relationKeys;
	if (fetchableRelations)
	{
		relationKeys = @[AUTO_RELATIONS_CHILD_CONTAINER_KEY, AUTO_RELATIONS_STRONG_OBJECT_KEY];
	}
	
	for (NSString *relationKey in relationKeys)
	{
		NSDictionary *classes = relations[relationKey];
		for (NSString *name in [classes allValues])
		{
			[propertyNames addObject:name];
		}
	}
	
	return propertyNames;
}


/*
 For relations to work we need to
 1, check each object if we have fetched relations already.
 2, Check the cache if our child has been fetched by someone else, but not paired with us - (this could happen regularly depending on how the app works).
 3, Fetch from db (but only those not in cache).
 4, pair the objects
 */
+ (void) fetchRelations:(NSArray*)objects_in
{
	[AutoModelRelation fetchRelations:objects_in queue:self.databaseQueue];
}

- (void) fetchRelations
{
	if (!hasFetchedRelations)
	{
		[self.class fetchRelations:@[self]];
	}
}

- (BOOL) hasFetchedRelations
{
	if (!hasFetchedRelations)
	{
		if ([self.class relations] == nil)
		{
			hasFetchedRelations = YES;
		}
	}
	return hasFetchedRelations;
}

- (void) setHasFetchedRelations:(BOOL)hasFetched
{
	hasFetchedRelations = hasFetched;
}


#pragma mark - table state

+ (NSMutableArray*) dictionaryRepresentation:(NSArray*)objects settings:(NSDictionary*)settings
{
	NSMutableArray *serverValues = [[NSMutableArray alloc] initWithCapacity:objects.count];
	for (AutoModel *object in objects)
	{
		NSDictionary *autoDictionary = [object dictionaryRepresentationRecursive:NO settings:settings];
		[serverValues addObject:autoDictionary];
	}
	return serverValues;
}

- (NSDictionary*) dictionaryRepresentationRecursive:(BOOL)recursive
{
	return [self dictionaryRepresentationRecursive:recursive settings:nil];
}

- (NSDictionary*) dictionaryRepresentationRecursive:(BOOL)recursive settings:(NSDictionary*)settings
{
	NSString *classString = NSStringFromClass(self.class);
	NSDictionary *syntax = [AutoDB.sharedInstance tableSyntaxForClass:classString];
	NSArray *columns = [syntax[AUTO_COLUMN_KEY] allKeys];
	
	NSDictionary *columnSyntax = syntax[AUTO_COLUMN_KEY];
	BOOL useUnixTimeStamp = [settings[@"useUnixTimeStamp"] boolValue];
	NSDictionary *translations = settings[@"translate"];
	NSSet *ignore = settings[@"ignore"];
	
	NSMutableDictionary *rep = [NSMutableDictionary dictionary];
	for (NSString *column in columns)
	{
		NSString *columnName = column;
		if (ignore && [ignore containsObject:column])
		{
			continue;
		}
		
		id value = [self valueForKey:column];
		if (value)
		{
			NSNumber *columnType = columnSyntax[column];
			if (columnType.integerValue == AutoFieldTypeBlob)
			{
				NSData *data = (NSData*)value;
				value = [NSString stringWithFormat:@"<Data with length %lu", (unsigned long)data.length];
			}
			if (settings)
			{
				if (useUnixTimeStamp && columnType.integerValue == AutoFieldTypeDate)
				{
					NSDate* date = (NSDate*)value;
					value = @([date timeIntervalSince1970]);
				}
			}
			if (translations && translations[column])
			{
				columnName = translations[column];
			}
			rep[columnName] = value;
		}
		else if (settings && [settings objectForKey:@"show_NULL"])	//only show null if we have to, omiting a value == being NULL.
		{
			rep[column] = @"<NULL>";
		}
	}
	
	//also relations
	NSDictionary *relations = [self.class relations];
	for (NSString *childClassString in [relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY] allKeys])
	{
		NSMutableArray *formattedChildren = [NSMutableArray array];
		NSString *childContainerString = relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY][childClassString];
		id <NSFastEnumeration>container = [self valueForKey:childContainerString];
		for (AutoModel *child in container)
		{
			NSString *childDescription;
			if (recursive)
			{
				childDescription = [NSString stringWithFormat:@"<%@ %@>", childClassString, [child dictionaryRepresentationRecursive:NO]];
			}
			else
			{
				childDescription = [NSString stringWithFormat:@"<%@ %@:%@>", childClassString, primaryKeyName, [child idValue]];
			}
			[formattedChildren addObject:childDescription];
		}
		NSString *childrenString = [NSString stringWithFormat:@"%@\n", [formattedChildren componentsJoinedByString:@", "]];
		[rep setObject:childrenString forKey:relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY][childClassString]];
	}
	
	//and parents
	for (NSString *parentClassString in [relations[AUTO_RELATIONS_PARENT_OBJECT_KEY] allKeys])
	{
		NSString *parentString = relations[AUTO_RELATIONS_PARENT_OBJECT_KEY][parentClassString];
		AutoModel *parent = [self valueForKey:parentString];
		if (!parent)
		{
			[rep setObject:@"<NULL>" forKey:parentString];
		}
		else
		{
			[rep setObject:[parent dictionaryRepresentationRecursive:NO] forKey:parentString];
		}
	}
	
	//and strong relations
	for (NSString *classString in [relations[AUTO_RELATIONS_STRONG_OBJECT_KEY] allKeys])
	{
		NSString *key = relations[AUTO_RELATIONS_STRONG_OBJECT_KEY][classString];
		AutoModel *parent = [self valueForKey:key];
		if (!parent)
		{
			[rep setObject:@"<NULL>" forKey:key];
		}
		else
		{
			NSString *description = [NSString stringWithFormat:@"<%@ %@:%@>", parent.class, primaryKeyName, [parent idValue]];
			[rep setObject:description forKey:key];
		}
	}
	
	//and weak relations
	for (NSString *classString in [relations[AUTO_RELATIONS_WEAK_OBJECT_KEY] allKeys])
	{
		NSString *key = relations[AUTO_RELATIONS_WEAK_OBJECT_KEY][classString];
		AutoModel *parent = [self valueForKey:key];
		if (!parent)
		{
			[rep setObject:@"<NULL>" forKey:key];
		}
		else
		{
			NSString *description = [NSString stringWithFormat:@"<%@ %@:%@>", parent.class, primaryKeyName, [parent idValue]];
			[rep setObject:description forKey:key];
		}
	}
	
	return rep;
}

- (NSString*) description
{
	return [NSString stringWithFormat:@"%@ %@", [super description], [[[self dictionaryRepresentationRecursive:NO] description] stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"]];
}

/*
 TODO: fix this by looping over all existing classes and taking their cache's allValues.
+ (void) printCachedTables
{
	NSEnumerator *enumerator = [databaseCache keyEnumerator];
	id table, oldTable;
	
	while ((table = [enumerator nextObject]))
	{
		if ([table isEqual:oldTable] == NO)
		{
			oldTable = table;
			NSLog(@"Printing cached table %@:", table);
		}
		AutoConcurrentMapTable *tableMap = [databaseCache objectForKey:table];
		NSEnumerator *tableMapEnumerator = [tableMap keyEnumerator];
		id objectKey;
		while ((objectKey = [tableMapEnumerator nextObject]))
		{
			NSLog(@"%@ : %@", objectKey, [tableMap objectForKey:objectKey]);
		}
	}
}
 */

#pragma mark - Track changes

- (void) setPrimitiveValue:(nullable id)value forKey:(NSString*)key
{
	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
	
	//remember that id has no observer
	
	//we call the primitive method since it does not have callbacks.
	NSString *primitiveMethodName = [NSString stringWithFormat:@"setPrimitive%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]];
	SEL primitiveSelector = NSSelectorFromString(primitiveMethodName);
	Method primitiveMethod = class_getInstanceMethod(self.class, primitiveSelector);
	IMP primitiveImplementation = method_getImplementation(primitiveMethod);
	
	//get the original method, implementation and selector:
	NSString *methodName = [NSString stringWithFormat:@"set%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]];
	Method originalMethod = class_getInstanceMethod(self.class, NSSelectorFromString(methodName));
	
	//we need to check type information, use objc - could also use the table info.
	int argLength = 3;
	char argumentType[argLength];
	method_getArgumentType(originalMethod, 2, argumentType, argLength);
	
	//https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100
	if (argumentType[0] == '@')
	{
		void (*func)(id, SEL, id) = (void *)primitiveImplementation;
		func(self, primitiveSelector, value);
	}
	else if (argumentType[0] == 'f' || argumentType[0] == 'd')
	{
		void (*func)(id, SEL, double) = (void *)primitiveImplementation;
		func(self, primitiveSelector, [value doubleValue]);
	}
	else
	{
		//some sort of int
		void (*func)(id, SEL, NSUInteger) = (void *)primitiveImplementation;
		func(self, primitiveSelector, [value integerValue]);
	}
	
	#pragma clang diagnostic pop
}

- (BOOL) hasChanges
{
	return hasChanges;
}

- (void) setHasChanges:(BOOL)_hasChanges
{
	if (ignoreChanges) return;
	if (hasChanges == NO && _hasChanges)
	{
		//Add us to the changes table!
		dispatch_async(tablesWithChangesQueue, ^(void){
			
			NSString *classString = NSStringFromClass(self.class);
			NSHashTable *changesCache = tablesWithChanges[classString];
			if (changesCache == nil)
			{
				//we must use strong memory, otherwise it may be release between changes and save
				changesCache = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory];
				tablesWithChanges[classString] = changesCache;
			}
			[changesCache addObject:self];
			if (changesCache.count > 250)
			{
				//We don't let them grow too large, have incremental saves.
				[AutoModel saveAllWithChangesInternal];
			}
		});
	}
	hasChanges = _hasChanges;
}

#pragma mark - fetching

+ (BOOL) preventObservingProperties
{
	return NO;
}

-(BOOL) isAwake
{
	return isAwake;
}

- (void) awakeFromFetch
{
	/*
	 no logic in the superclass, we cannot rely on subclasses to call super.
	if (isAwake)
	{
		return;
	}
	isAwake = YES;
	*/
	/*
	 Method swizzling does work, but should we use it for fetching relations?
	 
	NSArray *propertyNames = [self.class relationPropertyNamesOfType:YES];
	if (propertyNames.count && [self.class useMethodSwizzling]) //either method swizzling is so good and well tested that we can use it always - or not good enough.
	{
		
		if (!swizzledMethods)
		{
			swizzledMethods = [NSMutableDictionary new];
		}
		else
		{
			NSLog(@"Error. Calling awakeFromFetch twice.");
			return;
		}
		
		 
		 For each relationship to another object, we change the implementation to first fetch relationships - then return the value(s). So, do this:
		 1, Swizzle each method to use a block instead.
		 2, When the block is called, switch back to the original method.
		 3, Fetch the relation-objects.
		 4, return the object(s) for the relation that was called.
		 
		 Multi-threading: If several faulting relation properties are called at the same time, this should happen:
		 1, the orginal method will be set several times (first replacing the swizzled method, then replacing the original method). This should all work fine (it just sets a function pointer, should not need to be an intermidiate stage where half-a-pointer might be called - however it should be tested or not used in production code).
		 2, the first call will get the db-lock and the other will have to wait until the first is complete.
		 3, The first will return the values, the rest will skip fetching since already fetched, and thus return the values.
		 4, Any call after this should use the original method.
		
	 
		NSMutableDictionary* __weak weakSwizzledMethods = swizzledMethods;
		for (NSString *methodName in propertyNames)
		{
			SEL originalSel = NSSelectorFromString(methodName);
			
			
			Method originalMethod = class_getInstanceMethod(self.class, originalSel);
			IMP originalImplementation = method_getImplementation(originalMethod);
			NSValue *methodValue = [NSValue valueWithPointer:originalMethod];
			NSValue *implementationValue = [NSValue valueWithPointer:originalImplementation];
			
			//store the original method and the new block so they won't go away
			NSMutableDictionary *blockAndMethods = [NSMutableDictionary new];
			blockAndMethods[@"methodValue"] = methodValue;
			blockAndMethods[@"implementationValue"] = implementationValue;
			[swizzledMethods setObject:blockAndMethods forKey:methodName];
			
			//HELLO! object is SELF in this call!
			dynamicFunctionBlock newMethod = (id)^(id object, SEL _cmd)
			{
				//we need to swizzle the methods and fetch in sequence, otherwise calls following this may access non-fetched values, asuming it to be fetched.
				
				//NSLog(@"wokrs?");
				//NSValue *pointerValue = swizzledMethods[methodName];
				//IMP originalImplementation = pointerValue.pointerValue;
				
				//IMP originalImplementation = method_getImplementation(originalMethod);
				//IMP swizzlingImplementation = method_getImplementation(relationSwizzlingMethods);
				
				//before fetching relations, we need to switch back all implementations.
				
				for (NSDictionary *blockAndMethods in weakSwizzledMethods.allValues)
				{
					NSValue *methodValue = blockAndMethods[@"methodValue"];
					NSValue *implementationValue = blockAndMethods[@"implementationValue"];
					
					IMP originalImplementation = implementationValue.pointerValue;
					Method originalMethod = methodValue.pointerValue;
					
					method_setImplementation(originalMethod, originalImplementation);
				}
				[weakSwizzledMethods removeAllObjects];
				
				[AutoModelRelation fetchRelations:@[object] queue:databaseQueue];
				
				id (*func)(id, SEL) = (void *)originalImplementation;
				id result = func(object, originalSel);
				
				return result;
			};
			
			//copy block from heap to be extra safe/work on iOS 5.
			dynamicFunctionBlock blockSecuredByCopy = [newMethod copy];
			blockAndMethods[@"block"] = blockSecuredByCopy;
			IMP newMethodIMP = imp_implementationWithBlock(blockSecuredByCopy);
			//class_addMethod(self.class, originalSel, newMethodIMP, "v@:");
			method_setImplementation(originalMethod, newMethodIMP);
		}
	 
	}
	  */
}

#pragma mark - fetch with query

///Private blocking method to fetch results.
+ (AutoResult *) fetchQuery:(NSString*)whereQuery arguments:(NSArray* _Nullable)arguments
{
    __block AutoResult *returner = nil;
    //we are building something smarter here by bundling dictionaries and arrays into one object, so we can sort in DB which can be smarter for certain queries, but also query the result by id.
    NSString *query = [self cachedQuery:whereQuery].query;
    if (!query)
        return nil;
    [self.databaseQueue inDatabase:^(AFMDatabase *db)
	{
         //If there is a chached object, handleFetchResult: will take the cached variant instead. So if it's not saved, we will not get the cached object OR get the wrong object.
         AFMResultSet *result;
         if (arguments) result = [db executeQuery:query withArgumentsInArray:arguments];
         else result = [db executeQuery:query];
         
         if (result == nil)
         {
             if ([db lastErrorCode]) NSLog(@"DB query: %@", query);
             return;
         }
         returner = [self handleFetchResult:result];
     }];
    return returner;
}

//This is the primary non-blocking fetchQuery: function
+ (void) fetchQuery:(NSString*)whereQuery arguments:(NSArray*)arguments resultBlock:(AutoResultBlock)resultBlock
{
	[self executeInDatabase:^(AFMDatabase *db) {
		
		//create objects for the results we want
		AutoResult *result = [self fetchQuery:whereQuery arguments:arguments];
		//Not caring for the result is probably an error. if (resultBlock)
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void){ resultBlock(result); });
	}];
}

#pragma mark - fetchWithId

+ (instancetype) fetchId:(NSNumber*)id_field
{
	//For now we just make a call similar to fetchIds, but unwrap the result.
	if (!id_field)
	{
		NSLog(@"Error in fetchWithId! nil value!");
		return nil;
	}
	
	//if we have the object in cache, why not just return it?
	id object = [self.tableCache objectForKey:id_field];
	if (object)
		return object;
	
	return [self fetchIds:@[id_field]].rows.lastObject;
}

+ (void) fetchId:(NSNumber*)id_field resultBlock:(AutoModelSingleResultBlock)result
{
	//For now we just make a call similar to fetchIds, but unwrap the result.
	if (!id_field)
	{
		NSLog(@"Error in fetchWithId! nil value!");
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
		{
			result(nil);
		});
		return;
	}
	
	//if we have the object in cache, why not just return it?
	id object = [self.tableCache objectForKey:id_field];
	if (object)
	{
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
		{
			result(object);
		});
		return;
	}
	
	[self fetchIds:@[id_field] resultBlock:^(AutoResult * _Nullable resultSet) {
		
		AutoModel* object = resultSet.rows.firstObject;
		result(object);
	}];
}

+ (void) fetchIds:(NSArray*)ids resultBlock:(AutoResultBlock)resultBlock
{
	[self executeInDatabase:^(AFMDatabase * _Nonnull db) {
		
		AutoResult *result = [self fetchIds:ids];
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void){
			resultBlock(result);
		});
	}];
}

static NSString* fetchAllSignature = @"fetchAllIds";
+ (AutoResult*) fetchIds:(NSArray*)ids
{
    if (!ids || ids.count == 0)
        return nil;
	
	__block NSMutableArray <AutoModel*>*cachedObjects = nil;
	if (ids.count > 1)
	{
		//Don't go here if we only are looking for one - then this is already done.
		__block NSMutableArray <NSNumber*>*removeIds = nil;
		AutoConcurrentMapTable *cache = self.tableCache;
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
				}
				return fetchedObjects;
			}
		}
	}
	
	__block NSString *query;
    NSString *fetchAllKey = [AutoModelCacheHandler.sharedInstance keyForFunction:fetchAllSignature objects:ids.count class:self];
    FMStatement *cachedStatement = [self.queryCache objectForKey:fetchAllKey];
    if (!cachedStatement)
    {
        NSString *questionMarks = [self questionMarks:ids.count];
        query = [NSString stringWithFormat:@"%@ WHERE %@ IN (%@) AND is_deleted = 0", [AutoDB.sharedInstance selectQuery:self], primaryKeyName, questionMarks];
    }
    
    __block AutoResult* fetchedObjects = nil;
    [self inDatabase:^void(AFMDatabase* db)
    {
        if (cachedStatement)
        {
            query = cachedStatement.query;
        }
        else if (ids.count < 100)   //when should we cache this query?
        {
            FMStatement *statement = [db cacheStatementForQuery:query];
            if (statement) [self.queryCache setObject:statement forKey:fetchAllKey];
        }
        
        AFMResultSet *resultSet = [db executeQuery:query withArgumentsInArray:ids];
        if (resultSet) fetchedObjects = [self handleFetchResult:resultSet];
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

+ (void) fetchWithIdQuery:(NSString *)idQuery arguments:(nullable NSArray*)arguments resultBlock:(AutoResultBlock)resultBlock;
{
	[self executeInDatabase:^(AFMDatabase * _Nonnull db) {
		
		AutoResult *result = [self fetchWithIdQuery:idQuery arguments:arguments];
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void){
			resultBlock(result);
		});
	}];
}

+ (nullable AutoResult*) fetchWithIdQuery:(NSString *)idQuery arguments:(nullable NSArray*)arguments
{
	__block AutoResult* result;
	[self.databaseQueue inDatabase:^(AFMDatabase *db){
		
		//first fetch the ids we are interested in
		AFMResultSet *resultSet = [db executeQuery:idQuery withArgumentsInArray:arguments];
		if (result == nil && [db lastErrorCode])
		{
			NSLog(@"DB query: %@ has error code: %i", idQuery, [db lastErrorCode]);
			return;
		}
		if ([resultSet next])
		{
			NSMutableArray *ids = [NSMutableArray new];
			do
			{
				[ids addObject:[resultSet objectForColumnIndex:0]];
			} while ([resultSet next]);
			
			//then fetch the objects
			result = [self fetchIds:ids];
		}
	}];
	return result;
}

#pragma mark - handle results

///@warning: depricated move us out to the new result type.
+ (void) handleFetchResult:(AFMResultSet *)result dictionary:(NSMutableDictionary*)dictionary array:(NSMutableArray*)array
{
    AutoResult* resultSet = [self handleFetchResult:result];
    if (array)
        [array addObjectsFromArray:resultSet.rows];
    if (dictionary)
    {
        for (AutoModel *obj in resultSet.rows)
        {
            dictionary[obj.idValue] = obj;
        }
    }
}

///Build objects from a result-set and return both dictionary and array, for flexibility, wrapped up in one AutoResult object.
+ (AutoResult *) handleFetchResult:(AFMResultSet *)result
{
	if ([result next])
	{
		AutoConcurrentMapTable *tableCache = self.tableCache;
		if (!tableCache)
		{
			NSLog(@"ERROR:No tableCache for %@ this should be done when creating db", self);
		}
		NSDictionary *columnSyntax = [AutoDB.sharedInstance columnSyntaxForClass:self];
		NSArray *columns = [columnSyntax allKeys];
		NSInteger index = [columns indexOfObject:primaryKeyName];
		
		AutoResult *resultReturner = [AutoResult new];
		do
		{
			id id_field = result[(int)index];
			if (!id_field)
			{
				NSLog(@"cannot fetch no id! %@", result);
				return nil;
			}
			AutoModel *object = [tableCache objectForKey:id_field];
			if (object)
			{
				//this is thread safe, we are only reading from the cache
				[resultReturner setObject:object forKey:id_field];
				continue;
			}
			//this is thead safe, since we are creating a complete new object. The problem here is if we create the same object at the same time, somewhere else - but then the db queue is needed and we are currently using that.
			object = [self new];
			object->ignoreChanges = YES;
			
			//remember, primitive values cannot be null.
			[columns enumerateObjectsUsingBlock:^(id column, NSUInteger index, BOOL *stop)
			{
				id value = result[(int)index];
				
				//everything must go through this method since we need to populate our data by exchanging/washing some values.
				NSNumber *columnType = columnSyntax[column];
				if (value && value == [NSNull null])
				{
					//safeguard against FMDB adding extra data types.
					value = nil;
				}
				else if (value && columnType.integerValue == AutoFieldTypeDate)
				{
					value = [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
				}
				
				[object setValue:value forKey:column];
			}];
			
			[resultReturner setObject:object forKey:id_field];
			[tableCache setObject:object forKey:id_field];
		} while ([result next]);
		
		//we must call awakeFromFetch outside of the result, in case they also need to fetch
		for (AutoModel *object in resultReturner.rows)
		{
			if (!object->isAwake)
			{
				[object awakeFromFetch];
				object->isAwake = YES;
			}
			if (object->_is_deleted == NO)	//don't record changes for deleted objects
				object->ignoreChanges = NO;
		}
		
		return resultReturner;
	}
    return nil;
}

#pragma mark - delete

- (void) willBeDeleted
{
	ignoreChanges = YES;
}

- (void) delete
{
	[self.class delete:@[self]];
}

- (void) deleteAsync:(nullable dispatch_block_t)completeBlock
{
	[self.class delete:@[self] completeBlock:completeBlock];
}

+ (void) delete:(NSArray*)objects
{
	NSMutableArray *ids = [NSMutableArray new];
	for (AutoModel *object in objects)
	{
		[ids addObject:object.idValue];
	}
	[self deleteIds:ids];
}

+ (void) delete:(NSArray*)objects completeBlock:(dispatch_block_t)completeBlock
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
	{
		NSMutableArray *ids = [NSMutableArray new];
		for (AutoModel *object in objects)
		{
			[ids addObject:object.idValue];
		}
		[self deleteIds:ids];
		if (completeBlock) completeBlock();
	});
}

+ (void) deleteIds:(NSArray*)ids completeBlock:(dispatch_block_t)completeBlock
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
	{
		[self deleteIds:ids];
		if (completeBlock) completeBlock();
	});
}

+ (void) deleteIds:(NSArray*)ids
{
	if (!ids || ids.count == 0)
	{
		return;
	}
	
	[self.tableCache asyncExecuteBlock:^(NSMapTable * _Nonnull table) {
		
		//Check any object that are fetched
		for (NSNumber *id_field in ids)
		{
			AutoModel *object = [table objectForKey:id_field];
			if (object && !object.is_deleted)
			{
				[object willBeDeleted];
				object.is_deleted = YES;
				[table removeObjectForKey:id_field];	//This should be unnecessary? - yes in case someone hangs on to these objects somewhere, then they can be fetched in relations or other places making use of the cache.
			}
		}
	}];
	[self deleteIdsExecute:ids];
}

//syncing needs these two to be separate
+ (void) deleteIdsExecute:(NSArray*)ids
{
	//potential deadlock here? No - I don't think so, we always take the locks in this order and then it should be fine.
	NSString *classString = NSStringFromClass(self);
	NSString *updateQuery = nil;
	
	//Deleting is quite common, at least for one object - so use cache. TODO: This is stupid! We already have a query cache to handle this!
	NSString *deleteQueryKey = nil;
	if (ids.count < 4)
	{
		deleteQueryKey = [NSString stringWithFormat:@"DELETE_QUERY_%@_%i", classString, (int)ids.count];
		updateQuery = [[self.queryCache objectForKey:deleteQueryKey] query];
	}
	if (!updateQuery)
	{
		//Build the query string
		updateQuery = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ IN (%@)", classString, primaryKeyName, [self questionMarks:ids.count]];
		if (deleteQueryKey)
		{
			//don't cache everything.
			[self cacheQuery:updateQuery forKey:deleteQueryKey];
		}
	}
	
	[self inDatabase:^(AFMDatabase *db)
	{
		if (![db executeUpdate:updateQuery withArgumentsInArray:ids])
		{
			NSLog(@"Could not delete objects for %@ error: %@", classString, db.lastError);
		}
	}];
	//Post notifications so others can remove these objects too.
	dispatch_async(dispatch_get_main_queue(), ^(void){
		
		if (classString && ids)
			[[NSNotificationCenter defaultCenter] postNotificationName:AutoModelUpdateNotification object:nil userInfo:@{ classString : @{ @"delete" : ids }}];
	});
}

#pragma mark - storing

- (void) saveWithCompletion:(AutoModelSaveCompletionBlock)completion
{
	[self.class save:@[self] completion:completion];
}

- (NSError*) save
{
	if (_is_deleted) return nil;
	return [self.class save:@[self]];
}

+ (void) saveAllWithChanges:(AutoModelSaveCompletionBlock _Nullable)complete
{
	dispatch_async(tablesWithChangesQueue, ^(void)
	{
		NSError *error = [self saveAllWithChangesInternal];
		if (complete)
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void) { complete(error); });
	});
}

+ (nullable NSError *) saveAllWithChanges
{
	__block NSError *error = nil;
	dispatch_sync(tablesWithChangesQueue, ^(void)
	{
		error = [self saveAllWithChangesInternal];
	});
	return error;
}

+ (nullable NSError *) saveAllWithChangesInternal
{
	__block NSError *error = nil;
	[tablesWithChanges enumerateKeysAndObjectsUsingBlock:^(NSString* classString, NSHashTable *changesCache, BOOL *stop)
	{
		NSArray *allObjects = [changesCache allObjects];
		if (allObjects.count)
		{
			//NSLog(@"%@ had %i objects in its tablesWithChanges to save", classString, (int)allObjects.count);
			[changesCache removeAllObjects];
			Class table = NSClassFromString(classString);
			error = [table save:allObjects];
		}
	}];
	return error;
}

static NSMutableDictionary <NSString*, NSNumber*>* throttleKeys;
+ (void) throttleSaveChanges:(AutoModelSaveCompletionBlock _Nullable)complete
{
	dispatch_async(tablesWithChangesQueue, ^(void){
		
		//the first should go through the rest should wait 5
		NSString *throttleClass = NSStringFromClass(self);
		NSInteger actions = throttleKeys[throttleClass].integerValue;
		if (actions > 2)
			return;
		
		if (!throttleKeys)
			throttleKeys = [[NSMutableDictionary alloc] initWithObjectsAndKeys:@1, throttleClass, nil];
		else
			throttleKeys[throttleClass] = @(actions + 1);
		
		dispatch_block_t saveBlock =
		^{
			NSError *error = [self saveChangesInternal];
			if (complete)
			{
				dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
				{
					complete(error);
				});
			}
		};
		if (actions == 0)
		{
			saveBlock();
		}
		else
		{
			NSUInteger THROTTLE_TIME = 5;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(THROTTLE_TIME * NSEC_PER_SEC)), tablesWithChangesQueue, ^{
				
				[throttleKeys removeObjectForKey:throttleClass];
				saveBlock();
			});
		}
	});
}

+ (void) saveChanges:(AutoModelSaveCompletionBlock _Nullable)complete
{
	dispatch_async(tablesWithChangesQueue, ^(void){
		NSError *error = [self saveChangesInternal];
		if (complete)
		{
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void)
			{
				complete(error);
			});
		}
	});
}

+ (nullable NSError *) saveChanges
{
	__block NSError *error = nil;
	dispatch_sync(tablesWithChangesQueue, ^(void){
		error = [self saveChangesInternal];
	});
	return error;
}

+ (nullable NSError*) saveChangesInternal
{
	NSHashTable *changesCache = [tablesWithChanges objectForKey:NSStringFromClass(self)];
	NSArray *allObjects = [changesCache allObjects];
	if (allObjects.count)
	{
		[changesCache removeAllObjects];
		return [self save:allObjects];
	}
	return nil;
}

+ (void) save:(NSArray*)collection completion:(AutoModelSaveCompletionBlock)completion
{
	[self executeInDatabase:^(AFMDatabase * _Nonnull db) {
		
		NSError *error = [self save:collection];
		if (completion)
		{
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(void){
				completion(error);
			});
		}
	}];
}

//a blocking save
//TODO: we must block the DB-thread while building the queries and doing all that work. Otherwise two items might get saved at the same time - resulting in id-conflicts.
//We can also make a "saveQueue" so all saves get prepared alone and then sent to the DB.
+ (NSError*) save:(NSArray <AutoModel*>*)collection
{
	NSString *classString = NSStringFromClass(self);
	__block NSError* error = nil;
	[self inDatabase:^(AFMDatabase * _Nonnull db) {

		if ([self.class preventObservingProperties] == NO)
		{
			//The problem is noticing changes for these objects. So just stop observing here and remove them from changes, then DON'T trigger observable changes while inserting/updating.
			//if changes comes in before we stop observing, those will be with us when updating
			//if changes comes in after, those will set hasChanges to yes
			//changes that comes in-between will be used if you are using atomic properties, but might trigger hasChange which is ok (nothing gets lost, just one unnecessary update).
			for (AutoModel* object in collection)
			{
				//Remove objects without changes, the other's has been changed again.
				object.hasChanges = NO;
			}
			//async to prevent deadlocking, this does not really matter ... ? since if we set hasChanges inBetween, they will be added again.
			//fuck! I was interrupted and lost the thought. Ok, hopefully I can find it again.
			dispatch_async(tablesWithChangesQueue, ^(void){
				
				NSHashTable *changesCache = tablesWithChanges[classString];
				if (changesCache.count == 0) return;
				for (AutoModel* object in collection)
				{
					//Remove objects without changes, the other objects has been changed in-between.
					if (object.hasChanges == NO)
						[changesCache removeObject:object];
				}
			});
		}
		
		NSMutableArray *createObjects = nil;
		NSMutableArray *createObjectsWithoutId = nil;
		NSMutableArray *updateObjects = nil;
		AutoInsertStatement *insertStatement = [AutoInsertStatement statementForClass:self andClassString:classString];
		NSUInteger noIdCount = insertStatement.columnsWithoutId.count;
		NSUInteger withIdCount = insertStatement.columns.count;
		NSUInteger maxVariableLimit = 500000;

		//We used to save all ids here to check if they existed in db. Now this is done in the createNewInstance method, so it is asumed that all ids are unique.
		for (AutoModel* object in collection)
		{
			if (object.is_deleted)
			{
				//skip deleted objects
			}
			else if (object.isToBeInserted)
			{
				object.isToBeInserted = NO;
				if (object.id)
				{
					if (!createObjects) createObjects = [NSMutableArray new];
					
					//we must split objects into several if > 999.
					if (withIdCount * (createObjects.count + 1) > maxVariableLimit)
					{
						NSError *createError = [insertStatement insertObjects:createObjects objectsWithoutId:nil updateObjects:nil inDatabase:db];
						if (createError) error = createError;
						[createObjects removeAllObjects];
					}
					[createObjects addObject:object];
				}
				else
				{
					if (!createObjectsWithoutId) createObjectsWithoutId = [NSMutableArray new];
					if (noIdCount * (createObjectsWithoutId.count + 1) > maxVariableLimit)
					{
						NSError *createError = [insertStatement insertObjects:nil objectsWithoutId:createObjectsWithoutId updateObjects:nil inDatabase:db];
						if (createError) error = createError;
						[createObjectsWithoutId removeAllObjects];
					}
					[createObjectsWithoutId addObject:object];
				}
			}
			else
			{
				//if isToBeInserted == NO, but we don't have an id - then we can't insert it. It must be treated as a temporary object that shouldn't be saved (this is also a feature).
				if (!object.id)
					continue;
				if (!updateObjects) updateObjects = [NSMutableArray new];
				if (withIdCount * (updateObjects.count + 1) > maxVariableLimit)
				{
					NSError *createError = [insertStatement insertObjects:nil objectsWithoutId:nil updateObjects:updateObjects inDatabase:db];
					if (createError) error = createError;
					[updateObjects removeAllObjects];
				}
				[updateObjects addObject:object];
			}
		}
		
		NSError *createError = [insertStatement insertObjects:createObjects objectsWithoutId:createObjectsWithoutId updateObjects:updateObjects inDatabase:db];
		if (createError) error = createError;
	
	}];
    return error;
}

#pragma mark - helpers

- (NSNumber*) idValue
{
	return @(_id);
}

+ (NSString*) questionMarks:(NSInteger)amount
{
    if (amount == 0)
    {
        NSLog(@"AutoModel::questionMarks Can't create 0 questionmarks");
		return @"''";	//this will make your clause look like this: ... AND column IN ('') - which is always false (unless column can be the empty string), NOT IN is always true.
    }
	NSString *questionMarks = [@"" stringByPaddingToLength:amount * 2 withString:@"?," startingAtIndex:0];
	questionMarks = [questionMarks substringToIndex:questionMarks.length - 1];
	
	//No need to cache the generated questionMarks, cache the queries instead.
	
	return questionMarks;
}

///We want the format to be "INSERT INTO table (column1, column2) VALUES (?,?),(?,?),(?,?)", and then add an array with four values. Here objectCount = 3, columnCount = 2
+ (NSString*) questionMarksForQueriesWithObjects:(NSInteger)objectCount columns:(NSInteger)columnCount
{
	if (objectCount == 0)
	{
		NSLog(@"AutoDB ERROR, asking for 0 objects (%@) questionMarksForQueriesWithObjects:", self);
		return @"()";
	}
	NSString *questionObject = [NSString stringWithFormat:@"(%@),", [self questionMarks:columnCount]];
	NSString *questionMarks = [@"" stringByPaddingToLength:questionObject.length * objectCount withString:questionObject startingAtIndex:0];
	questionMarks = [questionMarks substringToIndex:questionMarks.length - 1];
	
	return questionMarks;
}

- (BOOL) bitField:(NSUInteger)bitField isSet:(NSUInteger)value
{
	return (bitField & value) > 0;
}

- (NSUInteger) setBitField:(NSUInteger)bitField value:(NSUInteger)value on:(BOOL)on
{
	if (on)
	{
		bitField |= value;
	}
	else
	{
		bitField &= (~value);
	}
	return bitField;
}

///Add all our values into an array using only certain columns.
- (void) addAllValues:(NSMutableArray*)values usingColumns:(NSArray*)columns
{
    NSDictionary <NSString *, NSNumber *>*columnSyntax = [AutoDB.sharedInstance columnSyntaxForClass:self.class];
	for (NSString *column in columns)
	{
		id value = [self valueForKey:column];
		if (value)
		{
            if (columnSyntax[column].integerValue == AutoFieldTypeDate)
            {
                [values addObject:@([value timeIntervalSince1970])];
            }
            else
            {
                [values addObject:value];
            }
		}
		else
		{
            //todo: we should look at if the column does not allow null, and handle that
			[values addObject:[NSNull null]];
		}
	}
}

///Create a query from our values using only certain columns, inserting into a parameter array \n
///example: NSString *query = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@", [columns componentsJoinedByString:@","], self.classString, [builder componentsJoinedByString:@" OR "]];
- (NSString*) createQueryUsingColumns:(NSArray*)columns values:(NSMutableArray*)values
{
	NSMutableArray* params = [NSMutableArray new];
    NSDictionary <NSString *, NSNumber *>*columnSyntax = [AutoDB.sharedInstance columnSyntaxForClass:self.class];
	for (NSString *column in columns)
	{
		id value = [self valueForKey:column];
		if (!value)
		{
            //todo: we should look at if the column does not allow null, and handle that
			value = [NSNull null];
		}
		else if (columnSyntax[column].integerValue == AutoFieldTypeDate)
		{
            value = @([value timeIntervalSince1970]);
		}
		[values addObject:value];
		[params addObject:[NSString stringWithFormat:@"%@ = ?", column]];
	}
	return [NSString stringWithFormat:@"(%@)", [params componentsJoinedByString:@" AND "]];
}

+ (NSMutableArray*) groupConcatQuery:(NSString*)query arguments:(nullable NSArray*)arguments
{
	__block NSMutableArray *result = nil;
	[self inDatabase:^(AFMDatabase * _Nonnull db)
    {
        AFMResultSet *resultSet = [db executeQuery:query withArgumentsInArray:arguments];
		if ([resultSet next])
		{
			result = [NSMutableArray new];
			do
			{
				id value = resultSet[0];
				if (value)
				{
					[result addObject:value];
				}
			} while ([resultSet next]);
		}
		[resultSet close];
    }];
	
	return result;
}

+ (NSMutableDictionary*) dictionaryQuery:(NSString*)query key:(nullable NSString*)key arguments:(nullable NSArray*)arguments
{
	__block NSMutableDictionary *result = nil;
	if (!key)
		key = @"id";
	
	[self inDatabase:^(AFMDatabase * _Nonnull db)
	{
		AFMResultSet *resultSet = [db executeQuery:query withArgumentsInArray:arguments];
		if ([resultSet next])
		{
			result = [NSMutableDictionary new];
			do
			{
				NSDictionary *row = resultSet.resultDictionary;
				if (row[key])
				{
					result[row[key]] = row;
				}
			} while ([resultSet next]);
		}
		[resultSet close];
	}];
	
	return result;
}

+ (NSMutableArray*) arrayQuery:(NSString*)query arguments:(nullable NSArray*)arguments
{
	__block NSMutableArray *result = nil;
    [self inDatabase:^(AFMDatabase * _Nonnull db)
    {
        AFMResultSet *resultSet = [db executeQuery:query withArgumentsInArray:arguments];
		if ([resultSet next])
		{
			result = [NSMutableArray new];
			do
			{
				NSDictionary *row = resultSet.resultDictionary;
				if (row)
				{
					[result addObject:row];
				}
			}
			while ([resultSet next]);
		}
		[resultSet close];
    }];
    
    return result;
}

+ (nullable NSDictionary*) rowQuery:(NSString*)query arguments:(nullable NSArray*)arguments
{
	__block NSDictionary *result = nil;
	[self inDatabase:^(AFMDatabase * _Nonnull db)
	{
		AFMResultSet *resultSet = [db executeQuery:query withArgumentsInArray:arguments];
		if ([resultSet hasAnotherRow])
		{
			[resultSet next];
			result = resultSet.resultDictionary;
		}
		[resultSet close];
	}];
	
	return result;
}

+ (id) valueQuery:(NSString*)query arguments:(nullable NSArray*)arguments
{
    __block id value = nil;
    [self inDatabase:^(AFMDatabase * _Nonnull db)
    {
        AFMResultSet *result = [db executeQuery:query withArgumentsInArray:arguments];
        if (result == nil && [db lastErrorCode])
        {
            NSLog(@"DB query: %@", query);
        }
        [result next];
        value = [result objectForColumnIndex:0];
        [result close];
    }];
    return value;
}

+ (NSArray*) deleteMissingIds:(nonnull NSArray*)ids
{
	__block NSArray *missingIds = nil;
	NSString *idString = [ids componentsJoinedByString:@","];
	NSString *className = NSStringFromClass(self);
	
	[self inDatabase:^(AFMDatabase *db)
	 {
		 NSArray *deleteIds = [self groupConcatQuery:[NSString stringWithFormat:@"SELECT id FROM %@ WHERE id NOT IN (%@)", className, idString] arguments:nil];
		 if (deleteIds.count)
		 {
			 [self deleteIds:deleteIds];
			 //NSLog(@"deleteMissingIds::will delete %i rows", (int)deleteIds.count);
		 }
		 
		 //Now all unecessary stuff is deleted, fetch all that should remain and see if there are any missing id.
		 NSArray *allIds = [self groupConcatQuery:[NSString stringWithFormat:@"SELECT id FROM %@ WHERE id IN (%@)", className, idString] arguments:nil];
		 NSMutableSet *missingIdSet = [NSMutableSet setWithArray:ids];
		 [missingIdSet minusSet:[NSSet setWithArray:allIds]];
		 if (missingIdSet.count)
		 {
			 missingIds = [missingIdSet allObjects];
		 }
	 }];
	
	return missingIds;
}

#pragma mark - handle caching of querys

+ (NSString*) cachedQueryForSignature:(NSString*)signature objects:(NSUInteger)count createBlock:(AutoModelGenerateQuery)createBlock
{
    NSString *cacheKey = [AutoModelCacheHandler.sharedInstance keyForFunction:signature objects:count class:self];
    FMStatement *cachedStatement = [self.queryCache objectForKey:cacheKey];
    if (cachedStatement)
    {
        return cachedStatement.query;
    }
    else
    {
        NSString *query = createBlock();
        [self cacheQuery:query forKey:cacheKey];
        return query;
    }
}

/**
 Private blocking method to cache queries and retrieve info from them. We must do the work when getting the parameter count - so we also cache the statements (and the query) for later use.
 If we get memory problems, the statements will get released
 */
+ (FMStatement*) cacheQuery:(NSString*)query forKey:(NSString*)queryKey
{
	//NSCache is thread safe - but should we use it?
	FMStatement *queryInfo = [self.queryCache objectForKey:queryKey];
	if (queryInfo)
	{
		return queryInfo;
	}
	
	//create and cache the query in the db - we must do it like this so we don't create two items at the same time.
	[self inDatabase:^(AFMDatabase *db){
		
		FMStatement *statement = [db cacheStatementForQuery:query];
		if (!statement)
		{
			NSLog(@"SQL Error! Could not create statement. Will crash now, query was:\n%@", query);
		}
		else
		{
			//NSCache is thread safe
			[self.queryCache setObject:statement forKey:queryKey];
		}
	}];
	
	return [self.queryCache objectForKey:queryKey];
}

///Private blocking method to cache queries and retrieve info from them - don't cache rarely used queries. Here we don't force the use of WHERE, only the column-names are implied
+ (FMStatement*) cachedQuery:(NSString*)whereQuery
{
	if (!whereQuery)
	{
		static NSString *emptyQuery = @"";
		whereQuery = emptyQuery;
	}
	FMStatement *statement = [self.queryCache objectForKey:whereQuery];
	if (statement) return statement;
	
	NSString *selectQuery = [[AutoDB.sharedInstance selectQuery:self] stringByAppendingString:whereQuery];
	return [self cacheQuery:selectQuery forKey:whereQuery];
}

@end

//TODO: Please give this class its own file!

@implementation AutoInsertStatement
{
	NSMutableDictionary *queries;   //Should we change the name to make it more appearant?
    FMStatement *updateQuery;
}

static NSMutableDictionary *statements;
static dispatch_queue_t statementQueue;

+ (instancetype) statementForClass:(Class)class andClassString:(NSString*)classString
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^(void)
	{
		statementQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
		statements = [NSMutableDictionary new];
	});
	
	//data race when accessing dicts to see if they are empty and only then perform locking? It means that the statements can be created twice, but not in this case since we also check inside the lock.
	if (!statements[classString])	//Ignore "race on a library obect" warning
	{
		dispatch_sync(statementQueue, ^(void)
		{
			AutoInsertStatement *statement = statements[classString];
			if (!statement)
			{
				NSDictionary *syntax = [AutoDB.sharedInstance tableSyntaxForClass:classString];
                NSArray *columns = [syntax[AUTO_COLUMN_KEY] allKeys];
                
                NSMutableArray *createColumns = columns.mutableCopy;
                [createColumns removeObject:primaryKeyName];
				
				statement = [AutoInsertStatement new];
                statement.columns = columns;
                statement.columnsWithoutId = createColumns;
				statement.classString = classString;
                statement.modelClass = class;
				statement.tableCache = [class tableCache];
                NSCache *queryCache = [class queryCache];
                if (!queryCache.delegate) queryCache.delegate = statement;
				
				statements[classString] = statement;
			}
		});
	}
	
	return statements[classString];
}

- (NSString *) updateQueryWithObjectCount:(NSUInteger)objectCount inDb:(AFMDatabase *)db
{
	BOOL cache = objectCount < 4;
	if (cache && queries)
	{
		//data race here?
		FMStatement *insertQuery = queries[@(StatementTypeUpdate)][@(objectCount)];
		if (insertQuery) return insertQuery.query;
	}
	
	
	NSString *columnString = [self.columns componentsJoinedByString:@","];
	NSString *questionMarks = [AutoModel questionMarksForQueriesWithObjects:objectCount columns:self.columns.count];
	NSString *query = [NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ (%@) VALUES %@", self.classString, columnString, questionMarks];
	
	/*
	if (cache)
	{
		FMStatement *statment = [db cacheStatementForQuery:insertQuery];
		dispatch_sync(self.cacheQueue, ^
					  {
						  if (!queries) queries = [NSMutableDictionary new];
						  if (!queries[@(useId)]) queries[@(useId)] = [NSMutableDictionary new];
						  queries[@(useId)][@(objectCount)] = statment;
					  });
	}
	*/
	return query;
}

- (NSString *) insertQueryWithObjectCount:(NSUInteger)objectCount usingId:(BOOL)useId inDb:(AFMDatabase *)db
{
    BOOL cache = objectCount < 4;
	if (cache && queries)
	{
		//data race here?
		FMStatement *insertQuery = queries[@(useId)][@(objectCount)];
		if (insertQuery) return insertQuery.query;
	}
    
    NSArray *useColumns = useId ? self.columns : self.columnsWithoutId;
    NSString *columnString = [useColumns componentsJoinedByString:@","];
	NSString *createQuestionMarks = [AutoModel questionMarksForQueriesWithObjects:objectCount columns:useColumns.count];
	NSString *insertQuery = [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES %@", self.classString, columnString, createQuestionMarks];
	
	if (cache)
	{
        FMStatement *statment = [db cacheStatementForQuery:insertQuery];
		dispatch_sync(statementQueue, ^
		{
			if (!queries) queries = [NSMutableDictionary new];
            if (!queries[@(useId)]) queries[@(useId)] = [NSMutableDictionary new];
			queries[@(useId)][@(objectCount)] = statment;
		});
	}
	
	return insertQuery;
}

//We cannot depend upon useAutoIncrement! - first create all arrays
- (NSMutableArray*) createParametersForObjects:(NSArray*)objectsToCreate hasId:(BOOL)hasId
{
    NSMutableArray *createParameters = [NSMutableArray new];
    for (AutoModel *object in objectsToCreate)
    {
        [object addAllValues:createParameters usingColumns:(hasId ? self.columns : self.columnsWithoutId)];
    }
    return createParameters;
}

//Then take the lock and insert!
- (NSError*) insertObjects:(NSMutableArray*)objects objectsWithoutId:(NSMutableArray*)objectsWithoutId updateObjects:(NSArray*)updateObjects inDatabase:(AFMDatabase *)db
{
    //generate parameters outside of the lock
    NSArray* objectParameters = nil, *parametersWithoutId = nil;
    if (objects) objectParameters = [self createParametersForObjects:objects hasId:YES];
    if (objectsWithoutId) parametersWithoutId = [self createParametersForObjects:objectsWithoutId hasId:NO];
	
	//TODO: also do updates.
    __block NSError *error = nil;
    //[self.modelClass inDatabase:^(FMDatabase *db)
    NSError *error_inside = nil;
    if (objects.count)
	{
		error_inside = [self insertObjects:objects withParameters:objectParameters hasId:YES inDb:db];
		if (error_inside) error = error_inside;
	}
	if (objectsWithoutId)
	{
		error_inside = [self insertObjects:objectsWithoutId withParameters:parametersWithoutId hasId:NO inDb:db];
		if (error_inside) error = error_inside;
	}
	if (updateObjects)
	{
		error_inside = [self updateObjects:updateObjects inDb:db];
		if (error_inside) error = error_inside;
	}
    
    return error;
}

- (NSError*) updateObjects:(NSArray*)updateObjects inDb:(AFMDatabase *)db
{
	/*This is really slow! Can we do something about it?
	 Yes! like this:
	 INSERT OR REPLACE INTO Employee (id, role, name)
	 VALUES (  1,
	 'code monkey',
	 'bla bla'
	 );
	 */
	NSMutableArray *parameters = [NSMutableArray new];
	for (AutoModel *object in updateObjects)
	{
		[object addAllValues:parameters usingColumns:self.columns];
	}
	
	NSError* error = nil;
	NSString *query = [self updateQueryWithObjectCount:updateObjects.count inDb:db];
	BOOL success = [db executeUpdate:query withArgumentsInArray:parameters];
	if (!success)
	{
		error = db.lastError;
	}
    return error;
}

- (NSError*) insertObjects:(NSMutableArray *)objectsToCreate withParameters:(NSArray*)createParameters hasId:(BOOL)hasId inDb:(AFMDatabase *)db
{
    NSError* error = nil;
    
    int idErrorCount = 0;
    int errorCode = 19;
    while (errorCode == 19)
    {
        //IS THIS A GOOD IDEA? - yes since it never will be an error.
        NSString *insertQuery = [self insertQueryWithObjectCount:objectsToCreate.count usingId:hasId inDb:db];
        BOOL success = [db executeUpdate:insertQuery withArgumentsInArray:createParameters];
        if (!success)
        {
            idErrorCount++;
            error = db.lastError;
            errorCode = [db lastErrorCode];
			
			NSArray<NSArray<NSString *> *> *unique = [self.modelClass uniqueConstraints];
			if (errorCode == 19 && unique)
			{
				//with unique constraints then we will get into trouble here.
				BOOL hasRemoved = NO;
				for (NSArray *columns in unique)
				{
					//build a query that selects the unique values
					NSMutableArray *parameters = [NSMutableArray new];
					NSMutableArray *builder = [NSMutableArray new];
					
					for (AutoModel *object in objectsToCreate)
					{
						NSString *build = [object createQueryUsingColumns:columns values:parameters];
						[builder addObject:build];
					}
					NSString *query = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@", [columns componentsJoinedByString:@","], self.classString, [builder componentsJoinedByString:@" OR "]];
					AFMResultSet *result = [db executeQuery:query withArgumentsInArray:parameters];
					while ([result next])
					{
						for (AutoModel *object in objectsToCreate.copy)
						{
							BOOL found = YES;
							for (NSString *column in columns)
							{
								NSLog(@"comparing %@", result[column]);
								if ([[object valueForKey:column] isEqual:result[column]] == NO)
								{
									found = NO;
									break;
								}
							}
							if (found)
							{
								NSLog(@"found myself a duplicate - we cannot save this!");
								[object willBeDeleted];
								object.is_deleted = YES;
								[objectsToCreate removeObject:object];
								hasRemoved = YES;
							}
						}
					}
					[result close];
				}
				if (hasRemoved)
				{
					if (objectsToCreate.count == 0)
					{
						NSLog(@"All objects were removed due to unique constraints %@", self.classString);
						return nil;
					}
					if (hasId)
						return [self insertObjects:objectsToCreate objectsWithoutId:nil updateObjects:nil inDatabase:db];
					else
						return [self insertObjects:nil objectsWithoutId:objectsToCreate updateObjects:nil inDatabase:db];
				}
			}
			
            
            //if we are trying to force an id that already exist, we generate errors for autoIncrement.
            //You are trying to bypass autoIncrement but failing
            //OR: you try to insert NULL for when the column has NOT NULL - (happens when changing from e.g. INT to DATE without telling the auto updater) 
            if (errorCode == 19 && hasId && ![self.modelClass useAutoIncrement])   //we can't generate ids if there is none.
            {
				if (idErrorCount < 2)
					NSLog(@"AutoModel generated colliding ids... this should not be possible %@\n\nTrying again...", [objectsToCreate[0] idValue]);
                //Nothing inserted since one id is not unique - which one? (this can never happen - really should never unless you have set your own ids. Which you will do...)
                [self generateConflictFreeIds:objectsToCreate inDb:db];
                
                //we need to re-generate parameters since they contain ids.
                createParameters = [self createParametersForObjects:objectsToCreate hasId:hasId];
				//we might get stuck this this while-loop, if this does not fix the issue.
            }
            else
            {
                NSLog(@"Could not INSERT new data for %@ - have you changed types without telling the migrater?", self.modelClass);
                errorCode = 0;
            }
        }
        else //if (success)
        {
            error = nil;
            errorCode = 0;
            if (objectsToCreate)
            {
                u_int64_t insertId = 0;
                if (hasId == NO && [self.modelClass useAutoIncrement])
                {
                    //now we must figure out what id they have and insert into cache
                    insertId = (db.lastInsertRowId - objectsToCreate.count) + 1;
                }
				
				//Make sure they get their ids
				if (insertId)
				{
					for (AutoModel* object in objectsToCreate)
					{
						object.id = insertId;
						insertId++;	//increment since we know the first id, and the total amount.
					}
				}
				
				//insert all the objects into the cache at once.
				[self.tableCache asyncExecuteBlock:^(NSMapTable * _Nonnull table) {
					
					for (AutoModel* object in objectsToCreate)
					{
						[table setObject:object forKey:object.idValue];
					}
				}];
            }
        }
        if (idErrorCount > 2)
        {
            NSLog(@"Unique-constraints error in %@, unique ids can't be generated in the local db. Please investigate", self.classString);
			//NOTE: its unique-constraints. If you have two objects with the same title, and title is unique - you get this error.
			//TODO: auto-detect what properties are to blame and discard similar objects.
			
            break;
        }
    }
    
    return error;
}

- (void) generateConflictFreeIds:(NSArray*)objectsToCreate inDb:(AFMDatabase *)db
{
    NSMutableDictionary *uniqueIds = [NSMutableDictionary new];
    for (AutoModel *object in objectsToCreate)
    {
        if (uniqueIds[object.idValue])
        {
            //the problem is that we are trying to insert objects with the same id...
            //make sure the wrong id isn't in the cache, these objects shouldn't be in the cache - but just to make sure...
            [self.tableCache removeObjectForKey:object];
            [object generateNewId];
        }
        else
        {
            [uniqueIds setObject:object forKey:object.idValue];
        }
    }
    
    //TODO: cache this, its not just the string
    NSString *uniqueQuery = [NSString stringWithFormat:@"SELECT id FROM %@ WHERE id IN (%@)", self.classString, [self.modelClass questionMarks:uniqueIds.count]];
    AFMResultSet *result = [db executeQuery:uniqueQuery withArgumentsInArray:uniqueIds.allKeys];
    while ([result next])
    {
        //Generate new ids
        AutoModel *object = [uniqueIds objectForKey:result[0]];
        if (object)
        {
            //make sure the wrong id isn't in the cache, these objects shouldn't be in the cache - but just to make sure...
            [self.tableCache removeObjectForKey:object];
            [object generateNewId];
        }
    }
	[result close];
}

#pragma mark - NSCacheDelegate

- (void)cache:(NSCache *)cache willEvictObject:(id)obj
{
    if ([obj isKindOfClass:[FMStatement class]])
    {
        FMStatement *statement = (FMStatement *)obj;
		[[self.modelClass databaseQueue] asyncExecuteDatabase:^(AFMDatabase *db){
			[db removeCachedStatementForQuery:statement.query];
		}];
    }
    
	//Think: check and evict cached stuff at intervals - or when removed from nscache. No, just when removed for now. If NSCache works as I think it does, we won't need to evict at intervalls
}

@end


@implementation AutoModelCacheHandler
{
    NSMapTable *keyCache;   //Should we change the name to make it more appearant?
    dispatch_queue_t cacheHandlerQueue;
}

static AutoModelCacheHandler *sharedInstance;
static NSMutableDictionary *statements;

+ (instancetype) sharedInstance
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^(void)
	{
		sharedInstance = [self new];
	});
	return sharedInstance;
}

- (instancetype) init
{
    self = [super init];
    
    cacheHandlerQueue = dispatch_queue_create(NULL, NULL);
    keyCache = [NSMapTable strongToStrongObjectsMapTable];
    
    return self;
}

- (NSString*) keyForFunction:(NSString*)function objects:(unsigned long)amount class:(Class)classObject
{
    __block NSString *key;
    NSNumber *amountObject = @(amount);
    dispatch_sync(cacheHandlerQueue, ^(void)
    {
        //inside the classes we have functions, which have different keys depending on amounts - everything else should be the same?
        NSMapTable *functions = [keyCache objectForKey:classObject];
        if (!functions)
        {
            functions = [NSMapTable strongToStrongObjectsMapTable];
            [keyCache setObject:functions forKey:function];
        }
        NSMapTable *amounts = [functions objectForKey:amountObject];
        if (!amounts)
        {
            amounts = [NSMapTable strongToStrongObjectsMapTable];
            [functions setObject:amounts forKey:amountObject];
        }
        key = [amounts objectForKey:amountObject];
        if (!key)
        {
			NSString *className = NSStringFromClass(classObject);
            key = [NSString stringWithFormat:@"%@_%@_%@", className, function, amountObject];
            [amounts setObject:key forKey:amountObject];
        }
    });
    
    return key;
}

@end

#pragma mark - AutoResult, handling object fetches

@implementation AutoResult

- (instancetype)init
{
    self = [super init];
    _mutableRows = [NSMutableArray new];
    return self;
}

- (BOOL) hasCreatedDict
{
	return _mutableDictionary != nil;
}

- (NSMutableDictionary *)mutableDictionary
{
	if (!_mutableDictionary)
	{
		_mutableDictionary = [NSMutableDictionary new];
		for (AutoModel* object in _mutableRows)
		{
			_mutableDictionary[object.idValue] = object;
		}
	}
	return _mutableDictionary;
}

-(NSArray *)rows
{
	return _mutableRows;
}
- (NSDictionary *)dictionary
{
	return self.mutableDictionary;
}

//to support keyd subscripting
- (void) setObject:(AutoModel*)object forKey:(nonnull id<NSCopying>)aKey
{
    [_mutableRows addObject:object];
    _mutableDictionary[aKey] = object;
}

- (id)copyWithZone:(NSZone *)zone
{
    AutoResult *copy = [AutoResult new];
    [copy.mutableRows addObjectsFromArray:_mutableRows];
    [copy.mutableDictionary addEntriesFromDictionary:_mutableDictionary];
    return copy;
}

@end
