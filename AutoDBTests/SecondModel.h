//
//  SecondModel.h
//  AutoDB
//
//  Created by Olof Thoren on 2018-08-05.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "AutoModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface SecondModel : AutoModel

@property (nonatomic) NSString *string;
@property (nonatomic) NSDate *last_update;	//to compare the two models they need the same columns
@property (nonatomic) NSData *lots_of_data;
@property (nonatomic) double double_number;
@property (nonatomic) int int_number;
@property (nonatomic) int int_number_change_for_each_test_12312312312312312312312312312312312323;

@end

NS_ASSUME_NONNULL_END
