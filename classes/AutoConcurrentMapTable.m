//
//  AutoConcurrentMapTable.m
//  rss
//
//  Created by Olof Thorén on 2018-08-28.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "AutoConcurrentMapTable.h"

@implementation AutoConcurrentMapTable
{
	NSMapTable *_backingStore;
	dispatch_queue_t _queue;
}
- (instancetype) init
{
	self = [super init];
	_queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
	return self;
}

+ (instancetype) strongToWeakObjectsMapTable
{
	AutoConcurrentMapTable *table = [AutoConcurrentMapTable new];
	table->_backingStore = [NSMapTable strongToWeakObjectsMapTable];
	return table;
}

+ (instancetype) weakToStrongObjectsMapTable
{
	AutoConcurrentMapTable *table = [AutoConcurrentMapTable new];
	table->_backingStore = [NSMapTable weakToStrongObjectsMapTable];
	return table;
}

+ (instancetype) strongToStrongObjectsMapTable
{
	AutoConcurrentMapTable *table = [AutoConcurrentMapTable new];
	table->_backingStore = [NSMapTable strongToStrongObjectsMapTable];
	return table;
}

- (NSUInteger)count
{
	__block NSUInteger count;
	dispatch_sync(_queue, ^{ count = _backingStore.count; });
	return count;
}

- (id)objectForKey:(id)key
{
	if (!key)
	{
		return nil;
	}
	__block id value;
	dispatch_sync(_queue, ^{ value = [_backingStore objectForKey:key]; });
	return value;
}

- (id)objectForKeyedSubscript:(id)key
{
	if (!key)
	{
		return nil;
	}
	__block id value;
	dispatch_sync(_queue, ^{ value = [_backingStore objectForKey:key]; });
	return value;
}

- (void)setObject:(id)object forKey:(id)key
{
	if (!key)
	{
		return;
	}
	
	//There is no point in doing this async - since we will most likely need the queue at once. Then we will just have to wait for GCD to context-switch and find threads etc.
	dispatch_sync(_queue, ^{
		
		if (!object)
			[_backingStore removeObjectForKey:key];
		else
			[_backingStore setObject:object forKey:key];
	});
}

- (void)setObject:(id)object forKeyedSubscript:(id<NSCopying>)key
{
	if (!key)
	{
		return;
	}
	[self setObject:object forKey:(id)key];
}

- (void)removeObjectForKey:(id)key
{
	if (!key)
	{
		return;
	}
	dispatch_async(_queue, ^{ [self->_backingStore removeObjectForKey:key]; });
}

- (void)removeAllObjects
{
	dispatch_async(_queue, ^{ [self->_backingStore removeAllObjects]; });
}

- (NSArray*) allKeys
{
	__block NSArray* keys = nil;
	dispatch_sync(_queue, ^{ keys = self->_backingStore.keyEnumerator.allObjects; });
	return keys;
}

- (NSArray*) allValues
{
	__block NSArray* values = nil;
	dispatch_sync(_queue, ^{ values = _backingStore.objectEnumerator.allObjects; });
	return values;
}

- (void)asyncExecuteBlock:(void(^)(NSMapTable *table)) block
{
	dispatch_async(_queue, ^{ block(self->_backingStore); });
}

- (void) syncPerformBlock:(void(^)(NSMapTable *table)) block
{
	dispatch_sync(_queue, ^{ block(_backingStore); });
}

@end
