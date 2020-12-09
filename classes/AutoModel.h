//
//  AutoModel.h
//  Simulator
//
//  Created by Olof Thorén on 2014-03-17.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.
//

#include <AvailabilityMacros.h>
@import UIKit;
#import "AutoModel.h"
#import "AFMDatabaseQueue.h"
#import "AutoConcurrentMapTable.h"
#import "AFMDatabase.h"

/*

 SWIFT:
 You must define classes like so:
	@objc(ClassName) ClassName: AutoModel
 where ClassName is the name of the class, and it must be globally unique.
 
 AND ALL properties that is to be inserted into DB must get the prefix:
 @objc dynamic 
 
 NOTE:
 We have moved all needed info to AutoModel_docs. Continue reading and writing there!

 We must wait for db to setup before usage, and we must wait in fifo order, BUT we don't want to wait in queues AFTER setup is done. We only need this when asking for tableInfo which is created during setup - everyhing else is done in queues or dedicated threads. SO: always go through AutoDB's dedicated functions to make sure this is thread-safe (and the info exists).
 */

NS_ASSUME_NONNULL_BEGIN

@class AutoModel;

///An object holding all results from a query, it preserves order and you can also query it by each individual object's id.
///Swift needs rows to be a regular array, while the result will never be changed, so you can just as well use its mutable variants.
@interface AutoResult<__covariant ObjectType>: NSObject <NSCopying>

//TODO: Swift: make ObjectType work inside arrays AND be of the actual type.
//Its complicated... https://www.mikeash.com/pyblog/friday-qa-2015-11-20-covariance-and-contravariance.html
@property (nonatomic) NSMutableArray <ObjectType> *mutableRows;
@property (nonatomic) NSMutableDictionary <NSNumber*, ObjectType> *mutableDictionary;
@property (nonatomic, readonly) NSArray <ObjectType> *rows;
@property (nonatomic, readonly) NSDictionary <NSNumber*, ObjectType> *dictionary;

- (BOOL) hasCreatedDict;
- (void) setObject:(__kindof AutoModel*)object forKey:(nonnull id<NSCopying>)aKey;

@end


#define AUTO_COLUMN_KEY @"COLUMNS"
#define AUTO_RELATIONS_PARENT_ID_KEY @"auto_parent_id"
#define AUTO_RELATIONS_PARENT_OBJECT_KEY @"auto_parent_object"
#define AUTO_RELATIONS_CHILD_CONTAINER_KEY @"auto_child_objects"
#define AUTO_RELATIONS_STRONG_ID_KEY @"auto_strong_id"
#define AUTO_RELATIONS_STRONG_OBJECT_KEY @"auto_strong_object"
#define AUTO_RELATIONS_WEAK_OBJECT_KEY @"auto_weak_object"
#define AUTO_RELATIONS_MANY_ID_KEY @"auto_many_ids"
#define AUTO_RELATIONS_MANY_CONTAINER_KEY @"auto_many_container"

#define AUTO_INDEX_COLUMN @"COLUMN_INDEX"
#define AUTO_INDEX_SPECIFIC @"SPECIFIC_INDEX"

#define AUTO_UNIQUE_COLUMNS @"UNIQUE"
#define AUTO_UNIQUE_COLUMNS_UPDATE @"UNIQUE_UPDATE"

typedef NS_ENUM(NSInteger, AutoFieldType)
{
	AutoFieldTypeText = 0,
	AutoFieldTypeBlob,
	AutoFieldTypeInteger,
	AutoFieldTypeDouble,
	AutoFieldTypeNumber,
	AutoFieldTypeDate,
	AutoFieldTypeUnknown,
};

typedef void(^AutoModelSyncResult)(NSDictionary  * _Nullable  resultSet, NSError * _Nullable error);
typedef void(^AutoResultBlock)(AutoResult<__kindof AutoModel*>* _Nullable resultSet);
typedef void(^AutoModelResultBlock)(NSMutableDictionary* _Nullable resultSet);
typedef void(^AutoModelArrayResultBlock)(NSMutableArray* _Nullable resultSet);
typedef void(^AutoModelSingleResultBlock)(id _Nullable result);	//TODO: figure out how to declare this as a subclass of AutoModel
typedef void(^AutoModelSaveCompletionBlock)(NSError* _Nullable error);
typedef NSString *_Nonnull(^AutoModelGenerateQuery)(void);

typedef void(^DatabaseBlock)(AFMDatabase *db);

