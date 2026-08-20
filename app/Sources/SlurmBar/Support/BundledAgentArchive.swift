import Foundation
import SlurmBarKit

enum BundledAgentArchive {
    static func load(bundle: Bundle = .main) throws -> Data {
        guard let url = bundle.url(forResource: "slurmbar-agent", withExtension: "pyz") else {
            throw ArchiveError.notBundled
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= RemoteAgentInstaller.maximumAgentBytes else {
            throw ArchiveError.invalidSize
        }
        return data
    }

    enum ArchiveError: LocalizedError {
        case notBundled
        case invalidSize

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "This development build does not contain the remote agent. Build SlurmBar.app with scripts/build-macos-app.sh and try again."
            case .invalidSize:
                return "The remote agent bundled with this copy of SlurmBar is invalid. Download a fresh copy and try again."
            }
        }
    }
}
