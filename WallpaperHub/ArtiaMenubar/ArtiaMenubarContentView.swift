import SwiftUI

struct ArtiaMenubarContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("WallBlank Menubar")
                .font(.headline)
            Text("This is a minimal host app for tests.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 180)
    }
}