//This is not used yet - hopefully we don't build in these types of swizzling: typedef id(^dynamicFunctionBlock)(id object, SEL _cmd);

#define auto_server_id @"auto_server_id"
extern NSString *const primaryKeyName;
///we send a notification about changes, you probably can't acess the db when you get the notifications, but you may refresh the GUI (cached objects have new data).
extern NSString *const AutoModelPrimaryKeyChangeNotification;
///Post a single notification for any update/create/delete for all objects. On the form { class_name : { update : [updated_created_ids], delete: [deleted_ids] } }
extern NSString *const AutoModelUpdateNotification;
///small function to generate a unique global id.
u_int64_t generateRandomAutoId(void);

@interface AutoModel : NSObject
{
	@public
	BOOL hasChanges, ignoreChanges, registerChanges;	//see below
}
/**
 
 All objects must have a unique primary key, that is an int.
 @warning, when using sync the id is just a suggestion until the server approves it. This means that until syncState has not AutoSyncStateCreated, the id may (and probably will) change. If you are using id for anything you must also listen to the AutoModelPrimaryKeyChangeNotification
 */

@property u_int64_t id;
///Use is_deleted when you want to delete objects some point in the future, but keep them in storage until that point. This allow you to keep objects around until you are decision without keeping two databases/tables moving data around.
@property BOOL is_deleted;
@property (nonatomic, nullable) NSMutableDictionary* modifiedColumns;

/**
 registerChanges: classes that observe properties may also register changes. Then modified columns are stored in the modifiedColumns dictionary (which has the old value for when you want to do deltas), by calling this method when something changes.
 Old value can be used when diffing, newValue when syncing.
 */
- (void) registerChange:(NSString*)columnName oldValue:(nullable id)oldValue newValue:(nullable id)newValue;

///Exclude table columns (parameters) from the database table.
+ (nullable NSSet*) excludeParametersFromTable;

///DON'T USE! Supply a string definition of default values (if you don't want 0 or ''). Like this: @{ @"setting" : @"1" }. Default implementation does nothing.
///@note You must also set these values in awakeFromFetch since we don't fetch anything from DB when creating new objects.
///@note Will not work for dates or objects that may be null - just how sqlite works.
+ (nullable NSDictionary*) defaultValues;

///Supply arrays of indexes, use AUTO_INDEX_COLUMN to set an index on a single column. (To be implemented is advanced index statements, AUTO_INDEX_SPECIFIC, a string where you can specify the index yourself).
///@example: return @{ AUTO_INDEX_COLUMN : @[@"indexed_column_name"]};
+ (nullable NSDictionary <NSString*, NSArray <NSString*>*>*) columnIndex;

///Supply arrays of unique constraints, the array one or more arrays with one or more strings. one string make that column unique, otherwise they are unique together.
///@example: return @[ @[@"unique_column"], @[ @"unique_pair_1", @"unique_pair_2" ]]
+ (nullable NSArray <NSArray <NSString*>*>*) uniqueConstraints;

///Use regular AutoIncrement when creating new ids for tables, otherwise a collision free id is generated. If you syncing against a remote db you will want to use a "collision free id", if it's just a local DB leave it as the default (YES).
+ (BOOL) useAutoIncrement;

///If keys from this dictionary exists as columns in the table, they are migrated to the new property. You can switch datatypes with this method, but the old values in the table will not be converted automatically. SQLite clames to have dynamic variables, so I don't think it should be an issue.
+ (nullable NSDictionary*) migrateParameters;
///When migrating columns with one type to another, you can convert existing values of one type to another by looping overt the arrayOfTuples [(id, columnValue), ...] and modifying them as you see fit.
+ (void) migrateTable:(NSString*)table column:(NSString*)column oldType:(AutoFieldType)oldType newType:(AutoFieldType)newType values:(NSMutableArray*)arrayOfTuples;

- (void) setHasFetchedRelations:(BOOL)hasFetched;
- (BOOL) hasFetchedRelations;

#pragma mark - create instances

/**
 Create a new instance, the primary key is either auto-incremented or set to a 60 bit random Integer when saved to db. It's ONLY made sure that it is unique in the local DB. This means that you can't use the primary key for anything until saved to DB.
 @note: It is not saved to db when calling this, so the id is temporary - and might not exist nor be inserted in the cache until saved.
 This is since you rarely need to fetch items that aren't saved (see discussion on temporary objects).
 */
