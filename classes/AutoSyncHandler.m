//
//  AutoSyncHandler.m
//  Auto Write
//
//  Created by Olof Thorén on 2014-07-28.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.
//

/*
 TODO:
 
 * Merging duplicate ids:
   Create one object in client A, and one in client B with the same id. A syncs first, B then syncs but will update its object then get an error of duplicate ID.
   We must handle duplicate ids before merging data.
 
 * We should listen to AutoModelUpdateNotification - where this matters and act on delete/updates
*/

#import "AutoSyncHandler.h"

#import "ADDiscHandler.h"
#import "AutoUser.h"
#import "AutoSync.h"
#import "ADSessionTaskHandler.h"
#import "ADBackgroundDownloadTask.h"

#import "AutoDB.h"
#import "AutoSyncRecord.h"

@implementation AutoSyncHandler
{
	dispatch_semaphore_t syncSemaphore;
	AutoSyncRecord* syncRecord;
	
	BOOL hasRequestedSync, transferIsSetup;
	NSInteger resyncCount, resetSync;
	UIBackgroundTaskIdentifier backgroundSyncIdentifier;
	NSMutableDictionary *serverClientTableMapping, *postDeleted, *postCreated, *postUpdated;
	NSDate *autoSyncLastRequest;
}

#pragma mark - setting up

static Class uiApplication;
static AutoSyncHandler *syncHandler = nil;
//we need one object to take care of syncs in the background.
+ (instancetype) sharedInstance
{
    if(!syncHandler)
    {
		static dispatch_once_t onceToken;
		dispatch_once(&onceToken, ^(void){
        	syncHandler = [self new];
			uiApplication = NSClassFromString(@"UIApplication");
		});
    }
    return syncHandler;
}

+ (void) mainSync
{
	[[self sharedInstance] mainSync];
}

+ (void) setupSync:(NSDictionary <NSString*, NSArray <NSString*>*> *)pathsForClassNames
{
	//group all to be synced, so we can use one query per group.
	NSMutableArray *syncClasses = [NSMutableArray new];
	for (NSArray<NSString*> *classNameGroup in pathsForClassNames.allValues)
	{
		NSMutableArray *group = [NSMutableArray new];
		for (NSString *tableName in classNameGroup)
		{
			if ([NSClassFromString(tableName) isSubclassOfClass:[AutoSync class]] && [tableName isEqualToString:@"AutoSync"] == NO)
			{
				[group addObject:tableName];
			}
		}
		if (group.count)
		{
			[syncClasses addObject:group];
		}
	}
	if (syncClasses.count)
	{
		[[self sharedInstance] setSyncClasses:syncClasses];
		[[self sharedInstance] mainSync];
	}
}

- (instancetype) init
{
	postDeleted = [NSMutableDictionary new];
	postCreated = [NSMutableDictionary new];
	postUpdated = [NSMutableDictionary new];
	syncRecord = [AutoSyncRecord createInstanceWithId:1];
	self.apiURL = [NSURL URLWithString:syncRecord.apiURL];
	syncSemaphore = dispatch_semaphore_create(1);
	[self setupBackgroundDownloads];
	
	if (DEBUG)
	{
		//During testing we sync when opening - we can't use this since it deactivates during phone calls
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mainSync) name:UIApplicationDidBecomeActiveNotification object:nil];
		//During testing we must also re-fetch syncRecord when switching to testDB.
		[[NSNotificationCenter defaultCenter] addObserverForName:AutoDBIsSetupNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
			
			syncRecord = [AutoSyncRecord createInstanceWithId:1];
			self.currentUser = [AutoUser createInstanceWithId:1];
		}];
	}
	
	return self;
}

- (void)setSyncClasses:(NSArray<NSArray<NSString *> *> *)syncClasses
{
	_syncClasses = syncClasses;
	serverClientTableMapping = [NSMutableDictionary new];
	for (NSArray<NSString*> *group in syncClasses)
	{
		for (NSString *className in group)
		{
			Class tableClass = NSClassFromString(className);
			NSString *serverTableName = [tableClass serverTableName];
			serverClientTableMapping[serverTableName] = className;
		}
	}
}

- (void)setApiURL:(NSURL *)apiURL
{
	_apiURL = apiURL;
	syncRecord.apiURL = [apiURL absoluteString];
}

#pragma mark - set records

- (void) addCreatedId:(NSNumber*)idValue forClass:(Class)classObject
{
	if (self.currentUser.userSettings & AutoUserSettingSyncingIsOn)
	{
		NSString *tableClass = NSStringFromClass(classObject);
		[syncRecord addCreatedId:idValue forClass:tableClass];
		[self requestSyncing];
	}
}

- (void) swapCreatedId:(NSNumber*)idValue withOldId:(NSNumber*)oldIdValue forClass:(Class)classObject
{
	if (self.currentUser.userSettings & AutoUserSettingSyncingIsOn)
	{
		NSString *tableClass = NSStringFromClass(classObject);
		[syncRecord swapCreatedId:idValue withOldId:oldIdValue forClass:tableClass];
		[self requestSyncing];
	}
}

- (void) addUpdatedId:(NSNumber*)idValue value:(id)value column:(NSString*)column forClass:(Class)classObject
{
	if (self.currentUser.userSettings & AutoUserSettingSyncingIsOn)
	{
		NSString *tableClass = NSStringFromClass(classObject);
		[syncRecord addUpdatedId:idValue value:value column:column forClass:tableClass];
		[self requestSyncing];
	}
}

- (void) deleteIds:(NSArray*)ids forClass:(NSString*)classString
{
	//throttle delete requests
	[syncRecord deleteIds:ids forClass:classString];
	[self requestSyncing];
}

- (void) purgeDeleted
{
	NSString *deletedQuery = @"DELETE FROM %@ WHERE is_deleted";
	for (NSArray<NSString*> *group in self.syncClasses)
	{
		Class syncClass = NSClassFromString(group.firstObject);
		[syncClass executeInDatabase:^(FMDatabase *db)
		{
			for (NSString *className in group)
			{
				[db executeUpdate:[NSString stringWithFormat:deletedQuery, className]];
				//NSLog(@"deleted %@", @(db.changes));
			}
		}];
	}
}

- (BOOL)isInitSyncing
{
	return syncRecord.syncOptions & SyncOptionsInitSync;
}

#pragma mark - the transfer
static NSString* downloadKey = @"AutoSyncTask";

- (void) setupBackgroundDownloads
{
	dispatch_semaphore_wait(syncSemaphore, DISPATCH_TIME_FOREVER);
	[ADBackgroundDownloadTask fetchQuery:@"WHERE key = ?" arguments:@[downloadKey] resultBlock:^(AutoResult * _Nullable resultSet) {
		
		ADBackgroundDownloadTask *task = resultSet.rows.lastObject;
		if (!task)
		{
			[self setupBackgroundDownloadsIsDone:task];
			return;
		}
		[[ADBackgroundDownload sharedInstance] onSession:task.session taskWithId:task.session_task_id performBlock:^(NSURLSessionTask * _Nullable sessionTask) {
			
			if (!sessionTask)
			{
				[self setupBackgroundDownloadsIsDone:task];
			}
			else if (sessionTask.state == NSURLSessionTaskStateCanceling)
			{
				//should not come in, delete it to make sure. Now we can start new syncs.
				[task delete];
				[self setupBackgroundDownloadsIsDone:nil];
			}
			else if (sessionTask.state != NSURLSessionTaskStateCompleted)
			{
				//its soon coming in or is stuck
				if (sessionTask.state == NSURLSessionTaskStateSuspended)
					[sessionTask resume];
				[self pollTaskCompletion:sessionTask downloadTask:task];
			}
			else	//completed, handle it!
			{
				NSHTTPURLResponse *response = ((NSHTTPURLResponse*)sessionTask.response);
				if (response)
				{
					task.statusCode = response.statusCode;
				}
				[self setupBackgroundDownloadsIsDone:task];
			}
		}];
	}];
}

