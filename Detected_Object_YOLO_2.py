import cv2
import numpy as np
import pyrealsense2 as rs
import argparse
import json
import sys
import os
from dataclasses import dataclass
from pathlib import Path
from ultralytics import YOLO


SCRIPT_DIR = Path(__file__).resolve().parent
MODELS_DIR = SCRIPT_DIR / "models"

CUSTOM_MODEL_PATH = MODELS_DIR / "models" / "fruits_strawberry_tomato_det" / "weights" / "best.pt"
BANANA_MODEL_PATH = SCRIPT_DIR / "yolo26n.pt"

CONF_CUSTOM = 0.25
CONF_BANANA = 0.35
IMG_SIZE = 640
DEVICE = None
STABLE_FRAMES = 5
MAX_TRIALS_PER_ROUND = 60
BANANA_SUPPRESS_IOU = 0.25
MIN_BANANA_YELLOW_RATIO = 0.12
YELLOW_TO_RED_RATIO = 1.5
TARGET_LOCK_IOU = 0.25
TARGET_LOCK_CENTER_SHIFT = 0.6
GRASP_ORDER = {
    "banana": 0,
    "strawberry": 1,
    "tomato": 2
}


@dataclass
class Detection:
    class_name: str
    confidence: float
    bbox: tuple[int, int, int, int]

    @property
    def center(self):
        x1, y1, x2, y2 = self.bbox
        return (x1 + x2) // 2, (y1 + y2) // 2

    def as_result(self):
        return {
            "class_name": self.class_name,
            "confidence": self.confidence,
            "center": self.center,
            "bbox": [float(v) for v in self.bbox]
        }


def get_place_id(fruit_class):
    if fruit_class == "banana":
        return 1
    elif fruit_class == "strawberry":
        return 2
    elif fruit_class == "tomato":
        return 3
    else:
        return 0


def get_valid_depth(depth_image, cx, cy, window_size=15, depth_scale=0.001, bbox=None):
    h, w = depth_image.shape
    half = window_size // 2

    x1 = max(cx - half, 0)
    x2 = min(cx + half + 1, w)
    y1 = max(cy - half, 0)
    y2 = min(cy + half + 1, h)

    patch = depth_image[y1:y2, x1:x2].astype(np.float32)
    valid = patch[patch > 0]

    if len(valid) > 0:
        return float(np.median(valid) * depth_scale)

    if bbox is None:
        return None

    bx1, by1, bx2, by2 = [int(v) for v in bbox]
    box_w = max(1, bx2 - bx1)
    box_h = max(1, by2 - by1)

    margin_x = max(1, int(box_w * 0.2))
    margin_y = max(1, int(box_h * 0.2))
    bx1 = max(bx1 + margin_x, 0)
    bx2 = min(bx2 - margin_x, w)
    by1 = max(by1 + margin_y, 0)
    by2 = min(by2 - margin_y, h)

    if bx2 <= bx1 or by2 <= by1:
        return None

    box_patch = depth_image[by1:by2, bx1:bx2].astype(np.float32)
    box_valid = box_patch[box_patch > 0]

    if len(box_valid) == 0:
        return None

    low, high = np.percentile(box_valid, [10, 90])
    trimmed = box_valid[(box_valid >= low) & (box_valid <= high)]
    if len(trimmed) == 0:
        trimmed = box_valid

    return float(np.median(trimmed) * depth_scale)


def pixel_to_camera(u, v, z, intrinsics):
    fx = intrinsics.fx
    fy = intrinsics.fy
    ppx = intrinsics.ppx
    ppy = intrinsics.ppy

    x = (u - ppx) * z / fx
    y = (v - ppy) * z / fy

    return float(x), float(y), float(z)


