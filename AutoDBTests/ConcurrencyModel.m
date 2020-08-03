//
//  ConcurrencyModel.m
//  AutoDB
//
//  Created by Olof Thorén on 2016-12-15.
//  Copyright © 2016 Aggressive Development AB. All rights reserved.
//

#import "ConcurrencyModel.h"

@implementation ConcurrencyModel

+ (instancetype) newSpecialModel
{
    return [self.class createInstance];
}

+ (BOOL) preventObservingProperties
{
	return YES;
}

@end
