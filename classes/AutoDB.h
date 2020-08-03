//
//  AutoDB.h
//  AutoDB
//
//  Created by Olof Thorén on 2018-08-30.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

@import Foundation;
#import "AutoModel.h"


#ifndef DEBUG
	#define DEBUG 0
#endif

#define AUTO_WAIT_FOR_SETUP if (!self->isSetup) [self->setupLockQueue.thread syncPerformBlock:^{}];
#define AutoDBIsSetupNotification @"AutoDBIsSetupNotification"

/**
 A database manager
 */

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MigrationState)
{
	MigrationStateError,
	MigrationStateStart,
	MigrationStateComplete
};
typedef void (^MigrationBlock)(MigrationState state, NSMutableSet * _Nullable willMigrateTables, NSArray <NSError*>* _Nullable migrationErrors);

@interface AutoDB : NSObject

+ (instancetype) sharedInstance;
@property (class, nonatomic, readonly) AutoDB *sharedInstance;

///Use only for testing, will destroy DB-connections and remove all info. Cancels and kills all threads, if you have lingering queries the app will die.
- (void) destroyDatabase;

/**
 Create database by supplying a path (supply nil for the default path, in applicationSupportDirectory that will be backed up). It will find all available classes for you.
 @arg migrateBlock is called if there will be migration with "start" state and a set of tables that will be migrated and/or after processing with "complete" state. If there are any errors, the third parameter will contain those. This means that the block can be called twice.
 @note The DB has locks so you can query the database while migration is taking place (you will just have to wait until it's done). BUT: You must call this on the main thread - before creating any new objects/fetches.
 A good practice is to call this method first at startup, it will leave the main thread as soon as possible and setup your DB in the background.
 */
- (void) createDatabaseMigrateBlock:(nullable MigrationBlock)migrateBlock;
/**
 @arg location Specify some other path for the DB.
 if you want to limit the classes used for the db, specify those in specificClassNames.
 
 @arg migrateBlock is called if there will be migration with "start" state and a set of tables that will be migrated and/or after processing with "complete" state. If there are any errors, the third parameter will contain those. This means that the block can be called twice.
 @note The DB has locks so you can query the database while migration is taking place (you will just have to wait until it's done). BUT: You must call this on the main thread - before creating any new objects/fetches.
 A good practice is to call this method first at startup, it will leave the main thread as soon as possible and setup your DB in the background.
 */
- (void) createDatabase:(nullable NSString*)location withModelClasses:(nullable NSArray<NSString*>*)specificClassNames migrateBlock:(nullable MigrationBlock)migrateBlock;

/**
 You can also separate the db's tables into different files, which can be faster (only slightly) but sometimes necessary e.g. when backing up to iCloud - so temporary data can be stored in a non-backed up location and while other tables still get backed up.
 Create extra files for specific classes by defining those paths and classes in the pathsForClasses dictionary.
 */
- (void) createDatabaseWithPathsForClasses:(nullable NSDictionary <NSString*, NSArray <NSString*>*>*)pathsForClassNames migrateBlock:(nullable MigrationBlock)migrateBlock;

- (NSArray <NSString *>*) columnNamesForClass:(Class)classObject;
- (NSDictionary <NSString *, NSNumber *>*) columnSyntaxForClass:(Class)classObject;
- (NSDictionary <NSString*, NSDictionary*> *) tableSyntaxForClass:(NSString*)classString;

//return all table names in use.
- (nonnull NSArray *) tableNames;
///list relations to this table from all other model classes
- (nonnull NSArray*) listRelations:(NSString*)tableName;

///Get the cached SELECT query (without WHERE) for an autoModel class. (ends with an extra space so you can easily append your WHERE).
- (NSString*) selectQuery:(Class)classObject;

///fetch only certain values, return a dictionary with the result (id is key), since we can't have ordering anyway.
/// @param translateDates YES will give you dates as NSDate, otherwise NSNumber (timestamp)
- (NSMutableDictionary <NSNumber*, NSMutableDictionary*> *) valuesForColumns:(NSMutableDictionary<NSNumber*, NSMutableSet*> *)idsWithColumns class:(Class)classObject translateDates:(BOOL)translateDates;

//These methods must be implemented by the sync engine
+ (void) mainSync;
+ (void) setupSync:(NSDictionary <NSString*, NSArray <NSString*>*> *)pathsForClassNames;



@end

NS_ASSUME_NONNULL_END
