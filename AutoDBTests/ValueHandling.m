//
//  ValueHandling.m
//  AutoDB
//
//  Created by Olof Thorén on 2018-08-21.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "ValueHandling.h"

@implementation ValueHandling

+ (NSSet<NSString *> *)keyPathsForValuesAffectingDate
{
	return [NSSet setWithObject:@"magicDate"];
}

- (void) magicDate:(NSString*)dateString
{
	NSLog(@"now we are changing date!");
}

@end
