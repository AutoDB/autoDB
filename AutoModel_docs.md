//  Created by Olof Thorén on 2014-03-17.
//  Copyright (c) 2014 Aggressive Development. All rights reserved.

### Todo notes
warn when creating - WAIT check that this actually is the case.
if (DEBUG) NSLog(@"customSetters and getters are illigal: %@::%s", self, setter);

* explain that all defaults may change

* Add to docs: Note that variables should be atomic since you will write to DB by reading at the same time as you might be modifying them.
	- if you have many files there will be many threads just idling, not good. FUTURE: join them together after db-creating if we notice they are not used much (nope, can deadlock, but we can go to queues instead).
	- if we are using threads or queues should be an implementation detail.
* create table statements: have a dictionary for not null / allowing null? is this needed, objects must always be able to be null, and values can't.
 
* The only thing needed to be feature complete is Many-to-many relations. But do these matter? Only if you are gone sell this. - then no, we are going open source. We are not going open source, sell it or don't bother.
 
* Index, we have index on relations, and on single columns but can't define any complex ones.
	- we could just have an array with statements.
* Many-to-many relations, could be interesting to create, not sure how necessary it is. We have a plan!
 
* Optimize all StringWithFormat methods to use c instead: (not really necessary, updating/saving/fetching still take 99% of the time).
 int i = 50;
 char cString[classString.length];
 sprintf (cString, "%d", 36);
 could also move to Swift
 



* we have tested the query cache, and with it turned on we get about 5% performance gains. Not much, but some.

 
#AutoDB Documentation
An automatic database model built on top of sqlite. Simply declare properties for your data class, make it a subclass of AutoModel - and you are done!
 
Features:
All properties are automatically turned into an SQLite table. Define your classes in code, get a database for free.
The rules are simple, for in objc use non-dynamic (and non-readonly) properties for everything that goes into db. Swift must be @objc and dynamic. You may exclude properties from become persistent by putting their name in the exclude list (or just don't use properties, use ordinary variables instead). Swift can just omit @objc and dynamic. If you use properties that are NOT data, string, date or number, they can't go into a table and simply won't.

AutoDB can detect if a table needs updating, and do updates to table schema aka "lightweight migration". New columns, deletion of columns, renaming of columns and changing of types are all supported. Adding a column is more or less instant. New tables are not seen as a change to the schema, and don't require migration. This means that AutoModel does not require database versions and complicated migration steps - almost all dealings with the underlying db is taken care of for you (except when renaming and changing types).

ORM like behaviour by auto-caching fetched objects (weak linking, so they will be released when not in use). Every new fetch to the db will return cached objects (if in the cache), you will not have duplicate objects just because you fetched the same object in different places. However: Ensuring that relations are kept up to date, cascading deletions and similar ORM-features is not part of its job. You need to manage that yourself in the awakeFromFetch method.

Batch-saving unsaved changes, by keeping track of changes. No need to manually keep track of objects states. Just one method to save all unsaved changes. This does not actually cost you much (CPU-wise), but can still be turned off if you need to cram out every drop of power.

Handle relations. You can have related objects many-to-many, many-to-one (here they are called parent-children) or one-to-one (those are called strong-weak relations). Before you can access a relation you must fetch. Assuming you are a parent that stores the children in an array called _children, this is done like this:
 
    - (NSMutableArray *) children
    {
       if (hasFetchedRelations == NO)
       {
           [self.class fetchRelations:@[self]];
       }
       return _children;
    }
 
Naturally, calling fetchRelations with several objects at once is more efficient, and won't make GUI-execution get stuck in the middle. Handling of relations can be optimized.

1. when fetching the first object, we could tell the db that we want the relations immediately
2. The "handle relations" scheme above could easily be auto-generated and thus be automatic.
 
## Thread safety

A major goal of the AutoDB is to be thread safe, however, you must setup the db on the main thread so all lockings and similar get setup correctly. You do this by calling one of the "createDatabase" functions on the main thread during "applicationDidLaunch:" or similar method - so you know for sure nothing is accessing the DB at the same time as setup.

Setup is fast, and all that isn't needed for the main thread is done in a background thread. When the DB is setup, the locks are removed and it moves into regular thread-safe mode. Sqlite does not handle multiple threads well and ensure safety by locks/blocks (so critical paths only get's run by one thread at a time). AutoDB works similar with threads, and schedule blocks on serial queues. However, when objects are in memory or in the cache - they can have multi-threaded access, without the need for locks or queues (use atomic properties when having multithreaded access). And of course, it does not matter on which thread they were created.

