import SwiftUI
import WidgetKit

struct SlowWalkWidgetEntry: TimelineEntry {
    let date: Date
}

struct SlowWalkWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SlowWalkWidgetEntry {
        SlowWalkWidgetEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (SlowWalkWidgetEntry) -> Void
    ) {
        completion(SlowWalkWidgetEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SlowWalkWidgetEntry>) -> Void
    ) {
        let timeline = Timeline(
            entries: [SlowWalkWidgetEntry(date: Date())],
            policy: .never
        )
        completion(timeline)
    }
}

struct SlowWalkWidgetEntryView: View {
    let entry: SlowWalkWidgetEntry

    var body: some View {
        Text("慢走")
            .font(.headline)
    }
}

struct SlowWalkWidget: Widget {
    private let kind = "SlowWalkWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: SlowWalkWidgetProvider()
        ) { entry in
            SlowWalkWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("慢走")
        .description("在主屏幕查看步行与安全状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
