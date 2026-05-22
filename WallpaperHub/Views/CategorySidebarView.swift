import SwiftUI

/// カテゴリサイドバー
struct CategorySidebarView: View {
    let categories: [String]
    @Binding var selectedCategory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Categories")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // All カテゴリ
            CategoryRow(name: "All", icon: "square.grid.2x2", isSelected: selectedCategory == "All") {
                selectedCategory = "All"
            }

            Divider()
                .padding(.vertical, 4)

            // 各カテゴリ
            ForEach(categories, id: \.self) { category in
                CategoryRow(
                    name: category,
                    icon: categoryIcon(for: category),
                    isSelected: selectedCategory == category
                ) {
                    selectedCategory = category
                }

            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func categoryIcon(for category: String) -> String {
        WallpaperCategoryIcon.icon(for: category)
    }
}

struct CategoryRow: View {
    let name: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(name)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
