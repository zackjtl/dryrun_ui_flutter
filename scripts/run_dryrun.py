"""MPTool Dry Run Automation Script

自動解壓 MPTool 7z 檔，對指定 Part Number 的所有 DevXX.txt 和 .ini 組合執行 dry run。
執行前會驗證 MPTool.exe 是否支援 CLI Mode，執行後收集 Dump 結果。

Usage:
    py -3.14 run_dryrun.py <7z_file> <part_number_path> [options]

Example:
    py -3.14 run_dryrun.py "MPTool_1290.1.0.2 (4K Mapping).7z" Samsung/K9GAG08U0D
    py -3.14 run_dryrun.py "MPTool_1290.1.0.2 (4K Mapping).7z" Samsung/K9GAG08U0D --ctype 36

Parameters:
    7z_file          - MPTool 的 .7z 壓縮檔路徑
    part_number_path - Vendor/PartNumber 格式路徑 (相對於 GeneratedDevices 資料夾)

Options:
    --ctype <n>      - 覆蓋 DevXX.txt 中的 Controller Type 值
    --ignore-spl     - 忽略 FlashSupportList.ini 載入 (傳入 -ignore_spl 給 MPTool)
    --keep-temp      - 執行完畢後不清理解壓暫存目錄
    --devices-dir    - 指定 GeneratedDevices 基礎路徑 (覆蓋預設)
"""

import sys
import os
import re
import json
import subprocess
import shutil
import argparse
import importlib.util
from pathlib import Path
from datetime import datetime

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def find_7z_exe():
    common_paths = [
        r"C:\Program Files\7-Zip\7z.exe",
        r"C:\Program Files (x86)\7-Zip\7z.exe",
    ]
    for p in common_paths:
        if os.path.isfile(p):
            return p
    result = shutil.which("7z")
    if result:
        return result
    return None


