import SwiftUI

struct PhotoRatingControls: View {
    let rating: Int
    let flag: String
    var setRating: (Int) -> Void
    var setFlag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("评分").foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                ForEach(1...5, id: \.self) { value in
                    Button { setRating(rating == value ? 0 : value) } label: {
                        Image(systemName: value <= rating ? "star.fill" : "star")
                            .font(.system(size: 17))
                    }
                    .help(rating == value ? "清除评分" : "\(value) 星")
                    .accessibilityLabel("\(value) 星")
                    .accessibilityAddTraits(value <= rating ? [.isSelected] : [])
                }
            }
            HStack(spacing: 14) {
                Text("标记").foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                flagButton("picked", title: "留用", symbol: "flag.fill")
                flagButton("rejected", title: "弃用", symbol: "flag.slash.fill")
            }
        }.buttonStyle(.plain)
    }

    private func flagButton(_ value: String, title: String, symbol: String) -> some View {
        Button { setFlag(flag == value ? "unflagged" : value) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(flag == value ? Color.primary : Color.secondary)
                .frame(width: 28, height: 26)
                .background(flag == value ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .help(flag == value ? "取消\(title)" : title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(flag == value ? [.isSelected] : [])
    }
}