//+ (void) createInstance:(AutoModelSingleResultBlock)resultBlock DEPRECATED_MSG_ATTRIBUTE("does not need the lock anymore, so is pointless");
/**
 Create a new instance (blocking), the primary key is either auto-incremented or set to a 60 bit random Integer when saved to db. It ONLY guarantees to be unique in the local cache. This means that you can't use the primary key for anything until saved to DB.
 @note: It is not saved to db when calling this, so the id is temporary - and might not exist nor be inserted in the cache until saved.
 This is since you rarely need to fetch items that aren't saved (see discussion on temporary objects).
 */
+ (nonnull instancetype) createInstance;

///Create a new instance with specific id, OR fetch old object if it already exists.
+ (void) createInstanceWithId:(u_int64_t)id_field result:(AutoModelSingleResultBlock)resultBlock;
///Blocking call of create instance with id - creates OR fetches old object with specific id.
+ (nonnull instancetype) createInstanceWithId:(u_int64_t)id_field;
///When having a temporary object that you want to store, insert it with this call (a blocking call). This will not save it to db, just prepare for insertion. Might be saved in another thread.
///Note: If you use useAutoIncrement they will get assigned an id after insertion
- (void) insertIntoDB;

#pragma mark - relations

///Relations are specified with a simple dictionary
+ (nullable NSDictionary*) relations;
///List all columns containing an id to another object
+ (nullable NSSet*) relationsIdColumns;

///Fetch relations for a group of objects, this must be called manually if auto-relations are used.
+ (void) fetchRelations:(NSArray*)objects;
///Fetch relations for this object, this must be called manually if auto-relations are used.
- (void) fetchRelations;

#pragma mark - fetching

///Log what's currently in the database cache, this is not a thread safe operation - only to be used for debugging or similar.
//+ (void) printCachedTables;

///called after creation or fetch from DB - only called once. Remember to always call [super awakeFromFetch];
- (void) awakeFromFetch;
///Check to see if an object is awoken or not, to make sure awakeFromFetch only are called once.
- (BOOL) isAwake;

#pragma mark - storing

///save/store to disk, will save the object no matter if it has changes or not.
- (void) saveWithCompletion:(nullable AutoModelSaveCompletionBlock)completion;

///A blocking save method
- (nullable NSError*) save;

///save/store to disk, will save the objects no matter if they have changes or not.
///@note Send a copy of your array if its mutable
+ (void) save:(NSArray*)collection completion:(nullable AutoModelSaveCompletionBlock)completion;

///A blocking variant of save:completion:
+ (nullable NSError*) save:(NSArray*)collection;

/**
 Save/store to disk, save all objects for all classes who have reported changes to database properties acording to KVC/KVO.
 @warning Changes to objects inside collections does not get reported as changes, only insert/replace/remove etc. If you want to use saveAllWithChanges you may need to call setHasChanges manually.
 @warning If you have dependent properties you need to call keyPathsForValuesAffecting<property-name> to get automatic behaviour (like if you store a dictionary in the db under some other property).
 */
+ (void) saveAllWithChanges:(nullable AutoModelSaveCompletionBlock)complete;
///Blocking version of saveAllWithChanges:
+ (nullable NSError *) saveAllWithChanges;
///Save all objects with changes for this class only - if you are using temporary objects, this is helpfull.
+ (void) saveChanges:(nullable AutoModelSaveCompletionBlock)complete;
///Sometimes we don't want to wait for the app to close before saving changes! NOTE: We only get complete callback IF AND ONLY IF, we wasn't throttled (one of them needs to handle all possible errors)...
+ (void) throttleSaveChanges:(AutoModelSaveCompletionBlock _Nullable)complete;
///Blocking version of saveChanges:
+ (nullable NSError *) saveChanges;

#pragma mark - 

///One database queue per file is used for all db connections to avoid thread-problems
+ (AFMDatabaseQueue *) databaseQueue;
///When using temporary files that you want to be inserted into db - call this.
- (void) setIsToBeInserted:(BOOL)isToBeInserted;
- (BOOL) isToBeInserted;

///Shortcut to valueForKey:@"id", wrapping the id into an number
- (NSNumber*) idValue;
///Fast access to each tables cache
+ (AutoConcurrentMapTable *) tableCache;

#pragma mark - perform changes manually

///Async execution of any query thread-safe inside db. This is the preferred method to execute queries in the db, if you are calling from outside AutoDB. 
+ (void) executeInDatabase:(void (^)(AFMDatabase *db))block NS_SWIFT_NAME(executeIn(db:));
///Sync execution of any queries (may be nested), inside db.
+ (void) inDatabase:(DatabaseBlock)block;

