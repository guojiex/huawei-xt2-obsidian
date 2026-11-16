#!/usr/bin/env python3
"""Record an OpenHarmony emulator by batching HDC screenshots."""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


FRAME_WIDTH = 1920
FRAME_HEIGHT = 1344
OUTPUT_FPS = 30
DEFAULT_TARGET = "127.0.0.1:5555"


def find_hdc(explicit_path):
    candidates = [explicit_path, shutil.which("hdc")]
    if sys.platform == "darwin":
        candidates.append(
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/"
            "toolchains/hdc"
        )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(candidate)
    raise RuntimeError("找不到 hdc；请将 hdc 加入 PATH 或通过 --hdc 指定路径")


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(detail or f"命令失败：{command[0]}")
    return result.stdout


def capture_command(remote_dir, duration_seconds):
    return f'''mkdir -p {remote_dir} || exit $?
start_seconds=$(date +%s)
deadline=$((start_seconds + {duration_seconds} + 1))
i=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  frame=$(printf '%06d' "$i")
  snapshot_display -f "{remote_dir}/frame_$frame.jpeg" -w {FRAME_WIDTH} -h {FRAME_HEIGHT} >/dev/null 2>&1 || exit $?
  i=$((i + 1))
done
echo "YAOSHI_CAPTURE:$i"'''


def main():
    parser = argparse.ArgumentParser(
        description="批量采集 OpenHarmony 模拟器画面并合成为无声 MP4。"
    )
    parser.add_argument("--duration", type=int, default=30, help="录制时长（秒，默认 30）")
    parser.add_argument("--output", required=True, help="输出 MP4 文件路径")
    parser.add_argument("--target", default=DEFAULT_TARGET, help=f"HDC 设备（默认 {DEFAULT_TARGET}）")
    parser.add_argument("--hdc", help="hdc 可执行文件路径；默认从 PATH 和 DevEco Studio 路径查找")
    args = parser.parse_args()

    if args.duration < 2:
        parser.error("--duration 不能小于 2 秒")
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        parser.error("找不到 ffmpeg；请先安装并将其加入 PATH")

    try:
        hdc = find_hdc(args.hdc)
    except RuntimeError as error:
        parser.error(str(error))

    output = Path(args.output).expanduser().resolve()
    if output.suffix.lower() != ".mp4":
        parser.error("--output 必须使用 .mp4 扩展名")
    output.parent.mkdir(parents=True, exist_ok=True)

    remote_dir = f"/data/local/tmp/yaoshi_capture_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    hdc_target = [hdc, "-t", args.target]
    temporary_output = output.with_name(f".{output.stem}.{uuid.uuid4().hex[:8]}.tmp.mp4")

    try:
        with tempfile.TemporaryDirectory(prefix="yaoshi_capture_") as frame_dir_name:
            frame_dir = Path(frame_dir_name)
            print(
                f"开始录制约 {args.duration} 秒；现在可以操作模拟器。",
                flush=True,
            )
            recording_started = time.perf_counter()
            capture_output = run(
                hdc_target + ["shell", capture_command(remote_dir, args.duration)]
            )
            capture_seconds = time.perf_counter() - recording_started
            metadata = next(
                (line for line in capture_output.splitlines() if line.startswith("YAOSHI_CAPTURE:")),
                None,
            )
            if not metadata:
                raise RuntimeError("设备没有返回截图数量")
            frame_count = int(metadata.split(":", 1)[1])
            if frame_count == 0:
                raise RuntimeError("设备没有采集到截图")
            actual_fps = frame_count / capture_seconds

            for index in range(frame_count):
                name = f"frame_{index:06d}.jpeg"
                local_frame = frame_dir / name
                run(hdc_target + ["file", "recv", f"{remote_dir}/{name}", str(local_frame)])
                if not local_frame.is_file() or local_frame.stat().st_size == 0:
                    raise RuntimeError(f"截图文件为空：{name}")

            print(
                f"已采集 {frame_count} 张，实测约 {actual_fps:.2f} 张/秒；"
                f"正在合成 {OUTPUT_FPS}fps MP4。",
                flush=True,
            )
            run(
                [
                    ffmpeg,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-framerate",
                    f"{actual_fps:.6f}",
                    "-start_number",
                    "0",
                    "-i",
                    str(frame_dir / "frame_%06d.jpeg"),
                    "-vf",
                    f"fps={OUTPUT_FPS}",
                    "-c:v",
                    "libx264",
                    "-preset",
                    "medium",
                    "-crf",
                    "18",
                    "-pix_fmt",
                    "yuv420p",
                    "-an",
                    "-movflags",
                    "+faststart",
                    str(temporary_output),
                ]
            )
            os.replace(temporary_output, output)
            print(f"完成：{output}（约 {capture_seconds:.1f} 秒）")
    finally:
        try:
            run(hdc_target + ["shell", f"rm -rf {remote_dir}"])
        except RuntimeError:
            pass
        if temporary_output.exists():
            temporary_output.unlink()


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"录制失败：{error}", file=sys.stderr)
        sys.exit(1)
