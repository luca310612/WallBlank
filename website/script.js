/* ============================================================
   WallBlank landing page — i18n, reveal, animated background
   ============================================================ */

/* ↓↓↓ 配布バイナリが用意できたら、ここにダウンロード URL を設定するだけで
   サイト内のすべての「ダウンロード/購入」ボタンに反映されます。
   未設定 ("") の場合はページ下部のダウンロードセクションへスクロールします。
   Set the download URL here once the build is ready; it wires up every
   download/buy button on the page. Leave "" to just scroll to the section. */
const DOWNLOAD_URL = "";

function initDownloadLinks() {
  if (!DOWNLOAD_URL) return;
  document.querySelectorAll("[data-download]").forEach((el) => {
    el.setAttribute("href", DOWNLOAD_URL);
  });
}

const I18N = {
  ja: {
    "meta.title": "WallBlank — 生きている macOS 壁紙",
    "meta.desc": "WallBlank は、動画・音楽連動・パーティクル・シェーダなどあらゆる壁紙で Mac のデスクトップを生まれ変わらせる macOS 向け壁紙アプリです。",
    "nav.features": "機能",
    "nav.types": "壁紙の種類",
    "nav.smart": "スマート機能",
    "nav.pricing": "料金",
    "nav.download": "ダウンロード",
    "hero.eyebrow": "macOS 13 Ventura 以降に対応",
    "hero.title": "デスクトップを、<br>生きた壁紙に。",
    "hero.sub": "動画・音楽連動・パーティクル・シェーダ。WallBlank は Metal と Rust で描く、なめらかで美しい macOS 壁紙アプリです。",
    "hero.ctaPrimary": "Mac 用をダウンロード",
    "hero.ctaSecondary": "機能を見る",
    "hero.note": "無料で利用可能 ・ 30 日間の Pro 体験版付き ・ 日本語/英語対応",
    "preview.video": "動画",
    "preview.audio": "音楽連動",
    "preview.particle": "パーティクル",
    "preview.shader": "シェーダ",
    "preview.parallax": "視差",
    "preview.web": "Web",
    "stats.types": "壁紙タイプ",
    "stats.fps": "FPS 可変",
    "stats.effects": "ビジュアルエフェクト",
    "stats.lang": "対応言語 (日 / 英)",
    "features.title": "できること",
    "features.sub": "静止画から、音に反応するインタラクティブな壁紙まで。Mac のデスクトップを思いのままに。",
    "feat.video.t": "動画・GIF 壁紙",
    "feat.video.d": "mp4 / mov / webm / GIF をそのまま壁紙に。お気に入りの映像が常にデスクトップで動きます。",
    "feat.audio.t": "音楽連動ビジュアライザ",
    "feat.audio.d": "システム音声を解析し、再生中の音楽に合わせて壁紙がリアルタイムに反応します。(macOS 13+)",
    "feat.effects.t": "豊富なエフェクト",
    "feat.effects.d": "ブラー・グリッチ・色収差・ブルーム・水の波紋・ヒートヘイズなど、10 種類以上のエフェクトを重ねがけ。",
    "feat.particle.t": "パーティクル演出",
    "feat.particle.d": "雨や雪のオーバーレイを密度・速度・風・サイズまで細かく調整。季節感のあるデスクトップに。",
    "feat.editor.t": "壁紙エディタ",
    "feat.editor.d": "レイヤー・マスク・ブラシ・エフェクトチェーンでオリジナル壁紙を制作。MP4 / GIF / .wallpaper で書き出し。",
    "feat.gallery.t": "コミュニティギャラリー",
    "feat.gallery.d": "世界中のクリエイターの壁紙を閲覧・ダウンロード。自分の作品を公開して評価やコメントをもらえます。",
    "feat.multi.t": "マルチモニター対応",
    "feat.multi.d": "複数ディスプレイをまたぐスパニング壁紙、ディスプレイごとの個別設定の両方に対応。",
    "feat.rgb.t": "RGB ライティング連携",
    "feat.rgb.d": "Razer Chroma 対応。壁紙の色をキーボードやマウスの LED にリアルタイムで反映します。",
    "feat.widget.t": "ウィジェット & スクリーンセーバー",
    "feat.widget.d": "メニューバーから即操作。アイドル時には壁紙をそのままスクリーンセーバーとして表示します。",
    "types.title": "あらゆる壁紙に対応",
    "types.sub": "手持ちの素材も、生成系の壁紙も。読み込めるフォーマットは多彩です。",
    "types.image": "静止画 (JPG / PNG / HEIC)",
    "types.video": "動画 (MP4 / MOV / WEBM / AVI)",
    "types.gif": "GIF アニメーション",
    "types.shader": "シェーダ生成エフェクト",
    "types.web": "Web 壁紙",
    "types.music": "音楽プレイヤー壁紙",
    "types.scene": "Wallpaper Engine シーン",
    "smart.title": "賢く、軽く動く",
    "smart.sub": "動く壁紙でもバッテリーと作業を邪魔しない。状況を読んで自動で最適化します。",
    "smart.perf.t": "パフォーマンスプリセット",
    "smart.perf.d": "Ultra / High / Balanced / 省電力 から選択。FPS (15–144) と解像度 (1–100%) を細かく調整できます。",
    "smart.pause.t": "インテリジェント自動停止",
    "smart.pause.d": "他アプリ使用中・全画面表示・高 GPU 負荷・バッテリー駆動を検知し、壁紙を自動で一時停止します。",
    "smart.schedule.t": "スケジュール & プレイリスト",
    "smart.schedule.d": "時間帯に応じた自動切り替えや、順次・ランダム・シャッフル再生のプレイリストに対応。",
    "smart.click.t": "デスクトップ操作はそのまま",
    "smart.click.d": "動く壁紙の上からアイコンやファイルをクリック可能。「デスクトップを表示」にも対応します。",
    "pricing.title": "料金プラン",
    "pricing.sub": "まずは無料で。すべての機能は 30 日間じっくり試せます。",
    "price.free.t": "Free",
    "price.free.amt": "¥0",
    "price.free.d": "基本的な壁紙機能をずっと無料で。",
    "price.free.f1": "静止画・動画・GIF 壁紙",
    "price.free.f2": "基本エフェクト",
    "price.free.f3": "ギャラリー閲覧 & ダウンロード",
    "price.free.cta": "ダウンロード",
    "price.trial.badge": "おすすめ",
    "price.trial.t": "Pro 体験版",
    "price.trial.amt": "30 日間無料",
    "price.trial.d": "初回起動から 30 日間、Pro の全機能を解放。",
    "price.trial.f1": "すべてのエフェクトと演出",
    "price.trial.f2": "音楽連動 & パーティクル",
    "price.trial.f3": "エディタ & 書き出し",
    "price.trial.f4": "RGB ライティング連携",
    "price.trial.cta": "無料で試す",
    "price.pro.t": "Pro",
    "price.pro.amt": "買い切り",
    "price.pro.d": "一度の購入で全機能を永続的に。",
    "price.pro.f1": "体験版の全機能を無期限で",
    "price.pro.f2": "ギャラリーへの作品公開",
    "price.pro.f3": "クラウド同期",
    "price.pro.f4": "今後のアップデート",
    "price.pro.cta": "購入する",
    "dl.title": "WallBlank を手に入れよう",
    "dl.sub": "いつものデスクトップを、毎日見たくなる景色に。macOS 13 Ventura 以降に対応。",
    "dl.cta": "Mac 用をダウンロード",
    "dl.meta": "Apple Silicon & Intel 対応 ・ 無料ダウンロード",
    "footer.copy": "© 2026 WallBlank. SwiftUI + Metal + Rust で構築。",
    "footer.note": "macOS は Apple Inc. の商標です。本サイトは Apple とは関係ありません。",
  },
  en: {
    "meta.title": "WallBlank — Living wallpapers for macOS",
    "meta.desc": "WallBlank is a macOS wallpaper app that brings your desktop to life with video, music-reactive, particle and shader wallpapers.",
    "nav.features": "Features",
    "nav.types": "Wallpaper Types",
    "nav.smart": "Smart",
    "nav.pricing": "Pricing",
    "nav.download": "Download",
    "hero.eyebrow": "For macOS 13 Ventura and later",
    "hero.title": "Bring your desktop<br>to life.",
    "hero.sub": "Video, music-reactive, particles and shaders. WallBlank is a smooth, beautiful macOS wallpaper app powered by Metal and Rust.",
    "hero.ctaPrimary": "Download for Mac",
    "hero.ctaSecondary": "See features",
    "hero.note": "Free to use · 30-day Pro trial · English / Japanese",
    "preview.video": "Video",
    "preview.audio": "Audio-reactive",
    "preview.particle": "Particles",
    "preview.shader": "Shader",
    "preview.parallax": "Parallax",
    "preview.web": "Web",
    "stats.types": "Wallpaper types",
    "stats.fps": "Adjustable FPS",
    "stats.effects": "Visual effects",
    "stats.lang": "Languages (EN / JA)",
    "features.title": "What you can do",
    "features.sub": "From static images to interactive wallpapers that react to sound — your desktop, your way.",
    "feat.video.t": "Video & GIF wallpapers",
    "feat.video.d": "Use mp4 / mov / webm / GIF directly as wallpaper. Your favorite footage, always alive on the desktop.",
    "feat.audio.t": "Music-reactive visualizer",
    "feat.audio.d": "Captures system audio and makes your wallpaper react to playing music in real time. (macOS 13+)",
    "feat.effects.t": "A suite of effects",
    "feat.effects.d": "Blur, glitch, chromatic aberration, bloom, water ripples, heat haze and more — over 10 stackable effects.",
    "feat.particle.t": "Particle overlays",
    "feat.particle.d": "Rain and snow overlays tuned by density, speed, wind and size for a desktop with a sense of season.",
    "feat.editor.t": "Wallpaper editor",
    "feat.editor.d": "Build originals with layers, masks, brushes and effect chains. Export as MP4 / GIF / .wallpaper.",
    "feat.gallery.t": "Community gallery",
    "feat.gallery.d": "Browse and download wallpapers from creators worldwide. Publish your own and gather ratings and comments.",
    "feat.multi.t": "Multi-monitor",
    "feat.multi.d": "Supports both a single wallpaper spanning all displays and independent settings per display.",
    "feat.rgb.t": "RGB lighting sync",
    "feat.rgb.d": "Razer Chroma support reflects your wallpaper's colors onto keyboard and mouse LEDs in real time.",
    "feat.widget.t": "Widget & screensaver",
    "feat.widget.d": "Control it instantly from the menu bar, and show your wallpaper as a screensaver when idle.",
    "types.title": "Works with any wallpaper",
    "types.sub": "Your own footage or generative wallpapers — the supported formats are broad.",
    "types.image": "Images (JPG / PNG / HEIC)",
    "types.video": "Video (MP4 / MOV / WEBM / AVI)",
    "types.gif": "GIF animations",
    "types.shader": "Shader-based effects",
    "types.web": "Web wallpapers",
    "types.music": "Music player wallpapers",
    "types.scene": "Wallpaper Engine scenes",
    "smart.title": "Smart and lightweight",
    "smart.sub": "Living wallpapers that never get in the way of your battery or your work — optimized automatically.",
    "smart.perf.t": "Performance presets",
    "smart.perf.d": "Choose Ultra / High / Balanced / Power Saver. Fine-tune FPS (15–144) and resolution (1–100%).",
    "smart.pause.t": "Intelligent auto-pause",
    "smart.pause.d": "Detects other active apps, fullscreen windows, high GPU load and battery mode to pause automatically.",
    "smart.schedule.t": "Schedule & playlists",
    "smart.schedule.d": "Time-based switching plus sequential, random and shuffle playlist modes.",
    "smart.click.t": "Desktop stays clickable",
    "smart.click.d": "Click icons and files right through your animated wallpaper. Works with macOS \"Show Desktop\" too.",
    "pricing.title": "Pricing",
    "pricing.sub": "Start free. Try every feature for a full 30 days.",
    "price.free.t": "Free",
    "price.free.amt": "$0",
    "price.free.d": "Core wallpaper features, free forever.",
    "price.free.f1": "Image, video & GIF wallpapers",
    "price.free.f2": "Basic effects",
    "price.free.f3": "Browse & download gallery",
    "price.free.cta": "Download",
    "price.trial.badge": "Recommended",
    "price.trial.t": "Pro Trial",
    "price.trial.amt": "Free for 30 days",
    "price.trial.d": "Unlock all Pro features for 30 days from first launch.",
    "price.trial.f1": "Every effect and animation",
    "price.trial.f2": "Music-reactive & particles",
    "price.trial.f3": "Editor & export",
    "price.trial.f4": "RGB lighting sync",
    "price.trial.cta": "Try it free",
    "price.pro.t": "Pro",
    "price.pro.amt": "One-time",
    "price.pro.d": "Buy once, keep every feature forever.",
    "price.pro.f1": "All trial features, unlimited",
    "price.pro.f2": "Publish to the gallery",
    "price.pro.f3": "Cloud sync",
    "price.pro.f4": "Future updates",
    "price.pro.cta": "Buy now",
    "dl.title": "Get WallBlank",
    "dl.sub": "Turn your everyday desktop into a view you'll want to see every day. For macOS 13 Ventura and later.",
    "dl.cta": "Download for Mac",
    "dl.meta": "Apple Silicon & Intel · Free download",
    "footer.copy": "© 2026 WallBlank. Built with SwiftUI + Metal + Rust.",
    "footer.note": "macOS is a trademark of Apple Inc. This site is not affiliated with Apple.",
  },
};

