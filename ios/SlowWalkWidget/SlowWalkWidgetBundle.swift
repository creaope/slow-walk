import SwiftUI
import WidgetKit

@main
struct SlowWalkWidgetBundle: WidgetBundle {
    var body: some Widget {
        SlowWalkWidget()
        SlowWalkLiveActivity()
    }
}
