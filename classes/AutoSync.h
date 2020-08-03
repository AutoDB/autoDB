//
//  AutoSync.h
//  Auto Write
//
//  Created by Olof Thorén on 2014-07-28.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.
//

#import "AutoModel.h"

NS_ASSUME_NONNULL_BEGIN

//sync this often after every user change - new changes restarts the timer.
#define AUTO_SYNC_DELAY 5

///This can be used to refresh UI or similar.
#define AutoSyncDoneNotification @"AutoSyncDoneNotification"
///When user is logged out, e.g. cookie-deletion, server migration etc, we need to stop using this authentication. Since we cannot know if this is due to an error or user request, we ask to re-login.
#define AutoSyncNeedsLogin @"AutoSyncNeedsLogin"
///Before setting up sync we ask to purge old data, so users don't need to send this to the server. You must handle it in the same thread that it was called.
#define AutoSyncRequestDataPurge @"AutoSyncRequestDataPurge"

/*
 This class describes objects that can be synced, and nothing about syncing logic.
 */

typedef NS_ENUM(NSUInteger, SyncError)
{
	SyncErrorDuplicateCreate = 1,
	SyncErrorCreate = 2,	//Could not create probably duplicate values
	SyncErrorMissingColumns = 3,
	SyncErrorUpdateResync = 4,
	SyncErrorDuplicateValues = 5,
	SyncErrorDeleteMissingValues = 6,
	SyncErrorNoAffect = 7,
	SyncErrorFailUpdate = 8,
	SyncErrorGroupPermissions = 9,
	SyncErrorDuplicateCreateUniqueValues = 10,	//setup has gone wrong, you are trying to create items with unique values that already exists.
};

typedef NS_OPTIONS(NSUInteger, AutoSyncState)
{
	AutoSyncStateRegular = 0,
	AutoSyncStateNotCreated = 1,	//when setting up sync you first need to mark all as not created, then unmark what the server has - the ones that are left needs to be created.
};

@interface AutoSyncTranslate : NSObject
@property (nonatomic) NSDictionary* clientToServer, *serverToClient;
@property (nonatomic) NSString *singleJSONKey;
//TODO: implement multiple JSON
+ (instancetype) clientToServerMapping:(nullable NSDictionary*)clientToServer singleJSONKey:(nullable NSString*)singleJSONKey multipleJSON:(nullable NSDictionary*)multipleJSON;
@end

@interface AutoSync : AutoModel

@property (nonatomic) AutoSyncState sync_state;

///defaults to sync all except is_deleted and sync_state - if subsclassing you must add these columns too
+ (NSSet<NSString*>*)preventSyncColumns;
///Supply a client-server mapping by translating syncData from generated table-as-dictionary
+ (nullable NSMutableDictionary<NSString*, id> *) syncDataToServer:(NSMutableDictionary<NSString*, id>*)dataColumns;
/**
 Convert server representation of table into a regular dictionary of column, we can send directly to DB. Then call super with the same method.
 This makes use of the localColumnsTakesSyncingPresident - if you have local changes, they overwrite server-changes. Otherwise YOUR local changes may be sqashed by server.
**/
+ (NSMutableDictionary*) syncTranslateFromServer:(NSMutableDictionary<NSString*, id>*)data;

/**
 Instead of manually handle translate to and from server, supply a dictionary with translations.
 
 */
+ (nullable AutoSyncTranslate*) syncTranslate;

///Prevent server from overwriting local changes - IFF made after last sync. Must always include is_deleted.
+ (NSMutableSet*) localColumnsTakesSyncingPresident;
//Prevent errors by specifying uniqueColumns, the system checks these when setting up sync to avoid creating duplicate objects
//TODO: This should be handled by the database, not syncing! + (nullable NSArray*) uniqueColumns;

///two clients may have created the same object, but with different ids. You need to move and/or update those objects, otherwise there will be duplicates. Default implementation does nothing.
+ (void) handleUniqueValues:(nonnull NSMutableDictionary <NSNumber*, NSMutableDictionary*>*)createObjects;

///What is the table called on the server?
+ (NSString*) serverTableName;
///When coming back from sync, it may duplicate values error. Those have to be mitigated by each class, since you have to decide manually what to do, if you want to change the value or delete one of the objects. default implementation just deletes the duplicates.
+ (void) syncErrorDuplicateValue:(NSArray*)ids;
///This allows you to decide what to do when creating new objects fails, imagine an id = 1, that should always be 1. You don't want to move that id. Default implementation does not move (overwrites client).
+ (BOOL) shouldMoveIdForDuplicateCreate:(NSArray*)ids;

/**
 Allows each class to handle common sync-errors like duplicates (where these are not allowed), ordering, selected item (e.g. when only one is allowed and the newly synced data has selected another object), or similar errors that can not be handled by the sync-protocol. 
 
 This method is called after all objects have been updated by new server-data but before notifications are sent about changed objects and before new updates are sent to the server.
 
 Default implementation does nothing. It has aquired no locks. 
 */
+ (void) syncDoneWithModifications;

@end


NS_ASSUME_NONNULL_END
