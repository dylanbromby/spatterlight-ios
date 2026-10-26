import SwiftUI

/// Settings are saved as they change; this model just feeds the form.
final class SettingsModel: ObservableObject {
    private let store = Settings.shared

    @Published var theme: ReaderTheme { didSet { store.theme = theme } }
    @Published var paneLayout: PaneLayout { didSet { store.paneLayout = paneLayout } }
    @Published var sidePane: SidePaneContent { didSet { store.sidePane = sidePane } }
    @Published var sidePaneSide: PaneSide { didSet { store.sidePaneSide = sidePaneSide } }
    @Published var sidePaneWidth: Double { didSet { store.sidePaneWidthFraction = sidePaneWidth } }
    @Published var autosave: Bool { didSet { store.autosave = autosave } }
    @Published var showGraphics: Bool { didSet { store.showGraphics = showGraphics } }
    @Published var haptics: Bool { didSet { store.haptics = haptics } }
    @Published var announceText: Bool { didSet { store.announceText = announceText } }
    @Published var showKeyRow: Bool { didSet { store.showKeyRow = showKeyRow } }

    init() {
        theme = store.theme
        paneLayout = store.paneLayout
        sidePane = store.sidePane
        sidePaneSide = store.sidePaneSide
        sidePaneWidth = store.sidePaneWidthFraction
        autosave = store.autosave
        showGraphics = store.showGraphics
        haptics = store.haptics
        announceText = store.announceText
        showKeyRow = store.showKeyRow
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ReaderPreview(theme: model.theme)
                        .listRowInsets(EdgeInsets())
                }

                Section("Appearance") {
                    Picker("Colours", selection: $model.theme.palette) {
                        ForEach(ReaderTheme.Palette.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Story font", selection: $model.theme.bodyFont) {
                        ForEach(ReaderTheme.BodyFont.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Fixed-width font", selection: $model.theme.fixedFont) {
                        ForEach(ReaderTheme.FixedFont.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper(value: $model.theme.fontSize, in: 12...36, step: 1) {
                        LabeledContent("Text size", value: "\(Int(model.theme.fontSize)) pt")
                    }
                    Toggle("Follow system text size", isOn: $model.theme.followsDynamicType)
                    Stepper(value: $model.theme.lineSpacing, in: 0...14, step: 1) {
                        LabeledContent("Line spacing", value: "\(Int(model.theme.lineSpacing)) pt")
                    }
                    Stepper(value: $model.theme.margin, in: 4...48, step: 4) {
                        LabeledContent("Margins", value: "\(Int(model.theme.margin)) pt")
                    }
                    Toggle("Justify text", isOn: $model.theme.justify)
                    Toggle("Colour your commands", isOn: $model.theme.accentInput)
                }

                Section {
                    Picker("Panes", selection: $model.paneLayout) {
                        ForEach(PaneLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Side pane shows", selection: $model.sidePane) {
                        ForEach(SidePaneContent.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .disabled(model.paneLayout == .single)
                    Picker("Side pane position", selection: $model.sidePaneSide) {
                        ForEach(PaneSide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.paneLayout == .single)
                    VStack(alignment: .leading) {
                        LabeledContent("Side pane width", value: "\(Int(model.sidePaneWidth * 100))%")
                        Slider(value: $model.sidePaneWidth, in: 0.25...0.6, step: 0.01)
                            .accessibilityLabel("Side pane width")
                    }
                    .disabled(model.paneLayout == .single)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("On a foldable or a wide screen the story can sit beside your library, notes, or commands. “Automatic” uses two panes whenever there is room.")
                }

                Section("Playing") {
                    Toggle("Autosave and resume", isOn: $model.autosave)
                    Toggle("Show pictures", isOn: $model.showGraphics)
                    Toggle("Keys row for “press any key”", isOn: $model.showKeyRow)
                    Toggle("Haptic feedback", isOn: $model.haptics)
                    Toggle("Read new text aloud with VoiceOver", isOn: $model.announceText)
                }

                Section {
                    LabeledContent("Interpreters", value: "Bocfel (Z-code), Glulxe (Glulx)")
                    Link("Spatterlight on GitHub", destination: URL(string: "https://github.com/angstsmurf/spatterlight")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Spatterlight is by Petter Sjölund and contributors. Changes made here apply immediately.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}

/// A few lines of sample text in the chosen theme.
struct ReaderPreview: View {
    let theme: ReaderTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let sheet = GlkStyleSheet(theme: theme, systemIsDark: colorScheme == .dark, contentSizeCategory: .large)
        let colors = sheet.colors
        VStack(alignment: .leading, spacing: theme.lineSpacing) {
            Text("West of House").font(Font(sheet.bufferBaseFont.withSize(sheet.bufferBaseFont.pointSize * 1.3))).bold()
            Text("You are standing in an open field west of a white house, with a boarded front door.")
                .font(Font(sheet.bufferBaseFont))
                .lineSpacing(theme.lineSpacing)
            Text("> open mailbox").font(Font(sheet.bufferBaseFont)).foregroundColor(Color(theme.accentInput ? colors.input : colors.text))
        }
        .multilineTextAlignment(theme.justify ? .leading : .leading)
        .foregroundColor(Color(colors.text))
        .padding(.horizontal, theme.margin)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(colors.background))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of story text")
    }
}
