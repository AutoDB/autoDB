//
//  ConcurrencyModel.h
//  AutoDB
//
//  Created by Olof Thorén on 2016-12-15.
//  Copyright © 2016 Aggressive Development AB. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "AutoModel.h"

@interface ConcurrencyModel : AutoModel
{}

@property (nonatomic) NSString *name;
@property (nonatomic) NSDate *last_update;
@property (nonatomic) NSData *lots_of_data;
@property (nonatomic) double double_number;
@property (nonatomic) int int_number;
@property (nonatomic) int int_number_change_for_each_test_12312312312312312312312312312312312323;

+ (instancetype) newSpecialModel;

@end