## SWIFT
AutoDB works of-course in Swift as well, but there are a few things to note:

1. Classes need to be defined with a global name:
	@objc(MyClass) public class MyClass: AutoModel
2. All properties must be dynamic and public, and visible to objc:
	@objc dynamic public var myDataColumn: Data?
 
##General

New objects are created with one of the createInstance methods. You may create temporary objects by not saving them. Temporary objects can be useful when parsing a lot of data you need to keep track of, but later can discard. You may set the class method "useAutoIncrement" if you want their ids in sequence, otherwise they will generate a 50-bit random integer.
Objects are not inserted into the cache until their ids are finalized, which won't happen until they are saved. So don't put them into dictionaries (by id), until saved.

Saving is a costly procedure since we need to generate SQL and go into DB, so coalesce as many objects you can into one save. Especially when parsing e.g. a large XML, save at certain "checkpoints" (that you can skip to if you need to start over) to speed up parsing. Saving 100 objects takes basically the same time as saving one, when done at the same time.

Default values can be set in a dictionary "defaultValues", which then is used for the table definition.

Non-null: just use primitives that cannot be null (like double, integer etc). All others can be null and thus are allowed to be null. This will be changed in the future so you can force not-null objects.

## Fetching objects and AutoResult

Fetching objects is simple, either supply a list of ids (it can handle both NSNumbers and NSStrings) or a query. You will be given an AutoResult back populated with matching objects.

Whenever fetching objects you get an AutoResult back. These simply contain a dictionary and an array (rows) of the result. Most common is to get the results in the order of the query (particularly when you have an ORDER BY clause), but it is very convenient to also have quick access to the fetched ids - or to be able to refer to a fetched object by its id.

## Populating arrays or dictionaries (dependent properties)

Having dependent properties, like an array of strings made from JSON or some other stored data, is easy and convenient. Only make sure that you don't get circular references AND that changes to the collection actually triggers changes.

Imagine a class ClusterBucket which stores words in a dictionary:

```
@objc(ClusterBucket) public class ClusterBucket: AutoModel
{
	//here is the collection - no need for AutoDB to know about
	public var words = [String:Int]()
	{
		didSet
		{
			setHasChanges(true)	//this is where the magic happens, now data will be saved.
		}
	}
	
	//we use a backing variable to prevent circular references - no need for AutoDB to know about
	var _wordsJSON: Data?
	
	//a computed property takes care of the DB-connection
	@objc dynamic public var wordsJSON: Data?
	{
		get
		{
			//create data from collection
			if let json = try? JSONEncoder().encode(words)
			{
				return json
			}
			return nil
		}
		set
		{
			//save to the backing variable, note that this will trigger when first loaded from DB
			_wordsJSON = newValue	//"newValue" is defined by Swift
		}
	}
	
	public override func awakeFromFetch()
	{
		//Just after reading from DB, _wordsJSON contains the data. Decode it and move it to "words". We only read from wordsJSON when waking up and when writing to disc (saving).
		if let json = _wordsJSON,
			let result = try? JSONDecoder().decode([String:Int].self, from: json),
			result.count > 0
		{
			words = result 	//Note that this does not trigger hasChanges (since in awakeFromFetch)
		}
	}
}
```

##Cache
If you use the supplied methods to fetch objects (like fetchIds) you will get a cache for free. The primary objective for this cache is to guarantee that you *always get the same object*, no matter where you fetch data. Think of a situation where you have two different viewControllers showing the same objects, if one changes an object the other should update its views with the correct data. We solve this problem with having a cache where all objects live until no longer referenced (weak linking).

Future road map: There will be notifications to subscribe to when objects are modified. But for now you will need to use KVO or keep track of this yourself.

##Automatic DB Migration

AutoDB does not have a concept of "Database Versions". It's always current, and if you change the structure it automatically performs "Lightweight Migration", which handles the following:

* New columns
* Change of column type
* Adding index
* Deletion of columns
* Adding tables
* Adding databases (new files)
* Moving a table to a different database (between files).
* Adding or removing unique constraints

Adding a column is more or less instant. New tables are not seen as a change to the schema, and don't require migration at all. This means that AutoModel does not require database versions and complicated migration steps - almost all dealings with the underlying db is automatically taken care of.

Deletion, renaming and changing types requires modification of each row of your table, and will make the app pause during start when this migration is performed (on a background thread). If this is noticeable depends on how much data you have - it is usually a very fast operation, unlike e.g. core data migration.

Before migration takes place, a block is given with the affected table names. Here you may show a spinner or set a flag in userDefaults (for example) to know if it all worked. After migration is complete the same block is called, so you can remove the flag or do other cleanup processing, etc, before continuing with the app.

