import SwiftUI

/// Lists coastty's licence, which carries Ghostty's MIT notice, and herdr's Apache 2.0 licence.
struct LicensesView: View {
    private struct License: Identifiable {
        let id: String
        let title: String
        let text: String

        /// Reads the licence text for `resource` up front, so the view never touches the bundle while drawing.
        init(resource: String, title: String) {
            self.id = resource
            self.title = title
            self.text = Self.read(resource)
        }

        /// Reads a licence from the bundle's resources, where only the release script puts them.
        private static func read(_ resource: String) -> String {
            guard let url = Bundle.main.url(forResource: resource, withExtension: nil),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "Not included in this build. Release builds carry it in the app's resources."
            }

            return text
        }
    }

    private let licenses = [
        License(resource: "LICENSE", title: "Coastty and Ghostty (MIT)"),
        License(resource: "LICENSE-herdr", title: "herdr agent detection (Apache 2.0)"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(licenses) { license in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(license.title)
                            .font(.headline)
                        Text(license.text)
                            .font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
