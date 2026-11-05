import SwiftUI

// Explicit alias selects the property wrapper on SDKs that also export a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>