- (void) pollTaskCompletion:(NSURLSessionTask*)sessionTask downloadTask:(ADBackgroundDownloadTask *)task
{
	NSUInteger completedUnitCount = sessionTask.progress.completedUnitCount;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		
		if (task.is_deleted)
		{
			//already handled!
			return;
		}
		if (sessionTask.state == NSURLSessionTaskStateCompleted)
		{
			[self setupBackgroundDownloadsIsDone:task];
		}
		else if (completedUnitCount == sessionTask.progress.completedUnitCount)
		{
			//nothing has happened in 15 sec - kill it!
			[task delete];
			[sessionTask cancel];
			[[ADBackgroundDownload sharedInstance] removeFromCache:task];
			[self setupBackgroundDownloadsIsDone:nil];
		}
		else
		{
			//we have progress, give it 15 more secs!
			[self pollTaskCompletion:sessionTask downloadTask:task];
		}
	});
}

- (void) setupBackgroundDownloadsIsDone:(ADBackgroundDownloadTask*)dbTask
{
	BOOL signalSemaphore = YES;	//if we have a task waiting, don't signal but process it first.
	if (dbTask)
	{
		if (dbTask.is_complete)
		{
			signalSemaphore = NO;
			[self handleDownload:dbTask];
		}
		else
			[dbTask delete];
	}
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadComplete:) name:downloadKey object:nil];
	transferIsSetup = YES;
	if (signalSemaphore)
	{
		dispatch_semaphore_signal(syncSemaphore);
		if (syncRecord.syncOptions & SyncOptionsInitSync)
		{
			//dead during initSync
			[self initialSync];
		}
		else if (hasRequestedSync)
		{
			[self mainSync];
		}
	}
}

#pragma mark - start syncing

//mainSync always happens in the DB thread to kick things off swiftly without taking mainThread. But most work is done in a bg-queue.
- (BOOL) mainSync
{
	if (self.syncClasses.count == 0 || !self.apiURL)
	{
		return NO;
	}
	else if (_isSyncing || !transferIsSetup)
	{
		hasRequestedSync = YES;
		return NO;
	}
	
	//having a semaphore blocking us when trying to double-sync is the only decent way to do this. You must release this semaphore when syncing is done or failed.
	long failure = dispatch_semaphore_wait(syncSemaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
	if (failure)
	{
		NSLog(@"Failed to take semaphore, rerun when done.");
		hasRequestedSync = YES;
		return NO;
	}
	
	self.lastSyncDate = [NSDate date];
	hasRequestedSync = NO;
	autoSyncLastRequest = nil;
	
	//we only have one user, don't have user-switching way to advanced for your apps.
	if (!self.currentUser)
		self.currentUser = [AutoUser fetchQuery:@"WHERE current_user = 1 LIMIT 1" arguments:nil].rows.firstObject;
	
	//if syncing is off, and initSync is off - ignore syncing
	BOOL syncingIsOff = (syncRecord.syncOptions & SyncOptionsInitSync)
		|| (self.currentUser.userSettings & AutoUserSettingSyncingIsOn) == 0;
	if (!self.currentUser || syncingIsOff)
	{
		//NSLog(@"No user, so no sync!");
		[self purgeDeleted];
					 
		dispatch_semaphore_signal(syncSemaphore);
		return NO;
	}
	NSLog(@"starting sync");
	_isSyncing = YES;
	[AutoModel saveAllWithChanges:^(NSError * _Nullable error) {
		
		#ifndef TARGET_IS_EXTENSION
		backgroundSyncIdentifier = [[uiApplication sharedApplication] beginBackgroundTaskWithName:@"syncHandler" expirationHandler:^{
			NSLog(@"Terminate background sync-task!");
			[[uiApplication sharedApplication] endBackgroundTask:backgroundSyncIdentifier];
			backgroundSyncIdentifier = UIBackgroundTaskInvalid;
		}];
		#endif
		
		[self determineSyncAction:YES];
	}];
	return YES;
}

- (void) waitForSync
{
	dispatch_semaphore_wait(syncSemaphore, DISPATCH_TIME_FOREVER);
	dispatch_semaphore_signal(syncSemaphore);
}

//each call to mainSync that manages to take the semaphore MUST call this method.
- (void) endSyncing
{
    NSLog(@"unlocking and ending sync");
	if (syncRecord.syncOptions & SyncOptionsInitSync)
	{
		[self initialSyncSetupComplete];
	}
	resyncCount = 0;
	[AutoModel saveAllWithChanges:nil];
	NSDictionary *userInfo = @{ @"updated" : postUpdated.copy, @"created": postCreated.copy, @"deleted": postDeleted.copy };
	[postUpdated removeAllObjects];
	[postCreated removeAllObjects];
	[postDeleted removeAllObjects];
	_isSyncing = NO;
    dispatch_semaphore_signal(syncSemaphore);
	[[NSNotificationCenter defaultCenter] postNotificationName:AutoSyncDoneNotification object:nil userInfo:userInfo];
	
	#ifndef TARGET_IS_EXTENSION
    if (backgroundSyncIdentifier != UIBackgroundTaskInvalid)
    {
        //this is actually not thread safe.
        [[uiApplication sharedApplication] endBackgroundTask:backgroundSyncIdentifier];
        backgroundSyncIdentifier = UIBackgroundTaskInvalid;
    }
	#endif
	if (hasRequestedSync)
		[self requestSyncing];
}

- (void) requestSyncing
{
	if (_preventAutoSync)
		return;
	
    //NSLog(@"will start syncing in %i sec", AUTO_SYNC_DELAY);
	if (!autoSyncLastRequest)
		autoSyncLastRequest = [NSDate date];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncAfterDelay) object:nil];
	if ([autoSyncLastRequest timeIntervalSinceNow] * -1 > AUTO_SYNC_DELAY)
	{
		//NSLog(@"Force sync: time interval too long %0.2f", [autoSyncLastRequest timeIntervalSinceNow]);
		[self syncAfterDelay];
	}
    else
	{
		//here is the problem! We must check preventSyncAFTER delay!
		[self performSelector:@selector(syncAfterDelay) withObject:nil afterDelay:AUTO_SYNC_DELAY];
	}
    hasRequestedSync = YES;
}

- (void) syncAfterDelay
{
	if (!_preventAutoSync && hasRequestedSync)
	{
		[self mainSync];
	}
}