const HTML_KEYS = new Set(["hero.title"]);

function applyLanguage(lang) {
  const dict = I18N[lang] || I18N.ja;
  document.documentElement.lang = lang;

  document.querySelectorAll("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    const val = dict[key];
    if (val == null) return;
    const attr = el.getAttribute("data-i18n-attr");
    if (attr) {
      el.setAttribute(attr, val);
    } else if (HTML_KEYS.has(key)) {
      el.innerHTML = val;
    } else {
      el.textContent = val;
    }
  });

  // toggle button shows the language you can switch TO
  const toggleLabel = document.querySelector("#lang-toggle .lang-jp");
  if (toggleLabel) toggleLabel.textContent = lang === "ja" ? "EN" : "日本語";

  try { localStorage.setItem("wb-lang", lang); } catch (e) {}
}

function initLanguage() {
  let lang = "ja";
  try {
    const saved = localStorage.getItem("wb-lang");
    if (saved) lang = saved;
    else if (navigator.language && !navigator.language.toLowerCase().startsWith("ja")) lang = "en";
  } catch (e) {}
  applyLanguage(lang);

  const btn = document.getElementById("lang-toggle");
  if (btn) {
    btn.addEventListener("click", () => {
      const next = document.documentElement.lang === "ja" ? "en" : "ja";
      applyLanguage(next);
    });
  }
}

