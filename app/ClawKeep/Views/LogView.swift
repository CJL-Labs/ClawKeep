import SwiftUI

struct LogView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenClaw 日志不再由 ClawKeep 持续采集。")
                .font(.headline)
            Text("修复 Agent 会直接根据设置里的日志路径去读取文件。这里不再显示实时日志流。")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