- (void) deleteAllAndResync
{
	//todo: delete all autoSync objects.
	[self initialSync];
}

- (void) initialSync
{
	//take the semaphore
	_preventAutoSync = YES;
	dispatch_semaphore_wait(syncSemaphore, DISPATCH_TIME_FOREVER);
	_isSyncing = YES;
	syncRecord.syncOptions |= SyncOptionsInitSync;
	syncRecord.change_id = @0;
	syncRecord.deleteTables = nil;
	if (!self.currentUser)
		self.currentUser = [AutoUser fetchQuery:@"WHERE current_user = 1 LIMIT 1" arguments:nil].rows.firstObject;
	self.currentUser.userSettings |= AutoUserSettingSyncingIsOn;	//all items created after this will be queued for syncing
	[AutoModel saveAllWithChanges:nil];
	[self syncFromScratch];
	_preventAutoSync = NO;
}

- (void) syncFromScratch
{
	/*
	 the algorithm is simple - fetch all from scratch, missing ids get's created (sent to server). Duplicate URLs get merged by changing their id, or deleting them.
	 NO: think again!
	 If client hasn't synched in weeks, all are building their local "truth". Then we purchase syncing again, and all clients setup initialSync:
	 A, is first and gets a lot of old objects that isn't interesting anymore.
	 B, comes in a few hours later with old data and overwrites what the server has - A will update these and get weird stuff.
	 Also, A could want/need all those old items - it could be a brand new phone, started with some new subscriptions - then remembering syncing and toggling it on to get all old stuffs back.
	 
	 Solve:
	 Since we cannot know if old data is useless or not, we must always merge kindly, and it must be easy to delete stuff. Then it will play out like this:
	 A, comes in first and creates all new items and displays the old unread items - and resumes feed-subscriptions from server which the client has deleted.
	 	-> solve by keeping a list on the client of all deleted crap - or marking everything that is under sync, and keeping track of deletion of those things and sending it in.
	 B, comes in second, and its new subs will be deleted or merged due to unique values, otherwise they will be added to sync.
	 B has old presidentColumn values, that should be overwritten by A - but are not. E.g. old read items will be seen as unread.
	 
	 So, it will be a little annoying to try out sync - then abandoning it while still use the app, for to finally turn it on again - but this usecase will not happen, those who abandon will never come back, and if they do - they won't have 100+ feeds to sync.
	 */
	
	//First purge old not-needed data - pointless to send this back-and-forth
	[[NSNotificationCenter defaultCenter] postNotificationName:@"AutoSyncRequestDataPurge" object:nil userInfo:nil];
	
	//loop through and mark all as not created
	for (NSArray<NSString*> *group in self.syncClasses)
	{
		[NSClassFromString(group.firstObject) inDatabase:^(FMDatabase * _Nonnull db) {
			for (NSString *className in group)
			{
				//Then mark all to be created, then sync - and unmark those, the ones left should be created
				[db executeUpdate:[NSString stringWithFormat:@"UPDATE %@ SET sync_state = 1 WHERE is_deleted = 0", className]];
			}
		}];
	}
	
	syncRecord.change_id = @0;
	syncRecord.syncOptions |= SyncOptionsResetSync;
	[syncRecord setupResync];
	
	[self syncActions:nil syncState:SyncStateInit];
}

- (void) resetSyncIsDone
{
	syncRecord.syncOptions = [syncRecord setBitField:syncRecord.syncOptions value:SyncOptionsResetSync on:NO];

	//when all is done, create missing values
	for (NSArray<NSString*> *group in self.syncClasses)
	{
		[NSClassFromString(group.firstObject) inDatabase:^(FMDatabase * _Nonnull db) {
			for (NSString *className in group)
			{
				Class tableClass = NSClassFromString(className);
				NSArray *unsyncedIds = [tableClass groupConcatQuery:[NSString stringWithFormat:@"SELECT id FROM %@ WHERE sync_state = 1 AND is_deleted = 0", className] arguments:nil];
				if (unsyncedIds.count == 0)
					continue;
				//all objects server did not have should be sent as creations, do this by first by adding them all to the record, then sending when all merging is done.
				[syncRecord bulkAddCreatedIds:unsyncedIds forClass:className];
				[db executeUpdate:[NSString stringWithFormat:@"UPDATE %@ SET sync_state = 0", className]];
			}
		}];
	}
	[syncRecord save];
	
	//Now do a regular sync with determineSyncAction, to send all stuff to the server.
	[self determineSyncAction:NO];
}

- (void) initialSyncSetupComplete
{
	syncRecord.syncOptions = [syncRecord setBitField:syncRecord.syncOptions value:SyncOptionsInitSync on:NO];
	[AutoModel saveAllWithChanges:nil];
	
	//when all is done, delete previously deleted rows.
	for (NSArray<NSString*> *group in self.syncClasses)
	{
		[NSClassFromString(group.firstObject) inDatabase:^(FMDatabase * _Nonnull db) {
			for (NSString *className in group)
			{
				NSString *query = [NSString stringWithFormat:@"DELETE FROM %@ WHERE is_deleted", className];
				[db executeUpdate:query];
			}
		}];
	}
}

