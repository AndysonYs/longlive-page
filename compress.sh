#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="assets/demo"

# 只找原始视频，排除已经压过的 *_web.*
find "$ROOT_DIR" -type f \
  \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" \) \
  ! -iname "*_web.*" -print0 |
while IFS= read -r -d '' in; do
  dir="$(dirname "$in")"
  base="$(basename "$in")"
  name="${base%.*}"
  out="${dir}/${name}_web.mp4"

  # 已存在且比源文件新 → 跳过
  if [[ -f "$out" && "$out" -nt "$in" ]]; then
    echo "✅ Skip (already compressed): $out"
    continue
  fi

  echo "▶️  Compressing: $in -> $out"
  ffmpeg -hide_banner -nostdin -y -i "$in" \
    -vf "scale=-2:720:flags=bicubic,format=yuv420p" -r 24 \
    -c:v libx264 -preset veryslow -crf 28 -profile:v high \
    -movflags +faststart \
    -c:a aac -b:a 96k -ac 2 "$out"

  # 体积对比（兼容 macOS 的 stat）
  in_size=$(stat -f%z "$in")
  out_size=$(stat -f%z "$out")
  printf "   📦 %s → %s (%.2f MB → %.2f MB)\n" "$base" "$(basename "$out")" \
    "$(echo "$in_size/1048576" | bc -l)" "$(echo "$out_size/1048576" | bc -l)"
done

echo "🎉 Done."