/* ---------- Scroll reveal ---------- */
function initReveal() {
  const items = document.querySelectorAll(".feature, .stat, .price, .chip");
  if (!("IntersectionObserver" in window)) {
    items.forEach((el) => el.classList.add("reveal-in"));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry, i) => {
      if (entry.isIntersecting) {
        const el = entry.target;
        const delay = Math.min(i * 40, 200);
        setTimeout(() => el.classList.add("reveal-in"), delay);
        io.unobserve(el);
      }
    });
  }, { threshold: 0.12 });
  items.forEach((el) => io.observe(el));
}

/* ---------- Animated background (drifting glow particles) ---------- */
function initCanvas() {
  const canvas = document.getElementById("bg-canvas");
  if (!canvas) return;
  if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const ctx = canvas.getContext("2d");
  let w, h, dpr, particles;
  const COLORS = ["#7c5cff", "#18c8ff", "#4be1c0", "#ff5c8a"];

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = canvas.width = window.innerWidth * dpr;
    h = canvas.height = window.innerHeight * dpr;
    canvas.style.width = window.innerWidth + "px";
    canvas.style.height = window.innerHeight + "px";
    const count = Math.round((window.innerWidth * window.innerHeight) / 42000);
    particles = Array.from({ length: Math.max(18, Math.min(count, 64)) }, () => spawn());
  }

  function spawn() {
    return {
      x: Math.random() * w,
      y: Math.random() * h,
      r: (Math.random() * 2.2 + 0.8) * dpr,
      vx: (Math.random() - 0.5) * 0.18 * dpr,
      vy: (Math.random() - 0.5) * 0.18 * dpr,
      a: Math.random() * 0.5 + 0.2,
      c: COLORS[(Math.random() * COLORS.length) | 0],
    };
  }

  function draw() {
    ctx.clearRect(0, 0, w, h);
    for (const p of particles) {
      p.x += p.vx;
      p.y += p.vy;
      if (p.x < -20) p.x = w + 20;
      if (p.x > w + 20) p.x = -20;
      if (p.y < -20) p.y = h + 20;
      if (p.y > h + 20) p.y = -20;

      const glow = p.r * 6;
      const g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, glow);
      g.addColorStop(0, hexA(p.c, p.a));
      g.addColorStop(1, hexA(p.c, 0));
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(p.x, p.y, glow, 0, Math.PI * 2);
      ctx.fill();
    }
    requestAnimationFrame(draw);
  }

  function hexA(hex, a) {
    const n = parseInt(hex.slice(1), 16);
    const r = (n >> 16) & 255, gg = (n >> 8) & 255, b = n & 255;
    return `rgba(${r},${gg},${b},${a})`;
  }

  let resizeTimer;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(resize, 200);
  });
  resize();
  draw();
}

document.addEventListener("DOMContentLoaded", () => {
  initLanguage();
  initDownloadLinks();
  initReveal();
  initCanvas();
});
