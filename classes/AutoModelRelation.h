//
//  AutoModelRelation.h
//  Simulator
//
//  Created by Olof Thorén on 2014-04-08.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AutoModel.h"
@class AFMDatabaseQueue;

//These classes can be used to store to-many relationships, and you can implement any other you like as long as they follow the AutoDBCollection.

@protocol AutoDBCollection <NSObject>
@property (nonatomic) BOOL hasChanges;
@property (nonatomic, weak) AutoModel *owner;
@end

@interface AutoDBArray<ObjectType> : NSMutableArray<ObjectType> <AutoDBCollection>
@end

@interface AutoDBSet<ObjectType> : NSMutableSet<ObjectType> <AutoDBCollection>
@end

@interface AutoDBOrderedSet<ObjectType> : NSMutableOrderedSet<ObjectType> <AutoDBCollection>
@end


@interface AutoModelRelation : NSObject

@property (nonatomic) Class mainClass;
@property (nonatomic) NSMutableDictionary* mainObjects;
@property (nonatomic) NSMutableArray* relatedObjects;
@property (nonatomic) NSMutableDictionary* databaseCache;
@property (nonatomic, readonly) NSDictionary *relationDictionary;


+ (void) fetchRelations:(NSArray*)objects_in queue:(AFMDatabaseQueue *)databaseQueue;

@end
