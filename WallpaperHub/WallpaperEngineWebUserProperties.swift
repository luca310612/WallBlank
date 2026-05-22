import Foundation

/// Wallpaper Engine Web 壁紙が期待する `wallpaperPropertyListener` コールを、ローカルの `project.json` から再現する。
enum WallpaperEngineWebUserProperties {

    /// `applyUserProperties` に渡す辞書（各キー → `["value": …]`）を `project.json` の `general.properties` から組み立てる。
    static func defaultUserProperties(forProjectRoot root: URL) -> [String: [String: Any]] {
        let projectURL = root.appendingPathComponent("project.json")
        let resolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: projectURL) ?? projectURL
        guard FileManager.default.fileExists(atPath: resolved.path),
              let data = try? Data(contentsOf: resolved),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = obj["general"] as? [String: Any],
              let props = general["properties"] as? [String: Any] else {
            return [:]
        }

        var out: [String: [String: Any]] = [:]
        out.reserveCapacity(props.count)
        for (key, raw) in props {
            guard let def = raw as? [String: Any] else { continue }
            let value = def["value"] ?? fallbackValue(forPropertyDefinition: def)
            out[key] = ["value": value]
        }
        return out
    }

    /// `applyGeneralProperties` 用。`fps: 0` は WE 相当の「制限なし」。
    static func defaultGeneralProperties() -> [String: Any] {
        ["fps": 0]
    }

    /// Base64 経由で UTF-8 JSON を渡し、`wallpaperPropertyListener` を発火する JS。
    static func propertyBridgeJavaScript(userProperties: [String: [String: Any]], generalProperties: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(userProperties),
              JSONSerialization.isValidJSONObject(generalProperties) else {
            return nil
        }
        guard let uData = try? JSONSerialization.data(withJSONObject: userProperties, options: []),
              let gData = try? JSONSerialization.data(withJSONObject: generalProperties, options: []) else {
            return nil
        }
        let uB64 = uData.base64EncodedString()
        let gB64 = gData.base64EncodedString()

        // TextDecoder は WKWebView で利用可能。リスナーが後から登録される壁紙向けに短時間ポーリングし、成功したら 1 回だけ発火する。
        return """
        (function(){
          if (window.__artiaWEPropsBridgeDone) return;
          function decode(b64) {
            var bin = atob(b64);
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
            return JSON.parse(new TextDecoder('utf-8').decode(bytes));
          }
          var user = decode('\(uB64)');
          var general = decode('\(gB64)');
          var done = false;
          function fireOnce() {
            if (done) return;
            var l = window.wallpaperPropertyListener;
            if (!l) return;
            try {
              if (typeof l.applyGeneralProperties === 'function') {
                l.applyGeneralProperties(general);
              }
              if (typeof l.applyUserProperties === 'function') {
                l.applyUserProperties(user);
              }
              done = true;
              window.__artiaWEPropsBridgeDone = true;
            } catch (e) {
              try { console.error('Artia WE bridge', e); } catch (_) {}
            }
          }
          function poll(step) {
            fireOnce();
            if (done) return;
            // 巨大な script（整形版など）のパースでリスナー登録が遅れる壁紙向けに十分長く待つ
            if (step >= 200) return;
            setTimeout(function() { poll(step + 1); }, step < 20 ? 16 : 80);
          }
          poll(0);
        })();
        """
    }

    private static func fallbackValue(forPropertyDefinition def: [String: Any]) -> Any {
        let type = ((def["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch type {
        case "slider":
            if let min = def["min"] { return min }
            return 0
        case "bool", "checkbox":
            return false
        case "color":
            return "1 1 1"
        case "text", "textinput":
            return ""
        case "file", "directory":
            return ""
        case "combo":
            if let opts = def["options"] as? [[String: Any]], let first = opts.first {
                return first["value"] ?? first["text"] ?? ""
            }
            return ""
        default:
            return ""
        }
    }
}
