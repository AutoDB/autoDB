//
//  AutoModelRelation.m
//  Simulator
//
//  Created by Olof Thorén on 2014-04-08.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.
//

#import "AutoDB.h"
#import "AutoModelRelation.h"
#import "AFMDatabaseQueue.h"
#import "AFMDatabase.h"

@import ObjectiveC;

@implementation AutoModelRelation

/**
 NOTE:
 TODO:
 
 We need to redo all of this since we now are thinking from a different model. The databaseQueue used to be a global lock for both the DB and the cache, but now we are separating the cache into a queue of its own.
 
 dispatch_async([self.class cacheQueue], ^(void)
 {
 
 Also note:
 
 */

+ (void) fetchRelations:(NSArray*)objects_in queue:(AFMDatabaseQueue *)databaseQueue
{
    //first setup the relation object by taking all un-fetched objects, loop over by class. Everything will be released when done.
    NSMutableDictionary *classRelations = [NSMutableDictionary dictionary];
    for (AutoModel *object in objects_in)
	{
		if (![object hasFetchedRelations])
        {
            NSString *classString = NSStringFromClass(object.class);
            AutoModelRelation *relation = classRelations[classString];
            if (!relation)
            {
                relation = [AutoModelRelation new];
                classRelations[classString] = relation;
                relation.mainClass = object.class;
            }
            relation.mainObjects[object.idValue] = object; //Don't store objects in different dictionaries, we need to check this at every step anyway.
            object.hasFetchedRelations = YES;
        }
	}
	
	for (AutoModelRelation *relation in classRelations.allValues)
	{
		[relation setupContainers];
		//now we need to find all children that is linking to this parent. Since the children has parent_id we must loop through all children.
		//because of that we must always fetch from db - and thus cache-looping becomes unnecessary.
		//[relation fetchChildrenFromCache];
		
		//we need to do one relation at a time, so if they are fetched from db and reused in other relations, will get retreived from cache.
		//they never will - one parent has many children, those children never has other parents!
		[relation fetchChildrenFromDb];
		[relation fetchManyFromDb];
		[relation fetchStrongFromCache];
		[relation fetchStrongFromDb];
		[relation.mainObjects removeAllObjects];
	}
	//here are our classrelations released! (should?)
	[classRelations removeAllObjects];
}

- (void) fetchStrongFromDb
{
    NSDictionary *relations = self.relationDictionary;
    NSString *thisClassString = NSStringFromClass(self.mainClass);
    
    //Find strong-weak relations, one class at a time
    for (NSString *strongClassString in [relations[AUTO_RELATIONS_STRONG_ID_KEY] allKeys])
    {
        NSString *strongRelationKey = relations[AUTO_RELATIONS_STRONG_ID_KEY][strongClassString];
        NSString *strongRelationObjectKey = relations[AUTO_RELATIONS_STRONG_OBJECT_KEY][strongClassString];
        
        //coalesce all ids
        NSMutableArray *strongRelationIds = [NSMutableArray array];
        for (AutoModel *hasStrongRelation in self.mainObjects.allValues)
        {
            if ([hasStrongRelation valueForKey:strongRelationObjectKey])
            {
                //don't fetch/insert objects that already exists. (it will lead to data corruption)
                continue;
            }
            NSNumber* strongRelationId = [hasStrongRelation valueForKey:strongRelationKey];
            if (strongRelationId.integerValue)
            {
                [strongRelationIds addObject:strongRelationId];
            }
        }
        
        if (strongRelationIds.count == 0)
        {
            //no relationship objects here.
            continue;
        }
        
        //fetch the data and create objects from them
        Class strongClass = NSClassFromString(strongClassString);
        NSDictionary *fetchedObjects = [strongClass fetchIds:strongRelationIds].dictionary;
        
        //when setting the strong relation, check if the want a corresponding weak relation back to us
        NSDictionary *weakRelations = [strongClass relations];
        id weakObjectKey = nil;
        if (weakRelations[AUTO_RELATIONS_WEAK_OBJECT_KEY])
        {
            weakObjectKey = weakRelations[AUTO_RELATIONS_WEAK_OBJECT_KEY][thisClassString];
        }
        
        //now set these objects to where they belong
        for (AutoModel *hasStrongRelation in self.mainObjects.allValues)
        {
            if ([hasStrongRelation valueForKey:strongRelationObjectKey])
            {
                //don't fetch/insert objects that already exists. (it will lead to data corruption)
                continue;
            }
            id strongRelation = [hasStrongRelation valueForKey:strongRelationKey];
            if (strongRelation)
            {
                AutoModel *strongObject = fetchedObjects[strongRelation];
                if (strongObject)
                {
                    [hasStrongRelation setValue:strongObject forKey:strongRelationObjectKey];
                    if (weakObjectKey)
                    {
                        //it had a weak reference back to us. Set it.
                        [strongObject setValue:hasStrongRelation forKey:weakObjectKey];
                    }
                }
                else
                {
                    NSLog(@"We are missing object for relation (%@), %@ = %@", strongClassString, strongRelationKey, strongRelation);
                }
            }
        }
    }
}

