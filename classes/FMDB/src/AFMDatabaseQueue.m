//
//  FMDatabaseQueue.m
//  fmdb
//
//  Created by August Mueller on 6/22/11.
//  Copyright 2011 Flying Meat Inc. All rights reserved.
//

#import "AFMDatabaseQueue.h"
#import "AFMDatabase.h"
#import "AutoThread.h"
#import <UIKit/UIKit.h>

@interface AFMDatabaseQueue()
{
	AFMDatabase* _db;
	BOOL preventReopen, autoClose;
	id backgroundIdentifier;
}
@end

@implementation AFMDatabaseQueue

@synthesize path = _path;
@synthesize openFlags = _openFlags;

+ (instancetype)databaseQueueWithPath:(NSString*)aPath
{    
    return [[self alloc] initWithPath:aPath];
}

+ (instancetype)databaseQueueWithPath:(NSString*)aPath flags:(int)openFlags
{
    return [[self alloc] initWithPath:aPath flags:openFlags];
}

+ (Class)databaseClass
{
    return [AFMDatabase class];
}

- (void) startBackgroundTask
{
	//we could use UIApplication (if available), but when time is up - we must force-close the DB and loose unsaved data. Then we will never know what caused the problem.
	//instead we use this, that works on all platforms. On iOS your app will be killed if you open DB when there are no background time remaining.
	//SO: What is the optimal way of doing this?
	backgroundIdentifier = [[NSProcessInfo processInfo] beginActivityWithOptions: NSActivityAutomaticTerminationDisabled | NSActivitySuddenTerminationDisabled | NSActivityUserInitiated reason:@"Saving data to database"];
	/*
	Class uiApplication = NSClassFromString(@"UIApplication");
	if (uiApplication)
	{
		backgroundIdentifier = [[uiApplication sharedApplication] beginBackgroundTaskWithName:@"AutoDB bg access" expirationHandler:^{
			
			
			self->autoClose = true;
			[self close];
			[[uiApplication sharedApplication] endBackgroundTask:self->backgroundIdentifier];
			self->backgroundIdentifier = UIBackgroundTaskInvalid;
		}];
	}
	*/
}

- (void) endBackgroundTask
{
	[[NSProcessInfo processInfo] endActivity:backgroundIdentifier];
}

- (instancetype)initWithPath:(NSString*)aPath flags:(int)openFlags
{
    self = [super init];
    
    if (self != nil)
	{
        _db = [[[self class] databaseClass] databaseWithPath:aPath];
        BOOL success = [_db openWithFlags:openFlags];
        if (!success)
		{
            NSLog(@"Could not create database queue for path %@", aPath);
            return 0x00;
        }
        
        _path = FMDBReturnRetained(aPath);
		
		_thread = [NSThread newThread:[NSString stringWithFormat:@"DBThread %@", [aPath lastPathComponent]]];
        _openFlags = openFlags;
    }
    
    return self;
}

- (instancetype)initWithPath:(NSString*)aPath
{
    
    // default flags for sqlite3_open
    return [self initWithPath:aPath flags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX]	;
}

- (instancetype)init
{
    return [self initWithPath:nil];
}

- (void)dealloc
{
	[_thread cancel];
	[_thread asyncExecuteBlock:^{}];
}

- (void) closeAndPreventReopen
{
	preventReopen = YES;
	[self close];
}

- (void) allowReopen
{
	preventReopen = NO;
}

- (void) autoClose: (BOOL)_autoClose
{
	autoClose = _autoClose;
}

- (BOOL) isClosed
{
	return !_db;
}

- (void) close
{
    [_thread syncPerformBlock:^()
	{
		//NSLog(@"Closing DB!");
        [self->_db close];
		self->_db = 0x00;
    }];
	[self endBackgroundTask];
}

