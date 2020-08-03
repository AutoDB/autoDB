//
//  AutoParent.h
//  AutoDB
//
//  Created by Olof Thoren on 2018-08-09.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "AutoModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface AutoStrongChild : AutoModel
@property NSString *name;
@end

@interface AutoManyChild : AutoModel
@property NSString *name;
@end

@interface AutoParent : AutoModel

@property NSString *name;
@property NSMutableArray <__kindof AutoModel*> *children;
@property uint64_t strong_child_id;
@property AutoStrongChild *strong_child;

@property NSString *manyChildIds;
@property NSMutableArray <__kindof AutoModel*> *manyChildren;

@end

@interface AutoChild : AutoModel

@property NSString *name;
@property uint64_t parent_id;
@property (weak) AutoParent *parent;

@end

NS_ASSUME_NONNULL_END
