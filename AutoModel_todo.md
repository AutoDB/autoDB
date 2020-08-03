//  Created by Olof Thorén on 2014-03-17.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.

#AutoDB TODO

* think about changing many-to-many arrays and getting notified at once (and updating string-ids).
	- swift has property observers that solve this problem
	- swift also can do lazy-loading, so we could e.g. fetch from db when requested instead of at once.
* ALSO:
	- detect abandoned old tables
	- @warning If you have dependent properties you need to call keyPathsForValuesAffecting<property-name> to get automatic behaviour (like if you store a dictionary in the db under some other property).
		! this is not true - test!

* //TODO: if table exist, drop first!

* Detecting changes: since large classes takes such huge amount of time to save, it would be nice if we could detect changed variables - and only save those.

Building bitFields like this?

NSDictionary *columnSyntax = [AutoDB.sharedInstance columnSyntaxForClass:self];
NSArray *columns = [columnSyntax allKeys];
NSInteger index = [columns indexOfObject:propertyName];
if (bitField & 1 << index)
	//it is changed.


* Allow dictionaries/arrays/other objects to be stored in DB as a Data row. All we need is a way to convert to/from Data.

##Grouped settings / bitFields

Look at these: all those could be a single setting. Better or worse?

+ (NSSet*) excludeParametersFromTable
{
	return [NSSet setWithObjects:@"mutations", @"showAll", nil];
}

+ (BOOL) useAutoIncrement
{
    return YES;
}

+ (BOOL)preventObservingProperties
{
	return YES;
}


##Thinking

	man cmp 

Compare files byte-by-byte, made by GNU and should be open source. When building sync, perhaps this is the way to go?