#pragma mark - fetch objects and auto-handle cache
/**
 Blocking method to fetch all objects by supplying a regular SQL-query, but excluding column names (and everything before). Eg: "WHERE name LIKE '%hor_n'" to match names like Thorén, or just "ORDER BY name" - to get your results pre-sorted.
 NOTE: You must include "WHERE" (if it has a where-clause), it will not be infered automatically.
 If you supply your arguments as an array - the variable argument list (...) will be ignored, also note that those must be NSObjects.
 @warning If you have cached objects with modified values, this may return the wrong objects. It only fetches based on values saved to disc. If a match is found, and the corresponding object is in the cache, it will return the cached object no matter what values it currently have. Similarly, if an object in the DB does not match but its cached object is matching (due to unsaved recent changes), it will NOT be returned.
 */
//TODO: here I want to specify the current subclass of AutoModel I'm using now. Can it be done? instead of __kindof AutoModel
+ (nullable AutoResult <__kindof AutoModel*>*) fetchQuery:(nullable NSString*)whereQuery arguments:(nullable NSArray*)arguments;
/**
 Non-blocking method to fetch all objects by supplying a regular SQL-query, but excluding column names (and everything before). Eg: "WHERE name LIKE '%hor_n'" to match names like Thorén, or just "ORDER BY name" - to get your results pre-sorted.
 NOTE: You must include "WHERE" (if it has a where-clause), it will not be infered automatically.
 Since this is an async call, you can only use array for your arguments.
 @warning If you have cached objects with modified values, this may return the wrong objects. It only fetches based on values saved to disc. If a match is found, and the corresponding object is in the cache, it will return the cached object no matter what values it currently have. Similarly, if an object in the DB does not match but its cached object is matching (due to unsaved recent changes), it will NOT be returned.
 */
+ (void) fetchQuery:(nullable NSString*)whereQuery arguments:(nullable NSArray*)arguments resultBlock:(AutoResultBlock)resultBlock;

#pragma mark - fetch with ids

///Fetch all objects (of the type of the calling class), by id. Will not fetch objects where is_deleted is set. Automatically detecting if within db or not.
///@note ids can consist of an array of NSNumber or NSString (as long as those strings are numbers e.g. "5").
///@note rows returned may come in any order.
+ (void) fetchIds:(NSArray <NSNumber*>*)ids resultBlock:(AutoResultBlock)resultBlock;

///A blocking version of fetchIds:resultBlock: - it automatically detects if within db or not.
///@note ids can consist of an array of NSNumber or NSString (as long as those strings are numbers e.g. "5").
///@note rows returned may come in any order.
+ (nullable AutoResult<__kindof AutoModel*>*) fetchIds:(NSArray*)ids;

///Same as fetchIds: but for only one id. This looks into the cache before calling fetchIds: which makes it a lot faster if there is only one object
+ (nullable instancetype) fetchId:(NSNumber*)id;
///Async version of fetchId:
+ (void) fetchId:(NSNumber*)id_field resultBlock:(AutoModelSingleResultBlock)result;

/**
 Supply a query which results in only one column of results (the id column), then AutoModel fetches the objects for those ids. There is no error checking, supply the wrong query and get no results.
 The point of this is when you want some more advanced queries. One example to use like a join:
 we have users and groups - you want to fetch users from a certain group. The query is then: "SELECT user_id FROM groups WHERE id = 2" BUT you send this to the user class so it can take those id values resulting from the groups-query and populate a list with model objects.
 @note Don't use this if you can use fetchIds:resultBlock: instead.
 */
+ (void) fetchWithIdQuery:(NSString *)idQuery arguments:(nullable NSArray*)arguments resultBlock:(AutoResultBlock)resultBlock;

/**
 Blocking version of fetchWithIdQuery:
 Supply a query which results in only one column of results (the id column), then AutoModel fetches the objects for those ids. There is no error checking, supply the wrong query and get no results.
 The point of this is when you want some more advanced queries. One example to use like a join:
 we have users and groups - you want to fetch users from a certain group. The query is then: "SELECT user_id FROM groups WHERE id = 2" BUT you send this to the user class so it can take those id values resulting from the groups-query and populate a list with model objects.
 @note Don't use this to fetch objects for known ids, like an array of ids. Then use fetchIds: instead.
 */