- (void) fetchChildrenFromDb
{
    NSDictionary *relations = self.relationDictionary;
    NSString *parentClassString = NSStringFromClass(self.mainClass);
    
    //find parent-children relations
    for (NSString *childClassString in [relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY] allKeys])
    {
        Class childClass = NSClassFromString(childClassString);
        NSDictionary *childRelations = [childClass relations];
        NSString *keyName = childRelations[AUTO_RELATIONS_PARENT_ID_KEY][parentClassString];
        if (!keyName)
        {
            NSLog(@"AutoDB:Could not fetch relation of %@ (child) to %@ (parent) due to missing key (likely you misspelled the AUTO_RELATIONS_PARENT_ID_KEY key).", childClass, parentClassString);
            continue;
        }
		
		//create a query to fetch all children refering to our parent.
		NSString *questionMarks = [AutoModel questionMarks:self.mainObjects.count];
		NSString *whereQuery = [NSString stringWithFormat:@"WHERE %@ IN (%@)", keyName, questionMarks];
		NSArray *resultArray = [childClass fetchQuery:whereQuery arguments:self.mainObjects.allKeys].rows;
		
		for (AutoModel *child in resultArray)
		{
			//we must also set the child to the parent (otherwise it will be dealloced).
			NSDictionary *childRelations = [child.class relations];
			NSString *parentIdProperty = childRelations[AUTO_RELATIONS_PARENT_ID_KEY][parentClassString];
			NSNumber* parentId = [child valueForKey:parentIdProperty];
			
			AutoModel *parent = self.mainObjects[parentId];
			if (parent)
			{
				//set the parent at the child
				NSString *objectKeyName = childRelations[AUTO_RELATIONS_PARENT_OBJECT_KEY][parentClassString];
				if (objectKeyName)
				{
					//We should check that this is a weak property OR that the container does not exist.
					[child setValue:parent forKey:objectKeyName];
				}
				
				//set the child at the parent
				NSString *arrayPropertyKeyName = relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY][childClassString];
				id container = [parent valueForKey:arrayPropertyKeyName];
				[container addObject:child];
			}
		}
    }
}

- (void) fetchManyFromDb
{
	NSDictionary *relations = self.relationDictionary;
	NSDictionary *manyContainers = relations[AUTO_RELATIONS_MANY_CONTAINER_KEY];
	
	//find parent-children relations
	for (NSString *childClassString in manyContainers)
	{
		Class childClass = NSClassFromString(childClassString);
		NSString *containerKey = manyContainers[childClassString];
		NSString *manyIdKey = relations[AUTO_RELATIONS_MANY_ID_KEY][childClassString];
		
		for (AutoModel *model in self.mainObjects.allValues)
		{
			NSString *idString = [model valueForKey:manyIdKey];
			if (!idString)
				continue;
			NSArray *rows = [childClass fetchIds:[idString componentsSeparatedByString:@","]].rows;
			NSMutableSet *container = [model valueForKey:containerKey];
			if (container == nil)
			{
				[model setValue:rows forKey:containerKey];	//this was a mutable array, those are not created.
			}
			else
			{
				if ([container respondsToSelector:@selector(addObjectsFromArray:)])
				{
					[container addObjectsFromArray:rows];
				}
				else
				{
					for (AutoModel *child in rows)
					{
						[container addObject:child];
					}
				}
			}
		}
	}
}

