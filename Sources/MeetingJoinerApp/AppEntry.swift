#if !os(macOS)
import Foundation
@main
enum MeetingJoinerAppUnavailable {
    static func main() {
        fatalError("MeetingJoinerApp is a native macOS application. Build it on macOS.")
    }
}
#endif
