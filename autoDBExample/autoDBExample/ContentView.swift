//
//  ContentView.swift
//  AutoDBExample
//
//  Created by Olof Thorén on 2020-08-02.
//  Copyright © 2020 Aggressive Development AB. All rights reserved.
//

import SwiftUI

struct ContentView: View
{
	let data: ExampleData
	
	init()
	{
		data = ExampleData.createInstance(withId: 1)
		data.counter += 1
	}
	
    var body: some View
	{
		Text("name: \(data.name!) counter: \(data.counter)")
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
