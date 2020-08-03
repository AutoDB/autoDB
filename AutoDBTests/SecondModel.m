//
//  SecondModel.m
//  AutoDB
//
//  Created by Olof Thoren on 2018-08-05.
//  Copyright © 2018 Aggressive Development AB. All rights reserved.
//

#import "SecondModel.h"

@implementation SecondModel

+ (BOOL) preventObservingProperties
{
	return NO;
}

+ (void) migrateTable:(NSString*)table column:(NSString*)column oldType:(AutoFieldType)oldType newType:(AutoFieldType)newType values:(NSMutableArray <NSMutableArray*>*)arrayOfTuples
{
	NSLog(@"table %@ column %@", table, column);
	for (NSMutableArray *tuples in arrayOfTuples)
	{
		id secondValue = tuples[1];
		if (oldType == AutoFieldTypeBlob && [secondValue isKindOfClass:[NSData class]])
		{
			NSString *newValue = [[NSString alloc] initWithData:secondValue encoding:NSUTF8StringEncoding];
			[tuples replaceObjectAtIndex:1 withObject:newValue];
		}
		else if (oldType == AutoFieldTypeText && [secondValue isKindOfClass:[NSString class]])
		{
			NSData *newValue = [(NSString*)secondValue dataUsingEncoding:NSUTF8StringEncoding];
			if (newValue)
				[tuples replaceObjectAtIndex:1 withObject:newValue];
		}
		
	}
}

@end