//called from main sync when starting. What do we want here?
//build a list of everything that is new or changed or deleted - then send it in!
- (void) determineSyncAction:(BOOL)checkInitSyncErrors
{
	//First we must save all unsaved work - otherwise we can't fetch from DB.
	[AutoModel saveAllWithChanges:nil];
	BOOL initSync = syncRecord.syncOptions & SyncOptionsInitSync;
	if (checkInitSyncErrors)	//e.g. resetSyncIsDone needs to skip this step when done, and finish initSync later.
	{
		if (initSync)
		{
			//init sync failed last time, perhaps the app crashed
			NSLog(@"found init sync problems!");
			[self syncFromScratch];
			return;
		}
	}
	if (syncRecord.syncOptions & SyncOptionsPartialSync)
	{
		syncRecord.syncOptions = [syncRecord setBitField:syncRecord.syncOptions value:syncRecord.syncOptions & SyncOptionsPartialSync on:NO];
	}
	/*
	build a list of all actions, use syncRecord for as much as possible - to mitigate locking errors.
	 
	This is sent to the server, on the form:
	"autoSync":
	{
		"id": self.change_id,
	SYNC_TYPE_DELETE: { table_name : [1,2,3,4] }, { other_table_name : [1,2,3,4] },
	SYNC_TYPE_CREATE:
		{
			table_name : [{data_from_object}, {data_from_object_2}, ... }],
			other_table_name : [{data_from_object}, {data_from_object_2}, ... }],
		}
	SYNC_TYPE_UPDATE:
		{
			table_name : [{data_from_object}, {data_from_object_2}, ... }],
			other_table_name : [{data_from_object}, {data_from_object_2}, ... }],
		}
	}
	if only id is supplied, we have a regular sync
	*/
	NSMutableDictionary *deleteTables = [NSMutableDictionary new];
	NSMutableDictionary *createTables = [NSMutableDictionary new];
	NSMutableDictionary <NSString*, NSDictionary <NSNumber*, NSMutableDictionary*>*> *updateTables = [NSMutableDictionary new];
	
	//it takes too much time and effort to measure the sizes of everything, let's start by just asuming we wont be syncing the complete work of shakespeare and just limit ourselves to 10 000 objects or so. If the assumption is wrong, e.g. each object is a video - those special cases need handling of their own.
	
	NSMutableDictionary<NSString*, NSMutableArray<NSNumber*> *> *createdTableIds = syncRecord.startCreateSync;
	NSMutableDictionary<NSString*, NSMutableDictionary<NSNumber*, NSMutableSet*> *> *updatedTableIds = syncRecord.startUpdateSync;
	
	NSString *deletedQuery = @"SELECT id FROM %@ WHERE is_deleted";
	for (NSArray<NSString*> *group in self.syncClasses)
	{
		Class syncClass = NSClassFromString(group.firstObject);
		[syncClass inDatabase:^(FMDatabase *db)
		{
			for (NSString *className in group)
			{
				Class tableClass = NSClassFromString(className);
				
				//we must loop through all classes to see if something is deleted.
				NSMutableArray *createdIds = createdTableIds[className];
				NSMutableDictionary<NSNumber*, NSMutableSet*> *updatedIds = updatedTableIds[className];
				NSMutableArray *deletedIds = [tableClass groupConcatQuery:[NSString stringWithFormat:deletedQuery, className] arguments:nil];
				if (deletedIds.count)
				{
					deleteTables[[tableClass serverTableName]] = deletedIds;
					[createdIds removeObjectsInArray:deletedIds];
					[updatedIds removeObjectsForKeys:deletedIds];
				}
				
				if (createdIds.count)
				{
					//Get a translated dictionary of all objects of this class - and remove columns not to be synced!
					NSMutableArray *columns = [[AutoDB sharedInstance] columnNamesForClass:tableClass].mutableCopy;
					NSSet *preventColumns = [tableClass preventSyncColumns];
					if (preventColumns)
					{
						[columns removeObjectsInArray:preventColumns.allObjects];
					}
					
					//remember to not try to update/create deleted items!
					NSString *query = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE id IN (%@) AND is_deleted = 0", [columns componentsJoinedByString:@","], className, [tableClass questionMarks:createdIds.count]];
					createTables[className] = [tableClass arrayQuery:query arguments:createdIds];
				}
				
				//lastly do the updates
				if (updatedIds.count)
				{
					//fetch the data for these columns of these objects!
					updateTables[className] = [[AutoDB sharedInstance] valuesForColumns:updatedIds class:tableClass translateDates:NO];
				}
			}
		}];
	}
	
	__block double approxDataSize = 0;	//, maxDataSize = 134217728;	//128mb is max, if one letter = one byte.
	NSMutableDictionary *actions = [NSMutableDictionary new];
	if (deleteTables.count)
	{
		actions[[@(SyncTypeDelete) stringValue]] = deleteTables;
		//We perform the delete when coming back from server, if fails we will calculate all of them again. If BG-download works, we will use this record and perform the delete.
		syncRecord.deleteTables = deleteTables;
	}
	if (createTables.count)
	{
		//if created objects, translate into sync-format
		NSMutableDictionary *translatedValues = [NSMutableDictionary new];
		actions[[@(SyncTypeCreate) stringValue]] = translatedValues;
		[createTables enumerateKeysAndObjectsUsingBlock:^(NSString *className, NSArray *rows, BOOL * _Nonnull stop) {
			Class tableClass = NSClassFromString(className);
			NSString *serverTableName = [tableClass serverTableName];
			NSMutableArray *translatedRows = [NSMutableArray new];
			for (NSMutableDictionary *object in rows)
			{
				NSDictionary* result = [tableClass syncDataToServer:object];
				if (result)
				{
					[translatedRows addObject:result];
					if (initSync && DEBUG)
						approxDataSize += [self approxSize:result];
				}
			}
			if (translatedRows.count)
				translatedValues[serverTableName] = translatedRows;
		}];
	}
	if (updateTables.count)
	{
		//instead of saving all values, we just save what columns have changed - and fetch those columns for each object above. We also remove deleted items then.
		NSMutableDictionary *translatedValues = [NSMutableDictionary new];
		actions[[@(SyncTypeUpdate) stringValue]] = translatedValues;
		for (NSString *className in updateTables)
		{
			Class tableClass = NSClassFromString(className);
			NSString *serverTableName = [tableClass serverTableName];
			NSMutableArray *translatedRows = [NSMutableArray new];
			[updateTables[className] enumerateKeysAndObjectsUsingBlock:^(NSNumber * idValue, NSMutableDictionary * _Nonnull object, BOOL * _Nonnull stop)
			{
				NSMutableDictionary* result = [tableClass syncDataToServer:object];
				if (result)
				{
					[translatedRows addObject:result];
					if (initSync && DEBUG)
						approxDataSize += [self approxSize:result];
				}
			}];
			if (translatedRows.count)
				translatedValues[serverTableName] = translatedRows;
		}
	}
	
	if (initSync && DEBUG)
		NSLog(@"approxDataSize became %@ mb", @(approxDataSize / (1024*1024)));
	
	//debug print actions
	/*
	NSArray *statuses = @[@"unknown", @"SyncTypeStatus", @"SyncTypeUpdate", @"SyncTypeDelete", @"SyncTypeCreate"];
	for (NSString *action in actions)
	{
		NSInteger index = [action integerValue];
		NSString *status = statuses[index];
		NSLog(@"%@: %@", status, [[actions[action] allKeys] componentsJoinedByString:@", "]);
	}
	*/
	[self syncActions:actions syncState:SyncStateRegular];
}

- (NSUInteger) approxSize:(NSDictionary*)result
{
	__block NSUInteger approxDataSize = 0;
	[result enumerateKeysAndObjectsUsingBlock:^(NSString*  _Nonnull key, NSString*  _Nonnull obj, BOOL * _Nonnull stop) {
		
		//keys are always strings here
		if ([key isKindOfClass:[NSString class]])
		{
			approxDataSize += key.length;
		}
		
		if ([obj isKindOfClass:[NSString class]])
		{
			approxDataSize += obj.length;
		}
		else if ([obj isKindOfClass:[NSNumber class]])
		{
			approxDataSize += ((NSNumber*)obj).stringValue.length;
		}
		else if ([obj isKindOfClass:[NSData class]])
		{
			approxDataSize += ((NSData*)obj).length;
		}
	}];
	return approxDataSize;
}

//I have states: regular, loopContinue, loopContinue - then [self determineSyncAction:NO]; and regular or loopContinue but if successfull ending with [self resetSyncIsDone];
- (void) syncActions:(NSMutableDictionary*)actions syncState:(SyncState)syncState
{
	//send these to server
	NSDictionary *sync;
	NSNumber *change_id = syncRecord.change_id;
	if (!change_id) change_id = @0;
	if (!actions)
	{
		sync = @{ @"autoSync": @{@"id": change_id }};
	}
	else
	{
		actions[@"id"] = change_id;
		sync = @{ @"autoSync": actions };
	}
	
	//we must always use bg whenever transfers take more than 5 sec. Setting up sync can take more than a minute!
	NSDictionary* settings =
	@{
		AutoTransferUserInfo: [@(syncState) stringValue],
		AutoTransferTaskPriority: @(NSURLSessionTaskPriorityHigh)
	};
	[[ADBackgroundDownload sharedInstance] transferWithRequest:[ADBackgroundDownload requestWithURL:self.apiURL parameters:sync] key:downloadKey settings:settings startBlock:nil];
	if (DEBUG) NSLog(@"sending sync");
}

