//
//  AutoSyncRecord.h
//  rss
//
//  Created by Olof Thorén on 2019-06-14.
//  Copyright © 2019 Aggressive Development AB. All rights reserved.
//

#import "AutoModel.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, SyncOptions)
{
	SyncOptionsInitSync = 1,
	SyncOptionsResetSync = 1 << 1,	//syncing from scratch, make sure to uncheck all items on server, and create all others.
	///If we have more data to send, we set this flag to continue sending until all is done.
	SyncOptionsPartialSync = 1 << 2,
};

///The sync record is book-keeping to keep track of what should be sent to sync, and what we have sent.
@interface AutoSyncRecord : AutoModel

@property (nonatomic) SyncOptions syncOptions;
///The max amount of items to sync each time, limit this if items get large...
@property (nonatomic) NSUInteger currentSyncAmount, maxSyncAmount, minSyncAmount;
@property (nonatomic, nullable) NSData *data;
@property (nonatomic, nullable) NSString *apiURL;
@property (nonatomic) NSNumber *change_id;
@property (nonatomic, nullable) NSDictionary* deleteTables;

///We want a easier way to keep track of sync-state. So whenever something is changed, that object adds its id to the changed table ids. Then when starting syncing we can copy these ids and clear out the arrays - so if something is changed/created while syncing those changes won't get missed.
- (NSMutableDictionary<NSString*, NSMutableArray<NSNumber*> *> *) startCreateSync;
- (NSMutableDictionary<NSString*, NSMutableDictionary<NSNumber*, NSMutableSet*> *> *) startUpdateSync;

///Remove everything before resyncing, and add it back later.
- (void) setupResync;
- (void) syncCreatedComplete:(NSString*)tableClass;
- (void) syncUpdatedComplete:(NSString*)tableClass;
- (void) syncComplete;
///When getting continue_sync the server has only regarded deleted ids, so we need to send any actions again.
- (void) reimburseActions;

- (void) deleteIds:(NSArray*)ids forClass:(NSString*)tableClass;
//managed by the handler
- (void) bulkAddCreatedIds:(NSArray <NSNumber*>*)bulkIds forClass:(NSString*)tableClass;
- (void) addCreatedId:(NSNumber*)id forClass:(NSString*)tableClass;
- (void) swapCreatedId:(NSNumber*)idValue withOldId:(NSNumber*)oldIdValue forClass:(NSString*)tableClass;
- (void) addUpdatedId:(NSNumber*)id value:(id)value column:(NSString*)column forClass:(NSString*)tableClass;
- (void) mergeValues:(NSMutableDictionary*)translatedValues presidentColumns:(NSSet*)presidentColumns id:(NSNumber*)idValue forClass:(NSString*)tableClass;
- (void) moveId:(NSNumber*)oldId toId:(NSNumber*)newId forClass:(NSString*)tableClass;
- (void) markAsCreated:(NSArray*)ids forClass:(NSString*)tableClass;

@end

NS_ASSUME_NONNULL_END
