//
//  AutoSync.m
//  Auto Write
//
//  Created by Olof Thorén on 2014-07-28.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.
//

#import "AutoSync.h"
#import "AutoSyncHandler.h"
#import "AutoDB.h"

@import ObjectiveC;

@implementation AutoSync

//We are separating AutoSync (objects that can be synced) with AutoSyncHandler (takes care of the syncing logic).

- (void)awakeFromFetch
{
	registerChanges = YES;	//sync objects must always register changes
	[super awakeFromFetch];
}

- (void) generateNewId
{
	u_int64_t oldId = self.id;
	self.id = generateRandomAutoId();
	if (oldId && self.isToBeInserted)
	{
		[[AutoSyncHandler sharedInstance] swapCreatedId:self.idValue withOldId:@(oldId) forClass:self.class];
	}
}

- (void) registerChange:(NSString*)columnName oldValue:(id)oldValue newValue:(id)newValue
{
	if (self.id == 0)
		return;	//only allow updates for created objects
	[super registerChange:columnName oldValue:oldValue newValue:newValue];
	
	//newly created objects need to send all of their stuff so we don't manage those
	if (self.isToBeInserted == NO)
	{
		NSSet *preventColumns = [self.class preventSyncColumns];
		if ([preventColumns containsObject:columnName] || [columnName isEqualToString:@"is_deleted"] || [columnName isEqualToString:@"sync_state"])
		{
			return;
		}
		if (newValue == nil)
			newValue = [NSNull null];
		[[AutoSyncHandler sharedInstance] addUpdatedId:self.idValue value:newValue column:columnName forClass:self.class];
	}
}

- (void) setIsToBeInserted:(BOOL)_isToBeInserted
{
    //mark inserted objects for update creation
    [super setIsToBeInserted:_isToBeInserted];
    if (_isToBeInserted)
    {
		[[AutoSyncHandler sharedInstance] addCreatedId:self.idValue forClass:self.class];
    }
}

+ (void) syncErrorDuplicateValue:(NSArray*)ids
{
	//default implementation just deletes the duplicates.
	[self deleteIds:ids];
}

+ (BOOL) shouldMoveIdForDuplicateCreate:(NSArray*)ids
{
	return NO;
}

+ (NSString*) serverTableName
{
	NSLog(@"ERROR! not implemented!");
	exit(-2);
	return @"";
}

+ (NSSet<NSString*>*)preventSyncColumns
{
	return [NSSet setWithObjects:@"is_deleted", @"sync_state", nil];
}

+ (NSMutableSet*) localColumnsTakesSyncingPresident
{
	NSMutableSet *columns = [NSMutableSet setWithObjects:@"is_deleted", nil];
	return columns;
}

+ (void) handleUniqueValues:(nonnull NSMutableDictionary <NSNumber*, NSMutableDictionary*>*)createObjects {}

+ (NSMutableDictionary*) syncDataToServer:(NSMutableDictionary<NSString*, id>*)dataColumns
{
	AutoSyncTranslate *translate = self.syncTranslate;
	if (!translate)
	{
		NSLog(@"ERROR! not implemented!");
		exit(-2);
	}
	NSMutableDictionary *result = [NSMutableDictionary new];
	if (dataColumns[@"id"])
	{
		result[@"id"] = dataColumns[@"id"];
		[dataColumns removeObjectForKey:@"id"];
	}
	NSDictionary *clientToServer = translate.clientToServer;
	for (NSString* key in clientToServer)
	{
		/*
		modeled around this:
		if (dataColumns[@"link"])
		{
			result[@"item_url"] = dataColumns[@"link"];
			[dataColumns removeObjectForKey:@"link"];
		}
		*/
		if (dataColumns[key])
		{
			NSString *translateKey = clientToServer[key];
			result[translateKey] = dataColumns[key];
			[dataColumns removeObjectForKey:key];
		}
	}
	
	//some data may be joined together inside one or more JSON, this does not exist on the client - only the server.
	if (translate.singleJSONKey)
	{
		//if we have a single data JSON key it means that ALL the rest of the columns goes into the JSON.
		//NOTE: TODO: If a column is data, just apply a string-transform.
		@try
		{
			NSError *error = nil;
			NSData *data = [NSJSONSerialization dataWithJSONObject:dataColumns options:0 error:&error];
			result[translate.singleJSONKey] = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
			if (error) NSLog(@"autoTranslate error %@", error);
		}
		@catch (NSException *exception)
		{
			NSLog(@"autoTranslate error %@", exception);
		}
	}
	else //if (translate.multi)
	{
		NSLog(@"TODO: implement multiJSON!");
	}
	return result;
}