### Not Automatic Migration

Changing the type of a column requires you to implement the "migrateTable:" class method. AutoDB will give you an array of tuples where the second one is the value that needs change. You must replace that with a new value (or [NSNull null] if you want to remove it, and the column supports NULL).

Note that sqlite is type-dynamic so if you don't convert to correct types, it will give you the old types later when fetching. If the app gets killed during this process, the next time it's launched the system will believe all went fine and give you old types for the new columns. Then you might want/need to loop through the values and convert them manually. That's all!

Name change: To know that you are not deleting one column, and adding a completely new: you need to supply the new and old name like this:

    + (NSDictionary*) migrateParameters
	{
		return @{ @"old_name" : @"new_name" };
	}

If you change the name several times you need to have one relation from all old names to the new name, like if you start with the name 'number_of_employees', change your mind to 'amount_of_employees' but end up using 'employee_count'. You need to relations from the old names to the new:

    + (NSDictionary*) migrateParameters
	{
		NSDictionary* migrateParameters =
		@{
			@"number_of_employees" : @"employee_count",
			@"amount_of_employees" : @"employee_count"
		}
	 }

### Not migrating at all

Some features is not yet supported (but will be).

* removing index
* setting a complex index (that is more than just a regular index on a single column)
* renaming a table/class
* deleting a table/class

Those things needs to be done manually (for now). When renaming a whole class/table you can just, in the migration block (when state is complete), check if the old table stil exists and then insert all the old values in the new table. The sql for this is a one-liner (if the columns are still the same).

## Dates

Dates are stored as REAL(double) timestamp-values, and are converted to/from dates when read/written. They however still allow NULL and default to NULL. At the moment you cannot set them to NOT NULL.

##Detecting changes

Changes are detected unless you return YES from the class method "preventObservingProperties". If any property is changed, the object is placed in a weak-hashMap. And you can use saveAllWithChanges or saveChanges to write these changes to disk. The idea with weak references is that you should be able to throw away temporary objects, and that you usually have them stored in arrays/dictionaries anyway. Like this:

1. objects are created or fetched from db.
2. these objects are shown in a table-view
3. user changes a few of these objects
4. user navigates to some other place in the app,
5. the list gets removed and saveChanges gets called - the few objects are written to disk.

##Locks and queues
There are a few queues.
One queue for the database. This ensures there can be no reads/writes of the db happens at the same time.
One queue for accessing the caches, cacheQueue. By separating this from the databaseQueue we can come back from DB sooner, give back results and update the cache separately.
One queue for modifying tablesWithChanges, tablesWithChangesQueue, where we store all info on all changed objects.

You can separate the database into several files, creating one new queue for each file. This has two advantages:

1. You can have one file that is backed up to iCloud and one that is more like a scrapbook that can be recreated after re-installation. Also you can have one file for temporary data (in tmp folder), that can be thrown away.
2. Since each file has its own queue, this can give some performance boost. Usually sqlite is so fast that the bottleneck rarely is within fetching from db.

It has one major downside:

You cannot access tables in one file from the other file's queue. This means that you cannot have JOIN's between tables in different files.

##Async
Sqlite is very fast but fetching and updating a considerable amount of objects still takes noticeable amount of time. You should always use async methods when in the main thread. Especially when server-syncing is used since those operations takes an unknown amount of time. Sometimes it is absolutely important that execution does not continue while you perform an operation. Because of this every method has both an async and a corresponding synchronized version.

Here is an example when creating a new object with a specific id:

+ (void) createInstanceWithId:(u_int64_t)id_field result:(AutoModelSingleResultBlock)resultBlock;
+ (instancetype) createInstanceWithId:(u_int64_t)id_field;

Here we tell you that we have an async method since there is a resultBlock, the other method has a return value and are therefore blocking. This is always implemented by having a default blocking method, and the async method is just calling it wrapped in a async call.

##Sync
Sync is a work in progress, but almost complete!

## Caching specific queries with AutoModelCacheHandler

For more advanced uses you want to just fetch specific values, you can then cache queries (beneficial if the operation is happening frequently in the app). Here is an example of a query that fetches a list of ids for objects not read in x months:

	NSString *query = [ADFeedItem cachedQueryForSignature:@"AutoDeleteMonthSelect" objects:0 createBlock:^NSString * _Nonnull {
		return [NSString stringWithFormat:@"SELECT id FROM ADFeedItem WHERE isRead = 0 AND date < strftime('%%s', 'now','%i month')", (months * -1)];
	}];
	NSArray *ids = [ADFeedItem groupConcatQuery:query arguments:nil];


