#!/usr/bin/env python3
"""Patch the vendored AnySplat Space app.py for self-hosted containers.

Idempotent-ish: fails loudly if an upstream string changed, so a Space bump is
caught at image-build time instead of at runtime.

Usage: patch_app.py /app/app.py
"""
import sys
from pathlib import Path

path = Path(sys.argv[1] if len(sys.argv) > 1 else "/app/app.py")
src = path.read_text()
orig = src


def sub(old, new, count=-1):
    global src
    if old not in src:
        raise SystemExit(f"patch_app: pattern not found: {old!r}")
    src = src.replace(old, new) if count < 0 else src.replace(old, new, count)


# 1) no runtime pip: pytorch3d + friends are installed at image build time
sub(
    'sh("pip install pytorch3d-0.7.9-cp310-cp310-linux_x86_64.whl")',
    "# pytorch3d installed at image build time (runtime pip disabled)",
)

# 2) don't hardcode the HF ZeroGPU arch; allow override (sm_80/sm_86 default)
sub(
    "os.environ['TORCH_CUDA_ARCH_LIST'] = '9.0'",
    "os.environ.setdefault('TORCH_CUDA_ARCH_LIST', '8.0;8.6')",
)

# 3) spaces.GPU is a ZeroGPU decorator; make it a no-op off HF Spaces
sub(
    "import spaces\n",
    "try:\n"
    "    import spaces  # optional: HF Spaces ZeroGPU helper\n"
    "except Exception:\n"
    "    spaces = None\n"
    "\n"
    "\n"
    "def GPU(*dargs, **dkwargs):\n"
    "    if len(dargs) == 1 and callable(dargs[0]) and not dkwargs:\n"
    "        return dargs[0]\n"
    "\n"
    "    def _deco(fn):\n"
    "        return fn\n"
    "\n"
    "    return _deco\n"
    "\n"
    "\n"
    "if spaces is not None and hasattr(spaces, 'GPU'):\n"
    "    GPU = spaces.GPU\n",
)

# 4) use the shim instead of the ZeroGPU decorator
sub("@spaces.GPU()", "@GPU()")

# 5) don't pre-cache examples at startup (slow / needs network)
sub("cache_examples=True", "cache_examples=False")

# 6) baked model weights: default to the in-image copy, overridable at runtime
sub(
    'AnySplat.from_pretrained(\n        "lhjiang/anysplat"\n    )',
    "AnySplat.from_pretrained(\n        os.environ.get('ANYSPLAT_MODEL', '/opt/models/anysplat')\n    )",
)

# 6b) let the output/working dir be overridden (default keeps upstream behaviour)
sub(
    'os.environ["ANYSPLAT_PROCESSED"] = f"{os.getcwd()}/proprocess_results"',
    'os.environ["ANYSPLAT_PROCESSED"] = os.environ.get("ANYSPLAT_PROCESSED", f"{os.getcwd()}/proprocess_results")',
)

# 7) serve on the container interface, no public share tunnel, no MCP server
sub(
    "demo.launch(show_error=True, share=True, mcp_server=True)",
    "demo.launch(\n"
    "        server_name=os.environ.get('GRADIO_SERVER_NAME', '0.0.0.0'),\n"
    "        server_port=int(os.environ.get('GRADIO_SERVER_PORT', '7860')),\n"
    "        root_path=os.environ.get('GRADIO_ROOT_PATH') or None,\n"
    "        show_error=True,\n"
    "        share=False,\n"
    "        mcp_server=False,\n"
    "        show_api=False,\n"
    "    )",
)

path.write_text(src)
print(f"patch_app: patched {path} ({len(orig)} -> {len(src)} bytes)")