- (AFMDatabase*)database
{
    if (!_db)
	{
		if (preventReopen)
		{
			NSLog(@"trying to open db while in prevent mode!");
			return nil;
		}
        _db = FMDBReturnRetained([AFMDatabase databaseWithPath:_path]);
        
#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [_db openWithFlags:_openFlags];
#else
        BOOL success = [db open];
#endif
        if (!success)
		{
            NSLog(@"FMDatabaseQueue could not reopen database for path %@", _path);
            _db  = 0x00;
            return 0x00;
        }
    }
    
    return _db;
}

- (void)inDatabase:(void (^)(AFMDatabase *db))block
{
	[_thread syncPerformBlock:^(){
        
        AFMDatabase *db = [self database];
        block(db);
        
        if ([db hasOpenResultSets])
		{
            NSLog(@"Warning: there is at least one open result set around after performing [FMDatabaseQueue inDatabase:]");
            
#ifdef DEBUG
            NSSet *openSetCopy = FMDBReturnAutoreleased([[db valueForKey:@"_openResultSets"] copy]);
            for (NSValue *rsInWrappedInATastyValueMeal in openSetCopy)
			{
                AFMResultSet *rs = (AFMResultSet *)[rsInWrappedInATastyValueMeal pointerValue];
                NSLog(@"open results query: '%@'", [rs query]);
            }
#endif
        }
		if (self->autoClose)
			[self close];
    }];
}

- (void)asyncExecuteDatabase:(void (^)(AFMDatabase *db))block
{
	[_thread asyncExecuteBlock:^(){
		
		AFMDatabase *db = [self database];
		block(db);
		
		if ([db hasOpenResultSets])
		{
			NSLog(@"Warning: there is at least one open result set around after performing [FMDatabaseQueue inDatabase:]");
			
#ifdef DEBUG
			NSSet *openSetCopy = FMDBReturnAutoreleased([[db valueForKey:@"_openResultSets"] copy]);
			for (NSValue *rsInWrappedInATastyValueMeal in openSetCopy)
			{
				AFMResultSet *rs = (AFMResultSet *)[rsInWrappedInATastyValueMeal pointerValue];
				NSLog(@"query: '%@'", [rs query]);
			}
#endif
		}
		if (self->autoClose)
			[self close];
	}];
}

- (void)beginTransaction:(BOOL)useDeferred withBlock:(void (^)(AFMDatabase *db, BOOL *rollback))block
{
	[_thread syncPerformBlock:^() {
        
        BOOL shouldRollback = NO;
        
        if (useDeferred)
		{
            [[self database] beginDeferredTransaction];
        }
        else
		{
            [[self database] beginTransaction];
        }
        
        block([self database], &shouldRollback);
        
        if (shouldRollback)
		{
            [[self database] rollback];
        }
        else
		{
            [[self database] commit];
        }
    }];
}

- (void)inDeferredTransaction:(void (^)(AFMDatabase *db, BOOL *rollback))block
{
    [self beginTransaction:YES withBlock:block];
}

- (void)inTransaction:(void (^)(AFMDatabase *db, BOOL *rollback))block
{
    [self beginTransaction:NO withBlock:block];
}

#if SQLITE_VERSION_NUMBER >= 3007000
- (NSError*)inSavePoint:(void (^)(AFMDatabase *db, BOOL *rollback))block
{
    static unsigned long savePointIdx = 0;
    __block NSError *err = 0x00;
	
	[_thread syncPerformBlock:^() {
        
        NSString *name = [NSString stringWithFormat:@"savePoint%ld", savePointIdx++];
        BOOL shouldRollback = NO;
        if ([[self database] startSavePointWithName:name error:&err])
		{
            block([self database], &shouldRollback);
            if (shouldRollback)
			{
                // We need to rollback and release this savepoint to remove it
                [[self database] rollbackToSavePointWithName:name error:&err];
            }
            [[self database] releaseSavePointWithName:name error:&err];
        }
    }];
    return err;
}
#endif

@end
