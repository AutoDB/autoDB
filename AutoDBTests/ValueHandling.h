//
//  ValueHandling.h
//  AutoDB
//
//  Created by Olof Thorén on 2018-08-21.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "AutoModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface ValueHandling : AutoModel

@property double doubleValue;
@property (getter=getInt, setter=setInt:) NSUInteger integer;
@property NSDate *date;
@property (nullable, setter=stringSet:) NSString *string;

- (void) magicDate:(NSString*)dateString;

@end

NS_ASSUME_NONNULL_END