- (void) downloadComplete:(NSNotification*)notif
{
	//NOTE: it won't come here before transfer is setup since we then don't listen to the callback.
	ADBackgroundDownloadTask* task = notif.object;
	[self handleDownload:task];
}

- (void) handleDownload:(ADBackgroundDownloadTask*) task
{
	SyncState syncState = [task.user_info integerValue];
    NSError * error = task.error;
	id result = nil;
	if (!error && task.statusCode == 200)
    {
        //NOTE: if we are using all file descriptors we might get no data here - blame backblaze!
        result = [task JSONDataWithError:&error];
	}
	
	//handle common errors
	if (error && isAutoErrorType(error.code, AutoErrorCodeLoginError) && [error.domain isEqualToString:AutoErrorDomain])
	{
		NSLog(@"Could not authenticate");
		self.currentUser.userSettings |= AutoUserSettingSyncingNeedsLogin;
		self.currentUser.userSettings = [self.currentUser setBitField:self.currentUser.userSettings value:AutoUserSettingSyncingIsOn on:NO];
		[self.currentUser saveWithCompletion:nil];
		dispatch_async(dispatch_get_main_queue(), ^(void)
		{
			[[NSNotificationCenter defaultCenter] postNotificationName:AutoSyncNeedsLogin object:nil userInfo:nil];
		});
		_isSyncing = NO;
		dispatch_semaphore_signal(syncSemaphore);
		return;
	}
	
	//Break if missing payments or unhandable server error - and insert new values into db.
	//if (task.statusCode == 304)//all is up to date
	
	BOOL transferNotWorking = (!result && task.statusCode != 200 && task.statusCode != 304);
	if (task.statusCode == 402)
	{
		//ask to fix payment before syncing again
		[self handleMissingPayment];
		_isSyncing = NO;
		dispatch_semaphore_signal(syncSemaphore);
		return;
	}
	else if (error || transferNotWorking)
	{
		NSLog(@"got server error - cannot continue %@ error: %@ httpResponseCode %@", result, error, @(task.statusCode));
		//TODO: handle all errors
		
		if ([error.domain isEqualToString:NSURLErrorDomain] && (error.code == -997 || error.code == -996))
		{
			//deamon is dead, try using less data
			[syncRecord reimburseActions];
			
			//current is too much, set it to max
			syncRecord.maxSyncAmount = syncRecord.currentSyncAmount;
			if (syncRecord.minSyncAmount >= syncRecord.currentSyncAmount)
				syncRecord.minSyncAmount = 1;
			
			//We know/hope that 1MB will work, so pick half between it and current (but safe up for errors).
			NSInteger nextAmount;
			double sizeInMB = ceil(task.sessionTask.originalRequest.HTTPBody.length / (1024*1024));
			if (sizeInMB > 1)
				nextAmount = floor(syncRecord.currentSyncAmount / sizeInMB);
			else
				nextAmount = syncRecord.currentSyncAmount / 4;
			if (nextAmount >= syncRecord.currentSyncAmount)
				nextAmount = syncRecord.minSyncAmount;
			nextAmount = (syncRecord.currentSyncAmount - nextAmount) / 2;
			if (nextAmount <= syncRecord.minSyncAmount)
				nextAmount = syncRecord.minSyncAmount;
			syncRecord.currentSyncAmount = nextAmount;
			NSLog(@"syncRecord.maxAmount became %@", @(syncRecord.currentSyncAmount));
			
			resyncCount++;
			[self determineSyncAction:YES];
			return;
		}
		else if (resyncCount < 4 && (transferNotWorking || [error.domain isEqualToString:NSPOSIXErrorDomain]))
		{
			//This error is due to bg-downloads never working properly - just send again
			resyncCount++;
			[self determineSyncAction:YES];
			return;
		}
		if (syncRecord.syncOptions & SyncOptionsInitSync)	//if there are any sort of error - we must go here and turn initSync off.
		{
			self.currentUser.userSettings = [self.currentUser setBitField:self.currentUser.userSettings value:AutoUserSettingSyncingIsOn on:NO];
		}
		if (!error)
			error = [ADBackgroundDownload createErrorWithCode:AutoErrorCodeClientError defaultString:nil additionalInfo:nil];
		[[NSNotificationCenter defaultCenter] postNotificationName:AutoSyncDoneNotification object:nil userInfo:@{ @"error": error }];
		_isSyncing = NO;
		dispatch_semaphore_signal(syncSemaphore);
		return;
	}
	else if (syncRecord.maxSyncAmount > syncRecord.currentSyncAmount && syncRecord.minSyncAmount < syncRecord.currentSyncAmount)
	{
		//syncing worked and we are between min and max
		syncRecord.minSyncAmount = syncRecord.currentSyncAmount;	//if working, don't go below this threshold.
		NSInteger nextAmount = floor((syncRecord.maxSyncAmount - syncRecord.currentSyncAmount) / 4);
		if (nextAmount >= 1 && nextAmount + syncRecord.currentSyncAmount <= syncRecord.maxSyncAmount)
		{
			syncRecord.currentSyncAmount += nextAmount;	//step up a little bit to get closer to
		}
	}
	/*Algorithm is as follows:
	 1. perform delete on all deleted ids (both from server and those we sent).
	 2. update and merge all values from server.
	 3. loop through errors, if any duplicate ids - we move those automatically, if duplicate unique columns - we need to call a resolver method. Or if just resync - then do nothing.
	 4. if there where errors, resync.
	 */
	
	//Note that result may be null if nothing has changed - so nothing can be updated and you can't delete anything.
	BOOL continueSync = NO;
	BOOL sendError = NO;
	if (result)
	{
		continueSync = result[@"continue_sync"] != nil;
		if (continueSync)
		{
			//if we get continue we must always resend actions - but not deletes
			[syncRecord reimburseActions];
		}
		[self updateServerReply:result];
		//always update change_id, since if we gotten new items we don't want to fetch those again in case of resync.
		if ([self verifyServerChanges:result])
		{
			if (result[@"id"]) syncRecord.change_id = result[@"id"];
			else
				NSLog(@"error! no change id!");
		}
		sendError = [self handleServerError:result];
		if (sendError && continueSync == NO)
		{
			//we have errors that are triggering resync
			//what to do if we are in initSync mode? It can't go wrong since its only fetching data and not sending.
			if (resyncCount >= 3)
			{
				NSLog(@"ERROR! Sync has failed, the only cause of action is to resync from scratch!");
				if (resetSync > 2)
				{
					NSLog(@"ERROR! Sync has failed too many times, turn it off...");
					self.currentUser.userSettings = [self.currentUser setBitField:self.currentUser.userSettings value:AutoUserSettingSyncingIsOn on:NO];	//TODO: Signal the user?
					resetSync = 0;
					[self endSyncing];	//no point in hammering the server
					return;
				}
				resetSync++;
				resyncCount = 0;
				syncRecord.change_id = @0;
				//we are somehow out of sync, so start from scratch and create or delete all.
				[self syncFromScratch];
			}
			else
				[self determineSyncAction:NO];
			return;
		}
	}
	//you may only reset sync count when a whole sync is complete! resyncCount = 0;
	if (continueSync)
	{
		//resend those actions when all is done
		[self syncActions:nil syncState:syncState | SyncStateResendActions];
	}
	else if (syncState & SyncStateInit || syncRecord.syncOptions & SyncOptionsResetSync)
	{
		[self resetSyncIsDone];
	}
	else if ((syncState & SyncStateResendActions) || (syncRecord.syncOptions & SyncOptionsPartialSync))
	{
		//if the server tells us to resend actions, or the client has more actions to send, just do it at once.
		[syncRecord syncComplete];
		[self determineSyncAction:NO];
	}
	else
	{
		[syncRecord syncComplete];
		[self endSyncing];
	}
}

