#import "AFMDatabase.h"
#import "unistd.h"
#import <objc/runtime.h>

@interface AFMDatabase ()

- (AFMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)args;
- (BOOL)executeUpdate:(NSString*)sql error:(NSError**)outErr withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)args;
@end

@implementation AFMDatabase
@synthesize cachedStatements=_cachedStatements;
@synthesize logsErrors=_logsErrors;
@synthesize crashOnErrors=_crashOnErrors;
@synthesize busyTimeout=_busyTimeout;
@synthesize checkedOut=_checkedOut;
@synthesize traceExecution=_traceExecution;

+ (instancetype)databaseWithPath:(NSString*)aPath
{
	return FMDBReturnAutoreleased([[self alloc] initWithPath:aPath]);
}

+ (NSString*)sqliteLibVersion
{
	return [NSString stringWithFormat:@"%s", sqlite3_libversion()];
}

+ (BOOL)isSQLiteThreadSafe
{
	// make sure to read the sqlite headers on this guy!
	return sqlite3_threadsafe() != 0;
}

- (instancetype)init
{
	return [self initWithPath:nil];
}

- (instancetype)initWithPath:(NSString*)aPath
{
	assert(sqlite3_threadsafe());
	self = [super init];
	
	if (self)
	{
		_databasePath		= [aPath copy];
		_openResultSets		= [[NSMutableSet alloc] init];
		_db					= nil;
		_logsErrors			= YES;
		_crashOnErrors		= NO;
		_busyTimeout		= 0;
        _cachedStatements = [NSMutableDictionary dictionary];
	}
	
	return self;
}

- (void)dealloc
{
	[self close];
	FMDBRelease(_openResultSets);
	FMDBRelease(_cachedStatements);
	FMDBRelease(_dateFormat);
	FMDBRelease(_databasePath);
	FMDBRelease(_openFunctions);
	
#if ! __has_feature(objc_arc)
	[super dealloc];
#endif
}

- (NSString *)databasePath
{
	return _databasePath;
}

- (sqlite3*)sqliteHandle
{
	return _db;
}

- (const char*)sqlitePath
{
	
	if (!_databasePath)
	{
		return ":memory:";
	}
	
	if ([_databasePath length] == 0)
	{
		return ""; // this creates a temporary database (it's an sqlite thing).
	}
	
	return [_databasePath fileSystemRepresentation];
	
}

- (BOOL)open
{
	if (_db)
	{
		return YES;
	}
	
	int err = sqlite3_open([self sqlitePath], &_db );
	if(err != SQLITE_OK)
	{
		NSLog(@"error opening!: %d", err);
		return NO;
	}
	
	if (_busyTimeout > 0.0)
	{
		sqlite3_busy_timeout(_db, (int)(_busyTimeout * 1000));
	}
	
	
	return YES;
}

#if SQLITE_VERSION_NUMBER >= 3005000
- (BOOL)openWithFlags:(int)flags
{
	/*
	 we have a strange error with releasing results while not beeing in the queue, SQLITE_OPEN_FULLMUTEX seems to solve this (by making db serialized) - we only access it in serialized mode anyway so this shouldn't matter.
	sqlite3_shutdown();
	if (sqlite3_config(SQLITE_CONFIG_SERIALIZED))
		NSLog(@"ERROR: SQLITE_CONFIG_SERIALIZED can't be used anymore!");
	sqlite3_initialize();
	*/
	
	int err = sqlite3_open_v2([self sqlitePath], &_db, flags, NULL /* Name of VFS module to use */);
	if(err != SQLITE_OK)
	{
		NSLog(@"error opening!: %d", err);
		return NO;
	}
	//we must know the limit on amount of variables, and divide our queries by that number. To know for sure we always set it to what is compiled at this moment in time (500000).
	sqlite3_limit(_db, SQLITE_LIMIT_VARIABLE_NUMBER, 500000);
	//int limit = sqlite3_limit(_db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	//NSLog(@"limit on amount of variables is: %i", limit);
	//Regardless of whether or not the limit was changed, the sqlite3_limit() interface returns the prior value of the limit. Hence, to find the current value of a limit without changing it, simply invoke this interface with the third parameter set to -1. (https://www.sqlite.org/c3ref/limit.html)
	
	if (_busyTimeout > 0.0)
	{
		sqlite3_busy_timeout(_db, (int)(_busyTimeout * 1000));
	}
	
	return YES;
}
#endif


- (BOOL)close
{
	if (!_db)
	{
		return YES;
	}
	
	[self clearCachedStatements];
	[self closeOpenResultSets];
	
	int	 rc;
	BOOL retry;
	BOOL triedFinalizingOpenStatements = NO;
	
    do
    {
		retry	= NO;
		rc		= sqlite3_close(_db);
		if (SQLITE_BUSY == rc || SQLITE_LOCKED == rc)
		{
			if (!triedFinalizingOpenStatements)
			{
				triedFinalizingOpenStatements = YES;
				sqlite3_stmt *pStmt;
				while ((pStmt = sqlite3_next_stmt(_db, nil)) !=0)
				{
					NSLog(@"Closing leaked statement");
					sqlite3_finalize(pStmt);
					retry = YES;
				}
			}
		}
		else if (SQLITE_OK != rc)
		{
			NSLog(@"error closing!: %d", rc);
		}
	}
	while (retry);
	
	_db = nil;
	return YES;
}


- (void)setRetryTimeout:(NSTimeInterval)timeout
{
	_busyTimeout = timeout;
	if (_db)
	{
		sqlite3_busy_timeout(_db, (int)(timeout * 1000));
	}
}

- (NSTimeInterval)retryTimeout
{
	return _busyTimeout;
}


// we no longer make busyRetryTimeout public
// but for folks who don't bother noticing that the interface to FMDatabase changed,
// we'll still implement the method so they don't get suprise crashes
- (int)busyRetryTimeout
{
	NSLog(@"%s:%d", __FUNCTION__, __LINE__);
	NSLog(@"FMDB: busyRetryTimeout no longer works, please use retryTimeout");
	return -1;
}

