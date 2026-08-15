"""Build-time sanity check for the image's Python environment.

Runs on the build runner, which has no GPU — so it checks build metadata, which
is where the damage would show anyway. Each failure here is one that otherwise
surfaces mid-render on a paid GPU, and two of them are silent (a CPU torch just
runs a hundred times slower; a clobbered cv2 just loses nodes).

Everything prints to stdout so the reason sits directly above buildx's "exit
code: 1" instead of in a separate stream.
"""

import sys
from importlib.metadata import distributions

failures = []


def check(label, fn):
    try:
        fn()
    except Exception as exc:  # a check that cannot run is a failure
        failures.append(f"{label}: {type(exc).__name__}: {exc}")


def torch_is_cuda():
    import torch

    print(f"torch      {torch.__version__}  (cuda {torch.version.cuda})")
    if torch.version.cuda is None:
        raise AssertionError(
            "this is a CPU wheel — something pip-installed torch over the base "
            "image. Every render would run on the CPU, with no error to show "
            "for it. Find the requirement that asked for torch and block it in "
            "install_nodes.sh."
        )


def numpy_is_1x():
    import numpy

    print(f"numpy      {numpy.__version__}")
    if not numpy.__version__.startswith("1."):
        raise AssertionError(
            "must be <2 — LayerStyle and Impact-Pack break at import on 2.x. "
            "Check that PIP_CONSTRAINT still points at constraints.txt."
        )


def cv2_is_contrib():
    import cv2

    variants = sorted(
        f"{d.metadata['Name']}=={d.version}"
        for d in distributions()
        if (d.metadata["Name"] or "").startswith("opencv")
    )
    print(f"cv2        {cv2.__version__}  ({', '.join(variants) or 'no dist metadata'})")

    if len(variants) > 1:
        raise AssertionError(
            "more than one opencv distribution is installed: "
            + ", ".join(variants)
            + ". They share site-packages/cv2, so the winner is whichever "
            "unpacked last. Only opencv-contrib-python-headless should remain."
        )
    if not hasattr(cv2, "ximgproc") or not hasattr(cv2.ximgproc, "guidedFilter"):
        raise AssertionError(
            "cv2.ximgproc.guidedFilter is missing, so a non-contrib opencv won. "
            "ultralytics pulls opencv-python and mediapipe pulls "
            "opencv-contrib-python; the normalisation step at the end of "
            "install_nodes.sh is what is meant to undo that."
        )


def mediapipe_imports():
    import mediapipe

    print(f"mediapipe  {mediapipe.__version__}")


check("torch", torch_is_cuda)
check("numpy", numpy_is_1x)
check("cv2", cv2_is_contrib)
check("mediapipe", mediapipe_imports)

if failures:
    print()
    for f in failures:
        print(f"[verify] FAIL  {f}")
    sys.exit(1)

print("[verify] ok")
