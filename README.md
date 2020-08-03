# autoDB

Automatic persistence and database handling for iOS/mac etc. Fast, automatic migrations and thread safe.


##Usage


1. Inherit AutoModel in your classes (objc or Swift), and define your properties using "@objc dynamic".

```Swift
@objc(ExampleData) class ExampleData: AutoModel
{
	@objc dynamic var name: String?
}
```

2. Make sure you setup and migrate (if needed) before using the objects. It happens in the background, and is usually very fast:

```
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
{
	AutoDB.sharedInstance.createDatabaseMigrateBlock(nil)
	return true
}
```

3. Done. Use the objects like any other objects, and they will automatically be persisted on disc when the app closes. If you add or remove properties, the underlying database table will be migrated seamlessly. Only if you rename values or change their type, will you be required to do some work.

Open AutoDBExample to see an example project.

---

## Installation
1. Download or clone the repository. 
2. Drag the AutoDBFramework.xcodeproj into your project. 
3. In your target settings, under "General" -> "Frameworks, Libraries and embedded content". Click the plus button and select AutoDBFramework.framework

---

## 🚀🚀 Sponsorships 🚀🚀

AutoDB is fully funded by [Aggressive Development AB](https://aggressive.se). Who are currently using it in the great news reader [Feeds](https://feeds-app.com), please check it out! (Its also my job).

If you require support or need a feature implemented, you can support its development. You can also be listed here as an official sponsor. Feel free to drop me a line at [autoDB@aggressive.se](mailto:autoDB@aggressive.se) or twitter [@olof_t](https://twitter.com/olof_t)

---

## Performance

AutoDB has very little overhead, in fact since it automatically performs bulk-saves of all changed objects it may be very well more performant than doing sql-queries manually. It uses SQLite with regular queries which is very fast. One can also add indexes to make fetches even faster.

It uses a dedicated thread per database file to ensure thread safety, this is analogous to using queues and is safer than using pools but can slower when having multiple reads at the same time.

When objects are fetched they can of course be accessed and modified from any thread at any time, just like regular objects. 

All objects are cached (but only as long as they are referenced), this means that sequential fetches are faster and if you know the objects id (primary key) - the disc is not even touched.

---

## SQL

All of the underlying SQLite-power is still accessible, and you are free to perform any tasks you like.

## Differences from CoreData etc

1. It's a database first, with some ORM features (instead of the other way around)
2. Thread safe, you can fetch objects in one place and use them anywhere else.
3. Migrations are usually automatic, or never needed. You are still free to modify your classes at will.
4. No dangling references
5. No conflicts
6. Only one model since the class IS the model. No other files needed to define your database.

---

## Syncing

Syncing is almost complete, and will be open source as well. Including the server-side code. This will make AutoDB a easy to use, robust and free alternative to commercial software. So you can make sure your customers data stays safe instead of giving it to third parties and hope for their good will.

The classes for syncing and some documentation is included so if you want to take it for a spin you can.

---

## Contributing

Use the library and tell me about it! That contributes the most.

If you find any bugs I will gladly fix those, but I need an test-case, code example or something so that I can reproduce the issue.

Regarding the actual code: the main focus now is Swift, since I am moving all of my projects to Swift. Sadly Swift isn't powerful enough (yet), to replace Objc in all aspects that AutoDB needs, at least not in the way it works currently. There could be ways to work around the limitations of Swift, I have a few ideas but not the time to try it out.

These are the main points:

* Follow the code style or at least write as readable code as you possibly can.
* Have an automatic mind-set: use sane defaults that can be changed, and let the code do the work so humans don't have to. 
* Improve Swift APIs, making the APIs having a more Swift-friendly style
* Find bugs 
* Improve syncing: find bugs and build more tests regarding syncing.
* Replace key features using Swift