- (void)setBusyRetryTimeout:(int)i
{
	NSLog(@"%s:%d", __FUNCTION__, __LINE__);
	NSLog(@"FMDB: setBusyRetryTimeout does nothing, please use setRetryTimeout:");
}

- (void)clearCachedStatements
{
	for (NSMutableSet *statements in [_cachedStatements objectEnumerator])
	{
		[statements makeObjectsPerformSelector:@selector(close)];
	}
	
	[_cachedStatements removeAllObjects];
}

- (BOOL)hasOpenResultSets
{
	return [_openResultSets count] > 0;
}

- (void)closeOpenResultSets
{
	//Copy the set so we don't get mutation errors
	NSSet *openSetCopy = FMDBReturnAutoreleased([_openResultSets copy]);
	for (NSValue *rsInWrappedInATastyValueMeal in openSetCopy)
	{
		AFMResultSet *rs = (AFMResultSet *)[rsInWrappedInATastyValueMeal pointerValue];
		
		[rs setParentDB:nil];
		[rs close];
		
		[_openResultSets removeObject:rsInWrappedInATastyValueMeal];
	}
}

- (void)resultSetDidClose:(AFMResultSet *)resultSet
{
	NSValue *setValue = [NSValue valueWithNonretainedObject:resultSet];
	[_openResultSets removeObject:setValue];
}

- (void) removeCachedStatementForQuery:(NSString*)query
{
    //see also clearCachedStatements - NO close here, called by dealloc.
    [_cachedStatements removeObjectForKey:query];
}

- (FMStatement*)cachedStatementForQuery:(NSString*)query
{
	NSMutableSet* statements = [_cachedStatements objectForKey:query];
    for (FMStatement *statement in statements)
    {
        if (![statement inUse])
        {
            return statement;
        }
    }
    return nil;
}

- (void)setCachedStatement:(FMStatement*)statement forQuery:(NSString*)query
{
    statement.query = query.copy;   //just in case!
	NSMutableSet* statements = [_cachedStatements objectForKey:query];
	if (!statements)
	{
		statements = [NSMutableSet set];
        [_cachedStatements setObject:statements forKey:query];
	}
	
	[statements addObject:statement];
	
	FMDBRelease(query);
}

- (BOOL)rekey:(NSString*)key
{
	NSData *keyData = [NSData dataWithBytes:(void *)[key UTF8String] length:(NSUInteger)strlen([key UTF8String])];
	
	return [self rekeyWithData:keyData];
}

- (BOOL)rekeyWithData:(NSData *)keyData
{
#ifdef SQLITE_HAS_CODEC
	if (!keyData)
	{
		return NO;
	}
	
	int rc = sqlite3_rekey(_db, [keyData bytes], (int)[keyData length]);
	
	if (rc != SQLITE_OK)
	{
		NSLog(@"error on rekey: %d", rc);
		NSLog(@"%@", [self lastErrorMessage]);
	}
	
	return (rc == SQLITE_OK);
#else
	return NO;
#endif
}

- (BOOL)setKey:(NSString*)key
{
	NSData *keyData = [NSData dataWithBytes:[key UTF8String] length:(NSUInteger)strlen([key UTF8String])];
	
	return [self setKeyWithData:keyData];
}

- (BOOL)setKeyWithData:(NSData *)keyData
{
#ifdef SQLITE_HAS_CODEC
	if (!keyData)
	{
		return NO;
	}
	
	int rc = sqlite3_key(_db, [keyData bytes], (int)[keyData length]);
	
	return (rc == SQLITE_OK);
#else
	return NO;
#endif
}

