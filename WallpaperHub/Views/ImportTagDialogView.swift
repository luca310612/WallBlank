import SwiftUI
import AVFoundation

/// インポート時のタグ入力ダイアログ
struct ImportTagDialogView: View {
    let urls: [URL]
    @ObservedObject var library: WallpaperLibrary
    @Binding var isPresented: Bool

    @State private var tagInput = ""
    @State private var tags: [String] = []
    @State private var thumbnails: [URL: NSImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("タグを追加")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            VStack(spacing: 16) {
                // インポート対象のプレビュー
                VStack(alignment: .leading, spacing: 8) {
                    Text("インポートするファイル (\(urls.count)件)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(urls, id: \.absoluteString) { url in
                                VStack(spacing: 4) {
                                    if let thumb = thumbnails[url] {
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .aspectRatio(16/10, contentMode: .fill)
                                            .frame(width: 100, height: 62)
                                            .clipped()
                                            .cornerRadius(6)
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(width: 100, height: 62)
                                            .cornerRadius(6)
                                            .overlay(
                                                Image(systemName: fileIcon(for: url))
                                                    .foregroundColor(.gray)
                                            )
                                    }
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                        .frame(width: 100)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(height: 90)
                }

                Divider()

                // タグ入力エリア
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("タグ")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("(必須)")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }

                    Text("壁紙の特徴やキャラクター名などを入力してください")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    // タグ入力フィールド（半分幅 + ＋ボタン）
                    HStack(spacing: 8) {
                        TextField("タグを入力（例: 風景、初音ミク）", text: $tagInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit {
                                addTag()
                            }

                        Button(action: addTag) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)

                        Spacer()
                    }

                    // 追加済みタグ一覧（多い場合はスクロール）
                    if !tags.isEmpty {
                        ScrollView {
                            FlowLayout(spacing: 6) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.system(size: 12))
                                        Button(action: { removeTag(tag) }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(12)
                                }
                            }
                        }
                        .frame(maxHeight: 70)
                    }

                    // よく使うタグの候補
                    let existingTags = library.getAllTags()
                    if !existingTags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("よく使うタグ")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)

                            FlowLayout(spacing: 4) {
                                ForEach(existingTags.filter { !tags.contains($0) }.prefix(10), id: \.self) { tag in
                                    Button(action: { tags.append(tag) }) {
                                        Text(tag)
                                            .font(.system(size: 11))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.gray.opacity(0.1))
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)

            Spacer()

            Divider()

            // フッター
            HStack {
                if tags.isEmpty {
                    Label("最低1つのタグが必要です", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                } else {
                    Text("\(tags.count)個のタグ")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("キャンセル") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button("インポート") {
                    performImport()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(tags.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 500, height: 480)
        .onAppear {
            loadThumbnails()
        }
    }

    private func addTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
        // 全角カンマを半角カンマに正規化してから分割
        let normalized = trimmed.replacingOccurrences(of: "、", with: ",")
        let newTags = normalized.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let tagsToAdd = (newTags.isEmpty ? [trimmed] : newTags)
            .filter { !$0.isEmpty && !tags.contains($0) }

        tags.append(contentsOf: tagsToAdd)
        tagInput = ""
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    private func performImport() {
        for url in urls {
            library.importFile(from: url, tags: tags)
        }
        isPresented = false
    }

    private func loadThumbnails() {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "heic", "gif"].contains(ext) {
                if let image = NSImage(contentsOf: url) {
                    thumbnails[url] = image
                }
            } else if ["mp4", "mov"].contains(ext) {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 200, height: 125)
                let semaphore = DispatchSemaphore(value: 0)
                let capturedURL = url
                generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
                    if let cgImage = cgImage {
                        DispatchQueue.main.async {
                            self.thumbnails[capturedURL] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        }
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            }
        }
    }

    private func fileIcon(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic"].contains(ext) { return "photo" }
        if ["mp4", "mov"].contains(ext) { return "play.rectangle" }
        if ext == "gif" { return "photo.stack" }
        return "doc"
    }
}