+ (nullable AutoResult<__kindof AutoModel*>*) fetchWithIdQuery:(NSString *)idQuery arguments:(nullable NSArray*)arguments;

#pragma mark - delete objects

///willBeDeleted is sent to objects just before they are deleted, so you can delete its related objects or clean up other things. Is only sent to cached objects (who are in use).
///Default implementation only makes sure to set ignoreChanges.
- (void) willBeDeleted;
///delete current object from database and set is_deleted as a signal to everyone using this object. This is an async call.
- (void) deleteAsync:(nullable dispatch_block_t)completeBlock;
///delete current object from database and set is_deleted as a signal to everyone using this object. This is a blocking call.
- (void) delete;
///Shorthand for a blocking delete of an array of objects.
+ (void) delete:(NSArray*)objects;
///Async delete some objects from DB.
+ (void) delete:(NSArray*)objects completeBlock:(nullable dispatch_block_t)completeBlock;

///Batch delete objects when you only know their ids, objects with these ids in the cache will be deleted too. Blocking call.
+ (void) deleteIds:(NSArray*)ids;
///Private method, only for syncing!
+ (void) deleteIdsExecute:(NSArray*)ids;

///Async batch delete objects when you only know their ids, objects with these ids in the cache will be deleted too.
+ (void) deleteIds:(NSArray*)ids completeBlock:(nullable dispatch_block_t)completeBlock;

/** By default you need to handle all your saves yourself.
 Auto DB can watch your properties and mark the objects if they have been changed or not. This does not take particularly more CPU power, since it's just toggling a bool. But it ads all changed objects to a weak hashMap, which has a small/insignificant performance penalty.
 By supplying NO to preventObservingProperties observing is allowed and you can call saveAllWithChanges/saveChanges when apropriate. Like when the app closes or every minute, etc. The reason is that most of the times you know when changes has occured and there is a need for saving, having the system keep tabs on changes is then just an unnecessary memory/cpu cost (so it may actually be benefitial).
 The problem is that it is using a weak map - so all object that you have not tucked away in an array or similar are released and the data is lost.

@warning By default this method prevents saveAllWithChanges to work. You will need to call either save or setHasChanges: manually
 */
+ (BOOL) preventObservingProperties;

/**
 base-method to handle fetch results. It populates objects from DB-resultSets and adds/inserts to a dictionary and array, the array keeps the order and the dictionary gives fast lookup with keys.
 It always uses cached objects if those exists.
 */
+ (nullable AutoResult<__kindof AutoModel*>*) handleFetchResult:(AFMResultSet *)result;

///To set values without triggering changes.
- (void) setPrimitiveValue:(nullable id)value forKey:(NSString*)key;
///Mark this object to be saved at the next call to saveAllWithChanges. When set to NO, it turns on KVO (if not already on) for this objects properties (KVO turns off itself).
- (void) setHasChanges:(BOOL)hasChanges;
- (BOOL) hasChanges;

/**
 Transform objects to dictionaries with strings and numbers
 @param settings can be used to determine the date format or use alternative names. Convienient if you want to build your own syncing/update mechanism. It contains:
 a boolean = settings[@"useUnixTimeStamp"], which determines if dates should be timestamps instead of strings.
 a translations dictionary containing key-value pairs of client_db_name : server_db_name, NSDictionary *translations = settings[@"translate"];
 a set of columns we should ignore and don't send to the server, NSSet *ignore = settings[@"ignore"];
 A key (if it exists it is true) for to show null values or not. [settings objectForKey:@"show_NULL"], instead of NULL you then get a string like this: @"<NULL>"
 */
+ (NSMutableArray*) dictionaryRepresentation:(NSArray*)objects settings:(NSDictionary*)settings;

/**
 Supply a list of ids that should be present in the table, all that are missing from the list should be deleted.
 @return a list of the ids you supplied and think exists in the table, but are actually missing from the table.
 
 Discussion:
 Perhaps this scheme is not too good. Perhaps it should be moved over to a dedicated sync class? There is a lot of class methods now.
 I think its good, we often want to delete stuff absent from a list.
 TODO: Change the name of this function so you understand that it returns ids we should fetch again (that are missing).
 */
+ (nullable NSArray*) deleteMissingIds:(nonnull NSArray*)ids;

#pragma mark - helpers

