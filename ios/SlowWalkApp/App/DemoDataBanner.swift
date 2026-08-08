import SwiftUI

/// Marks every screen that is driven by demo data.
///
/// Required by the project's safety rules: any demo content must be labelled so
/// it can never be mistaken for a clinical result.
struct DemoDataBanner: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(CompanionCopy.demoDataNotice)
                    .font(.headline)
                Text("演示数据，不用于临床用途")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(CompanionCopy.demoDataNotice)。演示数据，不用于临床用途。"
        )
    }
}

/// A low-emphasis marker for demo-driven screens where a full banner would
/// compete with the page's primary content.
struct DemoDataFooter: View {
    var body: some View {
        Text("\(CompanionCopy.demoDataNotice) · 演示数据，不用于临床用途")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
                "\(CompanionCopy.demoDataNotice)。演示数据，不用于临床用途。"
            )
    }
}

/// The app's standing reminder that SlowWalk gives reminders, not diagnoses.
struct NotADiagnosisNotice: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("使用说明")
                    .font(.headline)
                Text("SlowWalk 提供风险提示，不做医疗诊断。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("使用说明。SlowWalk 提供风险提示，不做医疗诊断。")
    }
}

#Preview("Light") {
    Form {
        Section {
            DemoDataBanner()
        }
        Section {
            NotADiagnosisNotice()
        }
    }
}

#Preview("Dark AX5") {
    Form {
        Section {
            DemoDataBanner()
        }
        Section {
            NotADiagnosisNotice()
        }
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
