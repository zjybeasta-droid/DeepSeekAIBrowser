import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var exported = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("DeepSeek") {
                    SecureField("API Key", text: $app.apiKey)
                    TextField("模型", text: $app.profile.model)
                    Slider(value: $app.profile.temperature, in: 0...1, step: 0.05) { Text("Temperature") }
                    Text("Temperature：\(app.profile.temperature, specifier: "%.2f")")
                }
                Section("行为") {
                    Toggle("自动清理广告和遮罩", isOn: $app.profile.autoCleanAds)
                    Toggle("自动执行 AI 动作", isOn: $app.profile.autoExecute)
                    Stepper("单次最多动作：\(app.profile.maxActionsPerTask)", value: $app.profile.maxActionsPerTask, in: 1...20)
                    TextEditor(text: $app.profile.systemPrompt).frame(minHeight: 240)
                }
                Section("配置") {
                    Button("保存") { app.saveSettings() }
                    Button("导出当前配置") { exported = app.profile.exportedJSON() }
                    if !exported.isEmpty { Text(exported).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { app.saveSettings(); dismiss() } } }
        }
    }
}
