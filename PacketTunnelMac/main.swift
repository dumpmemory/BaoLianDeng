import Foundation
import NetworkExtension

// macOS System Extensions are standalone processes that need an explicit main.
// The NEProvider main run loop handles extension lifecycle.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
