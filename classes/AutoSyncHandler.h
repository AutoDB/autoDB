//
//  AutoSync.h
//  AutoDB
//
//  Created by Olof Thorén on 2014-07-28.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.
//


#import "ADBackgroundDownload.h"
//#import "AutoSync.h"

typedef NS_ENUM(NSUInteger, SyncType)
{
	SyncTypeStatus = 1,
	SyncTypeUpdate = 2,
	SyncTypeDelete = 3,
	SyncTypeCreate = 1
};

typedef NS_ENUM(NSUInteger, SyncState)
{
	SyncStateRegular = 1,
	SyncStateResendActions = 1 << 1,
	SyncStateInit = 1 << 2,
};

NS_ASSUME_NONNULL_BEGIN

@class AutoUser;
/**

*/
@interface AutoSyncHandler : NSObject
{}

//allSyncClasses must be grouped by file, so we can fetch as much as possible per query.
@property (nonatomic, nullable) NSArray <NSArray <NSString*>*> *syncClasses;
@property (nonatomic, nullable) NSDate *lastSyncDate;
//@property (nonatomic) NSUInteger lastSyncStatus;
@property (nonatomic, nullable) NSURL *apiURL;
///Temporary prevent autoSync, for testing or in certain critical segments.
@property (nonatomic) BOOL preventAutoSync;
///tell us if we are syncing
@property (nonatomic, readonly) BOOL isSyncing, isInitSyncing;
@property (nonatomic) AutoUser *currentUser;	//here only for testing

+ (instancetype) sharedInstance;
+ (void) setupSync:(NSDictionary <NSString*, NSArray <NSString*>*> *)pathsForClassNames;
+ (void) mainSync;

///Determine if we should sync and start syncing
- (BOOL) mainSync;
///For more control over when syncing actually happens you can wait for the semaphore using this.
- (void) waitForSync;
///E.g. when first starting up sync - all local objects must be merged with existing or sent to server for creation.
- (void) initialSync;
///Whenever an object is changed or created, add it to keep track of state and request syncing.
- (void) addCreatedId:(NSNumber*)id forClass:(Class)classObject;
///If you need to swap after saving and getting a new id
- (void) swapCreatedId:(NSNumber*)idValue withOldId:(NSNumber*)oldIdValue forClass:(Class)classObject;
///Whenever an object is changed or created, add it to keep track of state and request syncing.
- (void) addUpdatedId:(NSNumber*)id value:(id)value column:(NSString*)column forClass:(Class)classObject;
///When deleting we might want to do processing, e.g. send deletions at once.
- (void) deleteIds:(NSArray*)ids forClass:(NSString*)classString;
///Move ids, set newIds = nil if you want it to generate new ids itself.
- (void) moveIdForTable:(NSString*)tableName andIds:(NSArray*)ids toNewIds:(nullable NSMutableArray*)newIds;

///request syncing - triggers syncing or delays if many requests come in at the same time.
- (void) requestSyncing;
@end

NS_ASSUME_NONNULL_END
