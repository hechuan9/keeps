import Foundation
import KeepsColorCore

@MainActor func run() throws {
    var args = CommandLine.arguments
    let prepareOnly = args.last == "--prepare-preview"
    if prepareOnly { args.removeLast() }
    guard (args.count == 7 || (args.count == 9 && ["--base-recipe", "--select-candidate"].contains(args[7]))), args[1] == "--darktable", args[3] == "--source", args[5] == "--job" else {
        throw ColorToolError("Usage: keeps-color-mcp --darktable /path/darktable-cli --source /path/input.ARW --job /private/job")
    }
    let engine = try DarktableProcess(executable: URL(fileURLWithPath: args[2]), source: URL(fileURLWithPath: args[4]), directory: URL(fileURLWithPath: args[6]))
    let tools = try ColorTools(engine: engine, baseRecipe: args.count == 9 && args[7] == "--base-recipe" ? Data(contentsOf: URL(fileURLWithPath: args[8])) : nil)
    if args.count == 9 && args[7] == "--select-candidate" {
        _ = try tools.selectCandidate(args[8])
    } else if prepareOnly {
        _ = try tools.call("inspect_photo", [:])
    } else {
        try JSONRPCServer(colorTools: tools).run()
    }
}
do { try run() }
catch {
    FileHandle.standardError.write(Data("\(String(reflecting: error))\n".utf8))
    exit(1)
}
