//
//  ExampleData.swift
//  autoDBExample
//
//  Created by Olof Thorén on 2020-08-02.
//  Copyright © 2020 Aggressive Development AB. All rights reserved.
//

import Foundation

@objc(ExampleData) class ExampleData: AutoModel
{
	@objc dynamic var name: String?
	@objc dynamic var counter: Int = 0
	
	static func new(_ name: String) -> ExampleData
	{
		let item = createInstance()
		item.name = name
		return item
	}
	
	//here is an example of what it looks like to work with AutoDB
	func exampleWork()
	{
		//create an array of items
		let names = ["Gunnar", "Bertil", "Maja"]
		let data: [ExampleData] = names.map
		{
			ExampleData.new($0)
		}
		data.last?.counter = 3
		ExampleData.saveChanges()	//persist to disc
		
		//fetch specific values, note that any sqlite syntax works (omiting the "SELECT column..." statement.
		if let maja = ExampleData.fetchQuery("WHERE name = ?", arguments: ["Maja"])?.rows.first as? ExampleData
		{
			print(maja.counter)
		}
	}
}