+ (NSMutableDictionary*) syncTranslateFromServer:(NSMutableDictionary<NSString*, id>*)source
{
	AutoSyncTranslate *translate = self.syncTranslate;
	if (!translate)
	{
		//default implementation translates nothing
		return source;
	}
	NSMutableDictionary *object = nil;
	if (translate.singleJSONKey)
	{
		NSString* jsonString = source[translate.singleJSONKey];
		if (jsonString && (NSNull*)jsonString != [NSNull null])
		{
			object = [NSJSONSerialization JSONObjectWithData:[jsonString dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:nil];
		}
	}
	if (!object)
		object = [NSMutableDictionary new];
	NSDictionary *syncTranslateReverse = translate.serverToClient;
	for (NSString* serverKey in syncTranslateReverse)
	{
		if (source[serverKey])
		{
			NSString *clientKey = syncTranslateReverse[serverKey];
			object[clientKey] = source[serverKey];
		}
	}
	return object;
}

+ (nullable AutoSyncTranslate*) syncTranslate
{
	return nil;
}

+ (void) syncDoneWithModifications{}

/*
 When deleting sync-objects we first mark them to be deleted, send these to the server, and if the server agrees, remove them afterwards. (otherwise they might re-appear).
 
 1, Mark them as deleted so they appear deleted for the user.
 2, when syncing: We send deletions as an update-request, if we are allowed to update we can delete.
 3, Otherwise, we un-delete them, and data will re-appear to the user. The user will then have to delete the items twice.
 4, If delete was ok by the server, we store deleted ids in a separate table, and delete their objects from disk.
 */
+ (void) deleteIds:(NSArray*)ids
{
	[self.tableCache syncPerformBlock:^(NSMapTable * _Nonnull table) {
		
		//Check any object that are fetched
		for (NSNumber *id_field in ids)
		{
			AutoModel *object = [table objectForKey:id_field];
			if (object && !object.is_deleted)
			{
				[object willBeDeleted];
				object.is_deleted = YES;
			}
		}
	}];
	
	NSString *classString = NSStringFromClass(self);
	NSString *questionMarks = [self questionMarks:ids.count];
	NSString *updateQuery = [NSString stringWithFormat:@"UPDATE %@ SET is_deleted = 1 WHERE id IN (%@)", classString, questionMarks];
	
	//while inside init-sync, we must delete stuff right away - otherwise it will be sent back and forth.
	if (AutoSyncHandler.sharedInstance.isInitSyncing)
	{
		NSString *selectQuery = [NSString stringWithFormat:@"SELECT id FROM %@ WHERE sync_state = %i AND id IN (%@)", classString, (int)AutoSyncStateNotCreated, questionMarks];
		NSArray *deleteIdsNow = [self groupConcatQuery:selectQuery arguments:ids];
		if (deleteIdsNow.count)
		{
			[super deleteIds:deleteIdsNow];
		}
	}
	
	[self inDatabase:^(FMDatabase *db)
	{
		if (![db executeUpdate:updateQuery withArgumentsInArray:ids])
		{
			NSLog(@"Could mark %@ for deletion, error: %@", classString, db.lastError);
		}
	}];
	[[AutoSyncHandler sharedInstance] deleteIds:ids forClass:classString];
}

@end

@implementation AutoSyncTranslate
{
	
}

+ (instancetype) clientToServerMapping:(NSDictionary*)clientToServer singleJSONKey:(NSString*)singleJSONKey multipleJSON:(NSDictionary*)multipleJSON
{
	AutoSyncTranslate *translate = [AutoSyncTranslate new];
	
	translate.clientToServer = clientToServer;
	if (clientToServer)
		translate.serverToClient = [NSDictionary dictionaryWithObjects:clientToServer.allKeys forKeys:clientToServer.allValues];
	
	translate.singleJSONKey = singleJSONKey;
	return translate;
}

@end