- (void) fetchStrongFromCache
{
    NSDictionary *relations = self.relationDictionary;
    
    //check the cache for weak-strong relations
    for (NSString *strongClassString in [relations[AUTO_RELATIONS_STRONG_ID_KEY] allKeys])
    {
		Class strongClass = NSClassFromString(strongClassString);
		AutoConcurrentMapTable *tableCache = [strongClass tableCache];
        for (AutoModel *hasStrongRelation in self.mainObjects.allValues)
        {
            //check if there are strong relations by finding the strong_id_key.
            id strongIdKey = relations[AUTO_RELATIONS_STRONG_ID_KEY][strongClassString];
            id strongId = [hasStrongRelation valueForKey:strongIdKey];
            id object = [tableCache objectForKey:strongId];
            if (strongId && object)
            {
                //set the object to the relation-property.
                id strongObjectKey = relations[AUTO_RELATIONS_STRONG_OBJECT_KEY][strongClassString];
                [hasStrongRelation setValue:object forKey:strongObjectKey];
                
                //check if the object has a coresponding weak-relationship
                NSDictionary *reverseRelations = [strongClass relations];
                id weakPropertyName = reverseRelations[AUTO_RELATIONS_WEAK_OBJECT_KEY][NSStringFromClass(hasStrongRelation.class)];
                if (weakPropertyName)
                {
                    [object setValue:hasStrongRelation forKey:weakPropertyName];
                }
            }
        }
    }
}

- (void) fetchChildrenFromCache
{
    NSDictionary *relations = self.relationDictionary;
    NSString *parentClassString = NSStringFromClass(self.mainClass);
    
    //check the cache for parent-children relations
    for (NSString *childClassString in [relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY] allKeys])
    {
		Class childClass = NSClassFromString(childClassString);
		//now we need to find all children that is linking to this parent. Since the children has parent_id we must loop through all children.
		AutoConcurrentMapTable *tableCache = [childClass tableCache];
        for (NSNumber* child_id in tableCache.allKeys)
        {
            AutoModel *child = [tableCache objectForKey:child_id];
            NSDictionary *childRelations = [child.class relations];
            NSString *parentIdProperty = childRelations[AUTO_RELATIONS_PARENT_ID_KEY][parentClassString];
            if (parentIdProperty)
            {
                NSNumber* parentId = [child valueForKey:parentIdProperty];
                if (parentId)
                {
                    AutoModel *parent = self.mainObjects[parentId];
					if (parent)
					{
						//set the parent at the child
						NSString *objectKeyName = childRelations[AUTO_RELATIONS_PARENT_OBJECT_KEY][parentClassString];
						if (objectKeyName) [child setValue:parent forKey:objectKeyName];
						
						//set the child at the parent
						NSString *arrayPropertyKeyName = relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY][childClassString];
						id container = [parent valueForKey:arrayPropertyKeyName];
						if ([container respondsToSelector:@selector(addObject:)])
						{
							[container addObject:child];
						}
						else
						{
							NSLog(@"fetchRelations::Unknown container for relation");
						}
					}
                }
            }
        }
    }
}

