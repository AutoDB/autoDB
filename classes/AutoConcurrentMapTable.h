//
//  AutoConcurrentMapTable.h
//  rss
//
//  Created by Olof Thorén on 2018-08-28.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import <Foundation/Foundation.h>

//https://stackoverflow.com/questions/36634315/dispatch-barrier-sync-always-deadlocks

NS_ASSUME_NONNULL_BEGIN

@interface AutoConcurrentMapTable<KeyType, ObjectType> : NSObject

+ (instancetype) strongToStrongObjectsMapTable;
+ (instancetype) strongToWeakObjectsMapTable;
+ (instancetype) weakToStrongObjectsMapTable;

- (nullable ObjectType)objectForKey:(nullable KeyType)key;
- (nullable ObjectType)objectForKeyedSubscript:(nullable KeyType)key;
- (void)setObject:(nullable ObjectType)object forKey:(nullable KeyType)key;
///Note: This casts objects that support copy to non-copy, so you can use subscripting with your map tables.
- (void)setObject:(nullable ObjectType)object forKeyedSubscript:(nullable KeyType<NSCopying>)key;
- (void)removeObjectForKey:(nullable KeyType)key;
- (void)removeAllObjects;
- (NSUInteger)count;
- (NSArray <KeyType>*) allKeys;
- (NSArray <ObjectType>*) allValues;

///Execute block inside queue asynchronously.
- (void)asyncExecuteBlock:(void(^)(NSMapTable *table)) block;
///Synchronously run block inside queue, waiting until complete.
- (void) syncPerformBlock:(void(^)(NSMapTable *table)) block;

@end

NS_ASSUME_NONNULL_END
