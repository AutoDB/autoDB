//
//  AutoSyncRecord.m
//  rss
//
//  Created by Olof Thorén on 2019-06-14.
//  Copyright © 2019 Aggressive Development AB. All rights reserved.
//

#import "AutoSyncRecord.h"

@implementation AutoSyncRecord
{
	///{ table_name: [1,2,3...] }
	NSMutableDictionary<NSString*, NSMutableArray<NSNumber*> *> *createdTableIds;
	///{ table_name: [1,2,3...] }
	NSMutableDictionary<NSString*, NSMutableDictionary<NSNumber*, NSMutableSet *> *> *updatedTableIds;
	NSMutableDictionary<NSString*, NSMutableArray<NSNumber*> *> *syncingCreatedTableIds;
	NSMutableDictionary<NSString*, NSMutableDictionary<NSNumber*, NSMutableSet *> *> *syncingUpdatedTableIds;
	dispatch_queue_t queue;
	NSUInteger amountLeft;
}

- (instancetype)init
{
	self = [super init];
	queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
	return self;
}

- (void)awakeFromFetch
{
	if (!_currentSyncAmount || _currentSyncAmount == 1000)
	{
		_minSyncAmount = 0;
		_maxSyncAmount = 2500;
		_currentSyncAmount = _maxSyncAmount;
	}
	
	if (_data)
	{
		NSError *error = nil;
		NSDictionary *data = nil;
		if (@available(iOS 11.0, *))
		{
			data = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:[NSMutableDictionary class], [NSMutableSet class], [NSMutableArray class], nil] fromData:_data error:&error];
		}
		else
		{
			// Fallback on earlier versions
			data = [NSKeyedUnarchiver unarchiveObjectWithData:_data];
		}
		if (!data || error) NSLog(@"error when unarchiving %@", error);
		
		createdTableIds = data[@"createdTableIds"];
		syncingCreatedTableIds = data[@"syncingCreatedTableIds"];
		_deleteTables = data[@"deleteTables"];
		
		updatedTableIds = data[@"updatedTableIds"];
		syncingUpdatedTableIds = data[@"syncingUpdatedTableIds"];
	}
	if (!createdTableIds)
	{
		createdTableIds = [NSMutableDictionary new];
		updatedTableIds = [NSMutableDictionary new];
	}
	if (!syncingCreatedTableIds)
		syncingCreatedTableIds = [NSMutableDictionary new];
	if (!syncingUpdatedTableIds)
		syncingUpdatedTableIds = [NSMutableDictionary new];
	[super awakeFromFetch];
}

+ (NSDictionary *)defaultValues
{
	return @{@"change_id" : @0};
}

- (void) deleteIds:(NSArray*)ids forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		
		if (updatedTableIds[tableClass].count || syncingUpdatedTableIds[tableClass].count)
		{
			for (__strong NSNumber *idValue in ids)
			{
				if ([idValue isKindOfClass:[NSString class]])
				{
					idValue = @([((NSString*)idValue) integerValue]);
				}
				[updatedTableIds[tableClass] removeObjectForKey:idValue];
				[syncingUpdatedTableIds[tableClass] removeObjectForKey:idValue];
			}
		}
		if (createdTableIds[tableClass].count)
			[createdTableIds[tableClass] removeObjectsInArray:ids];
		if (syncingCreatedTableIds[tableClass].count)
			[syncingCreatedTableIds[tableClass] removeObjectsInArray:ids];
	});
}

- (void) moveId:(NSNumber*)oldId toId:(NSNumber*)newId forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		for (NSDictionary *table in @[syncingUpdatedTableIds, updatedTableIds])
		{
			id object = table[tableClass][oldId];
			if (object)
			{
				table[tableClass][newId] = object;
				[table[tableClass] removeObjectForKey:oldId];
			}
		}
		//if item currently being created - remove it
		NSMutableArray *ids = syncingCreatedTableIds[tableClass];
		if (ids)
		{
			NSUInteger index = [ids indexOfObject:oldId];
			if (index != NSNotFound)
			{
				[ids removeObjectAtIndex:index];
			}
		}
		//item must sync its new id.
		ids = syncingCreatedTableIds[tableClass];
		if (ids)
		{
			NSUInteger index = [ids indexOfObject:oldId];
			if (index != NSNotFound)
			{
				[ids removeObjectAtIndex:index];
				[ids addObject:newId];
			}
			else
				[ids addObject:newId];
		}
	});
}

- (void) markAsCreated:(NSArray*)ids forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		[syncingCreatedTableIds[tableClass] removeObjectsInArray:ids];
		[createdTableIds[tableClass] removeObjectsInArray:ids];
	});
}			

