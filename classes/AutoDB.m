//
//  AutoDB.m
//  AutoDB
//
//  Created by Olof Thorén on 2018-08-30.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "AutoDB.h"
#import "AutoThread.h"
@import ObjectiveC;

#define AUTO_SQLITE_FIELD_NAMES @[@"TEXT", @"BLOB", @"INTEGER", @"REAL", @"REAL", @"REAL", @"NONE"]

@implementation AutoDB
{
	NSMutableDictionary *tablesWithChanges;
	NSMutableDictionary *tableSyntax;
	
	AFMDatabaseQueue *setupLockQueue;
	dispatch_queue_t tablesWithChangesQueue;		   //A queue for making changes to tablesWithChanges - so we don't need to interfere with the database queue while making changes to our objects. Was called dictionaryQueue
	BOOL needsMigration, isSetup, hasSetupObservingProperties;
	
	/*
	 I want to rebuild the concurrency model. I want one queue for DB-actions (like queries), and one for our cached objects. This should remove the semaphore since it is not needed (cached objects needs an own queue) - OR - we use all three.
	 This is done, but remember that the same cacheQueue must be used by all sub classes
	 */
	
	Class AutoSyncClass, AutoSyncHandlerClass;
}

+ (void) setupWithChangesQueue:(dispatch_queue_t)queue changesDictionary:(NSMutableDictionary*)tablesWithChanges {}

static Class uiApplication;
static AutoDB *sharedInstance = nil;
+ (instancetype) sharedInstance
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^(void)
	{
		sharedInstance = [[AutoDB alloc] init];
		uiApplication = NSClassFromString(@"UIApplication");
	});
	return sharedInstance;
}

- (instancetype) init
{
	self = [super init];
	tablesWithChanges = [NSMutableDictionary new];
	//not yet! API_URL = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"API_URL"];
	
	tablesWithChangesQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
	
	//we have to do this or have one queue for each table. Then we cannot save all classes at once - must know about them one-by-one.
	[AutoModel.class setupWithChangesQueue:tablesWithChangesQueue changesDictionary:tablesWithChanges];
	
	return self;
}