//TODO: you are here: Make sure that ALL items sent are saved in db. This is the bug!
- (BOOL) verifyServerChanges:(NSDictionary*)result
{
	//loop through all tables, and make sure we are fine.
	__block BOOL allChangesFound = YES;
	
	[result enumerateKeysAndObjectsUsingBlock:^(NSString *serverName, NSDictionary *sync, BOOL * _Nonnull stop) {
		NSString *className = serverClientTableMapping[serverName];
		if (!className) return;
		Class tableClass = NSClassFromString(className);
		if (!tableClass || [tableClass isSubclassOfClass:[AutoSync class]] == NO)
		{
			//it always asks about id first, so check class.
			return;
		}
		
		//delete what other clients have deleted
		NSArray *deletions = sync[[@(SyncTypeDelete) stringValue]];
		if (deletions)
		{
			
		}
		
		//create what other clients have created
		NSArray *objects = sync[[@(SyncTypeStatus) stringValue]];
		if (objects)
		{
			
		}
		
		//update new values
		NSDictionary *updates = sync[[@(SyncTypeUpdate) stringValue]];
		if (updates)
		{
			
		}
	}];
	
	return allChangesFound;
}

- (void) handleMissingPayment
{
	self.currentUser.userSettings = [self.currentUser setBitField:self.currentUser.userSettings value:AutoUserSettingSyncingIsOn on:NO];
	self.currentUser.userSettings = [self.currentUser setBitField:self.currentUser.userSettings value:AutoUserSettingSyncingIsPurchased on:NO];
	
	#ifndef TARGET_IS_EXTENSION
	//TODO: FIXME: [NagController presentNaggerWithType:NagTypeSubscription];
	#endif
}

#pragma mark - update local db from sync

- (void) updateServerReply:(NSDictionary*)result
{
	//delete those we sent in (if any)
	NSDictionary *deleteIds = syncRecord.deleteTables;
	[deleteIds enumerateKeysAndObjectsUsingBlock:^(NSString *serverName, NSArray* ids, BOOL * _Nonnull stop) {
		
		NSString *className = serverClientTableMapping[serverName];
		[self syncDelete:ids className:className notifyAndClear:NO];
	}];
	syncRecord.deleteTables = nil;	//only delete these once
	
	//Then loop through all tables, and update values.
	[result enumerateKeysAndObjectsUsingBlock:^(NSString *serverName, NSDictionary *sync, BOOL * _Nonnull stop) {
		//if ([sync.class isKindOfClass:[NSNumber class]]) return;
		NSString *className = serverClientTableMapping[serverName];
		if (!className) return;
		Class tableClass = NSClassFromString(className);
		if (!tableClass || [tableClass isSubclassOfClass:[AutoSync class]] == NO)
		{
			//it always asks about id first, so check class.
			return;
		}
		//also save information to notify the app.
		if (!postUpdated[className])
		{
			postUpdated[className] = [NSMutableArray new];
			postCreated[className] = [NSMutableArray new];
			postDeleted[className] = [NSMutableArray new];
		}
		
		//delete what other clients have deleted
		NSArray *deletions = sync[[@(SyncTypeDelete) stringValue]];
		if (deletions)
		{
			[tableClass deleteIds:deletions];
			[self syncDelete:deletions className:className notifyAndClear:YES];
			if (postDeleted[className])
				[postDeleted[className] addObjectsFromArray:deletions];
			else
				postDeleted[className] = deletions.mutableCopy;
		}
		
		//create what other clients have created
		NSArray *objects = sync[[@(SyncTypeStatus) stringValue]];
		if (objects)
		{
			@autoreleasepool { [self syncStatus:objects tableClass:tableClass className:className]; }
		}
		
		//update new values
		NSDictionary *updates = sync[[@(SyncTypeUpdate) stringValue]];
		if (updates)
		{
			@autoreleasepool{ [self syncUpdate:updates tableClass:tableClass className:className]; }
		}
	}];
	
	[AutoModel saveAllWithChanges:nil];
}

//we still need to take care of this here, since objects we delete cannot exist in the cache.
- (void) syncDelete:(NSArray*)ids className:(NSString*)className notifyAndClear:(BOOL)notifyAndClear
{
	if (!ids)
		return;
	[syncRecord deleteIds:ids forClass:className];
	Class tableClass = NSClassFromString(className);
	[tableClass executeInDatabase:^(FMDatabase * _Nonnull db) {
		[db executeUpdate:[NSString stringWithFormat:@"DELETE FROM %@ WHERE id IN (%@)", className, [AutoModel questionMarks:ids.count]] withArgumentsInArray:ids];
	}];
	if (notifyAndClear)
	{
		[[tableClass tableCache] syncPerformBlock:^(NSMapTable * _Nonnull table) {
			for (NSNumber *idValue in ids)
			{
				AutoModel *object = [table objectForKey:idValue];
				if (object && !object.is_deleted)
				{
					[object willBeDeleted];
					object.is_deleted = YES;
					[table removeObjectForKey:idValue];
				}
			}
		}];
		[[NSNotificationCenter defaultCenter] postNotificationName:AutoModelUpdateNotification object:nil userInfo:@{ className : @{ @"delete" : ids }}];
	}
}

