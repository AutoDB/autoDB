//
//  AFMDatabaseQueue.h
//  fmdb
//
//  Created by August Mueller on 6/22/11.
//  Copyright 2011 Flying Meat Inc. All rights reserved.
//

@import Foundation;
#import "sqlite3.h"

@class AFMDatabase;

/** To perform queries and updates on multiple threads, you'll want to use `AFMDatabaseQueue`.

 AFMDatabase is a renamed copy of FMDatabase in case you want to bundle your own version of FMDatabaseQueue.
 There are a few differences:
 1. The code is easier to read.
 2. Several critical bug fixes.
 3. Some rarely used methods are removed or hidden (to de-clutter auto-complete).
 
 Using a single instance of `<FMDatabase>` from multiple threads at once is a bad idea.  It has always been OK to make a `<FMDatabase>` object *per thread*.  Just don't share a single instance across threads, and definitely not across multiple threads at the same time.

 Instead, use `AFMDatabaseQueue`. Here's how to use it:

 First, make your queue.

    AFMDatabaseQueue *queue = [AFMDatabaseQueue databaseQueueWithPath:aPath];

 Then use it like so:

    [queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"INSERT INTO myTable VALUES (?)", [NSNumber numberWithInt:1]];
        [db executeUpdate:@"INSERT INTO myTable VALUES (?)", [NSNumber numberWithInt:2]];
        [db executeUpdate:@"INSERT INTO myTable VALUES (?)", [NSNumber numberWithInt:3]];

        FMResultSet *rs = [db executeQuery:@"select * from foo"];
        while ([rs next]) {
            //…
        }
    }];

 An easy way to wrap things up in a transaction can be done like this:

    [queue inTransaction:^(FMDatabase *db, BOOL *rollback) {
        [db executeUpdate:@"INSERT INTO myTable VALUES (?)", [NSNumber numberWithInt:1]];
        [db executeUpdate:@"INSERT INTO myTable VALUES (?)", [NSNumber numberWithInt:2]];
        [db executeUpdate:@"INSERT INTO myTable VALUES (?)", [NSNumber numberWithInt:3]];

        if (whoopsSomethingWrongHappened) {
            *rollback = YES;
            return;
        }
        // etc…
        [db executeUpdate:@"INSERT INTO myTable VALUES (?)", [NSNumber numberWithInt:4]];
    }];

 `AFMDatabaseQueue` will run the blocks on a serialized queue (hence the name of the class).  So if you call `AFMDatabaseQueue`'s methods from multiple threads at the same time, they will be executed in the order they are received.  This way queries and updates won't step on each other's toes, and every one is happy.

 ### See also

 - `<FMDatabase>`

 @warning Do not instantiate a single `<FMDatabase>` object and use it across multiple threads. Use `FMDatabaseQueue` instead.
 
 @warning The calls to `AFMDatabaseQueue`'s methods are blocking.  So even though you are passing along blocks, they will **not** be run on another thread.

 */

@interface AFMDatabaseQueue : NSObject
{
    NSString            *_path;
    int                 _openFlags;
}

//@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) NSThread *thread;
@property (atomic, retain) NSString *path;
@property (atomic, readonly) int openFlags;

///----------------------------------------------------
/// @name Initialization, opening, and closing of queue
///----------------------------------------------------

/** Create queue using path.
 
 @param aPath The file path of the database.
 
 @return The `AFMDatabaseQueue` object. `nil` on error.
 */

+ (instancetype)databaseQueueWithPath:(NSString*)aPath;

/** Create queue using path and specified flags.
 
 @param aPath The file path of the database.
 @param openFlags Flags passed to the openWithFlags method of the database
 
 @return The `AFMDatabaseQueue` object. `nil` on error.
 */
+ (instancetype)databaseQueueWithPath:(NSString*)aPath flags:(int)openFlags;

/** Create queue using path.

 @param aPath The file path of the database.

 @return The `AFMDatabaseQueue` object. `nil` on error.
 */

- (instancetype)initWithPath:(NSString*)aPath;

/** Create queue using path and specified flags.
 
 @param aPath The file path of the database.
 @param openFlags Flags passed to the openWithFlags method of the database
 
 @return The `AFMDatabaseQueue` object. `nil` on error.
 */

- (instancetype)initWithPath:(NSString*)aPath flags:(int)openFlags;

/** Returns the Class of 'FMDatabase' subclass, that will be used to instantiate database object.
 
 Subclasses can override this method to return specified Class of 'FMDatabase' subclass.
 
 @return The Class of 'FMDatabase' subclass, that will be used to instantiate database object.
 */

+ (Class)databaseClass;

/** Close database used by queue. */

- (void) close;
///Close and prevent automatic re-open. This is useful for extensions who may corrupt data if killed.
- (void) closeAndPreventReopen;
///Must be called when you want the db to reopen again.
- (void) allowReopen;
///When going background and you share the DB between other processes (like an extension), you need to always close the DB after accessing it - this closes it after every query so make sure to only use it when needed (eg saving bg-downloads, etc).
///Does not work with transactions (yet).
- (void) autoClose: (BOOL)autoClose;
- (BOOL) isClosed;

///-----------------------------------------------
/// @name Dispatching database operations to queue
///-----------------------------------------------

/** Synchronously perform database operations on queue.
 
 @param block The code to be run on the queue of `AFMDatabaseQueue`
 */

- (void)inDatabase:(void (^)(AFMDatabase *db))block;

/**
 enqueue a block of operations on queue.
 */
- (void)asyncExecuteDatabase:(void (^)(AFMDatabase *db))block;

///get the underlying db, only use this if you are inside the queue or certain that multithreading won't cause errors.
- (AFMDatabase*) database;

/** Synchronously perform database operations on queue, using transactions.

 @param block The code to be run on the queue of `AFMDatabaseQueue`
 */

- (void)inTransaction:(void (^)(AFMDatabase *db, BOOL *rollback))block;

/** Synchronously perform database operations on queue, using deferred transactions.

 @param block The code to be run on the queue of `AFMDatabaseQueue`
 */

- (void)inDeferredTransaction:(void (^)(AFMDatabase *db, BOOL *rollback))block;

///-----------------------------------------------
/// @name Dispatching database operations to queue
///-----------------------------------------------

/** Synchronously perform database operations using save point.

 @param block The code to be run on the queue of `AFMDatabaseQueue`
 */

#if SQLITE_VERSION_NUMBER >= 3007000
// NOTE: you can not nest these, since calling it will pull another database out of the pool and you'll get a deadlock.
// If you need to nest, use FMDatabase's startSavePointWithName:error: instead.
- (NSError*)inSavePoint:(void (^)(AFMDatabase *db, BOOL *rollback))block;
#endif

@end