///Create questionmarks for SQL queries, return amount ?.
+ (NSString*) questionMarks:(NSInteger)amount;
///Create questonMarks for groups, like this: We want the format to be "INSERT INTO table (column1, column2) VALUES (?,?),(?,?),(?,?)", and then add an array with four values. Here objectCount = 3, columnCount = 2. The result becomes @"(?,?),(?,?),(?,?)"
+ (NSString*) questionMarksForQueriesWithObjects:(NSInteger)objectCount columns:(NSInteger)columnCount;

///Beginning of making setting and getting values from bitFields (enums) automatic. All bitField types should be able to respond to/like this. (as [object configIsSet:value] or [object setConfig:value on:on])
- (BOOL) bitField:(NSUInteger)bitField isSet:(NSUInteger)value;
///Beginning of making setting and getting values from bitFields (enums) automatic.
- (NSUInteger) setBitField:(NSUInteger)bitField value:(NSUInteger)value on:(BOOL)on;
+ (NSUInteger) setBitField:(NSUInteger)bitField value:(NSUInteger)value on:(BOOL)on;

///return an array with all values in the table for a (the first) column.
+ (nullable NSMutableArray*) groupConcatQuery:(nonnull NSString*)query arguments:(nullable NSArray*)arguments;

///return the result of a query as an arrary of dictionaries with their values - without any parent objects created (or other related data), just the raw values in an array.
+ (nullable NSMutableArray*) arrayQuery:(NSString*)query arguments:(nullable NSArray*)arguments;

///return the result of a query as a dictionary (with id as key if key is null) of dictionaries with their values - without any parent objects created (or other related data), just the raw values in an array.
+ (nullable NSMutableDictionary*) dictionaryQuery:(NSString*)query key:(nullable NSString*)key arguments:(nullable NSArray*)arguments;

///return the first row of a result from a query as a dictionary of their values - without any parent objects created (or other related data), just the raw values in a dictionary.
+ (nullable NSDictionary*) rowQuery:(NSString*)query arguments:(nullable NSArray*)arguments;

///return a single value (the first) from a query.
+ (nullable id) valueQuery:(NSString*)query arguments:(nullable NSArray*)arguments;
///cache statement and query strings with this simple method, the actual creation of the query happens in the createBlock which is only called if needed.
///The query string is returned since we usually don't need to bother with FMStatements (which is doing the caching).
+ (NSString*) cachedQueryForSignature:(NSString*)signature objects:(NSUInteger)count createBlock:(AutoModelGenerateQuery)createBlock;

@end

typedef NS_ENUM(NSUInteger, StatementType)
{
	StatementTypeInsertWithoutId = 0,
	StatementTypeInsertUsingId,
	StatementTypeUpdate
};

///A class to cache create statements and their columns, in part so we don't need to generate them over and over, but mostly to make the code simpler and more readable.
@interface AutoInsertStatement : NSObject <NSCacheDelegate>
{ }

@property (nonatomic) NSArray *columns;
@property (nonatomic) NSArray *columnsWithoutId;
@property (nonatomic) NSString *classString;
@property (nonatomic) Class modelClass;
@property (nonatomic) AutoConcurrentMapTable *tableCache;

+ (instancetype) statementForClass:(Class)class andClassString:(NSString*)classString;
///Thread safe by not using owned arrays
- (NSMutableArray*) createParametersForObjects:(NSArray*)objectsToCreate hasId:(BOOL)hasId;
- (nullable NSError*) insertObjects:(nullable NSArray*)objects objectsWithoutId:(nullable NSArray*)objectsWithoutId updateObjects:(nullable NSArray*)updateObjects inDatabase:(AFMDatabase *)db;
@end

//We need a smart and consistent way to cache queries, statements and their keys. I don't want to generate the same stringly keys over and over again when fetching items from db. Also, we will do this many - many times, so having a dedicated class / system to handle this for us will pay off. And it makes things more clear.
@interface AutoModelCacheHandler : NSObject

+ (instancetype) sharedInstance;
///Get the key for your function-signature, e.g. insert queries can be called "insert"
- (NSString*) keyForFunction:(NSString*)functionSignature objects:(unsigned long)amount class:(Class)classObject;


@end


NS_ASSUME_NONNULL_END

/*
 
 some random info:
 
 List all sqlite table: .tables
 .schema <table_name>
 
 select * FROM AlcoveDocumentDb;
 
 //journaling must be off, of some strange reason.
 PRAGMA journal_mode = OFF;
 update AlcoveDocumentDb set sync_state = 2 where id = 36698364672804332;
 
 */