+ (NSDateFormatter *)storeableDateFormat:(NSString *)format
{
	
	NSDateFormatter *result = FMDBReturnAutoreleased([[NSDateFormatter alloc] init]);
	result.dateFormat = format;
	result.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
	result.locale = FMDBReturnAutoreleased([[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]);
	return result;
}


- (BOOL)hasDateFormatter
{
	return _dateFormat != nil;
}

- (void)setDateFormat:(NSDateFormatter *)format
{
	FMDBAutorelease(_dateFormat);
	_dateFormat = FMDBReturnRetained(format);
}

- (NSDate *)dateFromString:(NSString *)s
{
	return [_dateFormat dateFromString:s];
}

- (NSString *)stringFromDate:(NSDate *)date
{
	return [_dateFormat stringFromDate:date];
}


- (BOOL)goodConnection
{
	
	if (!_db)
	{
		return NO;
	}
	
	AFMResultSet *rs = [self executeQuery:@"select name from sqlite_master where type='table'"];
	
	if (rs)
	{
		[rs close];
		return YES;
	}
	
	return NO;
}

- (void)warnInUse
{
	NSLog(@"The FMDatabase %@ is currently in use.", self);
	
#ifndef NS_BLOCK_ASSERTIONS
	if (_crashOnErrors)
	{
		NSAssert1(false, @"The FMDatabase %@ is currently in use.", self);
		abort();
	}
#endif
}

- (BOOL)databaseExists
{
	
	if (!_db)
	{
			
		NSLog(@"The FMDatabase %@ is not open.", self);
		
	#ifndef NS_BLOCK_ASSERTIONS
		if (_crashOnErrors)
		{
			NSAssert1(false, @"The FMDatabase %@ is not open.", self);
			abort();
		}
	#endif
		
		return NO;
	}
	
	return YES;
}

- (NSString*)lastErrorMessage
{
	return [NSString stringWithUTF8String:sqlite3_errmsg(_db)];
}

- (BOOL)hadError
{
	int lastErrCode = [self lastErrorCode];
	
	return (lastErrCode > SQLITE_OK && lastErrCode < SQLITE_ROW);
}

- (int)lastErrorCode
{
	return sqlite3_errcode(_db);
}


- (NSError*)errorWithMessage:(NSString*)message
{
	NSDictionary* errorMessage = [NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:@"FMDatabase" code:sqlite3_errcode(_db) userInfo:errorMessage];	   
}

- (NSError*)lastError
{
   return [self errorWithMessage:[self lastErrorMessage]];
}

- (sqlite_int64)lastInsertRowId
{
	
	if (_isExecutingStatement)
	{
		[self warnInUse];
		return NO;
	}
	
	_isExecutingStatement = YES;
	
	sqlite_int64 ret = sqlite3_last_insert_rowid(_db);
	
	_isExecutingStatement = NO;
	
	return ret;
}

- (int)changes
{
	if (_isExecutingStatement)
	{
		[self warnInUse];
		return 0;
	}
	
	_isExecutingStatement = YES;
	
	int ret = sqlite3_changes(_db);
	
	_isExecutingStatement = NO;
	
	return ret;
}

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

- (void)bindObject:(id)obj toColumn:(int)idx inStatement:(sqlite3_stmt*)pStmt usingTypes:(NSArray*)types
{
	int error_code = 0;
	if ((!obj) || ((NSNull *)obj == [NSNull null]))
	{
		sqlite3_bind_null(pStmt, idx);
	}
	else
	{
		switch ([types[idx] integerValue])
		{
			case AutoFieldTypeBlob:
			{
				const void *bytes = [obj bytes];
				if (!bytes)
				{
					// it's an empty NSData object, aka [NSData data].
					// Don't pass a NULL pointer, or sqlite will bind a SQL null instead of a blob.
					bytes = "";
				}
				sqlite3_bind_blob(pStmt, idx, bytes, (int)[obj length], SQLITE_STATIC);
				break;
			}
			case AutoFieldTypeDate:
			{
				sqlite3_bind_double(pStmt, idx, [obj timeIntervalSince1970]);
				break;
			}
			case AutoFieldTypeDouble:
			{
				error_code = sqlite3_bind_double(pStmt, idx, [obj doubleValue]);
				break;
			}
			case AutoFieldTypeInteger:
			{
				if (strcmp([obj objCType], @encode(BOOL)) == 0)
				{
					sqlite3_bind_int(pStmt, idx, ([obj boolValue] ? 1 : 0));
				}
				else if (strcmp([obj objCType], @encode(char)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj charValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned char)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj unsignedCharValue]);
				}
				else if (strcmp([obj objCType], @encode(short)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj shortValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned short)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj unsignedShortValue]);
				}
				else if (strcmp([obj objCType], @encode(int)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj intValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned int)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedIntValue]);
				}
				else if (strcmp([obj objCType], @encode(long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, [obj longValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedLongValue]);
				}
				else if (strcmp([obj objCType], @encode(long long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, [obj longLongValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned long long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, [obj unsignedLongLongValue]);
				}
				else if (strcmp([obj objCType], @encode(double)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, [obj longLongValue]);	//an int claiming to be double? this means it is very large, but is it unsigned or not?
				}
				else
				{
					error_code = sqlite3_bind_int64(pStmt, idx, [obj longLongValue]);
				}
				
				break;
			}
			case AutoFieldTypeNumber:
			{
				//we have an NSNumber, so no idea what it might be... We just have to guess...
				if (strcmp([obj objCType], @encode(BOOL)) == 0)
				{
					sqlite3_bind_int(pStmt, idx, ([obj boolValue] ? 1 : 0));
				}
				else if (strcmp([obj objCType], @encode(char)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj charValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned char)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj unsignedCharValue]);
				}
				else if (strcmp([obj objCType], @encode(short)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj shortValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned short)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj unsignedShortValue]);
				}
				else if (strcmp([obj objCType], @encode(int)) == 0)
				{
					error_code = sqlite3_bind_int(pStmt, idx, [obj intValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned int)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedIntValue]);
				}
				else if (strcmp([obj objCType], @encode(long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, [obj longValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedLongValue]);
				}
				else if (strcmp([obj objCType], @encode(long long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, [obj longLongValue]);
				}
				else if (strcmp([obj objCType], @encode(unsigned long long)) == 0)
				{
					error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedLongLongValue]);
				}
				else if (strcmp([obj objCType], @encode(float)) == 0)
				{
					error_code = sqlite3_bind_double(pStmt, idx, [obj floatValue]);
				}
				else if (strcmp([obj objCType], @encode(double)) == 0)
				{
					error_code = sqlite3_bind_double(pStmt, idx, [obj doubleValue]);
				}
                else
                {
					error_code = sqlite3_bind_text(pStmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
				}
				break;
			}
			case AutoFieldTypeText:
			{
				sqlite3_bind_text(pStmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
				break;
			}
			default:
				sqlite3_bind_text(pStmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
				break;
		}
		
		if (error_code)
		{
			NSLog(@"sqlite bind failed error: %i value: %@", error_code, obj);
		}
	}
}