def detections_from_result(result, class_names, conf_threshold, allowed_classes=None):
    detections = []
    if result.boxes is None:
        return detections

    for box in result.boxes:
        conf = float(box.conf[0])
        if conf < conf_threshold:
            continue

        cls_id = int(box.cls[0])
        cls_name = class_names.get(cls_id, str(cls_id)) if hasattr(class_names, "get") else class_names[cls_id]
        if allowed_classes is not None and cls_name not in allowed_classes:
            continue

        x1, y1, x2, y2 = [int(v) for v in box.xyxy[0].tolist()]
        detections.append(Detection(cls_name, conf, (x1, y1, x2, y2)))
        print(f"[YOLO] detected: {cls_name}, conf={conf:.2f}")

    return detections


def color_ratios(frame, bbox):
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = bbox
    x1, x2 = max(0, x1), min(width, x2)
    y1, y2 = max(0, y1), min(height, y2)
    if x2 <= x1 or y2 <= y1:
        return 0.0, 0.0

    crop = frame[y1:y2, x1:x2]
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    yellow_mask = cv2.inRange(hsv, (15, 60, 80), (40, 255, 255))
    red_low = cv2.inRange(hsv, (0, 60, 50), (10, 255, 255))
    red_high = cv2.inRange(hsv, (170, 60, 50), (180, 255, 255))
    red_mask = cv2.bitwise_or(red_low, red_high)
    pixels = crop.shape[0] * crop.shape[1]
    return cv2.countNonZero(yellow_mask) / pixels, cv2.countNonZero(red_mask) / pixels


def fruit_color_mask(crop, fruit_class):
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    if fruit_class == "banana":
        return cv2.inRange(hsv, (15, 60, 80), (40, 255, 255))

    red_low = cv2.inRange(hsv, (0, 50, 40), (12, 255, 255))
    red_high = cv2.inRange(hsv, (165, 50, 40), (180, 255, 255))
    return cv2.bitwise_or(red_low, red_high)


def get_grasp_point(frame, detection):
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = detection.bbox
    x1, x2 = max(0, x1), min(width, x2)
    y1, y2 = max(0, y1), min(height, y2)
    if x2 <= x1 or y2 <= y1:
        return detection.center

    crop = frame[y1:y2, x1:x2]
    mask = fruit_color_mask(crop, detection.class_name)
    kernel = np.ones((5, 5), np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    min_area = max(30.0, crop.shape[0] * crop.shape[1] * 0.03)
    contours = [contour for contour in contours if cv2.contourArea(contour) >= min_area]
    if not contours:
        return detection.center

    contour = max(contours, key=cv2.contourArea)
    moments = cv2.moments(contour)
    if moments["m00"] == 0:
        return detection.center

    cx = int(x1 + moments["m10"] / moments["m00"])
    cy = int(y1 + moments["m01"] / moments["m00"])
    return cx, cy


def looks_like_banana_color(frame, detection):
    yellow_ratio, red_ratio = color_ratios(frame, detection.bbox)
    return (
        yellow_ratio >= MIN_BANANA_YELLOW_RATIO
        and yellow_ratio >= red_ratio * YELLOW_TO_RED_RATIO
    )


def relabel_yellow_strawberries_as_bananas(frame, detections):
    relabeled = []
    for det in detections:
        if det.class_name == "strawberry" and looks_like_banana_color(frame, det):
            relabeled.append(Detection("banana", det.confidence, det.bbox))
        else:
            relabeled.append(det)
    return relabeled


def box_iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0, ix2 - ix1), max(0, iy2 - iy1)
    intersection = iw * ih
    if intersection == 0:
        return 0.0

    a_area = max(0, ax2 - ax1) * max(0, ay2 - ay1)
    b_area = max(0, bx2 - bx1) * max(0, by2 - by1)
    union = a_area + b_area - intersection
    return intersection / union if union else 0.0


def bbox_center(bbox):
    x1, y1, x2, y2 = bbox
    return (x1 + x2) / 2.0, (y1 + y2) / 2.0