#ifndef TARGET_IS_EXTENSION
//this method is not available in extensions.
- (void) applicationWillResignActive:(NSNotification*)notif
{
	__block BOOL hasChanges = NO;
	dispatch_sync(tablesWithChangesQueue, ^(void){
		hasChanges = tablesWithChanges.count > 0;
	});
	if (hasChanges == NO) return;
	NSLog(@"AutoDB save due to resign message!");
	
	__block UIBackgroundTaskIdentifier backgroundTaskIdentifier = UIBackgroundTaskInvalid;
	dispatch_block_t endTaskHandler = ^
	{
		if (backgroundTaskIdentifier != UIBackgroundTaskInvalid)
		{
			//NSLog(@"resign active AutoDB save complete");
			[[uiApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];//72
			backgroundTaskIdentifier = UIBackgroundTaskInvalid;
		}
	};
	backgroundTaskIdentifier = [[uiApplication sharedApplication] beginBackgroundTaskWithName:@"saveAllWithChanges" expirationHandler:endTaskHandler];
	
	[AutoModel saveAllWithChanges:^(NSError * _Nullable error) {
		
		if (error) NSLog(@"AutoSave could not complete, got error %@", error);
		
		//lock db? - YES, but only when going background! (and all downloads and other tasks is taken care of! - how do we know this? We ask the queues!).
		//Solve this by setting an "autoClose-mode", whenever db is used it opens and closes itself afterwards.
		endTaskHandler();
	}];
}

- (void) applicationWillEnterForeground:(NSNotification*)notif
{
	//open db if locked
	//NSLog(@"open DB");
}

#endif

- (void) destroyDatabase
{
	AUTO_WAIT_FOR_SETUP
	if (!isSetup)
	{
		NSLog(@"db already destroyed");
		return;
	}
	[AutoModel saveAllWithChanges];
	
	NSLog(@"destroying database");
	setupLockQueue = nil;
	for (NSString *className in tableSyntax)
	{
		Class classObject = NSClassFromString(className);
		
		AFMDatabaseQueue *queue = objc_getAssociatedObject(classObject, @selector(databaseQueue));
		if (queue)
		{
			//always wait for db to empty all queues.
			[queue.thread syncPerformBlock:^{}];
			objc_setAssociatedObject(classObject, @selector(databaseQueue), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		
		AutoConcurrentMapTable *tableCache = objc_getAssociatedObject(classObject, @selector(tableCache));
		[tableCache removeAllObjects];
		objc_setAssociatedObject(classObject, @selector(tableCache), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	tableSyntax = nil;
	isSetup = NO;
	
	NSLog(@"all your database is destroyed!");
}

- (void) createDatabaseMigrateBlock:(nullable MigrationBlock)migrateBlock
{
	return [self createDatabase:nil withModelClasses:nil migrateBlock:migrateBlock];
}

- (void) createDatabase:(nullable NSString*)location withModelClasses:(nullable NSArray<NSString*>*)specificClassNames migrateBlock:(nullable MigrationBlock)migrateBlock
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if (location == nil)
	{
		//quick and easy default path
		NSString *supportPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
		location = [supportPath stringByAppendingPathComponent:@"auto_database.sqlite3"];
		if ([fileManager fileExistsAtPath:location] == NO)
		{
			[fileManager createDirectoryAtPath:supportPath withIntermediateDirectories:YES attributes:nil error:nil];
			
			//if we had an old version using the documents dir, move the db.
			NSString *documentsPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"auto"];
			NSString *oldLocation = [documentsPath stringByAppendingPathComponent:@"auto_database.sqlite3"];
			if ([fileManager fileExistsAtPath:oldLocation])
			{
				[fileManager moveItemAtPath:oldLocation toPath:location error:nil];
			}
		}
	}
	else if ([fileManager fileExistsAtPath:location] == NO)
	{
		[fileManager createDirectoryAtPath:[location stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
	}
	
	//convert classNames to classes, if specified.
	if (!specificClassNames)
		specificClassNames = [self modelClassesFromRuntime];
	
	[self createDatabaseWithPathsForClasses:@{location : specificClassNames} migrateBlock:migrateBlock];
}

- (void) createDatabaseWithPathsForClasses:(nullable NSDictionary <NSString*, NSArray <NSString*>*>*)pathsForClassNames migrateBlock:(nullable MigrationBlock)migrateBlock
{
	if (isSetup)
	{
		NSLog(@"you have already created the DB.");
		NSError *error = [NSError errorWithDomain:@"AUTO_DB" code:123731 userInfo:@{@"localizedDescription": NSLocalizedString(@"Create DB is called twice.", nil)}];
		if (migrateBlock) migrateBlock(MigrationStateError, nil, @[error]);
		return;
	}
	
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSMutableArray *allQueues = [NSMutableArray new];
	for (NSString *path in pathsForClassNames)
	{
		//make sure folders exists for all paths
		if ([fileManager fileExistsAtPath:path] == NO)
		{
			[fileManager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
		}
		if (DEBUG) NSLog(@"sqlite3 \"%@\"", path);
		AFMDatabaseQueue *specificQueue = [AFMDatabaseQueue databaseQueueWithPath:path];
		for (NSString *className in pathsForClassNames[path])
		{
			Class classObject = NSClassFromString(className);
			objc_setAssociatedObject(classObject, @selector(databaseQueue), specificQueue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		[allQueues addObject:specificQueue];
		if (!setupLockQueue)
			setupLockQueue = specificQueue;	//make one the lockQueue
	}
	
	if (DEBUG)
	{
		//always remember to add ALL classes, otherwise it will fail. So tell us otherwise!
		NSMutableSet *runtimeClasses = [NSMutableSet setWithArray:[self modelClassesFromRuntime]];
		for (NSString *className in @[@"AutoUser", @"AutoSync"])
		{
			[runtimeClasses removeObject:className];
		}
		if (pathsForClassNames.count)
		{
			for (NSArray *items in pathsForClassNames.allValues)
			{
				for (NSString *className in items)
				{
					[runtimeClasses removeObject:NSClassFromString(className)];
				}
			}
		}
		if (runtimeClasses.count)
		{
			NSLog(@"NOTE: Missing classes: %@", [runtimeClasses.allObjects componentsJoinedByString:@", "]);
		}
	}
	
	tableSyntax = [NSMutableDictionary new];
	//we don't start the threads until setup is complete, but someone who want the table-info needs to wait (AUTO_WAIT_FOR_SETUP).
	dispatch_async(tablesWithChangesQueue, ^{
		AUTO_WAIT_FOR_SETUP
		if (DEBUG) NSLog(@"DBSem is released!");
		[[NSNotificationCenter defaultCenter] postNotificationName:AutoDBIsSetupNotification object:nil userInfo:nil];
	});
	
	//We must close db when quitting, (and open again on going fg) but only close AFTER all is done.
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
	
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(void){
		
		//TODO: you are here - change this to use the dictionary with classNames instead of classes.
		[self internalCreateDatabaseWithPaths:pathsForClassNames allQueues:allQueues migrateBlock:migrateBlock];
	});
}

- (void) internalCreateDatabaseWithPaths:(nullable NSDictionary <NSString*, NSArray <NSString*>*>*)pathsForClassNames allQueues:(NSArray<AFMDatabaseQueue *>*)allQueues migrateBlock:(MigrationBlock)migrateBlock
{
	//allow for dynamical set/remove of sync engine.
	if (!AutoSyncHandlerClass && NSClassFromString(@"AutoSyncHandler"))
	{
		AutoSyncHandlerClass = NSClassFromString(@"AutoSyncHandler");
		AutoSyncClass = NSClassFromString(@"AutoSync");
	}
	if (pathsForClassNames.count > 1)
	{
		//give migration a chance to handle table changes, if we move from one file to the other.
		NSArray *paths = pathsForClassNames.allKeys;
		NSString *showTables = @"SELECT name FROM sqlite_master WHERE type = 'table'";
		for (NSInteger index = 0; index < paths.count - 1; index++)
		{
			NSString *path = paths[index];
			NSMutableSet <NSString*>* definedClassNames = [NSMutableSet setWithArray:pathsForClassNames[path]];
			__block NSMutableSet <NSString*>* movingClassNames = nil;
			
			//check if these will move here from the other db
			AFMDatabase *db = [AFMDatabase databaseWithPath:path];
			BOOL success = [db openWithFlags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX];
			if (!success)
				NSLog(@"ERROR Cannot open db %@\nWill crash...", path);
			AFMResultSet *result = [db executeQuery:showTables];
			while ([result next])
			{
				NSString *existingTable = [result stringForColumnIndex:0];
				if ([definedClassNames containsObject:existingTable])
				{
					//these are not moving here, they exist
					[definedClassNames removeObject:existingTable];
				}
				else
				{
					//these are moving somewhere, they should not exist.
					if (!movingClassNames) movingClassNames = [NSMutableSet new];
					[movingClassNames addObject:existingTable];
				}
			}
			if (movingClassNames == nil && definedClassNames.count == 0)
			{
				//All is fine, I have exactly those here that should be here.
				[db close];
				continue;
			}
			
			//compare against all other DBs. OBSERVE: the first time we run this there are no tables. OR if we have changed the file-path and has forgotten to move the actual file.
			//ALSO: new tables don't exist even if the files do!
			for (NSInteger other = index + 1; other < paths.count; other++)
			{
				NSString *otherPath = paths[other];
				NSMutableSet <NSString*>* otherClassNames = [NSMutableSet setWithArray:pathsForClassNames[otherPath]];
				NSMutableSet *foundMovers = nil;
				if ([movingClassNames intersectsSet:otherClassNames])
				{
					//at least one table will move from us to here, place all those in foundMovers, and remove them from our "movingClassNames".
					foundMovers = movingClassNames.mutableCopy;
					[foundMovers intersectSet:otherClassNames];
					[movingClassNames minusSet:foundMovers];
				}
				
				if (foundMovers == nil && definedClassNames.count == 0)
				{
					continue;
				}
				
				if (foundMovers && DEBUG)
					NSLog(@"I found classes that should be moved: %@", foundMovers);
				
				//and check if these other tables will move here from the our db
				__block NSMutableArray <NSString*>* foundSources = nil;
				__block NSMutableDictionary <NSString*, NSString*>* tableSchemas = nil;
				AFMDatabase *otherDB = [AFMDatabase databaseWithPath:otherPath];
				if ([otherDB openWithFlags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX])
				{
					AFMResultSet *result = [otherDB executeQuery:showTables];	//could attach and run SELECT name from aDB.sqlite_master, if we want to fiddle with removing "aDB." from all names.
					NSMutableArray *duplicateTables = [NSMutableArray new];
					while ([result next])
					{
						NSString *existingTable = [result stringForColumnIndex:0];
						if ([definedClassNames containsObject:existingTable])
						{
							//this one will move to us from here
							if (!foundSources)
							{
								foundSources = [NSMutableArray new];
								tableSchemas = [NSMutableDictionary new];
							}
							[foundSources addObject:existingTable];
							[definedClassNames removeObject:existingTable];
						}
						else if ([foundMovers containsObject:existingTable])
						{
							//this one will move FROM us TO Them, but old table with the same name still exists! We need to delete it before moving!
							[duplicateTables addObject:existingTable];
						}
					}
					//also copy the schema so we get the exact table.
					for (NSString *table in foundSources)
					{
						tableSchemas[table] = [self getSchemaFor:table prefixName:nil inDB:otherDB];
					}
					
					//drop the duplicated tables
					for (NSString* table in duplicateTables)
					{
						if ([otherDB executeUpdate:[NSString stringWithFormat:@"DROP TABLE %@", table]] == NO)
						{
							NSLog(@"dropping duplicateTable '%@' did not work", table);
						}
					}
					[otherDB close];
				}
				
				if (foundMovers.count == 0 && !foundSources)
					continue;
				
				if (![db executeUpdate:[NSString stringWithFormat:@"ATTACH DATABASE \"%@\" AS aDB", otherPath]])
				{
					NSLog(@"not working!");
					return;
				}
				
				//TODO: if table exist, drop first!
				for (NSString *table in foundSources)
				{
					//NSLog(@"createStatement became %@ for table %@", tableSchemas[table], table);
					[db executeUpdate:tableSchemas[table]];
					NSString *moveToUs = [NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ SELECT * FROM aDB.%@", table, table];
					[db executeUpdate:moveToUs];
					if ([db executeUpdate:[NSString stringWithFormat:@"DROP TABLE aDB.%@", table]] == NO)
					{
						NSLog(@"dropping 'foundSources' table did not work");
					}
				}
				
				for (NSString *table in foundMovers)
				{
					NSString *createStatement = [self getSchemaFor:table prefixName:@"aDB." inDB:db];
					//NSLog(@"createStatement became %@", createStatement);
					[db executeUpdate:createStatement];
					
					NSString *moveToThem = [NSString stringWithFormat:@"INSERT OR REPLACE INTO aDB.%@ SELECT * FROM %@", table, table];
					[db executeUpdate:moveToThem];
					if ([db executeUpdate:[NSString stringWithFormat:@"DROP TABLE %@", table]] == NO)
					{
						NSLog(@"could not move table %@", db.lastError);
					}
				}
				
				[db executeUpdate:@"DETACH DATABASE aDB"];
			}
			
			//now we are done with this table, move to the next
			[db close];
		}
	}
	
	//create syntax and check for migration
	NSMutableSet <NSString*>*lightweightMigrateTables = [NSMutableSet set];
	for (NSArray<NSString*>* tableNames in pathsForClassNames.allValues)
	{
		for (NSString* tableName in tableNames)
		{
			Class classObject = NSClassFromString(tableName);
			[self createTableSyntax:classObject];
			if (hasSetupObservingProperties == NO && [classObject preventObservingProperties] == NO)
			{
				//even if we destroy the DB we cannot run this twice, so we must have a hasSetupObservingProperties.
				[self setupObservingProperties:classObject];
			}
			objc_setAssociatedObject(classObject, @selector(tableCache), [AutoConcurrentMapTable strongToWeakObjectsMapTable], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			
			AFMDatabase *db = [[classObject databaseQueue] database];
			NSString *createTable = [self generateTableSyntax:tableName];
			//TODO: compare with existing syntax!
			if ([db executeUpdate:createTable] == NO)
			{
				NSLog(@"error: %@", [db lastErrorMessage]);
			}
			
			if ([self createIndexInTable:tableName inDB:db])
			{
				//couldn't add index - likely the column does not exist yet.
				needsMigration = YES;
				[lightweightMigrateTables addObject:tableName];
			}
			
			NSMutableDictionary *columnsInDB = [NSMutableDictionary dictionary];
			NSString *query = [NSString stringWithFormat:@"PRAGMA table_info(%@);", tableName];
			AFMResultSet *result = [db executeQuery:query];
			while ([result next])
			{
				//column name, data type, whether or not the column can be NULL, and the default value for the column (we only need name and data type
				columnsInDB[result[1]] = result[2];
			}
			[result close];
			
			NSMutableDictionary *syntax = tableSyntax[tableName];
			
			//check for unique constraints
			NSMutableArray *uniqueColumns = [syntax[AUTO_UNIQUE_COLUMNS] mutableCopy];
			query = [NSString stringWithFormat:@"SELECT sql FROM sqlite_master WHERE name = '%@';", tableName];
			result = [db executeQuery:query];
			[result next];
			NSString *table = result[0];
			for (NSString *row in [table componentsSeparatedByString:@"\n"])
			{
				//the actual query, here we can also find keys.
				NSRange range = [row rangeOfString:@"unique("];
				if (range.length)
				{
					NSString *constraint = [row substringFromIndex:NSMaxRange(range)];
					constraint = [constraint substringToIndex:[constraint rangeOfString:@")"].location];
					NSArray *existingUniqueStatement = [constraint componentsSeparatedByString:@","];
					BOOL hasFound = NO;
					for (NSArray *newUniqueStatement in uniqueColumns)
					{
						if ([newUniqueStatement isEqualToArray:existingUniqueStatement])
						{
							hasFound = YES;
						}
					}
					if (!hasFound)
					{
						needsMigration = YES;
						syntax[AUTO_UNIQUE_COLUMNS_UPDATE] = @1;
						[lightweightMigrateTables addObject:tableName];
					}
					else
					{
						[uniqueColumns removeObject:existingUniqueStatement];
					}
				}
			}
			[result close];
			if (uniqueColumns.count)
			{
				needsMigration = YES;
				syntax[AUTO_UNIQUE_COLUMNS_UPDATE] = @1;
				[lightweightMigrateTables addObject:tableName];
			}
			
			//check for missing columns
			NSDictionary *columnSyntax = syntax[AUTO_COLUMN_KEY];
			NSArray *fieldNames = AUTO_SQLITE_FIELD_NAMES;
			[columnSyntax enumerateKeysAndObjectsUsingBlock:^(NSString *columnName, NSNumber *columnType, BOOL *stop)
			 {
				NSString *columnTypeString = [fieldNames objectAtIndex:columnType.integerValue];
				if (columnsInDB[columnName] == nil)
				{
					needsMigration = YES;
					[lightweightMigrateTables addObject:tableName];	   //we need to migrate if we are missing columns.
				}
				else if ([columnsInDB[columnName] isEqualToString:columnTypeString] == NO)
				{
					//change type of column - we must do this. SQLite claims to not care about types (according to the docs), but it is not technically possible, e.g. changing a 64 bit float to 64 bit int.
					needsMigration = YES;
					[lightweightMigrateTables addObject:tableName];
					//NSLog(@"column is not equal %@ %@ %@", columnName, columnsInDB[columnName], columnTypeString);
				}
			}];
			
			//check for deleted columns
			[columnsInDB enumerateKeysAndObjectsUsingBlock:^(NSString *columnName, NSString *columnType, BOOL *stop)
			 {
				if (columnSyntax[columnName] == nil)
				{
					[lightweightMigrateTables addObject:tableName];
					needsMigration = YES;
				}
			}];
		}
	}
	hasSetupObservingProperties = YES;
	
	if (migrateBlock)
		migrateBlock(MigrationStateStart, lightweightMigrateTables, nil);
	
	if (lightweightMigrateTables.count)
	{
		//NOTE: if there are problems with lightweightMigration we can only ask for someone to fix it, and continue the best we can.
		NSArray *errors = [self lightweightMigration:lightweightMigrateTables];
		if (migrateBlock) migrateBlock(MigrationStateComplete, lightweightMigrateTables, errors);
	}
	else if (migrateBlock)
		migrateBlock(MigrationStateComplete, nil, nil);
	
	//kill semaphore after migration
	[self killSemaphore];
	for (AFMDatabaseQueue *queue in allQueues)
	{
		[queue.thread start];
	}
	
	//also check if we need syncing
	if (AutoSyncHandlerClass && pathsForClassNames)
		[AutoSyncHandlerClass setupSync:pathsForClassNames];
}

+ (void) setupSync:(NSDictionary <NSString*, NSArray <NSString*>*> *)pathsForClassNames{};
+ (void) mainSync{};

- (NSString*) getSchemaFor:(NSString*)table prefixName:(nullable NSString*)prefixName inDB:(AFMDatabase *)db
{
	NSString *schemaRow;
	AFMResultSet *result = [db executeQuery:[NSString stringWithFormat:@"SELECT sql from sqlite_master WHERE name = \"%@\"", table]];
	while ([result next])
	{
		schemaRow = [result stringForColumnIndex:0];
	}
	if (prefixName)
	{
		NSMutableString *schema = schemaRow.mutableCopy;
		NSRange nameRange = [schema rangeOfString:table];
		[schema insertString:prefixName atIndex:nameRange.location];
		return schema;
	}
	return schemaRow;
}

//Kill the semaphore when we don't need it anymore. This may improve performance, but more importantly it lets blocks be queued and unqueued in order. If that does not happen, we will get concurrent problems.
- (void) killSemaphore
{
	NSLog(@"db is now setup");
	isSetup = YES;
	
	/*
	 A better system:
	 We only need AUTO_WAIT_FOR_SETUP when asking for table-info.
	 1. Always wrap those questions in a function.
	 2. Check if setup is complete, otherwise enqueue onto a thread.
	 */
}

- (nullable NSArray <NSError*>*) lightweightMigration:(NSMutableSet*)migrateTables
{
	NSArray *fieldNames = AUTO_SQLITE_FIELD_NAMES;
	for (NSString *tableName in migrateTables)
	{
		Class classObject = NSClassFromString(tableName);
		AFMDatabase *db = [classObject databaseQueue].database;
		NSDictionary *syntax = tableSyntax[tableName];
		NSString *createTable = [self generateTableSyntax:tableName];
		NSMutableSet *allowNull = syntax[@"ALLOW_NULL"];
		
		NSString *query = [NSString stringWithFormat:@"PRAGMA table_info(%@);", tableName];
		AFMResultSet *result = [db executeQuery:query];
		NSMutableDictionary *columnsInDB = [NSMutableDictionary dictionary];
		while ([result next])
		{
			columnsInDB[result[1]] = result[2];
		}
		[result close];
		
		//if we are lucky we will need to only add new columns. Save the statements in order to hope for this, if not we just do a insert-select.
		__block BOOL onlyAddColumn = YES;
		NSMutableArray *addColumnStatements = [NSMutableArray array];
		
		//auto-rename columns
		NSMutableArray *newTableColumns = [[syntax[AUTO_COLUMN_KEY] allKeys] mutableCopy];
		NSMutableArray *oldTableColumns = [newTableColumns mutableCopy];
		NSDictionary *columnSyntax = syntax[AUTO_COLUMN_KEY];
		
		[columnSyntax enumerateKeysAndObjectsUsingBlock:^(NSString *columnName, NSNumber *columnType, BOOL *stop)
		{
			NSString *columnTypeString = [fieldNames objectAtIndex:columnType.integerValue];
			if (columnsInDB[columnName] == nil)
			{
				//If we are moving from NULL to NOT NULL we also need to set all values to 0. Is setting a default like this enough?
				NSString *nullRestriction = @" NOT NULL DEFAULT 0";
				if (columnType.integerValue == AutoFieldTypeDate || [allowNull containsObject:columnName])
				{
					nullRestriction = @"";
				}
				
				NSString *addColumnSyntax = [NSString stringWithFormat:@"ALTER TABLE %@ ADD %@ %@%@", tableName, columnName, columnTypeString, nullRestriction];
				[addColumnStatements addObject:addColumnSyntax];
				
				__block BOOL columnExistsInBothTables = NO;
				[syntax[@"MIGRATE_PARAMETERS"] enumerateKeysAndObjectsUsingBlock:^(NSString* oldName, NSString* newName, BOOL *stop)
				{
					if ([newName isEqualToString:columnName] && columnsInDB[oldName])
					{
						NSInteger index = [oldTableColumns indexOfObject:columnName];
						if (index != NSNotFound)
						{
							[oldTableColumns replaceObjectAtIndex:index withObject:oldName];
							onlyAddColumn = NO;
							columnExistsInBothTables = YES; //please explain this
						}
					}
				}];
				if (columnExistsInBothTables == NO)
				{
					//NSLog(@"We don't have column %@ in the new and the old table for %@. All its values will be removed and its default will be used.", columnName, tableName);
					[newTableColumns removeObject:columnName];
					[oldTableColumns removeObject:columnName];
				}
			}
			else if ([columnsInDB[columnName] isEqualToString:columnTypeString] == NO)
			{
				//we have changed type of a column, so we need to create a new table and copy in the old data. We don't need to further change column names (it would be taken care of in the previous step).
				onlyAddColumn = NO;
			}
		}];
		
		//check for deleted columns
		[columnsInDB enumerateKeysAndObjectsUsingBlock:^(NSString *columnName, NSNumber *columnType, BOOL *stop)
		{
			if (columnSyntax[columnName] == nil)
			{
				onlyAddColumn = NO;
			}
		}];
		
		//we need to copy table to insert/remove constraints, so we do full migration if that is the case.
		if (onlyAddColumn && syntax[AUTO_UNIQUE_COLUMNS_UPDATE] == nil)
		{
			for (NSString *statement in addColumnStatements)
			{
				[db executeUpdate:statement];
			}
		}
		else
		{
			NSString *oldTableName = [NSString stringWithFormat:@"%@_OLD", tableName];
			[db executeUpdate:[NSString stringWithFormat:@"DROP TABLE IF EXISTS %@", oldTableName]]; //drops the old table
			
			BOOL success = [db executeUpdate:[NSString stringWithFormat:@"ALTER TABLE %@ RENAME TO %@", tableName, oldTableName]];	   //renames the old table
			if (!success)
			{
				//TODO: handle error
				NSLog(@"Could not handle rename %@ in migration! What now?", tableName);
			}
			success = [db executeUpdate:createTable]; //creates the new table with all correct properties
			if (!success)
			{
				//TODO: handle error
				NSLog(@"Could not handle create table %@ during migration! What now?", tableName);
			}
			NSString *query = [NSString stringWithFormat:@"INSERT OR IGNORE INTO %@ (%@) SELECT %@ FROM %@;", tableName, [newTableColumns componentsJoinedByString:@","], [oldTableColumns componentsJoinedByString:@","], oldTableName];
			if ([db executeUpdate:query])
			{
				//inserts all data from the old table to the new, this is a remarkably fast operation.
				[db executeUpdate:[NSString stringWithFormat:@"DROP TABLE %@", oldTableName]]; //drops the old table
			}
			else
			{
				//failing! we need to rollback...
				NSLog(@"error failing! we need to rollback...");
				[db executeUpdate:[NSString stringWithFormat:@"DROP TABLE %@", tableName]]; //drops the old table
				[db executeUpdate:[NSString stringWithFormat:@"ALTER TABLE %@ RENAME TO %@", oldTableName, tableName]];	   //renames back again.
			}
			
			//Here we give the user the choice to translate the old values somehow. They can do this however they want.
			//Note: IF the app dies due to user implementing a bug, it will magically work again when relaunched - since we won't do this twice, the DB is already copied!
			[columnSyntax enumerateKeysAndObjectsUsingBlock:^(NSString *columnName, NSNumber *columnType, BOOL *stop)
			{
				NSString *columnTypeString = [fieldNames objectAtIndex:columnType.integerValue];
				NSString *existingColumnName = columnsInDB[columnName];
				if (existingColumnName && [existingColumnName isEqualToString:columnTypeString] == NO)
				{
					AutoFieldType oldType = [fieldNames indexOfObject:existingColumnName];
					AutoFieldType newType = columnType.integerValue;
					
					//Select all values on the form (id, columnName) and give it as an array to the user
					//they return a new array with new tuples which we save.
					NSMutableArray *arrayOfTuples = [NSMutableArray new];
					AFMResultSet *resultSet = [db executeQuery:[NSString stringWithFormat:@"SELECT id, %@ FROM %@", columnName, tableName]];
					while ([resultSet next])
					{
						id firstValue = resultSet[0];
						if (!firstValue)
							firstValue = [NSNull null];
						id secondValue = resultSet[1];
						if (!secondValue)
							secondValue = [NSNull null];
						
						[arrayOfTuples addObject:[NSMutableArray arrayWithObjects:firstValue, secondValue, nil]];
					}
					[classObject migrateTable:tableName column:columnName oldType:oldType newType:newType values:arrayOfTuples];
					BOOL correctType = NO;
					if (arrayOfTuples.count)
					{
						NSInteger index = 0;
						id firstObject = arrayOfTuples[index][1];
						while (firstObject == [NSNull null] && index < arrayOfTuples.count)
						{
							index++;
							firstObject = arrayOfTuples[index][1];
						}
						switch (newType)
						{
							case AutoFieldTypeBlob:
								if ([firstObject isKindOfClass:[NSData class]])
									correctType = YES;
								break;
							case AutoFieldTypeDate:
								if ([firstObject isKindOfClass:[NSNumber class]])
									correctType = YES;
								break;
							case AutoFieldTypeText:
								if ([firstObject isKindOfClass:[NSString class]])
									correctType = YES;
								break;
							case AutoFieldTypeDouble:
							case AutoFieldTypeInteger:
							case AutoFieldTypeNumber:
								if ([firstObject isKindOfClass:[NSNumber class]])
									correctType = YES;
								break;
							default:
								break;
						}
					}
					if (correctType && arrayOfTuples.count)
					{
						//group with regard to maxVariableLimit, so we can update without errors.
						NSUInteger maxVariableLimit = 200000;
						NSUInteger objectCount = 0;
						NSMutableArray *parameters = [NSMutableArray new];
						for (NSArray *tuple in arrayOfTuples)
						{
							[parameters addObjectsFromArray:tuple];
							objectCount++;
							if (parameters.count >= maxVariableLimit)
							{
								[self convertParameters:parameters objectCount:objectCount tableName:tableName columnName:columnName db:db];
								objectCount = 0;
								[parameters removeAllObjects];
							}
						}
						if (objectCount)
						{
							[self convertParameters:parameters objectCount:objectCount tableName:tableName columnName:columnName db:db];
						}
					}
				}
			}];
		}
		
		if ([self createIndexInTable:tableName inDB:db])
			NSLog(@"could not set index after migration: %@", tableName);
	}
	
	needsMigration = NO;
	return nil;
}

- (NSMutableArray <NSString*>*) modelClassesFromRuntime
{
	NSMutableSet *modelClasses = [NSMutableSet new];
	Class AutoModelClass = [AutoModel class];
	unsigned int numClasses;
	Class *classes = objc_copyClassList(&numClasses);
	
	for (int i = 0; i < numClasses; i++)
	{
		Class thisClass = classes[i];
		BOOL addThisClass = NO;
		if (!class_isMetaClass(thisClass) && thisClass != AutoSyncClass)
		{
			Class superClass = class_getSuperclass(thisClass);
			while (superClass)
			{
				// walk the inheritence because we don't know about this class at all
				if (superClass == AutoModelClass || superClass == AutoSyncClass)
				{
					addThisClass = YES;
					break;
				}
				superClass = class_getSuperclass(superClass);
			}
		}
		if (addThisClass)
		{
			//NSLog(@"Class name: %s", class_getName(thisClass.copy)); //thisClass.copy
			[modelClasses addObject:NSStringFromClass(thisClass)];
		}
	}
	
	free(classes);
	return modelClasses.allObjects.mutableCopy;
}

- (nullable NSError*) convertParameters:(NSArray*)parameters objectCount:(NSUInteger)objectCount tableName:(NSString*)tableName columnName:(NSString*)columnName db:(AFMDatabase *)db
{
	NSString *questionMarks = [AutoModel questionMarksForQueriesWithObjects:objectCount columns:2];
	NSString *query = [NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ (id, %@) VALUES %@", tableName, columnName, questionMarks];
	NSError* error = nil;
	BOOL success = [db executeUpdate:query withArgumentsInArray:parameters];
	if (!success)
	{
		error = db.lastError;
	}
	return error;
}

- (NSString*) generateTableSyntax:(NSString*)tableName
{
	NSDictionary *syntax = tableSyntax[tableName];
	NSMutableArray *columns = [NSMutableArray array];
	NSMutableSet *allowNull = syntax[@"ALLOW_NULL"];
	NSArray *fieldNames = AUTO_SQLITE_FIELD_NAMES;
	
	//start with default values now.
	NSDictionary *defaultValues = syntax[@"DEFAULT"];
	
	[syntax[AUTO_COLUMN_KEY] enumerateKeysAndObjectsUsingBlock:^(NSString *columnName, NSNumber *columnType, BOOL *stop)
	{
		 NSString *primaryKey = @"";
		 NSString *nullRestriction = @" NOT NULL";
		 NSString *defaultValue = defaultValues[columnName];
		 AutoFieldType columnTypeInt = columnType.integerValue;
		 
		 if ([syntax[@"PRIMARY_KEY"] isEqualToString:columnName])
		 {
			 primaryKey = @" PRIMARY KEY";
		 }
		 else if (columnTypeInt == AutoFieldTypeDate || [allowNull containsObject:columnName])
		 {
			 //we always allow null for dates, but include default value
			 if (defaultValue)
				 nullRestriction = [NSString stringWithFormat:@" DEFAULT %@", defaultValue];
			 else
				 nullRestriction = @"";
		 }
		 else if (!defaultValue)
		 {
			 nullRestriction = [nullRestriction stringByAppendingString:@" DEFAULT 0"];
		 }
		 else if (defaultValue)
		 {
			 nullRestriction = [nullRestriction stringByAppendingString:[NSString stringWithFormat:@" DEFAULT %@", defaultValue]];
		 }
		 
		 NSString *columnTypeString = [fieldNames objectAtIndex:columnTypeInt];
		 
		 //example: employee INTEGER NOT NULL PRIMARY KEY
		 NSString *columnSyntax = [NSString stringWithFormat:@"%@ %@%@%@", columnName, columnTypeString, nullRestriction, primaryKey];
		 [columns addObject:columnSyntax];
	 }];
	for (NSArray* unique in syntax[AUTO_UNIQUE_COLUMNS])
	{
		[columns addObject:[NSString stringWithFormat:@"unique(%@)", [unique componentsJoinedByString:@","]]];
	}
	
	//Remember that all numbers become REAL since it cannot know what type of number an NSNumber is.
	NSString *createTable = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ \n( \n%@ \n);", tableName, [columns componentsJoinedByString:@",\n"]];
	//NSLog(@"createTable %@", createTable);
	return createTable;
}

///Create one index for each relation. If you want to add special indexed columns, after super has completed, this would be an ideal place to do so.
- (BOOL) createIndexInTable:(NSString*)tableName inDB:(AFMDatabase *)db
{
	BOOL needsMigration = NO;
	NSDictionary *syntax = tableSyntax[tableName];
	NSMutableSet *indexes = syntax[@"INDEX"];
	for (NSString *column in indexes)
	{
		NSString *createIndex = [NSString stringWithFormat:@"CREATE INDEX IF NOT EXISTS %@_index ON %@ (%@);", column, tableName, column];
		if ([db executeUpdate:createIndex] == NO)
		{
			needsMigration = YES;
		}
	}
	return needsMigration;
}

//This is called once for each class
- (void) createTableSyntax:(Class)classObject
{
	//Create a table cache for each table
	NSString *classString = NSStringFromClass(classObject);
	
	NSMutableDictionary *syntax = [NSMutableDictionary dictionary];
	tableSyntax[classString] = syntax;
	syntax[@"PRIMARY_KEY"] = primaryKeyName;
	
	NSMutableSet *allowNull = [NSMutableSet new];
	syntax[@"ALLOW_NULL"] = allowNull;
	
	NSMutableDictionary *columns = [NSMutableDictionary dictionary];
	syntax[AUTO_COLUMN_KEY] = columns;
	
	syntax[@"MIGRATE_PARAMETERS"] = [classObject migrateParameters];
	
	NSMutableSet *indexes = [NSMutableSet new];
	syntax[@"INDEX"] = indexes;
	
	NSDictionary *dict = [classObject columnIndex];
	if (dict && dict[AUTO_INDEX_COLUMN])
	{
		[indexes addObjectsFromArray:dict[AUTO_INDEX_COLUMN]];
	}
	NSArray *uniqueColumns = [classObject uniqueConstraints];
	if (uniqueColumns)
		syntax[AUTO_UNIQUE_COLUMNS] = uniqueColumns;
	
	NSArray *parent_id_keys = [[classObject relations][AUTO_RELATIONS_PARENT_ID_KEY] allValues];
	if (parent_id_keys && parent_id_keys.count)
		[indexes addObjectsFromArray:parent_id_keys];
	NSArray *strong_id_keys = [[classObject relations][AUTO_RELATIONS_STRONG_ID_KEY] allValues];
	if (strong_id_keys && strong_id_keys.count)
		[indexes addObjectsFromArray:strong_id_keys];
	
	NSDictionary *defaultValues = [classObject defaultValues];
	if (defaultValues)
	{
		syntax[@"DEFAULT"] = defaultValues;
	}
	
	Class subclass = classObject;
	while (subclass != NSObject.class)
	{
		unsigned int propertyCount;
		objc_property_t *propertyList = class_copyPropertyList(subclass, &propertyCount);
		for (unsigned int i = 0; i < propertyCount; i++)
		{
			objc_property_t property = propertyList[i];
			//to read all info for debugging:
			//const char *attribute = property_getAttributes(property);
			
			//Check dynamic
			char *isDynamic = property_copyAttributeValue(property, "D"); //D = dynamic
			if (isDynamic != nil)
			{
				free(isDynamic);
				continue;
			}
			//Check readonly
			char *isReadOnly = property_copyAttributeValue(property, "R"); //R = read only
			if (isReadOnly != nil)
			{
				free(isReadOnly);
				continue;
			}
			
			//get property name
			const char *propertyName = property_getName(property);
			NSString *propertyNameString = @(propertyName);
			
			//check for exlusion
			if ([[classObject excludeParametersFromTable] containsObject:propertyNameString])
			{
				continue;
			}
			
			//get property type
			AutoFieldType fieldType = AutoFieldTypeUnknown;
			
			char *typeEncoding = property_copyAttributeValue(property, "T");	//T means, type of property
			switch (typeEncoding[0])
			{
					//is it an object
				case '@':
				{
					if (strlen(typeEncoding) >= 3)
					{
						char *className = strndup(typeEncoding + 2, strlen(typeEncoding) - 3);
						NSString *name = @(className);
						NSRange range = [name rangeOfString:@"<"];
						if (range.location != NSNotFound)
						{
							name = [name substringToIndex:range.location];
						}
						Class valueClass = NSClassFromString(name) ?: [NSObject class];
						free(className);
						
						if ([valueClass isSubclassOfClass:[NSString class]])
						{
							fieldType = AutoFieldTypeText;
						}
						else if ([valueClass isSubclassOfClass:[NSNumber class]])
						{
							fieldType = AutoFieldTypeNumber;
						}
						else if ([valueClass isSubclassOfClass:[NSDate class]])
						{
							fieldType = AutoFieldTypeDate;
						}
						else if ([valueClass isSubclassOfClass:[NSData class]])
						{
							fieldType = AutoFieldTypeBlob;
						}
						if (fieldType != AutoFieldTypeUnknown)
						{
							//per default we allow all real objects to be null, we can add another list excluding even more.
							[allowNull addObject:propertyNameString];
						}
					}
					break;
				}
				case 'c':
				case 'B':
				{
					fieldType = AutoFieldTypeInteger;
					break;
				}
				case 'i':
				case 's':
				case 'l':
				case 'q':
				case 'C':
				case 'I':
				case 'S':
				case 'L':
				case 'Q':
				{
					fieldType = AutoFieldTypeInteger;
					break;
				}
				case 'f':
				case 'd':
				{
					fieldType = AutoFieldTypeDouble;
					break;
				}
				case '{': //struct
				case '(': //union
				case ':': //selector
				case '#': //class
				default:
				{
				}
			}
			
			//add it to the syntax
			if (fieldType != AutoFieldTypeUnknown)
			{
				columns[propertyNameString] = @(fieldType);
			}
			
			free(typeEncoding);
		}
		free(propertyList);
		subclass = [subclass superclass];
	}
	
	if ([[columns objectForKey:syntax[@"PRIMARY_KEY"]] integerValue] == AutoFieldTypeInteger)
	{
		syntax[@"PRIMARY_KEY_INT"] = @YES;
	}
}

#pragma mark - get table syntax

//column syntax is a dict on the form columnName: type
- (NSDictionary <NSString *, NSNumber *>*) columnSyntaxForClass:(Class)classObject
{
	AUTO_WAIT_FOR_SETUP
	
	NSDictionary *syntax = tableSyntax[NSStringFromClass(classObject)];
	return syntax[AUTO_COLUMN_KEY];
}

//TODO: we should make all our function use this instead, so access can be controlled
- (NSArray <NSString *>*) columnNamesForClass:(Class)classObject
{
	AUTO_WAIT_FOR_SETUP
	
	NSDictionary *syntax = tableSyntax[NSStringFromClass(classObject)];
	return [syntax[AUTO_COLUMN_KEY] allKeys];
}

- (NSDictionary <NSString*, NSDictionary*> *) tableSyntaxForClass:(NSString*)classString
{
	AUTO_WAIT_FOR_SETUP
	
	return tableSyntax[classString];
}

- (nonnull NSArray *) tableNames
{
	AUTO_WAIT_FOR_SETUP
	
	return [tableSyntax allKeys];
}

- (NSArray*) listRelations:(NSString*)tableName
{
	NSMutableArray *relations = [NSMutableArray new];
	for (NSString *relatedTable in tableSyntax.allKeys)
	{
		if ([relatedTable isEqualToString:tableName])
		{
			continue;
		}
		NSDictionary *subRelation = [NSClassFromString(relatedTable) relations];
		if (subRelation[AUTO_RELATIONS_PARENT_ID_KEY][tableName])
		{
			//NSLog(@"listRelations: %@ is parent of %@", tableName, relatedTable);
			[relations addObject:@{relatedTable: subRelation[AUTO_RELATIONS_PARENT_ID_KEY][tableName]}];
		}
		if (subRelation[AUTO_RELATIONS_STRONG_ID_KEY][tableName])
		{
			//NSLog(@"listRelations: %@ has strong relation to %@", relatedTable, tableName);
			[relations addObject:@{relatedTable: subRelation[AUTO_RELATIONS_STRONG_ID_KEY][tableName]}];
		}
	}
	
	return relations;
}

- (NSString*) selectQuery:(Class)classObject
{
	static char selectKey;
	NSString *selectQuery = objc_getAssociatedObject(classObject, &selectKey);
	if (!selectQuery)
	{
		AUTO_WAIT_FOR_SETUP
		
		NSString *classString = NSStringFromClass(classObject);
		NSDictionary *syntax = tableSyntax[classString];
		NSArray *columns = [syntax[AUTO_COLUMN_KEY] allKeys];
		
		selectQuery = [NSString stringWithFormat:@"SELECT %@ FROM %@ ", [columns componentsJoinedByString:@","], classString];
		objc_setAssociatedObject(classObject, &selectKey, selectQuery, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return selectQuery;
}

- (NSMutableDictionary <NSNumber*, NSMutableDictionary*> *) valuesForColumns:(NSMutableDictionary<NSNumber*, NSMutableSet*> *)idsWithColumns class:(Class)classObject translateDates:(BOOL)translateDates
{
	NSMutableDictionary <NSNumber*, NSMutableDictionary*> *values = [NSMutableDictionary new];
	NSMutableDictionary *columnsToFetch = [NSMutableDictionary new];
	AutoConcurrentMapTable *tableCache = [classObject tableCache];
	[tableCache syncPerformBlock:^(NSMapTable * _Nonnull table) {
		
		[idsWithColumns enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull idValue, NSMutableSet * _Nonnull columns, BOOL * _Nonnull stop) {
			
			//if the object exist in cache we don't need to fetch it
			AutoModel *object = [table objectForKey:idValue];
			if (object)
			{
				NSMutableDictionary *result = [NSMutableDictionary new];
				for (NSString *column in columns)
				{
					id value = [object valueForKey:column];
					if (!translateDates && value && [value isKindOfClass:[NSDate class]])
					{
						value = @([(NSDate*)value timeIntervalSince1970]);
					}
					result[column] = value ? value : [NSNull null];	//we must have null if there is null
				}
				result[@"id"] = idValue;
				values[idValue] = result;
			}
			else
			{
				//we group all ids by their columns, to fetch as few times as possible.
				if (!columnsToFetch[columns])
					columnsToFetch[columns] = [NSMutableArray arrayWithObject:idValue];
				else
					[columnsToFetch[columns] addObject:idValue];
			}
		}];
	}];
	
	//now loop through all and fetch them!
	NSString *classString = NSStringFromClass(classObject);
	NSDictionary <NSString*, NSNumber*> *columnSyntax;
	if (translateDates)
		columnSyntax = [self columnSyntaxForClass:classObject];
	[classObject inDatabase:^(AFMDatabase * _Nonnull db) {

		[columnsToFetch enumerateKeysAndObjectsUsingBlock:^(NSMutableSet* columnSet, NSArray *ids, BOOL * _Nonnull stop) {
			
			//sometimes columnSet looses its mutability...
			NSMutableArray *columns = columnSet.allObjects.mutableCopy;
			[columns insertObject:@"id" atIndex:0];
			NSString *selectQuery = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE id IN (%@)", [columns componentsJoinedByString:@","], classString, [AutoModel questionMarks:ids.count]];
			
			AFMResultSet *resultSet = [db executeQuery:selectQuery withArgumentsInArray:ids];
			while ([resultSet next])
			{
				NSMutableDictionary *result = [[NSMutableDictionary alloc] initWithCapacity:columns.count];
				[columns enumerateObjectsUsingBlock:^(id column, NSUInteger index, BOOL *stop)
				{
					id value = resultSet[(int)index];
					if (!value)
					{
						//here we must introduce an extra data type.
						value = [NSNull null];
					}
					else if (translateDates && columnSyntax[column].integerValue == AutoFieldTypeDate)
					{
						value = [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
					}
					result[column] = value;
					if (index == 0)
					{
						values[value] = result;
					}
				}];
			}
		}];
	}];
	
	return values;
}

#pragma mark - observing

- (void) setupObservingProperties:(Class)classObject
{
	//never hard-code anything
	NSString *typeFormat = [NSString stringWithFormat: @"%s%s%s%%s", @encode(void), @encode(id), @encode(SEL)];
	
	NSString *tableName = NSStringFromClass(classObject);
	NSDictionary *syntax = tableSyntax[tableName];
	NSDictionary <NSString *, NSNumber *>* columnSyntax = syntax[AUTO_COLUMN_KEY];
	for (NSString* property in columnSyntax)
	{
		if ([property isEqualToString:@"id"])
			continue;
		//here we swizzle the whole class once! Basically gives us tracking without any CPU-penalty. With this we can also know exactly what values that change, so we don't need to save the entire object every time. (for the future).
		
		NSString *methodName, *primitiveMethodName;
		objc_property_t propertyStruct = class_getProperty(classObject, property.UTF8String);
		char *setter = property_copyAttributeValue(propertyStruct, "S");	//S means custom Setter
		if (setter)
		{
			NSLog(@"customSetters and getters are illigal: %@::%s", classObject, setter);
			methodName = [NSString stringWithUTF8String:setter];
		}
		else
		{
			methodName = [NSString stringWithFormat:@"set%@%@:", [[property substringToIndex:1] uppercaseString], [property substringFromIndex:1]];
		}
		primitiveMethodName = [NSString stringWithFormat:@"setPrimitive%@%@:", [[property substringToIndex:1] uppercaseString], [property substringFromIndex:1]];
		
		NSSet *keyPaths = [classObject keyPathsForValuesAffectingValueForKey:property];
		if (keyPaths && keyPaths.count)
		{
			//swizzling these methods is kindof tricky since they can be of any type and any args.
			NSLog(@"Warning, at %@ trying to cascade changes by setting keyPathsForValuesAffecting%@ - this will not work, you need to call setHasChanges manually.", tableName, property);
		}
		
		//get the original method, implementation and selector:
		SEL originalSel = NSSelectorFromString(methodName);
		Method originalMethod = class_getInstanceMethod(classObject, originalSel);
		IMP originalImplementation = method_getImplementation(originalMethod);
		
		//we need to form type information, use what already exists.
		int argLength = 3;
		char argumentType[argLength];
		method_getArgumentType(originalMethod, 2, argumentType, argLength);
		const char *types = [[NSString stringWithFormat:typeFormat, argumentType] UTF8String];
		
		//create a version that isn't swizzled
		class_addMethod(classObject, NSSelectorFromString(primitiveMethodName), originalImplementation, argumentType);
		
		/*
		 To get the actual argument types we need to look inside the method. Currently we are changing the types when going through our swizzled methods.
		 if (strncmp(argumentType, @encode(id), argLength) == 0)
		 {
		 
		 }
		 else if (strncmp(argumentType, @encode(double), argLength) == 0)
		 {
		 
		 }
		 else if (strncmp(argumentType, @encode(NSInteger), argLength) == 0)
		 {
		 //unsigned long long = Q BUT NSInteger = q.
		 NSLog(@"Int has: %s", argumentType);
		 }
		 else
		 {
		 NSLog(@"ERROR No matching argumentType for %s", argumentType);
		 }
		 */
		AutoFieldType columnTypeInt = columnSyntax[property].integerValue;
		switch (columnTypeInt)
		{
			case AutoFieldTypeDate:
			case AutoFieldTypeNumber:
			case AutoFieldTypeText:
			case AutoFieldTypeBlob:
			case AutoFieldTypeUnknown:
			{
				//these have object args
				IMP newMethodIMP = imp_implementationWithBlock(^(AutoModel* objectSelf, id arg){
					
					//and inside we call hasChanges, then just call the original (if there are any changes and it is not deleted).
					if ((objectSelf->hasChanges == NO || objectSelf->registerChanges) && objectSelf->ignoreChanges == NO)	//TODO: set ignoreChanges when is_deleted
					{
						id oldValue = [objectSelf valueForKey:property];
						if (oldValue && arg && [oldValue isEqual:arg])
							return;
						else if (!oldValue && !arg)
							return;
						//hasChanges must come last!
						if (objectSelf->registerChanges && objectSelf.isToBeInserted == NO)
							[(objectSelf) registerChange:property oldValue:oldValue newValue:arg];
						((AutoModel*)objectSelf).hasChanges = YES;
					}
					void (*func)(id, SEL, id) = (void *)originalImplementation;
					func(objectSelf, originalSel, arg);
				});
				
				//we try to permanently change the class, so we only need to do this once!
				class_replaceMethod(classObject, originalSel, newMethodIMP, types);
				break;
			}
			case AutoFieldTypeInteger:
			{
				IMP newMethodIMP = imp_implementationWithBlock(^(AutoModel* objectSelf, NSInteger arg){
					
					//and inside we call hasChanges, then just call the original.
					if ((objectSelf->hasChanges == NO || objectSelf->registerChanges) && objectSelf->ignoreChanges == NO)
					{
						NSNumber *oldValue = [objectSelf valueForKey:property];
						if (oldValue && oldValue.integerValue == arg)
							return;
						if (objectSelf->registerChanges && objectSelf.isToBeInserted == NO)
							[((AutoModel*)objectSelf) registerChange:property oldValue:oldValue newValue:@(arg)];
						((AutoModel*)objectSelf).hasChanges = YES;
					}
					void (*func)(id, SEL, NSUInteger) = (void *)originalImplementation;
					func(objectSelf, originalSel, arg);
				});
				class_replaceMethod(classObject, originalSel, newMethodIMP, types);
				break;
			}
			case AutoFieldTypeDouble:
			{
				IMP newMethodIMP = imp_implementationWithBlock(^(AutoModel* objectSelf, double arg){
					
					//and inside we call hasChanges, then just call the original.
					if ((objectSelf->hasChanges == NO || objectSelf->registerChanges) && objectSelf->ignoreChanges == NO)
					{
						NSNumber *oldValue = [objectSelf valueForKey:property];
						if (oldValue && oldValue.doubleValue == arg)
							return;
						if (objectSelf->registerChanges && objectSelf.isToBeInserted == NO)
							[((AutoModel*)objectSelf) registerChange:property oldValue:oldValue newValue:@(arg)];
						((AutoModel*)objectSelf).hasChanges = YES;
					}
					void (*func)(id, SEL, double) = (void *)originalImplementation;
					func(objectSelf, originalSel, arg);
				});
				class_replaceMethod(classObject, originalSel, newMethodIMP, types);
				break;
			}
			default:
				break;
		}
	}
}

#pragma mark - helpers


@end


/* removed code, perhaps for the future
 
+ (NSDictionary*) fetchDuplicates:(NSString*)tableName
{
	AUTO_WAIT_FOR_SETUP
	
	NSDictionary *syntax = tableSyntax[tableName];
	NSMutableArray *columnQueries = [NSMutableArray new];
	for (NSString *column in [syntax[AUTO_COLUMN_KEY] allKeys])
	{
		if ([column isEqualToString:primaryKeyName] || [column isEqualToString:@"last_update"] || [column isEqualToString:@"sync_state"])
		{
			//ignore stuff inherited from AutoModel or AutoSync.
			continue;
		}
		NSString *query = [NSString stringWithFormat:@" AND a.%@ = b.%@", column, column];
		[columnQueries addObject:query];
	}
	NSString *query = [NSString stringWithFormat:@"SELECT a.id, b.id FROM %@ AS a, %@ AS b WHERE a.id != b.id %@ ORDER BY a.id, b.id", tableName, tableName, [columnQueries componentsJoinedByString:@""]];
	//NSLog(@"query %@", query);
	
	NSMutableDictionary *duplicateDictionary = [NSMutableDictionary new];
	[self.databaseQueue inDatabase:^(FMDatabase *db)
	 {
		 FMResultSet *result = [db executeQuery:query];
		 while ([result next])
		 {
			 NSNumber *a_id = [result objectForColumnIndex:0];
			 NSNumber *b_id = [result objectForColumnIndex:1];
			 NSNumber *rootNumber = a_id, *duplicateNumber = b_id;
			 
			 //duplicates comes always in pairs, first a,b then; b,a. This complicates things but we must only add duplicates once.
			 if (duplicateDictionary[b_id])
			 {
				 rootNumber = b_id;
				 duplicateNumber = a_id;
			 }
			 __block NSMutableSet *duplicates = duplicateDictionary[rootNumber];
			 if (duplicates)
			 {
				 [duplicates addObject:duplicateNumber];
				 continue;	//we have found our dup, and can continue to the next pair.
			 }
			 
			 //check all values to find wether something is a duplicate to some other item way up in the tree.
			 [duplicateDictionary enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSMutableSet *values, BOOL *stop)
			  {
				  for (NSNumber *storedValue in values.allObjects)
				  {
					  if ([storedValue isEqualToNumber:duplicateNumber] || [storedValue isEqualToNumber:rootNumber])
					  {
						  //TODO: please check that this works
						  [duplicates addObject:duplicateNumber];
						  [duplicates addObject:rootNumber];
						  duplicates = values;
						  *stop = YES;
						  break;
					  }
				  }
			  }];
			 
			 if (!duplicates)
			 {
				 duplicates = [NSMutableSet new];
				 [duplicates addObject:duplicateNumber];
				 duplicateDictionary[rootNumber] = duplicates;
			 }
			 
		 }
	 }];
	
	//It does check recursively to find wether something is a duplicate to some other item way up in the tree. As this example will make a and b two "root" numbers, even though they are equal: a = b, b = c, b = a etc...
	
	return duplicateDictionary;
}
*/