Note that it makes use of the short-hand method "groupConcatQuery", which returns an array with the first value of each row of the result. Take a look at the API to discover the other very handy convenience methods.

To know if caching is good or not, you simply need to test your app. Most of the time it does not matter much (actually). Simply put, sqlite is quite fast as it is. However, [NSString stringWithFormat:...] is not fast, so there lies an opportunity for optimization.

##COMMON QUESTIONS

* Will you convert to swift?

There are a lot of dynamism that Swift isn't capable of at the moment, and probably won't be in the foreseeable future. Without dynamic power, most of the automatic coding can't happen. There are however other ways to solve the same problems and I hope to get some time to look in to this. I really like Swift and while using objc in Swift usually works well there are a few annoyances you can't get around. 

##Architecture
The AutoModel class was so small in the beginning, and has gradually grown into one of those monolithic "Class method" classes, with several thousand rows of code. The create, fetch and update methods are taken care of by the AutoInsertStatement class, which also cache these.

##App Extensions

To make AutoDB work with app-extensions you must close the sqlite-file whenever exiting the app and also the extension, which can interfere with background processing. An alternative is to only use AutoDB in the main app.

AutoSync will not start syncing within extensions, but will recognize changes and sync when the main app launches again.

##Relations.

Disclaimer:
I started with this since I felt that auto-handling of relations should be an easy task and needed in every project. Later I came to the conclusion that it is in fact not needed at all, and probably easier to handle manually. however, for when you each and every time fetch an object's relations, it is more convenient to let it be handled automatically.

Setting it up:

One-to-many: We have two classes, parent class and child class. The child has a relation to parent, in the DB a value called "parent_id" (a 64 bit number), when fetching the object it gets stored in the "parent" property (optional and must be weak).
The parent has an NSMutableArray OR NSMutableSet property "children" where the children gets stored.
Each class has a dictionary connecting the variables with classes (here the classes are named AutoParent and AutoChild), these dictionary is returned from the class method "relations", on the form:

    NSDictionary *relations =
    @{
        AUTO_RELATIONS_PARENT_ID_KEY : @{ @"AutoParent" : @"parent_id"},
        AUTO_RELATIONS_PARENT_OBJECT_KEY : @{ @"AutoParent" : @"parent" } (optional)
    };

and in the parent:

    NSDictionary *relations =
    @{
        AUTO_RELATIONS_CHILD_CONTAINER_KEY : @{ @"AutoChild" : @"children" }
    };
	
	Note that the parent object must be a weak property. An alternative is to use a strong property (see below)
	if you don't need to store the children in an array.

For one-to-one relations we need one class who has the strong relation and a receiver who has the weak. The weak reference is optional.

    NSDictionary *relations =
    @{
        AUTO_RELATIONS_STRONG_ID_KEY : @{ @"AutoChild" : @"this_child_id" },
        AUTO_RELATIONS_STRONG_OBJECT_KEY : @{ @"AutoChild" : @"this_child" }
    };

    NSDictionary *relations =
    @{
       AUTO_RELATIONS_WEAK_OBJECT_KEY : @{ @"AutoParent" : @"this_parent" }
    };

Many-to-many relations are built by having one array of objects, and a comma separated string with all their ids. This is to contain the relation within one table, since joins might be impossible. The reverse-relation is built in the other class just the same way.

Note that you must to handle changes to the array and populating the id-string yourself.

    NSDictionary *relations =
    @{
		AUTO_RELATIONS_MANY_ID_KEY : @{ @"AutoManyChild" : @"manyChildIds" },
		AUTO_RELATIONS_MANY_CONTAINER_KEY : @{ @"AutoManyChild" : @"manyChildren" },
	};

Here our class have a string "manyChildIds" which are used when populating the mutable array "manyChildren" with objects of the "AutoManyChild" class.

OBSERVE: This causes a limit on how many relations you can have between two objects of the same types. A parent can only have one list of children (with the same class), if you want two lists (as goodChildren, and badChildren), you will have to divide these with other means. Like having the "good" property on the child instead. After fetching you can then separate the children into two arrays, and even delete the original array.

Side Note: We handle index automatically by setting a index on relations, since it will always be needed there.

This is quite easy to do yourself, so it is not much benefit to define the relations like this. However, the system is quite fast so it does not have much of an overhead so there are no real downsides either. But if you have a lot of relations, you need a system that keeps track of whether those have been fetched or not (and implement that code every time in every class). So this makes it easier since all that work is already tested and done.


TODO: figure out how to detect container changes AND auto-update the ids-string.

