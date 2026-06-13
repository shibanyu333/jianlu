import Foundation
import JianLuCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

expect(CoreVersion.name == "JianLuCore", "core module exposes its name")
print("JianLuCoreChecks passed")