def same_target_bbox(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    aw, ah = max(1, ax2 - ax1), max(1, ay2 - ay1)
    bw, bh = max(1, bx2 - bx1), max(1, by2 - by1)
    acx, acy = bbox_center(a)
    bcx, bcy = bbox_center(b)
    center_dist = np.hypot(acx - bcx, acy - bcy)
    max_shift = max(25.0, TARGET_LOCK_CENTER_SHIFT * min(aw, ah, bw, bh))
    return box_iou(a, b) >= TARGET_LOCK_IOU or center_dist <= max_shift


def compatible_locked_class(candidate_class, locked_class):
    if candidate_class == locked_class:
        return True
    return {candidate_class, locked_class} <= {"strawberry", "tomato"}


def center_inside(inner, outer):
    cx, cy = inner.center
    x1, y1, x2, y2 = outer.bbox
    return x1 <= cx <= x2 and y1 <= cy <= y2


def dedupe_banana_detections(banana_detections):
    kept = []
    for det in sorted(banana_detections, key=lambda item: item.confidence, reverse=True):
        duplicate = any(
            box_iou(det.bbox, kept_det.bbox) >= BANANA_SUPPRESS_IOU
            or center_inside(det, kept_det)
            or center_inside(kept_det, det)
            for kept_det in kept
        )
        if not duplicate:
            kept.append(det)
    return kept


def suppress_custom_overlapping_bananas(custom_detections, banana_detections):
    if not banana_detections:
        return custom_detections

    filtered = []
    for det in custom_detections:
        overlaps_banana = any(
            box_iou(det.bbox, banana.bbox) >= BANANA_SUPPRESS_IOU
            or center_inside(banana, det)
            for banana in banana_detections
        )
        if not overlaps_banana:
            filtered.append(det)
    return filtered


def sort_detections(detections):
    return sorted(detections, key=lambda det: (GRASP_ORDER.get(det.class_name, 999), det.center[0]))


def select_target_detection(detections, locked_class=None, locked_bbox=None):
    if not detections:
        return None

    if locked_class is None or locked_bbox is None:
        return detections[0]

    candidates = [
        det for det in detections
        if compatible_locked_class(det.class_name, locked_class)
        and same_target_bbox(det.bbox, locked_bbox)
    ]
    if not candidates:
        return None

    return max(candidates, key=lambda det: box_iou(det.bbox, locked_bbox))


def detect_fruit_combined(custom_model, banana_model, color_image):
    custom_result = custom_model.predict(
        color_image, imgsz=IMG_SIZE, conf=CONF_CUSTOM, device=DEVICE, verbose=False
    )[0]
    banana_result = banana_model.predict(
        color_image, imgsz=IMG_SIZE, conf=CONF_BANANA, device=DEVICE, verbose=False
    )[0]

    custom_detections = detections_from_result(
        custom_result, custom_model.names, CONF_CUSTOM, {"strawberry", "tomato"}
    )
    custom_detections = relabel_yellow_strawberries_as_bananas(color_image, custom_detections)

    banana_detections = detections_from_result(
        banana_result, banana_model.names, CONF_BANANA, {"banana"}
    )
    color_banana_detections = [
        det for det in custom_detections if det.class_name == "banana"
    ]
    custom_detections = [
        det for det in custom_detections if det.class_name != "banana"
    ]

    banana_detections = dedupe_banana_detections(banana_detections + color_banana_detections)
    custom_detections = suppress_custom_overlapping_bananas(custom_detections, banana_detections)
    detections = sort_detections(custom_detections + banana_detections)

    if not detections:
        return False, None, []

    return True, detections[0].as_result(), detections


def draw_detections(display, detections, target_det=None):
    for index, det in enumerate(detections, start=1):
        x1, y1, x2, y2 = det.bbox
        is_target = target_det is not None and det.bbox == tuple(map(int, target_det["bbox"]))
        cx, cy = target_det["center"] if is_target else det.center
        color = (0, 255, 0) if is_target else (80, 180, 255)
        label_class = target_det["class_name"] if is_target else det.class_name
        label_conf = target_det["confidence"] if is_target else det.confidence
        label = f"{index}. {label_class} {label_conf:.2f}"
        cv2.rectangle(display, (x1, y1), (x2, y2), color, 2)
        cv2.circle(display, (cx, cy), 5, (255, 0, 0), -1)
        cv2.putText(display, label, (x1, max(y1 - 10, 20)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2)


def save_result(found, observe_id, camera_xyz=None, fruit_class=None,
                confidence=None, bbox=None, output_file="vision_result.json"):
    place_id = get_place_id(fruit_class) if fruit_class is not None else 0

    data = {
        "found": bool(found),
        "observe_id": int(observe_id),
        "fruit_class": fruit_class,
        "place_id": int(place_id),
        "confidence": float(confidence) if confidence is not None else None,
        "bbox": bbox,
        "camera_xyz": [float(v) for v in camera_xyz] if camera_xyz is not None else None
    }

    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

    print(f"[INFO] Result saved to: {os.path.abspath(output_file)}")
    print(json.dumps(data, indent=2, ensure_ascii=False))


def parse_args():
    parser = argparse.ArgumentParser(description="Detect fruits and write the vision result JSON.")
    parser.add_argument(
        "observe_id",
        nargs="?",
        type=int,
        default=0,
        help="Observation id written into the result JSON."
    )
    parser.add_argument(
        "--output",
        default=str(SCRIPT_DIR / "vision_result.json"),
        help="Path of the result JSON file."
    )
    return parser.parse_args()


def get_stable_target(custom_model, banana_model, pipeline, align, color_intrinsics, depth_scale,
                      stable_frames=STABLE_FRAMES, max_trials=MAX_TRIALS_PER_ROUND,
                      window_size=15):
    samples = []
    class_votes = []
    confs = []
    last_bbox = None
    current_class = None
    current_bbox = None

    for trial in range(1, max_trials + 1):
        frames = pipeline.wait_for_frames()
        aligned_frames = align.process(frames)

        depth_frame = aligned_frames.get_depth_frame()
        color_frame = aligned_frames.get_color_frame()

        if not depth_frame or not color_frame:
            continue

        color_image = np.asanyarray(color_frame.get_data())
        depth_image = np.asanyarray(depth_frame.get_data())
        display = color_image.copy()

        found, _, detections = detect_fruit_combined(custom_model, banana_model, color_image)

        if found:
            selected = select_target_detection(detections, current_class, current_bbox)
            if selected is None:
                samples.clear()
                class_votes.clear()
                confs.clear()
                current_class = None
                current_bbox = None
                selected = detections[0]
                print(f"[{trial}/{max_trials}] Target changed. Restarting stable samples.")

            det = selected.as_result()
            det["center"] = get_grasp_point(color_image, selected)

            cx, cy = det["center"]
            fruit_class = det["class_name"]
            conf = det["confidence"]
            bbox = tuple(map(int, det["bbox"]))

            z = get_valid_depth(
                depth_image,
                cx,
                cy,
                window_size=window_size,
                depth_scale=depth_scale,
                bbox=bbox
            )

            if z is not None:
                draw_detections(display, detections, det)

                if (
                    current_class is not None
                    and (fruit_class != current_class or not same_target_bbox(bbox, current_bbox))
                ):
                    samples.clear()
                    class_votes.clear()
                    confs.clear()
                current_class = fruit_class
                current_bbox = bbox
                last_bbox = bbox

                x, y, z = pixel_to_camera(cx, cy, z, color_intrinsics)

                samples.append((x, y, z))
                class_votes.append(fruit_class)
                confs.append(conf)

                cv2.putText(display, f"Sample {len(samples)}/{stable_frames}",
                            (10, 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)

                cv2.putText(display, f"XYZ=({x:.3f}, {y:.3f}, {z:.3f}) m",
                            (10, 60),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)

                print(f"[{trial}/{max_trials}] Sample {len(samples)}/{stable_frames}: "
                      f"{fruit_class}, conf={conf:.2f}, "
                      f"Camera XYZ=({x:.3f}, {y:.3f}, {z:.3f}) m")

                if len(samples) >= stable_frames:
                    avg_xyz = np.mean(np.array(samples), axis=0)
                    final_class = max(set(class_votes), key=class_votes.count)
                    avg_conf = float(np.mean(confs))
                    return True, avg_xyz.tolist(), final_class, avg_conf, last_bbox

            else:
                draw_detections(display, detections, det)
                cv2.putText(display, "No valid depth at target",
                            (10, 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

        else:
            draw_detections(display, detections)
            cv2.putText(display, "Fruit not found - keep scanning",
                        (10, 30),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

        cv2.imshow("YOLO Fruit Detection", display)
        key = cv2.waitKey(1) & 0xFF

        if key == 27 or key == ord("q"):
            return None, None, None, None, None

    return False, None, None, None, None


def main():
    args = parse_args()
    observe_id = args.observe_id
    output_file = args.output

    if not CUSTOM_MODEL_PATH.exists():
        raise FileNotFoundError(f"Custom model not found: {CUSTOM_MODEL_PATH}")

    banana_model_path = BANANA_MODEL_PATH if BANANA_MODEL_PATH.exists() else "yolov8n.pt"

    print("[INFO] Loading custom strawberry/tomato YOLO model...")
    print(f"       {CUSTOM_MODEL_PATH}")
    custom_model = YOLO(str(CUSTOM_MODEL_PATH))

    print("[INFO] Loading banana YOLO model...")
    print(f"       {banana_model_path}")
    banana_model = YOLO(str(banana_model_path))

    pipeline = rs.pipeline()
    config = rs.config()

    config.enable_stream(rs.stream.color, 640, 480, rs.format.bgr8, 30)
    config.enable_stream(rs.stream.depth, 640, 480, rs.format.z16, 30)

    print("[INFO] Starting RealSense pipeline...")
    profile = pipeline.start(config)

    align = rs.align(rs.stream.color)

    depth_sensor = profile.get_device().first_depth_sensor()
    depth_scale = depth_sensor.get_depth_scale()

    color_stream = profile.get_stream(rs.stream.color)
    color_intrinsics = color_stream.as_video_stream_profile().get_intrinsics()

    print(f"[INFO] Depth scale: {depth_scale}")
    print("[INFO] Camera intrinsics:")
    print(f"       fx={color_intrinsics.fx}, fy={color_intrinsics.fy}")
    print(f"       ppx={color_intrinsics.ppx}, ppy={color_intrinsics.ppy}")
    print(f"[INFO] observe_id = {observe_id}")
    print(f"[INFO] output_file = {os.path.abspath(output_file)}")
    print("[INFO] Scanning continuously. Press q or Esc to quit.")

    try:
        while True:
            found, avg_xyz, fruit_class, avg_conf, bbox = get_stable_target(
                custom_model=custom_model,
                banana_model=banana_model,
                pipeline=pipeline,
                align=align,
                color_intrinsics=color_intrinsics,
                depth_scale=depth_scale,
                stable_frames=STABLE_FRAMES,
                max_trials=MAX_TRIALS_PER_ROUND,
                window_size=15
            )

            if found is None:
                print("[INFO] User stopped detection.")
                save_result(False, observe_id, None, output_file=output_file)
                break

            if found:
                print(f"[FOUND] class={fruit_class}, avg_camera_xyz={avg_xyz}")
                save_result(
                    True,
                    observe_id,
                    avg_xyz,
                    fruit_class=fruit_class,
                    confidence=avg_conf,
                    bbox=bbox,
                    output_file=output_file
                )
                cv2.waitKey(500)
                continue   # keep scanning

            print("[WAITING] No stable target found. Retrying...")
            save_result(False, observe_id, None, output_file=output_file)
            continue

    except Exception as e:
        print(f"[ERROR] {e}")
        save_result(False, observe_id, None, output_file=output_file)

    finally:
        pipeline.stop()
        cv2.destroyAllWindows()
        print("[INFO] Pipeline stopped.")


if __name__ == "__main__":
    main()


    
