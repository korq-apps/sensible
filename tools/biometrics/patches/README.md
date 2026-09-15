# Howdy-next 3.4.0 compatibility patches

Patches 0001–0003 come from the GPL-3.0-or-later packaging project
[howdy-next-apt, a79e6489](https://github.com/JochemKuipers/howdy-next-apt/tree/a79e6489dce24cdd86fd8846559beb33141d2360/debian/patches).
They disable OpenCL during comparison, adjust the bounded resource limits for
OpenCV 5, and select the FP32 SFace model with its upstream hash and size.

Patch 0004 updates the existing sandbox regression scenarios for the changed
limits: preferred values, lower usable limits, and rejection immediately below
the new minimum. Patch 0005 updates the model-manifest integrity test for the
selected FP32 artifact. Patch 0006 aligns the shipped model provenance notice
with that artifact. The builder runs the upstream CTest suite.
The private OpenCV build uses V4L2 and GTK; FFmpeg is unnecessary
for camera testing and is disabled to avoid the stale binary package dependency.

These are local evaluation builds. Installation does not add a PAM profile to
desktop login or install the third-party package's polkit sandbox override.