def extract_7z(archive_path, extract_dir):
    seven_z = find_7z_exe()
    if not seven_z:
        print("[Error] 找不到 7z.exe，請安裝 7-Zip。")
        sys.exit(1)

    cmd = [seven_z, "x", str(archive_path), f"-o{extract_dir}", "-y"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[Error] 解壓失敗: {archive_path}")
        print(result.stderr)
        sys.exit(1)


def find_mptool_exe(extract_dir):
    extract_path = Path(extract_dir)
    candidates = list(extract_path.rglob("MPTool.exe"))

    if not candidates:
        print(f"[Error] 在 {extract_dir} 中找不到 MPTool.exe")
        sys.exit(1)

    for c in candidates:
        rel = c.relative_to(extract_path)
        parts = rel.parts
        if len(parts) == 1:
            return c
        if len(parts) == 2 and parts[0].lower() == "mptool":
            return c

    return candidates[0]


def _pick_effective_extract_root(extract_dir: str) -> Path:
    root = Path(extract_dir).resolve()
    try:
        entries = [e for e in root.iterdir() if e.name not in (".", "..")]
    except FileNotFoundError:
        return root

    dirs = [e for e in entries if e.is_dir()]
    files = [e for e in entries if e.is_file()]

    if len(dirs) == 1 and len(files) == 0:
        return dirs[0].resolve()
    return root


def _copy_tree_merge(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for entry in src.iterdir():
        if entry.resolve() == dst.resolve():
            continue
        target = dst / entry.name
        if entry.is_dir():
            try:
                shutil.copytree(entry, target, dirs_exist_ok=True)
            except TypeError:
                if not target.exists():
                    shutil.copytree(entry, target)
                else:
                    _copy_tree_merge(entry, target)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                shutil.copy2(entry, target)
            except Exception:
                pass


def _ensure_mptool_has_dependencies(extract_root: Path, mptool_exe: Path) -> None:
    mptool_dir = mptool_exe.parent.resolve()
    extract_root = extract_root.resolve()

    try:
        dir_items = list(mptool_dir.iterdir())
    except Exception:
        return

    if mptool_dir == extract_root:
        return

    if len(dir_items) <= 2 and any(p.name.lower() == "mptool.exe" for p in dir_items):
        print("[Info] 偵測到 MPTool.exe 所在資料夾內容很少，嘗試把解壓根目錄的檔案/子目錄合併到 MPTool.exe 同層...")
        _copy_tree_merge(extract_root, mptool_dir)
        try:
            dir_items_after = list(mptool_dir.iterdir())
            print(f"[Info] MPTool dir items: {len(dir_items)} -> {len(dir_items_after)}")
        except Exception:
            pass


def check_cli_support(mptool_exe):
    script_dir = Path(__file__).parent.resolve()
    rf_script = script_dir / "read_feature.py"

    if not rf_script.exists():
        print(f"[Error] 找不到 read_feature.py: {rf_script}")
        return None

    spec = importlib.util.spec_from_file_location("read_feature", str(rf_script))
    rf_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rf_module)

    id_1001 = rf_module.get_string_resource(str(mptool_exe), 1001)
    id_1002 = rf_module.get_string_resource(str(mptool_exe), 1002)

    return {"cli_support": id_1001, "protocol": id_1002}


def get_ce_count(device_file):
    raw = device_file.read_bytes()
    if raw[:2] == bytes([0xFF, 0xFE]):
        text = raw[2:].decode("utf-16-le")
    else:
        text = raw.decode("utf-8")

    in_flash_section = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("[Flash]"):
            in_flash_section = True
            continue
        if stripped.startswith("[") and in_flash_section:
            break
        if in_flash_section and "Chip" in stripped and "=" in stripped:
            value_part = stripped.split("=", 1)[1].strip().rstrip(";").strip()
            if value_part:
                return len(value_part.split())
            return 0
    return 0


def _override_controller_type(file_path, ctype):
    raw = file_path.read_bytes()
    if raw[:2] == bytes([0xFF, 0xFE]):
        text = raw[2:].decode('utf-16-le')
        has_bom = True
    else:
        text = raw.decode('utf-8')
        has_bom = False

    new_text = re.sub(
        r'(Controller Type\s*=\s*)\d+(\s*;)',
        r'\g<1>' + str(ctype) + r'\2',
        text,
    )

    if has_bom:
        file_path.write_bytes(bytes([0xFF, 0xFE]) + new_text.encode('utf-16-le'))
    else:
        file_path.write_bytes(new_text.encode('utf-8'))


def run_dryrun(mptool_exe, flash_file, config_file, ignore_spl=False, ctype=None):
    exe_dir = mptool_exe.parent
    staging_dir = exe_dir / "_dryrun_input"
    staging_dir.mkdir(exist_ok=True)

    staged_flash = staging_dir / flash_file.name
    staged_config = staging_dir / config_file.name
    shutil.copy2(flash_file, staged_flash)
    shutil.copy2(config_file, staged_config)

    if ctype is not None:
        _override_controller_type(staged_flash, ctype)

    flash_rel = str(staged_flash.relative_to(exe_dir))
    config_rel = str(staged_config.relative_to(exe_dir))

    cmd = [
        str(mptool_exe),
        "-dryrun",
        "-flash", flash_rel,
        "-config", config_rel,
    ]
    if ignore_spl:
        cmd.append("-ignore_spl")

    result = subprocess.run(
        cmd,
        capture_output=True,
        cwd=str(exe_dir),
        creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0,
    )

    stdout_text = _decode_output(result.stdout)
    stderr_text = _decode_output(result.stderr)

    return result.returncode, stdout_text, stderr_text, ' '.join(cmd)


def _decode_output(raw_bytes):
    if not raw_bytes:
        return ""
    for encoding in ("utf-8", "cp950", "big5", "cp1252", "latin-1"):
        try:
            return raw_bytes.decode(encoding)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw_bytes.decode("latin-1", errors="replace")


def collect_dump(mptool_exe, config_file, device_file, vendor, output_base,
                 cli_version_text):
    exe_dir = mptool_exe.parent
    config_name = config_file.stem
    ce_count = get_ce_count(device_file)

    dump_folder_name = f"{config_name}x{ce_count}"
    source_dump = exe_dir / "Dump" / dump_folder_name

    if not source_dump.is_dir():
        return None

    dest_dump = output_base / "Dump" / vendor / dump_folder_name
    if dest_dump.exists():
        shutil.rmtree(dest_dump)
    shutil.copytree(source_dump, dest_dump)

    (dest_dump / "CLI_Version.txt").write_text(cli_version_text, encoding="utf-8")

    return dest_dump


def parse_args():
    parser = argparse.ArgumentParser(
        description="MPTool Dry Run Automation - 自動執行指定 Part Number 的所有 device/config 組合",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Example:\n  py -3.14 run_dryrun.py "MPTool_1290.1.0.2 (4K Mapping).7z" Samsung/K9GAG08U0D',
    )
    parser.add_argument("archive", help="MPTool .7z 壓縮檔路徑")
    parser.add_argument("part_number", help="Vendor/PartNumber 路徑 (e.g. Samsung/K9GAG08U0D)")
    parser.add_argument("--ctype", type=int, default=None,
                        help="覆蓋 DevXX.txt 中的 Controller Type 值 (e.g. 36)")
    parser.add_argument("--ignore-spl", action="store_true",
                        help="忽略 FlashSupportList.ini 載入")
    parser.add_argument("--keep-temp", action="store_true",
                        help="執行完畢後保留解壓暫存目錄")
    parser.add_argument("--devices-dir", default=None,
                        help="指定 GeneratedDevices 基礎路徑 (覆蓋預設)")
    parser.add_argument(
        "--output-base",
        default=None,
        help="指定 Dump 輸出根目錄。預設為 GeneratedDevices 的上一層",
    )
    parser.add_argument(
        "--work-root",
        default=None,
        help="指定本地工作根目錄（用於解壓與執行 MPTool）。預設為目前工作目錄下的 _dryrun_work",
    )
    parser.add_argument(
        "--work-name",
        default=None,
        help="指定本次工作資料夾名稱（位於 work-root 之下）。未指定時會用 archive 名稱 + 時間戳產生",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    archive_path = Path(args.archive).resolve()
    part_number_path = args.part_number

    pn_parts = Path(part_number_path).parts
    vendor = pn_parts[0] if pn_parts else "Unknown"

    if args.devices_dir:
        devices_base = Path(args.devices_dir).resolve()
    else:
        devices_base = Path(__file__).parent.resolve() / "GeneratedDevices"
    devices_dir = devices_base / part_number_path

    if args.output_base:
        output_base = Path(args.output_base).resolve()
    else:
        output_base = devices_base.parent

    if not archive_path.is_file():
        print(f"[Error] 找不到 7z 壓縮檔: {archive_path}")
        sys.exit(1)

    if not devices_dir.is_dir():
        print(f"[Error] Part Number 資料夾不存在: {devices_dir}")
        sys.exit(1)

    device_files = sorted(devices_dir.glob("*.txt"))
    config_files = sorted(devices_dir.glob("*.ini"))

    if not device_files:
        print(f"[Error] 在 {devices_dir} 中找不到任何 .txt device 檔案")
        sys.exit(1)

    if not config_files:
        print(f"[Error] 在 {devices_dir} 中找不到任何 .ini config 檔案")
        sys.exit(1)

    print("=" * 60)
    print(f"Part Number: {part_number_path}")
    print(f"Device files (.txt): {len(device_files)}")
    for f in device_files:
        print(f"  - {f.name}")
    print(f"Config files (.ini): {len(config_files)}")
    for f in config_files:
        print(f"  - {f.name}")
    total_runs = len(device_files) * len(config_files)
    print(f"Total runs: {total_runs}")
    if args.ignore_spl:
        print("Option: --ignore-spl enabled")
    if args.ctype is not None:
        print(f"Option: --ctype {args.ctype} (override Controller Type)")
    print("=" * 60)
    print()

    if args.work_root:
        work_root = Path(args.work_root).resolve()
    else:
        work_root = Path.cwd() / "_dryrun_work"
    work_root.mkdir(parents=True, exist_ok=True)

    if args.work_name:
        folder_name = args.work_name
    else:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_stem = re.sub(r"[^A-Za-z0-9._-]+", "_", archive_path.stem).strip("_")
        folder_name = f"mptool_{safe_stem}_{ts}_{os.getpid()}"

    extract_dir = str((work_root / folder_name).resolve())
    print(f"[Info] 解壓 {archive_path.name} ...")
    print(f"[Info] Work dir: {extract_dir}")
    if os.path.isdir(extract_dir) and os.listdir(extract_dir):
        print("[Info] Work dir already exists and not empty, reusing it.")
    else:
        os.makedirs(extract_dir, exist_ok=True)
        extract_7z(archive_path, extract_dir)

    extract_root = _pick_effective_extract_root(extract_dir)
    if extract_root != Path(extract_dir).resolve():
        print(f"[Info] Extract root adjusted to: {extract_root}")

    try:
        root_entries = sorted([e.name for e in extract_root.iterdir()])
        print(f"[Info] Extract root entries: {len(root_entries)}")
        for name in root_entries[:50]:
            print(f"  - {name}")
        if len(root_entries) > 50:
            print("  ...")
    except Exception:
        pass

    mptool_exe = find_mptool_exe(str(extract_root))
    print(f"[Info] 找到 MPTool.exe: {mptool_exe}")
    _ensure_mptool_has_dependencies(extract_root, mptool_exe)
    try:
        mptool_entries = sorted([e.name for e in mptool_exe.parent.iterdir()])
        print(f"[Info] MPTool dir entries: {len(mptool_entries)}")
        for name in mptool_entries[:50]:
            print(f"  - {name}")
        if len(mptool_entries) > 50:
            print("  ...")
    except Exception:
        pass

    print(f"[Info] 檢查 CLI 支援狀態...")
    cli_info = check_cli_support(mptool_exe)

    if cli_info is None:
        print("[FAIL] 無法讀取 MPTool.exe 的 CLI 資訊 (read_feature.py 缺失)")
        shutil.rmtree(extract_dir, ignore_errors=True)
        sys.exit(1)

    print(f"  ID 1001: {cli_info['cli_support']}")
    print(f"  ID 1002: {cli_info['protocol']}")

    if cli_info["cli_support"] != "CLI_SUPPORT=YES":
        print(f"[FAIL] MPTool.exe 不支援 CLI Mode (ID 1001 = {cli_info['cli_support']})")
        shutil.rmtree(extract_dir, ignore_errors=True)
        sys.exit(1)

    print(f"[Info] CLI 支援確認，協議版本: {cli_info['protocol']}")
    print()

    cli_version_text = (
        f"Archive: {archive_path.name}\n"
        f"ID 1001: {cli_info['cli_support']}\n"
        f"ID 1002: {cli_info['protocol']}\n"
    )

    results = []
    run_count = 0

    try:
        for config_file in config_files:
            for device_file in device_files:
                run_count += 1

                returncode, stdout_text, stderr_text, cmd_str = run_dryrun(
                    mptool_exe,
                    device_file,
                    config_file,
                    ignore_spl=args.ignore_spl,
                    ctype=args.ctype,
                )

                dump_dir = collect_dump(
                    mptool_exe,
                    config_file,
                    device_file,
                    vendor,
                    output_base,
                    cli_version_text,
                )

                print(
                    "@@DRYRUN_RUN "
                    + json.dumps(
                        {
                            "device": device_file.name,
                            "config": config_file.name,
                            "exit_code": returncode,
                            "dump_dir": str(dump_dir) if dump_dir else "",
                        },
                        ensure_ascii=False,
                    )
                )

                print(f"--- Run {run_count}/{total_runs}: {device_file.name} + {config_file.name} ---")
                print(f"  Command: {cmd_str}")
                if stdout_text:
                    print(stdout_text.rstrip("\n"))
                if stderr_text:
                    print(stderr_text.rstrip("\n"))

                results.append({
                    "device": device_file.name,
                    "config": config_file.name,
                    "exit_code": returncode,
                    "dump_dir": str(dump_dir) if dump_dir else "",
                })
                print()

        passed = sum(1 for r in results if r["exit_code"] == 0)
        failed = len(results) - passed
        print("=" * 60)
        print(f"Summary: total={len(results)}, passed={passed}, failed={failed}")
        print("=" * 60)
        if failed != 0:
            sys.exit(1)
    finally:
        if args.keep_temp:
            print(f"[Info] 保留解壓暫存目錄: {extract_dir}")
        else:
            shutil.rmtree(extract_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
