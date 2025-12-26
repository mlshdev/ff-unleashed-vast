#!/usr/bin/env python3
"""
Patch FaceFusion source to remove NSFW checks and model downloads.

This script modifies:
1. content_analyser.py - Disables NSFW detection, removes model downloads
2. core.py - Bypasses hash integrity check for content_analyser

Usage:
    python patch-facefusion.py <facefusion_source_dir>
"""

import re
import sys
from pathlib import Path


def patch_content_analyser(file_path: Path) -> None:
    """
    Patch content_analyser.py to:
    - Return empty model set (no NSFW models)
    - Make pre_check() return True without downloading
    - Make all analyse functions return False (not NSFW)
    """
    content = file_path.read_text()
    original = content

    # 1. Replace create_static_model_set to return empty dict
    # This prevents any NSFW model definitions
    pattern = r"(@lru_cache\(\)\ndef create_static_model_set\(download_scope : DownloadScope\) -> ModelSet:.*?^\t\}$)"
    replacement = """@lru_cache()
def create_static_model_set(download_scope : DownloadScope) -> ModelSet:
\t# PATCHED: NSFW models removed
\treturn {}"""

    content = re.sub(pattern, replacement, content, flags=re.MULTILINE | re.DOTALL)

    # 2. Replace pre_check to always return True without downloading
    pattern = r"def pre_check\(\) -> bool:.*?return conditional_download_hashes\(model_hash_set\) and conditional_download_sources\(model_source_set\)"
    replacement = """def pre_check() -> bool:
\t# PATCHED: Skip NSFW model downloads
\treturn True"""

    content = re.sub(pattern, replacement, content, flags=re.DOTALL)

    # 3. Replace analyse_frame to always return False
    pattern = r"def analyse_frame\(vision_frame : VisionFrame\) -> bool:\n\treturn detect_nsfw\(vision_frame\)"
    replacement = """def analyse_frame(vision_frame : VisionFrame) -> bool:
\t# PATCHED: NSFW check disabled
\treturn False"""

    content = re.sub(pattern, replacement, content)

    # 4. Replace analyse_stream to always return False
    pattern = r"def analyse_stream\(vision_frame : VisionFrame, video_fps : Fps\) -> bool:.*?return False"
    replacement = """def analyse_stream(vision_frame : VisionFrame, video_fps : Fps) -> bool:
\t# PATCHED: NSFW check disabled
\treturn False"""

    content = re.sub(pattern, replacement, content, flags=re.DOTALL)

    # 5. Replace analyse_image to always return False
    pattern = r"@lru_cache\(\)\ndef analyse_image\(image_path : str\) -> bool:\n\tvision_frame = read_image\(image_path\)\n\treturn analyse_frame\(vision_frame\)"
    replacement = """@lru_cache()
def analyse_image(image_path : str) -> bool:
\t# PATCHED: NSFW check disabled
\treturn False"""

    content = re.sub(pattern, replacement, content)

    # 6. Replace analyse_video to always return False
    pattern = r"@lru_cache\(\)\ndef analyse_video\(video_path : str, trim_frame_start : int, trim_frame_end : int\) -> bool:.*?return bool\(rate > 10\.0\)"
    replacement = """@lru_cache()
def analyse_video(video_path : str, trim_frame_start : int, trim_frame_end : int) -> bool:
\t# PATCHED: NSFW check disabled
\treturn False"""

    content = re.sub(pattern, replacement, content, flags=re.DOTALL)

    # 7. Replace detect_nsfw to always return False
    pattern = r"def detect_nsfw\(vision_frame : VisionFrame\) -> bool:.*?return is_nsfw_1 and is_nsfw_2 or is_nsfw_1 and is_nsfw_3 or is_nsfw_2 and is_nsfw_3"
    replacement = """def detect_nsfw(vision_frame : VisionFrame) -> bool:
\t# PATCHED: NSFW detection disabled
\treturn False"""

    content = re.sub(pattern, replacement, content, flags=re.DOTALL)

    if content == original:
        print(f"  ⚠️  Warning: No changes made to {file_path.name}")
        print("     This may indicate the file structure has changed upstream.")
    else:
        file_path.write_text(content)
        print(f"  ✅ Patched {file_path.name}")


def patch_core(file_path: Path) -> None:
    """
    Patch core.py to bypass the content_analyser hash check.
    """
    content = file_path.read_text()
    original = content

    # Replace hash check with True
    # Match pattern: content_analyser_hash == 'XXXXXXXX' (8 hex chars)
    pattern = r"content_analyser_hash == '[a-f0-9]{8}'"
    replacement = "True  # PATCHED: Hash check bypassed"

    content = re.sub(pattern, replacement, content)

    # Alternative: Remove the entire hash computation and check
    # This is more robust if the hash value changes
    pattern = r"\tcontent_analyser_content = inspect\.getsource\(content_analyser\)\.encode\(\)\n\tcontent_analyser_hash = hash_helper\.create_hash\(content_analyser_content\)\n\n\treturn all\(module\.pre_check\(\) for module in common_modules\) and content_analyser_hash == '[a-f0-9]{8}'"
    replacement = """\t# PATCHED: Hash check removed
\treturn all(module.pre_check() for module in common_modules)"""

    content = re.sub(pattern, replacement, content)

    if content == original:
        # Try alternative pattern for different formatting
        pattern = r"content_analyser_hash == '[a-f0-9]+'"
        content = re.sub(pattern, "True  # PATCHED", content)

    if content == original:
        print(f"  ⚠️  Warning: No changes made to {file_path.name}")
        print("     This may indicate the file structure has changed upstream.")
    else:
        file_path.write_text(content)
        print(f"  ✅ Patched {file_path.name}")


def verify_patches(source_dir: Path) -> bool:
    """Verify that patches were applied correctly."""
    content_analyser = source_dir / "facefusion" / "content_analyser.py"
    core = source_dir / "facefusion" / "core.py"

    success = True

    if content_analyser.exists():
        content = content_analyser.read_text()
        checks = [
            ("NSFW models removed", "# PATCHED: NSFW models removed" in content),
            ("pre_check disabled", "# PATCHED: Skip NSFW model downloads" in content),
            ("analyse_frame disabled", "# PATCHED: NSFW check disabled" in content),
        ]
        for name, passed in checks:
            if passed:
                print(f"  ✓ {name}")
            else:
                print(f"  ✗ {name} - FAILED")
                success = False

    if core.exists():
        content = core.read_text()
        if "# PATCHED" in content:
            print("  ✓ Hash check bypassed")
        else:
            print("  ✗ Hash check bypass - FAILED")
            success = False

    return success


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <facefusion_source_dir>")
        sys.exit(1)

    source_dir = Path(sys.argv[1])

    if not source_dir.exists():
        print(f"Error: Source directory not found: {source_dir}")
        sys.exit(1)

    print(f"\n🔧 Patching FaceFusion source in: {source_dir}\n")

    # Locate files
    content_analyser = source_dir / "facefusion" / "content_analyser.py"
    core = source_dir / "facefusion" / "core.py"

    if not content_analyser.exists():
        print(f"Error: content_analyser.py not found at {content_analyser}")
        sys.exit(1)

    if not core.exists():
        print(f"Error: core.py not found at {core}")
        sys.exit(1)

    # Apply patches
    print("Applying patches...")
    patch_content_analyser(content_analyser)
    patch_core(core)

    # Verify
    print("\nVerifying patches...")
    if verify_patches(source_dir):
        print("\n✅ All patches applied successfully!\n")
    else:
        print("\n❌ Some patches failed! Check the source file structure.\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
