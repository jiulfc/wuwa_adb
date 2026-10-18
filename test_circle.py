#!/usr/bin/env python3
import sys

try:
    import cv2
    import numpy as np
except ModuleNotFoundError:
    raise SystemExit("Missing OpenCV: python3 -m pip install opencv-python")


path = sys.argv[1] if len(sys.argv) > 1 else "rect.png"
image = cv2.imread(path)
if image is None:
    raise SystemExit(f"Cannot read image: {path}")

h, w = image.shape[:2]
y, x = np.indices((h, w))
radius = np.hypot(x - w / 2, y - h / 2)
ring = (radius >= 30) & (radius <= 36)

hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
green = cv2.inRange(hsv, (55, 60, 60), (95, 255, 255)) > 0

angle = (np.degrees(np.arctan2(y - h / 2, x - w / 2)) + 360) % 360
bins = (angle / 2).astype(np.uint8)
total = np.bincount(bins[ring], minlength=180)
hits = np.bincount(bins[ring & green], minlength=180)
valid = total > 0
filled = hits >= np.maximum(1, total * 0.2)
percentage = filled[valid].mean()

print(f"green: {percentage:.1%}")
print("full" if percentage >= 0.9 else "not full")
