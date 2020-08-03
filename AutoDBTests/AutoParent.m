//
//  AutoParent.m
//  AutoDB
//
//  Created by Olof Thoren on 2018-08-09.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "AutoParent.h"

@implementation AutoParent

+ (NSDictionary*) relations
{
	return @{
		AUTO_RELATIONS_CHILD_CONTAINER_KEY : @{ @"AutoChild" : @"children" },
		AUTO_RELATIONS_STRONG_ID_KEY : @{ @"AutoStrongChild" : @"strong_child_id" },
		AUTO_RELATIONS_STRONG_OBJECT_KEY : @{ @"AutoStrongChild" : @"strong_child" },
		AUTO_RELATIONS_MANY_ID_KEY : @{ @"AutoManyChild" : @"manyChildIds" },
		AUTO_RELATIONS_MANY_CONTAINER_KEY : @{ @"AutoManyChild" : @"manyChildren" },
	};
}

@end

@implementation AutoChild

+ (NSDictionary*) relations
{
  	return @{
	  	AUTO_RELATIONS_PARENT_ID_KEY : @{ @"AutoParent" : @"parent_id"},
		//AUTO_RELATIONS_PARENT_OBJECT_KEY : @{ @"AutoParent" : @"parent" }
	};
}

@end

@implementation AutoStrongChild
@end

@implementation AutoManyChild
@end
