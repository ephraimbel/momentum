import SwiftUI

/// The profile header as a Paper card — what "Share profile" hands to the share sheet. Fixed
/// light canvas with ink type and a periwinkle rule (the Paper share style's grammar), rendered
/// off-screen by `ImageRenderer`; nothing here is interactive.
struct ProfileShareCard: View {
    let name: String
    let handle: String
    let avatar: Data?
    let rows: [(String, String)]
    let chips: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                AvatarView(photo: avatar, name: name, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.display(28, weight: .black)).foregroundStyle(Theme.inkOnFixedLight)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if !handle.isEmpty {
                        Text("@\(handle)").font(.rounded(15, weight: .semibold))
                            .foregroundStyle(Theme.inkOnFixedLight.opacity(0.55))
                    }
                }
            }
            Rectangle().fill(Theme.route).frame(height: 2)
            HStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.display(30, weight: .heavy)).monospacedDigit()
                            .foregroundStyle(Theme.inkOnFixedLight)
                        Text(row.1.uppercased()).font(.rounded(11, weight: .bold)).tracking(1)
                            .foregroundStyle(Theme.inkOnFixedLight.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip).font(.rounded(13, weight: .semibold))
                            .foregroundStyle(Theme.inkOnFixedLight)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().stroke(Theme.inkOnFixedLight.opacity(0.18), lineWidth: 1))
                    }
                }
            }
            HStack {
                Spacer()
                Text("momentum").font(.display(13, weight: .bold)).tracking(2)
                    .foregroundStyle(Theme.inkOnFixedLight.opacity(0.45))
            }
        }
        .padding(28)
        .frame(width: 360)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