//Create or refresh from server
- (void) syncStatus:(NSArray*)serverData tableClass:(Class)tableClass className:(NSString*)className
{
	NSDictionary <NSString *, NSNumber *>*columnSyntax = [AutoDB.sharedInstance columnSyntaxForClass:tableClass];
	NSMutableArray *columnKeys = columnSyntax.allKeys.mutableCopy;
	NSSet *preventSyncColumns = [tableClass preventSyncColumns];
	if (preventSyncColumns)
	{
		[columnKeys removeObjectsInArray:[preventSyncColumns allObjects]];
	}
	
	NSMutableArray *ids = [NSMutableArray new];
	for (NSDictionary *data in serverData)
	{
		[ids addObject:data[@"id"]];
	}
	
	NSMutableSet *presidentColumns = [tableClass localColumnsTakesSyncingPresident];
	
	//refresh those objects we already have, create the rest.
	NSMutableDictionary *objects = [tableClass fetchIds:ids].dictionary;
	NSMutableDictionary <NSNumber*, NSMutableDictionary*> *createObjects = [NSMutableDictionary new];;
	NSMutableArray *createValues = [NSMutableArray new];
	for (NSMutableDictionary *source in serverData)
	{
		NSMutableDictionary *translatedValues = [tableClass syncTranslateFromServer:source];
		NSNumber *idValue = source[@"id"];
		AutoSync *object = objects[idValue];
		if (object.sync_state & AutoSyncStateNotCreated)
			[object setPrimitiveValue:@(AutoSyncStateRegular) forKey:@"sync_state"];
		
		if (!object)
		{
			//new objects must check their unique values first, if they have any.
			translatedValues[@"id"] = idValue;
			createObjects[idValue] = translatedValues;
			continue;
		}
		
		//Merge with our records, if we have changed these columns we overwrite them the next time we send stuff to the server.
		[syncRecord mergeValues:translatedValues presidentColumns:presidentColumns id:object.idValue forClass:className];
		
		//we had this object, so update it - but only db, we don't want to write this to the syncRecords
		[postUpdated[className] addObject:idValue];
		[self syncPerformUpdate:object merge:translatedValues syntax:columnSyntax];
	}
	
	if (createObjects.count)
	{
		[tableClass handleUniqueValues:createObjects];
		[createObjects enumerateKeysAndObjectsUsingBlock:^(NSNumber *idValue, NSMutableDictionary *translatedValues, BOOL * _Nonnull stop) {
			
			for (NSString* column in columnKeys)
			{
				id value = translatedValues[column];
				if (value) [createValues addObject:value];
				else [createValues addObject:[NSNull null]];
			}
			[postCreated[className] addObject:idValue];
		}];
	}
	
	//Save and notify UI
	if (objects.count)
		[tableClass save:objects.allValues completion:nil];	//this will write to disc our invisble changes
	if (createObjects.count)
	{
		//TODO: This should go into autoDB so it can break up the query in two if needed.
		NSString *columnString = [columnKeys componentsJoinedByString:@","];
		NSString *createQuestionMarks = [AutoModel questionMarksForQueriesWithObjects:createObjects.count columns:columnKeys.count];
		NSString *insertQuery = [NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ (%@) VALUES %@", className, columnString, createQuestionMarks];
		[tableClass executeInDatabase:^(FMDatabase * _Nonnull db) {
			
			BOOL success = [db executeUpdate:insertQuery withArgumentsInArray:createValues];
			if (!success)
			{
				NSLog(@"could not create objects! Sync will fail forever! %@", [db lastError]);
			}
		}];
	}
	
	//Update the db last, in case you have missed something.
	if (syncRecord.syncOptions & (SyncOptionsResetSync|SyncOptionsInitSync))
	{
		[tableClass executeInDatabase:^(FMDatabase * _Nonnull db) {
			
			[db executeUpdate:[NSString stringWithFormat:@"UPDATE %@ SET sync_state = 0 WHERE id IN (%@)", className, [AutoModel questionMarks:ids.count]] withArgumentsInArray:ids];
		}];
		//also update the cache
		[[tableClass tableCache] asyncExecuteBlock:^(NSMapTable * _Nonnull table) {
			for (AutoSync* object in table.objectEnumerator.allObjects)
			{
				if (object.sync_state & 1)
				{
					[object setPrimitiveValue:@(AutoSyncStateRegular) forKey:@"sync_state"];
				}
			}
		}];
	}
}

- (void) syncUpdate:(NSDictionary*)updates tableClass:(Class)tableClass className:(NSString*)className
{
	NSMutableArray *ids = [NSMutableArray new];
	NSMutableDictionary *data = [NSMutableDictionary new];
	
	//These ids are all strings because JSON
	[updates enumerateKeysAndObjectsUsingBlock:^(NSString* idString, NSArray *changes, BOOL * _Nonnull stop) {
		
		NSMutableDictionary *result = nil;
		for (NSString *changeString in changes)
		{
			//sync data comes in as JSON - decode that
			NSMutableDictionary *change = [NSJSONSerialization JSONObjectWithData:[changeString dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:nil];
			if (!change)
			{
				NSLog(@"error with JSON: %@", changeString);
				continue;
			}
			//now we must also use each class own server-client translations
			NSMutableDictionary *translatedData = [tableClass syncTranslateFromServer:change];
			if (!result) result = translatedData;
			else
				[result addEntriesFromDictionary:translatedData];
		}
		//Now all values are coalesced, store as one change-dict
		NSNumber *idValue = @([idString integerValue]);
		[ids addObject:idValue];
		data[idValue] = result;
	}];
	NSDictionary <NSString *, NSNumber *>*columnSyntax = [AutoDB.sharedInstance columnSyntaxForClass:tableClass];
	NSSet *presidentColumns = [tableClass localColumnsTakesSyncingPresident];
	NSArray *objects = [tableClass fetchIds:ids].rows;
	
	for (AutoSync *object in objects)
	{
		NSMutableDictionary *translatedValues = data[object.idValue];
		[syncRecord mergeValues:translatedValues presidentColumns:presidentColumns id:object.idValue forClass:className];
		[self syncPerformUpdate:object merge:translatedValues syntax:columnSyntax];
	}
	//save changes!
	[tableClass save:objects completion:nil];
	[postUpdated[className] addObjectsFromArray:ids];
}

- (void) syncPerformUpdate:(AutoSync*)object merge:(NSDictionary *)mergeValues syntax:(NSDictionary <NSString *, NSNumber *>*)columnSyntax
{
	if (!mergeValues)
	{
		return;
	}
	for (NSString *column in mergeValues)
	{
		NSNumber *syntax = columnSyntax[column];
		if (syntax)
		{
			//merge these values:
			id value = mergeValues[column];
			if (value == [NSNull null])
			{
				//It works! NSLog(@"testing null!");
				[object setPrimitiveValue:nil forKey:column];
			}
			else if (syntax.integerValue == AutoFieldTypeDate)
				[object setPrimitiveValue:[NSDate dateWithTimeIntervalSince1970:[value doubleValue]] forKey:column];
			else
				[object setPrimitiveValue:value forKey:column];
		}
		else
			NSLog(@"error, trying to set a column that don't exist: %@ value: %@", column, mergeValues[column]);
	}
}

#pragma mark - error handling

- (BOOL) handleServerError:(NSDictionary*)result
{
	//mark classes NOT in here as complete
	NSDictionary *error = result[@"error"];
	if (!error)
	{
		return NO;
	}
	NSLog(@"error became %@ - we are rebuilding error handling", error);
	
	//if table has on update-errors, OR no errors at all - remove it!
	for (NSString *serverTable in error)
	{
		BOOL hasUpdateError = NO;
		BOOL hasCreateError = NO;
		for (NSDictionary *errorDict in error[serverTable])
		{
			SyncError code = [errorDict[@"code"] integerValue];
			if (code == SyncErrorUpdateResync || code == SyncErrorDuplicateValues || code == SyncErrorFailUpdate)
			{
				hasUpdateError = YES;
			}
			if (code == SyncErrorCreate || code == SyncErrorDuplicateCreate || code == SyncErrorDuplicateCreateUniqueValues)
			{
				hasCreateError = YES;
			}
		}
		if (hasUpdateError == NO)
		{
			NSString *className = serverClientTableMapping[serverTable];
			[syncRecord syncUpdatedComplete:className];
		}
		if (hasCreateError == NO)
		{
			NSString *className = serverClientTableMapping[serverTable];
			[syncRecord syncCreatedComplete:className];
		}
	}
	
	__block BOOL needResync = NO;
	[error enumerateKeysAndObjectsUsingBlock:^(NSString *serverTable, NSArray* errors, BOOL * _Nonnull stop) {
		
		NSString *className = serverClientTableMapping[serverTable];
		Class tableClass = NSClassFromString(className);
		for (NSDictionary *error in errors)
		{
			SyncError code = [error[@"code"] integerValue];
			switch (code)
			{
				case SyncErrorDuplicateCreateUniqueValues:
				{
					//we have sent in duplicates - this won't do!
					//sometimes we get back already created values - so both unique constraints AND id is the same
					//Other times only unique constraints, meaning two clients manages to create the same item at the same time (this is actually more likely than it sounds).
					[syncRecord markAsCreated:error[@"values"] forClass:className];
					needResync = YES;
					break;
				}
				//these we send off to the classes to deal with
				case SyncErrorDuplicateCreate:
				{
					//creating one or more items with a taken id - this can still be a duplicate, like with config where there should only be one.
					NSArray *ids = error[@"values"];
					if (ids)
					{
						if ([tableClass shouldMoveIdForDuplicateCreate:ids])
						{
							[self moveIdForTable:className andIds:ids toNewIds:nil];
						}
						else
						{
							[syncRecord markAsCreated:ids forClass:className];
						}
					}
					needResync = YES;
				}
				break;
					
				case SyncErrorCreate:
					NSLog(@"Sync create error - server broken!");
				break;
					
				case SyncErrorDuplicateValues: //updating one or more objects with the same unique value
					[tableClass syncErrorDuplicateValue:error[@"values"]];
					needResync = YES;
				break;
				//these we handle ourselves
				case SyncErrorNoAffect:
					//not used anymore
				break;
				case SyncErrorUpdateResync:
					//updating already changed objects we need to merge with server values before resyncing!
					//just merge and resync!
					needResync = YES;
				break;
				case SyncErrorMissingColumns:
					//never happens
					NSLog(@"Sync setup error - wrong server table name or server broken!");
				break;
				case SyncErrorDeleteMissingValues:
					//You are sending in an empty array to delete. Probably bug
					NSLog(@"You are sending in an empty array to delete. Probably bug");
				break;
				default:
					NSLog(@"handle NEW error %@", error);
					break;
			}
		}
	}];
	
	if (needResync)
	{
		NSLog(@"resync!");
		resyncCount++;
		if (DEBUG)
		{
			//Tests need to know if we call resync, but no one else should care
			[[NSNotificationCenter defaultCenter] postNotificationName:@"SYNC_CALL_RESYNC" object:nil userInfo:nil];
		}
		return YES;
	}
	return NO;
}

- (void) moveIdForTable:(NSString*)tableName andIds:(NSArray*)ids toNewIds:(NSMutableArray*)newIds
{
	if (!ids)
		return;
	Class tableClass = NSClassFromString(tableName);
	//Since we already have our ORM, all objects has a reference in the tableCache, so it is easy to modify all objects underneath any other class that might have them.
	
	//we must remember what objects have been changed
	NSMutableDictionary *allChanges = [NSMutableDictionary new];
	
	//get related tables on the form [{otherTable : our_id_column_name }, ...]
	NSArray *relationList = [AutoDB.sharedInstance listRelations:tableName];
	//TODO: we need to test relationships too!
	for (NSNumber *oldId in ids)
	{
		__block NSNumber *newId = nil;
		NSString *query = [NSString stringWithFormat:@"SELECT count(*) FROM %@ WHERE id = ?", tableName];
		[tableClass inDatabase:^(FMDatabase * _Nonnull db) {
			
			while (newIds == nil)	//skip this if you already know the ids.
			{
				newId = @(generateRandomAutoId());
				FMResultSet *result = [db executeQuery:query, newId];
				[result next];
				[result close];
				if ([result[0] integerValue] > 0)
					continue;
				else
					break;
			}
			if (newIds)
			{
				newId = newIds.firstObject;
				[newIds removeObjectAtIndex:0];
			}
		
			NSString *query = [NSString stringWithFormat:@"UPDATE %@ SET id = %@ WHERE id = %@", tableName, newId, oldId];
			if ([db executeUpdate:query] == NO)
			{
				NSLog(@"Error, db is now broken. Errors was: %@ with code: %i and message: %@", [db lastError], [db lastErrorCode], [db lastErrorMessage]);
				return;
			}
		}];
		//we have changed the db, now also change our cache and the cached object
		[[tableClass tableCache] syncPerformBlock:^(NSMapTable * _Nonnull tableCache) {
			
			AutoModel *object = [tableCache objectForKey:oldId];
			if (!object) return;
			object.id = newId.integerValue;	//id has no observer
			[tableCache removeObjectForKey:oldId];
			[tableCache setObject:object forKey:newId];
			allChanges[oldId] = newId;
		}];
		//also move the id within syncRecord so nothing goes bananas
		[syncRecord moveId:oldId toId:newId forClass:tableName];
		
		for (NSDictionary *relation in relationList)
		{
			for (NSString *otherTable in relation)
			{
				NSString *ourIdColumn = relation[otherTable];
				NSMutableSet *modifiedIds = [NSMutableSet new];
				
				Class otherTableClass = NSClassFromString(otherTable);
				[otherTableClass inDatabase:^(FMDatabase * _Nonnull db) {
					
					NSString *query = [NSString stringWithFormat:@"UPDATE %@ SET %@ = %@ WHERE %@ = %@", otherTable, ourIdColumn, newId, ourIdColumn, oldId];
					//NSLog(@"query %@", query);
					if ([db executeUpdate:query] == NO)
					{
						NSLog(@"Error, db is now broken. Errors was: %@ with code: %i and message: %@", [db lastError], [db lastErrorCode], [db lastErrorMessage]);
					}
					
					//add all ids from the other tables
					query = [NSString stringWithFormat:@"SELECT id FROM %@ WHERE %@ = %@", otherTable, ourIdColumn, newId];
					//NSLog(@"query %@", query);
					FMResultSet *result = [db executeQuery:query];
					while ([result next])
					{
						[modifiedIds addObject:result[0]];
					}
					[result close];
				}];
				
				[[otherTableClass tableCache] asyncExecuteBlock:^(NSMapTable * _Nonnull tableCache) {
					
					for (NSNumber *idValue in modifiedIds)
					{
						AutoModel *object = [tableCache objectForKey:idValue];
						if (!object) return;
						[object setPrimitiveValue:newId forKey:ourIdColumn];
					}
				}];
			}
		}
	}
	
	dispatch_async(dispatch_get_main_queue(), ^(void)
	{
		//we send a notification about the changes, it may not be possible to acess the db, but you may refresh the GUI (cached objects have new data).
		[[NSNotificationCenter defaultCenter] postNotificationName:AutoModelPrimaryKeyChangeNotification object:nil userInfo:@{tableName: allChanges}];
	});
}

@end