- (void) setupContainers
{
    NSDictionary *relations = self.relationDictionary;
	NSDictionary *childContainers = relations[AUTO_RELATIONS_CHILD_CONTAINER_KEY];
	NSDictionary *manyContainers = relations[AUTO_RELATIONS_MANY_CONTAINER_KEY];
	
    //setup the parent for storing the child - all child relations for each parent
    for (NSString *childClassString in childContainers)
    {
		//only when we have the child container key, will our objects be parents - so we know all our mainObjects are parents.
        for (AutoModel *parent in self.mainObjects.allValues)
        {
            NSString *arrayPropertyKeyName = childContainers[childClassString];
			[self setupContainerForParent:parent propertyKey:arrayPropertyKeyName ignoreArray:NO];
        }
    }
	
	for (NSString *childClassString in manyContainers)
	{
		//only when we have the child container key, will our objects be parents - so we know all our mainObjects are parents.
		for (AutoModel *parent in self.mainObjects.allValues)
		{
			NSString *arrayPropertyKeyName = manyContainers[childClassString];
			[self setupContainerForParent:parent propertyKey:arrayPropertyKeyName ignoreArray:YES];
		}
	}
}

- (void) setupContainerForParent:(AutoModel *)parent propertyKey:(NSString*)arrayPropertyKeyName ignoreArray:(BOOL)ignoreArray
{
	NSMutableArray* container = [parent valueForKey:arrayPropertyKeyName];
	if (!container)    //create the container (array or set)
	{
		objc_property_t property = class_getProperty(self.mainClass, [arrayPropertyKeyName UTF8String]);
		
		char *typeEncoding = property_copyAttributeValue(property, "T");    //T means, type of property
		
		if (typeEncoding[0] == '@' && strlen(typeEncoding) >= 3)
		{
			char *className = strndup(typeEncoding + 2, strlen(typeEncoding) - 3);
			NSString *name = @(className);
			NSRange range = [name rangeOfString:@"<"];
			if (range.location != NSNotFound)
			{
				name = [name substringToIndex:range.location];
			}
			if (ignoreArray && [name isEqualToString:@"NSMutableArray"])
			{
				//when fetching an array, we use that instead of building it like this.
				free(typeEncoding);
				free(className);
				return;
			}
			Class valueClass = NSClassFromString(name);
			if (!valueClass)
			{
				NSLog(@"could not get class (%@) from property. Will likely crash and burn now.", name);
			}
			container = [valueClass new];
			[parent setValue:container forKey:arrayPropertyKeyName];
			free(typeEncoding);
			free(className);
		}
	}
	else if (container.count > 0)
	{
		//since we are fetching relations - nothing should be here. Let's remove so we don't double add.
		[container removeAllObjects];
	}
	if ([container respondsToSelector:@selector(addObject:)] == NO)
	{
		NSLog(@"ERROR! This container cannot be used to add children! Will crash");
	}
}

#pragma mark - property handlers

- (NSDictionary*) relationDictionary
{
    return [self.mainClass relations];
}

- (NSMutableDictionary*) mainObjects
{
    if (!_mainObjects)
    {
        _mainObjects = [NSMutableDictionary new];
    }
    return _mainObjects;
}

- (NSMutableArray*) relatedObjects
{
    if (!_relatedObjects)
    {
        _relatedObjects = [NSMutableArray new];
    }
    return _relatedObjects;
}

@end

#pragma mark - Storage implementations

@implementation AutoDBArray
{
	NSMutableArray *storage;
}
@synthesize hasChanges, owner;

- (void)setHasChanges:(BOOL)hasChanges_
{
	if (hasChanges_ && owner.hasChanges == NO)
		owner.hasChanges = hasChanges_;
	hasChanges = hasChanges_;
}

- (instancetype)init
{
	self = [super init];
	storage = [NSMutableArray new];
	return self;
}

- (instancetype)initWithCapacity:(NSUInteger)numItems
{
	self = [super init];
	storage = [[NSMutableArray alloc] initWithCapacity:numItems];
	return self;
}

- (instancetype)initWithObjects:(id  _Nonnull const [])objects count:(NSUInteger)cnt
{
	self = [super initWithObjects:objects count:cnt];
	storage = [[NSMutableArray alloc] initWithObjects:objects count:cnt];
	return self;
}

