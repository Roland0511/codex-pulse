import Darwin
import Foundation
import PulseCore

// 永远不输出上下文、许可决定或错误正文；缺失 / 关闭 Pulse 不影响 Codex。
// --check 仅供显式合成输入验证，安装命令从不使用它，也不发送网络信号。
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--check"),
   arguments.first == "--event", let event = ActivityEvent(rawValue: arguments[1]) {
    let time = Date().timeIntervalSince1970
    if let metadata = try? HookMetadata.read(from: .standardInput, event: event) {
        if arguments.last == "--check", let owner = ActivityOwner.read(getpid()),
           let data = try? JSONEncoder().encode(metadata.signal(owner: owner, time: time)) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        } else if let owner = ActivityOwner.codexAncestor() {
            try? ActivitySocket.send(metadata.signal(owner: owner, time: time))
        }
    }
}
exit(0)
