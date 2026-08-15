import sys
import torch, numpy, cv2
print("torch:", torch.__version__, "cuda:", torch.version.cuda)
print("numpy:", numpy.__version__, "cv2:", cv2.__version__)
fail = []
if torch.version.cuda is None:
    fail.append("torch is a CPU build — something pip-installed torch over the base image")
if not numpy.__version__.startswith("1."):
    fail.append(f"numpy is {numpy.__version__}, must be <2 (LayerStyle/Impact-Pack break on 2.x)")
if not hasattr(cv2, "ximgproc") or not hasattr(cv2.ximgproc, "guidedFilter"):
    fail.append("cv2.ximgproc.guidedFilter missing — the non-contrib opencv won")
try:
    import mediapipe
    print("mediapipe:", mediapipe.__version__)
except Exception as e:
    fail.append(f"mediapipe does not import: {e}")
if fail:
    print("\n".join("[verify] FAIL: " + f for f in fail), file=sys.stderr)
    sys.exit(1)
print("[verify] ok")
