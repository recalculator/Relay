import RelayCore
import SwiftUI

/// Fills a command template's placeholders and copies the result.
///
/// Values live only in this view's `@State` and disappear when the sheet closes. They
/// are never saved, synced, or logged. Parsing and rendering are `Template`'s pure
/// functions, so this view only holds input state.
struct FillTemplateView: View {
    let template: Template
    let onCopy: (String) -> Void

    @State private var values: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(text: String, onCopy: @escaping (String) -> Void) {
        template = Template(parsing: text)
        self.onCopy = onCopy
    }

    private var missing: [String] { template.missingValues(in: values) }
    private var rendered: String { template.render(with: values) }

    var body: some View {
        NavigationStack {
            Form {
                if template.placeholders.isEmpty {
                    Section {
                        Text("This template has no placeholders, so it's copied as written.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Values") {
                        ForEach(template.placeholders, id: \.self) { name in
                            TextField(name, text: binding(for: name), prompt: Text("required"))
                                .font(.body.monospaced())
                                .autocorrectionDisabled()
                                .accessibilityLabel("Value for \(name)")
                        }
                    }
                }

                if !template.issues.isEmpty {
                    Section {
                        ForEach(Array(template.issues.enumerated()), id: \.offset) { _, issue in
                            Label {
                                Text("Line \(issue.line): \(Text(issue.text).monospaced()) isn't a valid placeholder and is copied as written.")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                        }
                    } header: {
                        Text("Not recognized")
                    } footer: {
                        Text("Placeholder names use letters, digits, and _, and can't start with a digit, e.g. {{user_id}}.")
                    }
                }

                Section {
                    ScrollView([.vertical, .horizontal]) {
                        Text(rendered)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 200)
                    .accessibilityLabel("Preview")
                } header: {
                    Text("Preview")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !missing.isEmpty {
                            Text("Fill in: \(missing.joined(separator: ", "))")
                        }
                        Label("Review the command before running it. Values are inserted exactly as typed, without shell quoting.",
                              systemImage: "eye")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Fill Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        onCopy(rendered)
                        dismiss()
                    }
                    .disabled(!missing.isEmpty)
                    .help(missing.isEmpty ? "Copy the completed text" : "Fill in every value first")
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { values[name, default: ""] }, set: { values[name] = $0 })
    }
}