- (void)bindObject:(id)obj toColumn:(int)idx inStatement:(sqlite3_stmt*)pStmt
{
	if ((!obj) || ((NSNull *)obj == [NSNull null]))
	{
		sqlite3_bind_null(pStmt, idx);
	}
	else if ([obj isKindOfClass:[NSData class]])
	{
		const void *bytes = [obj bytes];
		if (!bytes)
		{
			// it's an empty NSData object, aka [NSData data].
			// Don't pass a NULL pointer, or sqlite will bind a SQL null instead of a blob.
			bytes = "";
		}
		sqlite3_bind_blob(pStmt, idx, bytes, (int)[obj length], SQLITE_STATIC);
	}
	else if ([obj isKindOfClass:[NSDate class]])
	{
		if (self.hasDateFormatter)
			sqlite3_bind_text(pStmt, idx, [[self stringFromDate:obj] UTF8String], -1, SQLITE_STATIC);
		else
			sqlite3_bind_double(pStmt, idx, [obj timeIntervalSince1970]);
	}
	else if ([obj isKindOfClass:[NSNumber class]])
	{
		/*if (strcmp([obj objCType], @encode(double)) == 0)
		{
			NSLog(@"used to be a problem!");
		}*/
		BOOL ok = NO;
		CFNumberRef number = (__bridge CFNumberRef)obj;
		CFNumberType numberType = CFNumberGetType(number);
		switch (numberType)
		{
			case kCFNumberCGFloatType:
			case kCFNumberFloat64Type:
			case kCFNumberFloat32Type:
			{
				double value;
				ok = CFNumberGetValue(number, kCFNumberFloat64Type, &value);
				if (ok)
				{
					ok = (sqlite3_bind_double(pStmt, idx, value) == SQLITE_OK);
				}
				break;
			}
			default:
			{
				SInt64 value;
				ok = CFNumberGetValue(number, kCFNumberSInt64Type, &value);
				
				if (ok)
				{
					ok = (sqlite3_bind_int64(pStmt, idx, value) == SQLITE_OK);
				}
				break;
			}
		}
		if (!ok)
		{
			NSString *stringValue = [obj stringValue];
			ok = (sqlite3_bind_text(pStmt, idx, [stringValue UTF8String], -1, SQLITE_TRANSIENT) == SQLITE_OK);
			if (!ok)
			{
				NSLog(@"FMDatabase::Failed to bind statement");
			}
		}
		
		/*
		 if (strcmp([obj objCType], @encode(BOOL)) == 0)
		 {
			sqlite3_bind_int(pStmt, idx, ([obj boolValue] ? 1 : 0));
		}
		 else if (strcmp([obj objCType], @encode(char)) == 0)
		 {
			error_code = sqlite3_bind_int(pStmt, idx, [obj charValue]);
		}
		 else if (strcmp([obj objCType], @encode(unsigned char)) == 0)
		 {
			error_code = sqlite3_bind_int(pStmt, idx, [obj unsignedCharValue]);
		}
		 else if (strcmp([obj objCType], @encode(short)) == 0)
		 {
			error_code = sqlite3_bind_int(pStmt, idx, [obj shortValue]);
		}
		 else if (strcmp([obj objCType], @encode(unsigned short)) == 0)
		 {
			error_code = sqlite3_bind_int(pStmt, idx, [obj unsignedShortValue]);
		}
		 else if (strcmp([obj objCType], @encode(int)) == 0)
		 {
			error_code = sqlite3_bind_int(pStmt, idx, [obj intValue]);
		}
		 else if (strcmp([obj objCType], @encode(unsigned int)) == 0)
		 {
			error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedIntValue]);
		}
		 else if (strcmp([obj objCType], @encode(long)) == 0)
		 {
			error_code = sqlite3_bind_int64(pStmt, idx, [obj longValue]);
		}
		 else if (strcmp([obj objCType], @encode(unsigned long)) == 0)
		 {
			error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedLongValue]);
		}
		 else if (strcmp([obj objCType], @encode(long long)) == 0)
		 {
			error_code = sqlite3_bind_int64(pStmt, idx, [obj longLongValue]);
		}
		 else if (strcmp([obj objCType], @encode(unsigned long long)) == 0)
		 {
			error_code = sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedLongLongValue]);
		}
		 else if (strcmp([obj objCType], @encode(float)) == 0)
		 {
			error_code = sqlite3_bind_double(pStmt, idx, [obj floatValue]);
		}
		else if (strcmp([obj objCType], @encode(double)) == 0)
		{
			unsigned long long intValue = [obj unsignedLongLongValue];
			int64_t int64Value = (int64_t)[obj doubleValue];
			if (intValue == int64Value)
			{
				error_code = sqlite3_bind_int64(pStmt, idx, [obj unsignedLongLongValue]);
			}
			else
			{
				error_code = sqlite3_bind_double(pStmt, idx, [obj doubleValue]);
			}
		}
		else {
			error_code = sqlite3_bind_text(pStmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
		}
		if (error_code)
		{
			NSLog(@"sqlite bind failed error: %i value: %@", error_code, obj);
		}
		 */
	}
	else
	{
		sqlite3_bind_text(pStmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
	}
}

- (void)extractSQL:(NSString *)sql argumentsList:(va_list)args intoString:(NSMutableString *)cleanedSQL arguments:(NSMutableArray *)arguments
{
	
	NSUInteger length = [sql length];
	unichar last = '\0';
	for (NSUInteger i = 0; i < length; ++i)
	{
		id arg = nil;
		unichar current = [sql characterAtIndex:i];
		unichar add = current;
		if (last == '%')
		{
			switch (current)
			{
				case '@':
					arg = va_arg(args, id);
					break;
				case 'c':
					// warning: second argument to 'va_arg' is of promotable type 'char'; this va_arg has undefined behavior because arguments will be promoted to 'int'
					arg = [NSString stringWithFormat:@"%c", va_arg(args, int)];
					break;
				case 's':
					arg = [NSString stringWithUTF8String:va_arg(args, char*)];
					break;
				case 'd':
				case 'D':
				case 'i':
					arg = [NSNumber numberWithInt:va_arg(args, int)];
					break;
				case 'u':
				case 'U':
					arg = [NSNumber numberWithUnsignedInt:va_arg(args, unsigned int)];
					break;
				case 'h':
					i++;
					if (i < length && [sql characterAtIndex:i] == 'i')
					{
						//	warning: second argument to 'va_arg' is of promotable type 'short'; this va_arg has undefined behavior because arguments will be promoted to 'int'
						arg = [NSNumber numberWithShort:(short)(va_arg(args, int))];
					}
					else if (i < length && [sql characterAtIndex:i] == 'u')
					{
						// warning: second argument to 'va_arg' is of promotable type 'unsigned short'; this va_arg has undefined behavior because arguments will be promoted to 'int'
						arg = [NSNumber numberWithUnsignedShort:(unsigned short)(va_arg(args, uint))];
					}
                    else
                    {
						i--;
					}
					break;
				case 'q':
					i++;
					if (i < length && [sql characterAtIndex:i] == 'i')
					{
						arg = [NSNumber numberWithLongLong:va_arg(args, long long)];
					}
					else if (i < length && [sql characterAtIndex:i] == 'u')
					{
						arg = [NSNumber numberWithUnsignedLongLong:va_arg(args, unsigned long long)];
					}
                    else
                    {
						i--;
					}
					break;
				case 'f':
					arg = [NSNumber numberWithDouble:va_arg(args, double)];
					break;
				case 'g':
					// warning: second argument to 'va_arg' is of promotable type 'float'; this va_arg has undefined behavior because arguments will be promoted to 'double'
					arg = [NSNumber numberWithFloat:(float)(va_arg(args, double))];
					break;
				case 'l':
					i++;
					if (i < length)
					{
						unichar next = [sql characterAtIndex:i];
						if (next == 'l')
						{
							i++;
							if (i < length && [sql characterAtIndex:i] == 'd')
							{
								//%lld
								arg = [NSNumber numberWithLongLong:va_arg(args, long long)];
							}
							else if (i < length && [sql characterAtIndex:i] == 'u')
							{
								//%llu
								arg = [NSNumber numberWithUnsignedLongLong:va_arg(args, unsigned long long)];
							}
                            else
                            {
								i--;
							}
						}
						else if (next == 'd')
						{
							//%ld
							arg = [NSNumber numberWithLong:va_arg(args, long)];
						}
						else if (next == 'u')
						{
							//%lu
							arg = [NSNumber numberWithUnsignedLong:va_arg(args, unsigned long)];
						}
                        else
                        {
							i--;
						}
					}
                    else
                    {
						i--;
					}
					break;
				default:
					// something else that we can't interpret. just pass it on through like normal
					break;
			}
		}
		else if (current == '%')
		{
			// percent sign; skip this character
			add = '\0';
		}
		
		if (arg != nil)
		{
			[cleanedSQL appendString:@"?"];
			[arguments addObject:arg];
		}
		else if (add == (unichar)'@' && last == (unichar) '%')
		{
			[cleanedSQL appendFormat:@"NULL"];
		}
		else if (add != '\0')
		{
			[cleanedSQL appendFormat:@"%C", add];
		}
		last = current;
	}
}

- (AFMResultSet *)executeQuery:(NSString *)sql withParameterDictionary:(NSDictionary *)arguments
{
	return [self executeQuery:sql withArgumentsInArray:nil orDictionary:arguments orVAList:nil];
}

- (FMStatement*) cacheStatementForQuery:(NSString *)sql
{
    FMStatement *statement = [self cachedStatementForQuery:sql];
    if (!statement)
    {
        sqlite3_stmt *preparedStatement = 0x00;
        int rc = sqlite3_prepare_v2(_db, [sql UTF8String], -1, &preparedStatement, 0);
        
        if (SQLITE_OK != rc)
        {
            if (_logsErrors)
            {
                NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                NSLog(@"DB Query: %@", sql);
                NSLog(@"DB Path: %@", _databasePath);
            }
            
            //delete the preparedStatement
            sqlite3_finalize(preparedStatement);
            
            return nil;
        }
        
        statement = [[FMStatement alloc] init];
        statement.parameterCount = sqlite3_bind_parameter_count(preparedStatement);
        statement.statement = preparedStatement;
        [self setCachedStatement:statement forQuery:sql];
    }
    
    return statement;
}

- (AFMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)args
{
	
	if (![self databaseExists])
	{
		return 0x00;
	}
	
	if (_isExecutingStatement)
	{
		[self warnInUse];
		return 0x00;
	}
	
	_isExecutingStatement = YES;
	
	int rc					= 0x00;
	sqlite3_stmt *preparedStatement = 0x00;
	AFMResultSet *rs			= 0x00;
	
	if (_traceExecution && sql)
	{
		NSLog(@"%@ executeQuery: %@", self, sql);
	}
	
    FMStatement *statement = [self cachedStatementForQuery:sql];
	if (statement)
	{
        preparedStatement = [statement statement];
		[statement reset];
	}
	
	if (!preparedStatement)
	{
		rc = sqlite3_prepare_v2(_db, [sql UTF8String], -1, &preparedStatement, 0);
		
		if (SQLITE_OK != rc)
		{
			if (_logsErrors)
			{
				NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
				NSLog(@"DB Query: %@", sql);
				NSLog(@"DB Path: %@", _databasePath);
#ifndef NS_BLOCK_ASSERTIONS
				if (_crashOnErrors)
				{
					abort();
					NSAssert2(false, @"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
				}
#endif
			}
			
			sqlite3_finalize(preparedStatement);
			_isExecutingStatement = NO;
			return nil;
		}
	}
	
	id obj;
	int idx = 0;
	int queryCount = sqlite3_bind_parameter_count(preparedStatement); // pointed out by Dominic Yu (thanks!)
	
	// If dictionaryArgs is passed in, that means we are using sqlite's named parameter support
	if (dictionaryArgs)
	{
		for (NSString *dictionaryKey in [dictionaryArgs allKeys])
		{
			// Prefix the key with a colon.
			NSString *parameterName = [[NSString alloc] initWithFormat:@":%@", dictionaryKey];
			
			// Get the index for the parameter name.
			int namedIdx = sqlite3_bind_parameter_index(preparedStatement, [parameterName UTF8String]);
			
			if (namedIdx > 0)
			{
				// Standard binding from here.
				[self bindObject:[dictionaryArgs objectForKey:dictionaryKey] toColumn:namedIdx inStatement:preparedStatement];
				// increment the binding count, so our check below works out
				idx++;
			}
            else
            {
				NSLog(@"Could not find index for %@", dictionaryKey);
			}
		}
	}
	else
	{
		while (idx < queryCount)
		{
			if (arrayArgs && idx < (int)[arrayArgs count])
			{
				obj = [arrayArgs objectAtIndex:(NSUInteger)idx];
			}
			else if (args)
			{
				obj = va_arg(args, id);
			}
			else
			{
				//We ran out of arguments
				break;
			}
			
			if (_traceExecution)
			{
				if ([obj isKindOfClass:[NSData class]])
				{
					NSLog(@"data: %ld bytes", (unsigned long)[(NSData*)obj length]);
				}
                else
                {
					NSLog(@"obj: %@", obj);
				}
			}
			
			idx++;
			[self bindObject:obj toColumn:idx inStatement:preparedStatement];
		}
	}
	
	if (idx != queryCount)
	{
		NSLog(@"Error: the bind count is not correct for the # of variables (executeQuery)");
		sqlite3_finalize(preparedStatement);
		_isExecutingStatement = NO;
		return nil;
	}
	
	if (!statement)
	{
		statement = [[FMStatement alloc] init];
		[statement setStatement:preparedStatement];
		
		if (_shouldCacheStatements && sql)
		{
			[self setCachedStatement:statement forQuery:sql];
		}
	}
	
	// the statement gets closed in rs's dealloc or [rs close];
	rs = [AFMResultSet resultSetWithStatement:statement usingParentDatabase:self];
	[rs setQuery:sql];
	
	NSValue *openResultSet = [NSValue valueWithNonretainedObject:rs];
	[_openResultSets addObject:openResultSet];
	
	[statement setUseCount:[statement useCount] + 1];
	_isExecutingStatement = NO;
	return rs;
}

- (AFMResultSet *)executeQuery:(NSString*)sql, ...
{
	va_list args;
	va_start(args, sql);
	
	id result = [self executeQuery:sql withArgumentsInArray:nil orDictionary:nil orVAList:args];
	
	va_end(args);
	return result;
}

- (AFMResultSet *)executeQueryWithFormat:(NSString*)format, ...
{
	va_list args;
	va_start(args, format);
	
	NSMutableString *sql = [NSMutableString stringWithCapacity:[format length]];
	NSMutableArray *arguments = [NSMutableArray array];
	[self extractSQL:format argumentsList:args intoString:sql arguments:arguments];	   
	
	va_end(args);
	
	return [self executeQuery:sql withArgumentsInArray:arguments];
}

- (AFMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray *)arguments
{
	return [self executeQuery:sql withArgumentsInArray:arguments orDictionary:nil orVAList:nil];
}

- (AFMResultSet *)executeQuery:(NSString*)sql withVAList:(va_list)args
{
	return [self executeQuery:sql withArgumentsInArray:nil orDictionary:nil orVAList:args];
}

- (BOOL)executeUpdate:(NSString*)sql error:(NSError**)outErr withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)vaListArgs
{
	if (![self databaseExists])
	{
		return NO;
	}
	
	if (_isExecutingStatement)
	{
		[self warnInUse];
		return NO;
	}
	
	_isExecutingStatement = YES;
	
	int rc					 = 0x00;
	sqlite3_stmt *preparedStatement = 0x00;
	
	if (_traceExecution && sql)
	{
		NSLog(@"%@ executeUpdate: %@", self, sql);
	}
	
    //we might cache some statements but don't want to force caching of all.
    FMStatement *cachedStmt = [self cachedStatementForQuery:sql];
	if (cachedStmt)
	{
        preparedStatement = [cachedStmt statement];
		[cachedStmt reset];
	}
	
	if (!preparedStatement)
	{
		rc = sqlite3_prepare_v2(_db, [sql UTF8String], -1, &preparedStatement, 0);
		
		if (SQLITE_OK != rc)
		{
			if (_logsErrors)
			{
				NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
				NSLog(@"DB Query: %@", sql);
				NSLog(@"DB Path: %@", _databasePath);
#ifndef NS_BLOCK_ASSERTIONS
				if (_crashOnErrors)
				{
					abort();
					NSAssert2(false, @"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
				}
#endif
			}
			
			sqlite3_finalize(preparedStatement);
			if (outErr)
			{
				*outErr = [self errorWithMessage:[NSString stringWithUTF8String:sqlite3_errmsg(_db)]];
			}
			
			_isExecutingStatement = NO;
			return NO;
		}
	}
	
	id obj;
	int idx = 0;
	int queryCount = sqlite3_bind_parameter_count(preparedStatement);
	
	// If dictionaryArgs is passed in, that means we are using sqlite's named parameter support
	if (dictionaryArgs)
	{
		for (NSString *dictionaryKey in [dictionaryArgs allKeys])
		{		
			// Prefix the key with a colon.
			NSString *parameterName = [[NSString alloc] initWithFormat:@":%@", dictionaryKey];
			
			// Get the index for the parameter name.
			int namedIdx = sqlite3_bind_parameter_index(preparedStatement, [parameterName UTF8String]);
			
			FMDBRelease(parameterName);
			
			if (namedIdx > 0)
			{
				// Standard binding from here.
				[self bindObject:[dictionaryArgs objectForKey:dictionaryKey] toColumn:namedIdx inStatement:preparedStatement];
				
				// increment the binding count, so our check below works out
				idx++;
			}
            else
            {
				NSLog(@"Could not find index for %@", dictionaryKey);
			}
		}
	}
    else
    {
		
		while (idx < queryCount)
		{
			
			if (arrayArgs && idx < (int)[arrayArgs count])
			{
				obj = [arrayArgs objectAtIndex:(NSUInteger)idx];
			}
			else if (vaListArgs)
			{
				obj = va_arg(vaListArgs, id);
			}
            else
            {
				//We ran out of arguments
				break;
			}
			
			if (_traceExecution)
			{
				if ([obj isKindOfClass:[NSData class]])
				{
					NSLog(@"data: %ld bytes", (unsigned long)[(NSData*)obj length]);
				}
                else
                {
					NSLog(@"obj: %@", obj);
				}
			}
			
			idx++;
			
			[self bindObject:obj toColumn:idx inStatement:preparedStatement];
		}
	}
	
	
	if (idx != queryCount)
	{
		NSLog(@"Error: the bind count (%d) is not correct for the # of variables in the query (%d) (%@) (executeUpdate)", idx, queryCount, sql);
		sqlite3_finalize(preparedStatement);
		_isExecutingStatement = NO;
		return NO;
	}
	
	/* Call sqlite3_step() to run the virtual machine. Since the SQL being
	 ** executed is not a SELECT statement, we assume no data will be returned.
	 */
	
	rc = sqlite3_step(preparedStatement);
	
	if (SQLITE_DONE == rc)
	{
		// all is well, let's return.
	}
	else if (SQLITE_ERROR == rc)
	{
		if (_logsErrors)
		{
			NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_ERROR", rc, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
	else if (SQLITE_MISUSE == rc)
	{
		// uh oh.
		if (_logsErrors)
		{
			NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_MISUSE", rc, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
    else if (SQLITE_CONSTRAINT == rc)
    {
        // uh oh.
        if (_logsErrors)
        {
            NSLog(@"Error calling sqlite3_step, unique ids? (%d: %s) SQLITE_CONSTRAINT", rc, sqlite3_errmsg(_db));
            NSLog(@"DB Query: %@", sql);
        }
    }
    else
    {
		// wtf?
		if (_logsErrors)
		{
			NSLog(@"Unknown error calling sqlite3_step (%d: %s) wtf?", rc, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
	
	if (rc == SQLITE_ROW)
	{
		NSAssert1(NO, @"A executeUpdate is being called with a query string '%@'", sql);
	}
	
	if (_shouldCacheStatements && !cachedStmt && sql)
	{
		cachedStmt = [[FMStatement alloc] init];
		
		[cachedStmt setStatement:preparedStatement];
		
		[self setCachedStatement:cachedStmt forQuery:sql];
		
		FMDBRelease(cachedStmt);
	}
	
	int closeErrorCode;
	
	if (cachedStmt)
	{
		[cachedStmt setUseCount:[cachedStmt useCount] + 1];
		closeErrorCode = sqlite3_reset(preparedStatement);
	}
    else
    {
		/* Finalize the virtual machine. This releases all memory and other
		 ** resources allocated by the sqlite3_prepare() call above.
		 */
		closeErrorCode = sqlite3_finalize(preparedStatement);
	}
	
	if (closeErrorCode != SQLITE_OK)
	{
		if (_logsErrors)
		{
			NSLog(@"Unknown error finalizing or resetting statement (%d: %s)", closeErrorCode, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
	
	_isExecutingStatement = NO;
	return (rc == SQLITE_DONE || rc == SQLITE_OK);
}

- (BOOL)executeUpdate:(NSString*)sql withArgumentsInArray:(NSArray*)arrayArgs andTypes:(NSArray*)arrayTypes
{
	_isExecutingStatement = YES;
	
	sqlite3_stmt *pStmt		 = 0x00;
	FMStatement *cachedStmt	 = 0x00;
	int rc = sqlite3_prepare_v2(_db, [sql UTF8String], -1, &pStmt, 0);
	if (SQLITE_OK != rc)
	{
		if (_logsErrors)
		{
			NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
			NSLog(@"DB Query: %@", sql);
			NSLog(@"DB Path: %@", _databasePath);
		}
		
		sqlite3_finalize(pStmt);
		
		_isExecutingStatement = NO;
		return NO;
	}
	id obj;
	int idx = 0;
	int queryCount = sqlite3_bind_parameter_count(pStmt);
	
	while (idx < queryCount)
	{
		if (arrayArgs && idx < (int)[arrayArgs count])
		{
			obj = [arrayArgs objectAtIndex:(NSUInteger)idx];
		}
		else
		{
			//We ran out of arguments
			break;
		}
		
		if (_traceExecution)
		{
			if ([obj isKindOfClass:[NSData class]])
			{
				NSLog(@"data: %ld bytes", (unsigned long)[(NSData*)obj length]);
			}
			else
			{
				NSLog(@"obj: %@", obj);
			}
		}
		
		idx++;
		
		[self bindObject:obj toColumn:idx inStatement:pStmt];
	}
	
	if (idx != queryCount)
	{
		NSLog(@"Error: the bind count (%d) is not correct for the # of variables in the query (%d) (%@) (executeUpdate)", idx, queryCount, sql);
		sqlite3_finalize(pStmt);
		_isExecutingStatement = NO;
		return NO;
	}
	
	/* Call sqlite3_step() to run the virtual machine. Since the SQL being
	 ** executed is not a SELECT statement, we assume no data will be returned.
	 */
	
	rc = sqlite3_step(pStmt);
	
	if (SQLITE_DONE == rc)
	{
		// all is well, let's return.
	}
	else if (SQLITE_ERROR == rc)
	{
		if (_logsErrors)
		{
			NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_ERROR", rc, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
	else if (SQLITE_MISUSE == rc)
	{
		// uh oh.
		if (_logsErrors)
		{
			NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_MISUSE", rc, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
	else
	{
		// wtf?
		if (_logsErrors)
		{
			NSLog(@"Unknown error calling sqlite3_step (%d: %s) eu2", rc, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
	
	if (rc == SQLITE_ROW)
	{
		NSAssert1(NO, @"A executeUpdate is being called with a query string '%@'", sql);
	}
	
	int closeErrorCode;
	
	if (cachedStmt)
	{
		[cachedStmt setUseCount:[cachedStmt useCount] + 1];
		closeErrorCode = sqlite3_reset(pStmt);
	}
    else
    {
		/* Finalize the virtual machine. This releases all memory and other
		 ** resources allocated by the sqlite3_prepare() call above.
		 */
		closeErrorCode = sqlite3_finalize(pStmt);
	}
	
	if (closeErrorCode != SQLITE_OK)
	{
		if (_logsErrors)
		{
			NSLog(@"update:withArray:andTypes:: Unknown error finalizing or resetting statement (%d: %s)", closeErrorCode, sqlite3_errmsg(_db));
			NSLog(@"DB Query: %@", sql);
		}
	}
	
	_isExecutingStatement = NO;
	return (rc == SQLITE_DONE || rc == SQLITE_OK);
}

- (BOOL)executeUpdate:(NSString*)sql, ...
{
	va_list args;
	va_start(args, sql);
	
	BOOL result = [self executeUpdate:sql error:nil withArgumentsInArray:nil orDictionary:nil orVAList:args];
	
	va_end(args);
	return result;
}

- (BOOL)executeUpdate:(NSString*)sql withArgumentsInArray:(NSArray *)arguments
{
	return [self executeUpdate:sql error:nil withArgumentsInArray:arguments orDictionary:nil orVAList:nil];
}

- (BOOL)executeUpdate:(NSString*)sql withParameterDictionary:(NSDictionary *)arguments
{
	return [self executeUpdate:sql error:nil withArgumentsInArray:nil orDictionary:arguments orVAList:nil];
}

- (BOOL)executeUpdate:(NSString*)sql withVAList:(va_list)args
{
	return [self executeUpdate:sql error:nil withArgumentsInArray:nil orDictionary:nil orVAList:args];
}

- (BOOL)executeUpdateWithFormat:(NSString*)format, ...
{
	va_list args;
	va_start(args, format);
	
	NSMutableString *sql	  = [NSMutableString stringWithCapacity:[format length]];
	NSMutableArray *arguments = [NSMutableArray array];
	
	[self extractSQL:format argumentsList:args intoString:sql arguments:arguments];	   
	
	va_end(args);
	
	return [self executeUpdate:sql withArgumentsInArray:arguments];
}

- (BOOL)update:(NSString*)sql withErrorAndBindings:(NSError**)outErr, ...
{
	va_list args;
	va_start(args, outErr);
	
	BOOL result = [self executeUpdate:sql error:outErr withArgumentsInArray:nil orDictionary:nil orVAList:args];
	
	va_end(args);
	return result;
}

- (BOOL)rollback
{
	BOOL b = [self executeUpdate:@"rollback transaction"];
	
	if (b)
	{
		_inTransaction = NO;
	}
	
	return b;
}

- (BOOL)commit
{
	BOOL b =  [self executeUpdate:@"commit transaction"];
	
	if (b)
	{
		_inTransaction = NO;
	}
	
	return b;
}

- (BOOL)beginDeferredTransaction
{
	
	BOOL b = [self executeUpdate:@"begin deferred transaction"];
	if (b)
	{
		_inTransaction = YES;
	}
	
	return b;
}

- (BOOL)beginTransaction
{
	
	BOOL b = [self executeUpdate:@"begin exclusive transaction"];
	if (b)
	{
		_inTransaction = YES;
	}
	
	return b;
}

- (BOOL)inTransaction
{
	return _inTransaction;
}

#if SQLITE_VERSION_NUMBER >= 3007000

static NSString *FMEscapeSavePointName(NSString *savepointName)
{
	return [savepointName stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

- (BOOL)startSavePointWithName:(NSString*)name error:(NSError**)outErr
{
	
	NSParameterAssert(name);
	
	NSString *sql = [NSString stringWithFormat:@"savepoint '%@';", FMEscapeSavePointName(name)];
	
	if (![self executeUpdate:sql])
	{

		if (outErr)
		{
			*outErr = [self lastError];
		}
		
		return NO;
	}
	
	return YES;
}

- (BOOL)releaseSavePointWithName:(NSString*)name error:(NSError**)outErr
{
	
	NSParameterAssert(name);
	
	NSString *sql = [NSString stringWithFormat:@"release savepoint '%@';", FMEscapeSavePointName(name)];
	BOOL worked = [self executeUpdate:sql];
	
	if (!worked && outErr)
	{
		*outErr = [self lastError];
	}
	
	return worked;
}

- (BOOL)rollbackToSavePointWithName:(NSString*)name error:(NSError**)outErr
{
	
	NSParameterAssert(name);
	
	NSString *sql = [NSString stringWithFormat:@"rollback transaction to savepoint '%@';", FMEscapeSavePointName(name)];
	BOOL worked = [self executeUpdate:sql];
	
	if (!worked && outErr)
	{
		*outErr = [self lastError];
	}
	
	return worked;
}

- (NSError*)inSavePoint:(void (^)(BOOL *rollback))block
{
	static unsigned long savePointIdx = 0;
	
	NSString *name = [NSString stringWithFormat:@"dbSavePoint%ld", savePointIdx++];
	
	BOOL shouldRollback = NO;
	
	NSError *err = 0x00;
	
	if (![self startSavePointWithName:name error:&err])
	{
		return err;
	}
	
	block(&shouldRollback);
	
	if (shouldRollback)
	{
		// We need to rollback and release this savepoint to remove it
		[self rollbackToSavePointWithName:name error:&err];
	}
	[self releaseSavePointWithName:name error:&err];
	
	return err;
}

#endif


- (BOOL)shouldCacheStatements
{
	return _shouldCacheStatements;
}

- (void)setShouldCacheStatements:(BOOL)value
{
	_shouldCacheStatements = value;
	
	if (!_shouldCacheStatements)
	{
		[self setCachedStatements:nil];
	}
}

void FMDBBlockSQLiteCallBackFunction(sqlite3_context *context, int argc, sqlite3_value **argv);
void FMDBBlockSQLiteCallBackFunction(sqlite3_context *context, int argc, sqlite3_value **argv)
{
#if ! __has_feature(objc_arc)
	void (^block)(sqlite3_context *context, int argc, sqlite3_value **argv) = (id)sqlite3_user_data(context);
#else
	void (^block)(sqlite3_context *context, int argc, sqlite3_value **argv) = (__bridge id)sqlite3_user_data(context);
#endif
	block(context, argc, argv);
}


- (void)makeFunctionNamed:(NSString*)name maximumArguments:(int)count withBlock:(void (^)(sqlite3_context *context, int argc, sqlite3_value **argv))block
{
	
	if (!_openFunctions)
	{
		_openFunctions = [NSMutableSet new];
	}
	
	id b = FMDBReturnAutoreleased([block copy]);
	
	[_openFunctions addObject:b];
	
	/* I tried adding custom functions to release the block when the connection is destroyed- but they seemed to never be called, so we use _openFunctions to store the values instead. */
#if ! __has_feature(objc_arc)
	sqlite3_create_function([self sqliteHandle], [name UTF8String], count, SQLITE_UTF8, (void*)b, &FMDBBlockSQLiteCallBackFunction, 0x00, 0x00);
#else
	sqlite3_create_function([self sqliteHandle], [name UTF8String], count, SQLITE_UTF8, (__bridge void*)b, &FMDBBlockSQLiteCallBackFunction, 0x00, 0x00);
#endif
}

@end

@implementation FMStatement

@synthesize statement=_statement;
@synthesize query=_query;
@synthesize useCount=_useCount;
@synthesize inUse=_inUse;

- (void)dealloc
{
	[self close];
	FMDBRelease(_query);
#if ! __has_feature(objc_arc)
	[super dealloc];
#endif
}

- (void)close
{
	if (_statement)
	{
		sqlite3_finalize(_statement);
		_statement = 0x00;
	}
	
	_inUse = NO;
}

- (void)reset
{
	if (_statement)
	{
		sqlite3_reset(_statement);
	}
	
	_inUse = NO;
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"%@ %ld hit(s) for query %@", [super description], _useCount, _query];
}


@end
