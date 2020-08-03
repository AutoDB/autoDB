//
//  DataObjc.h
//  autoDBExample
//
//  Created by Olof Thorén on 2020-08-02.
//  Copyright © 2020 Aggressive Development AB. All rights reserved.
//

#import <AutoDBFramework/AutoDBFramework.h>

NS_ASSUME_NONNULL_BEGIN

@interface DataObjc: AutoModel

@property (nullable) NSString *name;

@end

NS_ASSUME_NONNULL_END