- (void) mergeValues:(NSMutableDictionary*)translatedValues presidentColumns:(NSSet*)presidentColumns id:(NSNumber*)idValue forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		NSMutableSet *updatedTable = updatedTableIds[tableClass][idValue].mutableCopy;
		NSSet *syncingTable = syncingUpdatedTableIds[tableClass][idValue];
		[updatedTable unionSet:syncingTable];
		
		if (!updatedTable && !syncingTable)
			return;	//we have no changes.
		
		//skip some cases, e.g. if we have changed isRead before syncing was done BUT now sync want's to change it back - don't agree.
		[updatedTable intersectSet:presidentColumns];
		
		//last change takes president, so here we guess that the client is more recent.
		if (updatedTable.count)
			[translatedValues removeObjectsForKeys:updatedTable.allObjects];
	});
}

- (void) bulkAddCreatedIds:(NSArray <NSNumber*>*)bulkIds forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		NSMutableArray *ids = createdTableIds[tableClass];
		if (!ids)
		{
			ids = [NSMutableArray new];
			createdTableIds[tableClass] = ids;
		}
		[ids addObjectsFromArray:bulkIds];
	});
	self.hasChanges = YES;
}

- (void) addCreatedId:(NSNumber*)id forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		NSMutableArray *ids = createdTableIds[tableClass];
		if (!ids)
		{
			ids = [NSMutableArray new];
			createdTableIds[tableClass] = ids;
		}
		[ids addObject:id];
	});
	self.hasChanges = YES;
}

- (void) swapCreatedId:(NSNumber*)idValue withOldId:(NSNumber*)oldIdValue forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		NSMutableArray *ids = createdTableIds[tableClass];
		if (!ids)
		{
			ids = [NSMutableArray new];
			createdTableIds[tableClass] = ids;
			[ids addObject:idValue];
		}
		else
		{
			[ids removeObject:oldIdValue];
			[ids addObject:idValue];
		}
		
	});
	self.hasChanges = YES;
}

- (void) addUpdatedId:(NSNumber*)idValue value:(id)value column:(NSString*)column forClass:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		
		if ([createdTableIds[tableClass] containsObject:idValue])
		{
			return;
		}
		NSMutableDictionary *ids = updatedTableIds[tableClass];
		if (!ids)
		{
			ids = [NSMutableDictionary new];
			updatedTableIds[tableClass] = ids;
		}
		NSMutableSet *row = ids[idValue];
		if (!row)
		{
			row = [NSMutableSet new];
			ids[idValue] = row;
		}
		[row addObject:column];
	});
	self.hasChanges = YES;
}

#pragma mark - sending values

//return the old values or start new sync build.
- (NSDictionary*) startCreateSync
{
	//if the old tables did not get through, or wasn't marked - return them before building new
	dispatch_sync(queue, ^{
		
		BOOL escape = NO;
		if (syncingCreatedTableIds.count)
		{
			for (NSString *table in syncingCreatedTableIds)
			{
				if ([syncingCreatedTableIds[table] count])
				{
					escape = YES;
				}
			}
		}
		if (escape)
		{
			if (createdTableIds.count)
				self.syncOptions |= SyncOptionsPartialSync;
			amountLeft = 0;	//prevent update when we have create
			return;	//we still have stuff to do
		}
		amountLeft = _currentSyncAmount;
		[syncingCreatedTableIds removeAllObjects];
		
		[createdTableIds.copy enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull table, NSMutableArray<NSNumber *> * _Nonnull ids, BOOL * _Nonnull stop) {
			if (ids.count > amountLeft)
			{
				NSRange range = NSMakeRange(0, amountLeft);
				syncingCreatedTableIds[table] = [ids subarrayWithRange:range].mutableCopy;
				[ids removeObjectsInRange:range];
				*stop = YES;
				amountLeft = 0;
				self.syncOptions |= SyncOptionsPartialSync;
			}
			else
			{
				[createdTableIds removeObjectForKey:table];
				syncingCreatedTableIds[table] = ids;
				amountLeft -= ids.count;
			}
		}];
	});
	
	if (syncingCreatedTableIds.count)
	{
		self.hasChanges = YES;
	}
	return syncingCreatedTableIds;
}

