#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="compress_assets/"
TARGET_MB=2
HEIGHT=480
FPS=16
AUDIO_K=48
MIN_VK=80
PRESET="veryslow"

stat_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

has_audio() {
  ffprobe -v error -select_streams a:0 -show_entries stream=index \
          -of csv=p=0 "$1" >/dev/null 2>&1
}

# 不再排除 *_web.*；并确保使用 -print0 传给 while
find "$ROOT_DIR" -type f \
  \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" \) -print0 |
while IFS= read -r -d '' in; do
  dir="$(dirname "$in")"
  base="$(basename "$in")"
  name="${base%.*}"
  out="${dir}/${name}_compressed.mp4"
  passlog="${dir}/.ffpass_${name}"

  # 跳过规则：已存在、更新且小于目标体积 1.1x
  if [[ -f "$out" && "$out" -nt "$in" ]]; then
    out_size_bytes=$(stat_size "$out")
    awk -v s="$out_size_bytes" -v t="$TARGET_MB" 'BEGIN{exit !(s <= (t*1024*1024*1.1))}' \
      && { echo "✅ Skip (already small enough): $out"; continue; }
  fi

  # 时长
  dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$in")
  [[ -z "${dur}" || "${dur}" == "N/A" ]] && dur=1

  # 目标码率计算
  total_bits=$(awk -v mb="$TARGET_MB" 'BEGIN{print int(mb*1024*1024*8)}')
  audio_bps=$((AUDIO_K*1000))
  vbps_k=$(awk -v tb="$total_bits" -v d="$dur" -v ab="$audio_bps" -v minvk="$MIN_VK" \
    'BEGIN{ if (d<1) d=1; v = (tb/d) - ab; if (v < minvk*1000) v = minvk*1000; print int(v/1000); }')

  # 统一过滤器 & 统一 x264 参数（两遍必须一致）
  VF="fps=${FPS},scale=-2:${HEIGHT}:flags=bicubic,format=yuv420p"
  X264_COMMON=(-c:v libx264 -preset "$PRESET" -b:v "${vbps_k}k" \
               -maxrate "${vbps_k}k" -bufsize "$((vbps_k*2))k" \
               -pix_fmt yuv420p -profile:v high -g 96 -keyint_min 48 -sc_threshold 0)

  # 是否有音频
  if has_audio "$in"; then
    AUDIO_ARGS=(-c:a aac -b:a "${AUDIO_K}k" -ac 2)
    echo "▶️  Compressing: $in -> $out"
    echo "    duration=${dur}s, target≈${TARGET_MB}MB, video_bitrate=${vbps_k}k, audio=${AUDIO_K}k"
  else
    AUDIO_ARGS=(-an)
    echo "▶️  Compressing: $in -> $out (no audio stream)"
    echo "    duration=${dur}s, target≈${TARGET_MB}MB, video_bitrate=${vbps_k}k"
  fi

  # Pass 1
  ffmpeg -hide_banner -nostdin -y -i "$in" \
    -vf "$VF" "${X264_COMMON[@]}" \
    -pass 1 -passlogfile "$passlog" -map 0:v:0 -an \
    -f mp4 /dev/null

  # Pass 2
  ffmpeg -hide_banner -nostdin -y -i "$in" \
    -vf "$VF" "${X264_COMMON[@]}" \
    -pass 2 -passlogfile "$passlog" \
    "${AUDIO_ARGS[@]}" -movflags +faststart "$out"

  # 清理日志
  rm -f "${passlog}-0.log" "${passlog}-0.log.mbtree" "${passlog}.log" "${passlog}.log.mbtree" 2>/dev/null || true

  in_size=$(stat_size "$in")
  out_size=$(stat_size "$out")
  printf "   📦 %s → %s (%.2f MB → %.2f MB)\n" "$base" "$(basename "$out")" \
    "$(echo "$in_size/1048576" | bc -l)" "$(echo "$out_size/1048576" | bc -l)"
done

echo "🎉 Done."
