import SwiftUI

/// The legacy Markdown view shares Orb's tested renderer for display formulas.
struct OrbMath: View {
    let source: String
    var body: some View { OrbRichText(source: "$$\n" + source + "\n$$") }
}
