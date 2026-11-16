// panel_postprocess.h
//
// Post-processing for YOLO panel detections. Header-only and free of OpenCV so
// it can be unit-tested on a desktop (see test/panel_postprocess_test.cpp).
//
// All boxes are NORMALISED to the page: x, y, w, h in 0..1. Working in
// normalised units makes every threshold independent of the pixel size the
// page happened to be decoded at.
//
// Pipeline (called from panelshift_core.cpp):
//   nms -> filter_geometry -> merge_fragments -> [variance check] -> sort_reading_order
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace panelshift {

struct Box {
  float x;
  float y;
  float w;
  float h;
  float score;

  float right() const { return x + w; }
  float bottom() const { return y + h; }
  float area() const { return (w > 0.f && h > 0.f) ? w * h : 0.f; }
};

struct Params {
  // --- NMS --------------------------------------------------------------
  // 0.50 (was 0.45): panels that touch without a gutter overlap a little and
  // were being suppressed as "duplicates". True duplicates of one panel
  // overlap far more than this, and containment/fragment cases are handled
  // by merge_fragments(), which sees geometry that IoU cannot.
  float nms_iou = 0.50f;
  std::size_t max_candidates = 300;  // bounds the O(n^2) loops

  // --- geometry limits, normalised -------------------------------------
  // Derived from the previous pixel constants (25 px / 15 px / 350 px^2) at a
  // 1600x2400 reference page, so typical scans behave as before.
  float min_width = 0.016f;
  float min_height = 0.010f;
  float min_height_wide = 0.006f;  // panels wider than wide_aspect
  float min_area = 1.0e-4f;
  float wide_aspect = 2.0f;
  float min_aspect = 0.15f;
  float max_aspect = 8.0f;
  // width / height of the source page. The old pixel-space aspect test is
  // (w / h) * page_aspect for normalised boxes.
  float page_aspect = 1.0f;

  // --- fragment merging --------------------------------------------------
  // inter / min(areaA, areaB). At or above this, one box is (nearly) inside
  // the other and is absorbed (was: merge at > 0.45 regardless of shape).
  float containment = 0.80f;
  // Below this the boxes only touch/bleed over a border: never merged.
  float partial_overlap = 0.30f;
  // Between the two, merge only if the union's bounding box is mostly filled
  // by the two boxes themselves (fragments of one panel: ~1.0; two different
  // panels forming an L: well below).
  float min_fill = 0.82f;

  // --- reading order -----------------------------------------------------
  float row_overlap = 0.50f;        // vertical overlap (of the smaller box) to share a row
  float column_tolerance = 0.03f;   // x difference treated as "same column"
};

inline float intersection_area(const Box& a, const Box& b) {
  const float iw = std::min(a.right(), b.right()) - std::max(a.x, b.x);
  const float ih = std::min(a.bottom(), b.bottom()) - std::max(a.y, b.y);
  return (iw > 0.f && ih > 0.f) ? iw * ih : 0.f;
}

inline float iou(const Box& a, const Box& b) {
  const float inter = intersection_area(a, b);
  const float uni = a.area() + b.area() - inter;
  return uni > 0.f ? inter / uni : 0.f;
}

inline Box bounding_box(const Box& a, const Box& b) {
  Box u;
  u.x = std::min(a.x, b.x);
  u.y = std::min(a.y, b.y);
  u.w = std::max(a.right(), b.right()) - u.x;
  u.h = std::max(a.bottom(), b.bottom()) - u.y;
  u.score = std::max(a.score, b.score);
  return u;
}

// Greedy, class-agnostic non-maximum suppression (highest score first).
inline std::vector<Box> nms(std::vector<Box> boxes, const Params& p) {
  std::stable_sort(boxes.begin(), boxes.end(),
                   [](const Box& a, const Box& b) { return a.score > b.score; });
  if (boxes.size() > p.max_candidates) boxes.resize(p.max_candidates);

  std::vector<Box> keep;
  keep.reserve(boxes.size());
  for (const Box& b : boxes) {
    bool suppressed = false;
    for (const Box& k : keep) {
      if (iou(b, k) > p.nms_iou) {
        suppressed = true;
        break;
      }
    }
    if (!suppressed) keep.push_back(b);
  }
  return keep;
}

// Drops boxes that are too small or have an implausible aspect ratio.
inline std::vector<Box> filter_geometry(const std::vector<Box>& in, const Params& p) {
  std::vector<Box> out;
  out.reserve(in.size());
  for (const Box& b : in) {
    if (b.w <= 0.f || b.h <= 0.f) continue;
    const float aspect = (b.w / b.h) * p.page_aspect;
    const float min_h = (aspect > p.wide_aspect) ? p.min_height_wide : p.min_height;
    if (b.w < p.min_width || b.h < min_h) continue;
    if (b.area() < p.min_area) continue;
    if (aspect < p.min_aspect || aspect > p.max_aspect) continue;
    out.push_back(b);
  }
  return out;
}

inline bool should_merge(const Box& a, const Box& b, const Params& p) {
  const float inter = intersection_area(a, b);
  if (inter <= 0.f) return false;

  const float min_area = std::min(a.area(), b.area());
  if (min_area <= 0.f) return false;

  const float overlap_of_smaller = inter / min_area;
  if (overlap_of_smaller >= p.containment) return true;     // one swallows the other
  if (overlap_of_smaller < p.partial_overlap) return false;  // just touching borders

  const float union_area = a.area() + b.area() - inter;
  const float bbox_area = bounding_box(a, b).area();
  return bbox_area > 0.f && (union_area / bbox_area) >= p.min_fill;
}

// Merges fragments of the same panel.
//  * Largest boxes first, so the result does not depend on detector order.
//  * Repeats until nothing changes: a merge enlarges a box, and the enlarged
//    box can now overlap a third fragment that the old single pass never
//    revisited.
inline std::vector<Box> merge_fragments(std::vector<Box> boxes, const Params& p) {
  std::stable_sort(boxes.begin(), boxes.end(),
                   [](const Box& a, const Box& b) { return a.area() > b.area(); });

  bool changed = true;
  for (int pass = 0; changed && pass < 16; ++pass) {
    changed = false;
    for (std::size_t i = 0; i < boxes.size(); ++i) {
      for (std::size_t j = i + 1; j < boxes.size();) {
        if (should_merge(boxes[i], boxes[j], p)) {
          boxes[i] = bounding_box(boxes[i], boxes[j]);
          boxes.erase(boxes.begin() + static_cast<std::ptrdiff_t>(j));
          changed = true;
        } else {
          ++j;
        }
      }
    }
  }
  return boxes;
}

// Stable insertion sort. Unlike std::sort it stays well-defined when the
// comparator is not a strict weak ordering (a tolerance comparison is not).
template <class T, class Before>
inline void insertion_sort(std::vector<T>& v, Before before) {
  for (std::size_t i = 1; i < v.size(); ++i) {
    const T key = v[i];
    std::size_t j = i;
    while (j > 0 && before(key, v[j - 1])) {
      v[j] = v[j - 1];
      --j;
    }
    v[j] = key;
  }
}

// Top-to-bottom rows, left-to-right inside a row. A box joins the row of the
// topmost unplaced box when they overlap vertically by row_overlap of the
// smaller height; inside a row, boxes in the same column are ordered by y.
//
// The old comparator (|dy| > 45px ? by y : by x) is not transitive, which is
// undefined behaviour for std::sort and can read out of bounds.
inline void sort_reading_order(std::vector<Box>& boxes, const Params& p) {
  if (boxes.size() < 2) return;

  std::stable_sort(boxes.begin(), boxes.end(),
                   [](const Box& a, const Box& b) { return a.y < b.y; });

  std::vector<Box> ordered;
  ordered.reserve(boxes.size());
  std::vector<bool> used(boxes.size(), false);

  for (std::size_t i = 0; i < boxes.size(); ++i) {
    if (used[i]) continue;
    const Box seed = boxes[i];
    std::vector<Box> row;
    row.push_back(seed);
    used[i] = true;

    for (std::size_t j = i + 1; j < boxes.size(); ++j) {
      if (used[j]) continue;
      const Box& c = boxes[j];
      const float overlap = std::min(seed.bottom(), c.bottom()) - std::max(seed.y, c.y);
      const float min_h = std::min(seed.h, c.h);
      if (min_h > 0.f && overlap > p.row_overlap * min_h) {
        row.push_back(c);
        used[j] = true;
      }
    }

    insertion_sort(row, [&p](const Box& a, const Box& b) {
      if (std::fabs(a.x - b.x) > p.column_tolerance) return a.x < b.x;
      return a.y < b.y;
    });
    ordered.insert(ordered.end(), row.begin(), row.end());
  }
  boxes.swap(ordered);
}

}  // namespace panelshift
