#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="assets/demo"
TARGET_MB=2             # 目标体积（单位：MB）
HEIGHT=480              # 目标高度（像素）
FPS=16                  # 目标帧率
AUDIO_K=48              # 音频码率（kbps）
MIN_VK=80               # 视频码率下限（kbps，避免过度糊）
PRESET="veryslow"       # x264 预设，体积越小越适合用慢预设

# macOS/Linux 均可用的 stat 封装
stat_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

# 只找原始视频，排除已经压过的 *_web.*
find "$ROOT_DIR" -type f \
  \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" \) \
  ! -iname "*_web.*" -print0 |
while IFS= read -r -d '' in; do
  dir="$(dirname "$in")"
  base="$(basename "$in")"
  name="${base%.*}"
  out="${dir}/${name}_web.mp4"
  passlog="${dir}/.ffpass_${name}"

  # 若已存在且：1) 比源文件新 且 2) 小于等于目标体积的 1.1 倍 → 跳过
  if [[ -f "$out" && "$out" -nt "$in" ]]; then
    out_size_bytes=$(stat_size "$out")
    # 1.1 倍的宽松阈值
    if awk -v s="$out_size_bytes" -v t="$TARGET_MB" 'BEGIN{exit !(s <= (t*1024*1024*1.1))}'; then
      echo "✅ Skip (already small enough): $out"
      continue
    fi
  fi

  # 获取时长（秒）
  dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$in")
  # 兜底
  if [[ -z "${dur}" || "${dur}" == "N/A" ]]; then dur=1; fi

  # 目标总比特（bits）
  total_bits=$(awk -v mb="$TARGET_MB" 'BEGIN{print int(mb*1024*1024*8)}')
  # 音频比特率（bps）
  audio_bps=$((AUDIO_K*1000))
  # 计算视频比特率（kbps），并设置下限
  vbps_k=$(awk -v tb="$total_bits" -v d="$dur" -v ab="$audio_bps" -v minvk="$MIN_VK" \
    'BEGIN{
       if (d<1) d=1;
       v = (tb/d) - ab;       # 目标视频 bps
       if (v < minvk*1000) v = minvk*1000;
       print int(v/1000);
     }')

  echo "▶️  Compressing: $in -> $out"
  echo "    duration=${dur}s, target≈${TARGET_MB}MB, video_bitrate=${vbps_k}k, audio=${AUDIO_K}k"

  # 两遍码控
  # 第 1 遍（视频无声、丢弃输出）
  ffmpeg -hide_banner -nostdin -y -i "$in" \
    -vf "fps=${FPS},scale=-2:${HEIGHT}:flags=bicubic,format=yuv420p" \
    -c:v libx264 -preset "$PRESET" -b:v "${vbps_k}k" -pass 1 -passlogfile "$passlog" \
    -tune fastdecode -movflags +faststart -an -f mp4 /dev/null

  # 第 2 遍（写入最终文件）
  ffmpeg -hide_banner -nostdin -y -i "$in" \
    -vf "fps=${FPS},scale=-2:${HEIGHT}:flags=bicubic,format=yuv420p" \
    -c:v libx264 -preset "$PRESET" -b:v "${vbps_k}k" -maxrate "${vbps_k}k" -bufsize "$((vbps_k*2))k" \
    -pass 2 -passlogfile "$passlog" -profile:v high -pix_fmt yuv420p \
    -c:a aac -b:a "${AUDIO_K}k" -ac 2 \
    -movflags +faststart "$out"

  # 清理两遍日志
  rm -f "${passlog}-0.log" "${passlog}-0.log.mbtree" "${passlog}.log" "${passlog}.log.mbtree" 2>/dev/null || true

  # 体积对比
  in_size=$(stat_size "$in")
  out_size=$(stat_size "$out")
  printf "   📦 %s → %s (%.2f MB → %.2f MB)\n" "$base" "$(basename "$out")" \
    "$(echo "$in_size/1048576" | bc -l)" "$(echo "$out_size/1048576" | bc -l)"
done

echo "🎉 Done."