- (NSDictionary*) startUpdateSync
{
	dispatch_sync(queue, ^{
		
		if (syncingUpdatedTableIds.count)
		{
			for (NSString *table in syncingUpdatedTableIds)
			{
				if ([syncingUpdatedTableIds[table] count])
				{
					if (updatedTableIds.count)
						self.syncOptions |= SyncOptionsPartialSync;
					return;	//we still have stuff to do
				}
			}
		}
		
		[syncingUpdatedTableIds removeAllObjects];
		if (amountLeft == 0)
			return;
		
		[updatedTableIds.copy enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull table, NSMutableDictionary<NSNumber *,NSMutableSet *> * _Nonnull ids, BOOL * _Nonnull stop) {
			
			if (ids.count > amountLeft)
			{
				NSMutableDictionary *subDic = [[NSMutableDictionary alloc] initWithCapacity:amountLeft];
				NSRange range = NSMakeRange(0, amountLeft);
				NSArray *keys = [ids.allKeys subarrayWithRange:range];
				for (NSNumber *key in keys)
				{
					subDic[key] = ids[key];
				}
				syncingUpdatedTableIds[table] = subDic;
				[ids removeObjectsForKeys:keys];
				*stop = YES;
				amountLeft = 0;
				self.syncOptions |= SyncOptionsPartialSync;
			}
			else
			{
				syncingUpdatedTableIds[table] = ids;
				[updatedTableIds removeObjectForKey:table];
				amountLeft -= ids.count;
			}
		}];
		
		if (syncingUpdatedTableIds.count)
		{
			self.hasChanges = YES;
		}
	});
	return syncingUpdatedTableIds;
}

- (void) syncCreatedComplete:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		[syncingCreatedTableIds removeObjectForKey:tableClass];
	});
	self.hasChanges = YES;
}

- (void) syncUpdatedComplete:(NSString*)tableClass
{
	dispatch_sync(queue, ^{
		[syncingUpdatedTableIds removeObjectForKey:tableClass];
	});
	self.hasChanges = YES;
}

- (void) setupResync
{
	dispatch_sync(queue, ^{
		[syncingCreatedTableIds removeAllObjects];
		[createdTableIds removeAllObjects];
		[syncingUpdatedTableIds removeAllObjects];
		[updatedTableIds removeAllObjects];
	});
	self.hasChanges = YES;
}

- (void) syncComplete
{
	dispatch_sync(queue, ^{
		[syncingCreatedTableIds removeAllObjects];
		[syncingUpdatedTableIds removeAllObjects];
	});
	self.hasChanges = YES;
}

- (void) reimburseActions
{
	//put back everything again!
	dispatch_sync(queue, ^{
		
		[syncingCreatedTableIds enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull table, NSMutableArray<NSNumber *> * _Nonnull ids, BOOL * _Nonnull stop) {
			if (!createdTableIds[table])
			{
				createdTableIds[table] = ids;
				return;
			}
			[createdTableIds[table] addObjectsFromArray:ids];
		}];
		
		[syncingUpdatedTableIds enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull table, NSMutableDictionary<NSNumber *,NSMutableSet *> * _Nonnull ids, BOOL * _Nonnull stop) {
			
			if (!updatedTableIds[table])
			{
				updatedTableIds[table] = ids;
				return;
			}
			for (NSNumber *idValue in ids)
			{
				NSMutableSet *object = updatedTableIds[table][idValue];
				if (object)
					[ids[idValue] addObjectsFromArray:object.allObjects];	//replace if there are newer changes
				updatedTableIds[table][idValue] = ids[idValue];
			}
		}];
		[syncingCreatedTableIds removeAllObjects];
		[syncingUpdatedTableIds removeAllObjects];
	});
	self.hasChanges = YES;
}

- (void)setDeleteTables:(NSDictionary *)deleteTables
{
	_deleteTables = deleteTables;
	self.hasChanges = YES;
}

- (NSData *)data
{
	__block NSData *archive;
	
	//we cannot use numbers as keys, so you must convert back and forth manually
	dispatch_sync(queue, ^{
		
		NSMutableDictionary *data = [NSMutableDictionary new];
		data[@"updatedTableIds"] = updatedTableIds;
		data[@"createdTableIds"] = createdTableIds;
		if (syncingCreatedTableIds)
			data[@"syncingCreatedTableIds"] = syncingCreatedTableIds;
		if (syncingUpdatedTableIds)
			data[@"syncingUpdatedTableIds"] = syncingUpdatedTableIds;
		if (self.deleteTables)
			data[@"deleteTables"] = self.deleteTables;
		NSError *error = nil;
		if (@available(iOS 11.0, *))
		{
			archive = [NSKeyedArchiver archivedDataWithRootObject:data requiringSecureCoding:YES error:&error];
		}
		else
		{
			// Fallback on earlier versions
			archive = [NSKeyedArchiver archivedDataWithRootObject:data];
		};
		if (!archive || error)
			NSLog(@"error could not make archive from sync-record %@", error);
	});
	return archive;
}

@end