- (NSUInteger)count
{
	return [storage count];
}

- (id)objectAtIndex:(NSUInteger)index
{
	return [storage objectAtIndex:index];
}

- (void)insertObject:(id)anObject atIndex:(NSUInteger)index
{
	hasChanges = YES;
	[storage insertObject:anObject atIndex:index];
}

- (void)removeObjectAtIndex:(NSUInteger)index
{
	hasChanges = YES;
	[storage removeObjectAtIndex:index];
}

- (void)addObject:(id)anObject
{
	hasChanges = YES;
	[storage addObject:anObject];
}

- (void)removeLastObject
{
	hasChanges = YES;
	[storage removeLastObject];
}

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject
{
	hasChanges = YES;
	[storage replaceObjectAtIndex:index withObject:anObject];
}
@end

@implementation AutoDBSet
{
	NSMutableSet *storage;
}
@synthesize hasChanges, owner;

- (void)setHasChanges:(BOOL)hasChanges_
{
	if (hasChanges_ && owner.hasChanges == NO)
		owner.hasChanges = hasChanges_;
	hasChanges = hasChanges_;
}

- (instancetype)init
{
	self = [super init];
	storage = [NSMutableSet new];
	return self;
}

- (instancetype)initWithCapacity:(NSUInteger)numItems
{
	self = [super init];
	storage = [[NSMutableSet alloc] initWithCapacity:numItems];
	return self;
}

- (instancetype)initWithObjects:(id  _Nonnull const [])objects count:(NSUInteger)cnt
{
	self = [super initWithObjects:objects count:cnt];
	storage = [[NSMutableSet alloc] initWithObjects:objects count:cnt];
	return self;
}

- (void)addObject:(id)object
{
	hasChanges = YES;
	[storage addObject:object];
}

- (void)removeObject:(id)object
{
	hasChanges = YES;
	[storage removeObject:object];
}

- (NSUInteger)count
{
	return storage.count;
}

- (id)member:(id)object
{
	return [storage member:object];
}

- (NSEnumerator *)objectEnumerator
{
	return [storage objectEnumerator];
}

@end

@implementation AutoDBOrderedSet
{
	NSMutableOrderedSet *storage;
}
@synthesize hasChanges, owner;

- (void)setHasChanges:(BOOL)hasChanges_
{
	if (hasChanges_ && owner.hasChanges == NO)
		owner.hasChanges = hasChanges_;
	hasChanges = hasChanges_;
}

- (instancetype)init
{
	self = [super init];
	storage = [NSMutableOrderedSet new];
	return self;
}

- (instancetype)initWithCapacity:(NSUInteger)numItems
{
	self = [super init];
	storage = [[NSMutableOrderedSet alloc] initWithCapacity:numItems];
	return self;
}

- (instancetype)initWithObjects:(id  _Nonnull const [])objects count:(NSUInteger)cnt
{
	self = [super initWithObjects:objects count:cnt];
	storage = [[NSMutableOrderedSet alloc] initWithObjects:objects count:cnt];
	return self;
}

- (void)addObject:(id)object
{
	hasChanges = YES;
	[storage addObject:object];
}

- (void)removeObject:(id)object
{
	hasChanges = YES;
	[storage removeObject:object];
}

- (NSUInteger)count
{
	return storage.count;
}

- (BOOL)containsObject:(id)object
{
	return [storage containsObject:object];
}

- (NSEnumerator *)objectEnumerator
{
	return [storage objectEnumerator];
}

- (id)objectAtIndex:(NSUInteger)index
{
	return [storage objectAtIndex:index];
}

- (void)insertObject:(id)anObject atIndex:(NSUInteger)index
{
	hasChanges = YES;
	[storage insertObject:anObject atIndex:index];
}

- (void)removeObjectAtIndex:(NSUInteger)index
{
	hasChanges = YES;
	[storage removeObjectAtIndex:index];
}

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject
{
	hasChanges = YES;
	[storage replaceObjectAtIndex:index withObject:anObject];
}

@end
