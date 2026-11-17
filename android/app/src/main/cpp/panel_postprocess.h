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
//   nms -> filter_geometry -> drop_union_boxes -> merge_fragments -> [variance check]
//   -> sort_reading_order
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <utility>
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

  // --- union-box guard (drop_union_boxes) --------------------------------
  // A "union" box spans several neighbouring panels, see drop_union_boxes().
  // Smallest child, as a share of the union's area: anything smaller is a bubble
  // or a fragment, not a panel. Kept high on purpose: dropping a correct box is
  // worse than leaving a union in, and a large speech bubble is easily 5-10% of
  // the panel it sits in.
  float union_child_min_area = 0.12f;
  // The children together must fill at least this share of the union. A value
  // above 1.0 switches the guard off.
  float union_coverage = 0.65f;
  // Children that overlap each other by this much (of the smaller one) are
  // fragments of ONE panel, not separate panels.
  float union_child_overlap = 0.10f;

  // --- reading order -----------------------------------------------------
  float row_overlap = 0.50f;        // vertical overlap (of the smaller box) to share a row
  float column_tolerance = 0.03f;   // x difference treated as "same column"
  // A box may reach this far (normalised) across a cut line and the cut still
  // counts as clean: detector boxes of neighbouring panels overlap a little.
  float cut_tolerance = 0.02f;
  // false = reading order by row grouping only, exactly as before (a rollback
  // switch). true = also split the boxes at a clear gap when some box spans several
  // rows, see sort_reading_order().
  bool use_cuts = true;
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

// Removes "union" boxes: a detection that spans several neighbouring panels.
//
// NMS cannot remove one (it overlaps each neighbour with an IoU of about 1/k, below
// nms_iou), and merge_fragments() then ABSORBS the neighbours into it through the
// containment rule, so two real panels with a gutter between them come out as one.
// merge_fragments() never bridges a gap by itself (it needs overlap), so a box like
// this is the one way a gutter gets swallowed.
//
// A box is dropped only when ALL of these hold:
//  * at least two boxes lie (nearly) inside it, each big enough to be a panel rather
//    than a bubble (>= union_child_min_area of the box);
//  * those boxes are separate from each other: a pair that overlaps is fragments of
//    ONE panel, which merge_fragments() should reunite, so the big box is left alone;
//  * together they fill most of it (union_coverage): a panel with a few speech
//    bubbles inside is not mostly bubbles;
//  * the big box is LESS confident than every one of them: a correct panel that also
//    produced two weak fragments keeps its higher score and stays.
// Known limit: a weak box over a panel plus two confident, NON-overlapping halves of
// that same panel looks exactly like a union, so the weak (correct) box is dropped and
// the panel is read as two stops. Telling those apart needs pixels (is there a gutter
// between the halves?), which this OpenCV-free header does not have.
// Returns how many boxes were dropped.
inline std::size_t drop_union_boxes(std::vector<Box>& boxes, const Params& p) {
  const std::size_t n = boxes.size();
  if (n < 3) return 0;  // a union plus at least two children

  std::vector<bool> drop(n, false);
  std::vector<std::size_t> kids;
  for (std::size_t i = 0; i < n; ++i) {
    const Box& u = boxes[i];
    const float ua = u.area();
    if (ua <= 0.f) continue;

    kids.clear();
    float covered = 0.f;
    float weakest = std::numeric_limits<float>::max();
    for (std::size_t j = 0; j < n; ++j) {
      if (j == i) continue;
      const Box& c = boxes[j];
      const float ca = c.area();
      if (ca <= 0.f || ca >= ua || ca < p.union_child_min_area * ua) continue;
      if (intersection_area(u, c) / ca < p.containment) continue;
      kids.push_back(j);
      covered += ca;
      weakest = std::min(weakest, c.score);
    }
    if (kids.size() < 2 || covered < p.union_coverage * ua || !(u.score < weakest)) continue;

    bool separate = true;
    for (std::size_t a = 0; separate && a < kids.size(); ++a) {
      for (std::size_t b = a + 1; b < kids.size(); ++b) {
        const Box& ka = boxes[kids[a]];
        const Box& kb = boxes[kids[b]];
        if (intersection_area(ka, kb) >= p.union_child_overlap * std::min(ka.area(), kb.area())) {
          separate = false;
          break;
        }
      }
    }
    if (separate) drop[i] = true;
  }

  std::size_t kept = 0;
  for (std::size_t i = 0; i < n; ++i) {
    if (!drop[i]) boxes[kept++] = boxes[i];
  }
  const std::size_t dropped = n - kept;
  boxes.erase(boxes.begin() + static_cast<std::ptrdiff_t>(kept), boxes.end());
  return dropped;
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

// Row grouping: top-to-bottom rows, left-to-right inside a row. A box joins the row
// of the topmost unplaced box when they overlap vertically by row_overlap of the
// smaller height; inside a row, boxes in the same column are ordered by y.
//
// This is what sort_reading_order() used to do on its own (flatten the rows and you
// have the old result; Params::use_cuts = false still does exactly that).
// sort_reading_order() below starts from it but no longer trusts it when a box spans
// several rows: deciding who shares a row from the overlap with the topmost box
// alone is fragile there (a tall panel next to a stack was ordered right or wrong
// depending on a fraction of a percent of vertical offset, and a 2x2 block beside a
// tall panel was read column by column).
//
// The old comparator (|dy| > 45px ? by y : by x) is not transitive, which is
// undefined behaviour for std::sort and can read out of bounds.
inline std::vector<std::vector<Box>> group_rows(std::vector<Box> boxes, const Params& p) {
  std::vector<std::vector<Box>> rows;
  if (boxes.empty()) return rows;

  std::stable_sort(boxes.begin(), boxes.end(),
                   [](const Box& a, const Box& b) { return a.y < b.y; });

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
    rows.push_back(std::move(row));
  }
  return rows;
}

namespace detail {

// Splits `items` at their first clear gap along one axis: the top-most gap when
// by_y, the left-most otherwise. A gap exists where the next box starts no earlier
// than the furthest edge reached so far, less `tolerance`. Returns false when there
// is none, i.e. some box spans the whole region on that axis.
inline bool split_at_gap(std::vector<Box> items, bool by_y, float tolerance,
                         std::vector<Box>& first, std::vector<Box>& second) {
  std::stable_sort(items.begin(), items.end(), [by_y](const Box& a, const Box& b) {
    return by_y ? a.y < b.y : a.x < b.x;
  });
  float reach = by_y ? items[0].bottom() : items[0].right();
  for (std::size_t k = 1; k < items.size(); ++k) {
    const float start = by_y ? items[k].y : items[k].x;
    if (start >= reach - tolerance) {
      first.assign(items.begin(), items.begin() + static_cast<std::ptrdiff_t>(k));
      second.assign(items.begin() + static_cast<std::ptrdiff_t>(k), items.end());
      return true;
    }
    reach = std::max(reach, by_y ? items[k].bottom() : items[k].right());
  }
  return false;
}

inline bool shares_row(const Box& a, const Box& b, const Params& p) {
  const float min_h = std::min(a.h, b.h);
  const float overlap = std::min(a.bottom(), b.bottom()) - std::max(a.y, b.y);
  return min_h > 0.f && overlap > p.row_overlap * min_h;
}

// The row grouping is trustworthy when it is a real partition into rows: boxes in a
// row all overlap each other vertically, and boxes in different rows never do.
// A box that spans several rows (a tall panel) breaks this, and so does a stack.
inline bool rows_consistent(const std::vector<std::vector<Box>>& rows, const Params& p) {
  for (std::size_t r = 0; r < rows.size(); ++r) {
    for (std::size_t i = 0; i < rows[r].size(); ++i) {
      for (std::size_t j = i + 1; j < rows[r].size(); ++j) {
        if (!shares_row(rows[r][i], rows[r][j], p)) return false;
      }
      for (std::size_t s = r + 1; s < rows.size(); ++s) {
        for (const Box& other : rows[s]) {
          if (shares_row(rows[r][i], other, p)) return false;
        }
      }
    }
  }
  return true;
}

// Each call splits at one cut, so the recursion always shrinks and ends.
inline void order_region(std::vector<Box> items, const Params& p, std::vector<Box>& out) {
  if (items.size() < 2) {
    out.insert(out.end(), items.begin(), items.end());
    return;
  }
  const std::vector<std::vector<Box>> rows = group_rows(items, p);
  if (!p.use_cuts || rows_consistent(rows, p)) {
    for (const std::vector<Box>& row : rows) out.insert(out.end(), row.begin(), row.end());
    return;
  }
  std::vector<Box> first;
  std::vector<Box> second;
  if (split_at_gap(items, /*by_y=*/true, p.cut_tolerance, first, second) ||
      split_at_gap(items, /*by_y=*/false, p.cut_tolerance, first, second)) {
    order_region(std::move(first), p, out);
    order_region(std::move(second), p, out);
    return;
  }
  for (const std::vector<Box>& row : rows) out.insert(out.end(), row.begin(), row.end());  // no clean cut
}

}  // namespace detail

// Reading order, left-to-right and top-to-bottom.
//
// Row grouping (above) is robust on ordinary pages: a stray box between two rows
// just becomes a row of its own. It goes wrong only when a box spans several rows
// (a tall panel beside a stack), and then the answer depends on a fraction of a
// percent of vertical offset. So, for the boxes at hand:
//  1. Group them into rows. If the rows are a real partition (boxes of a row all
//     overlap each other vertically, boxes of different rows never do), use them.
//  2. Otherwise some box spans rows: split the boxes at the first clear horizontal
//     gap (upper part first), or failing that the first clear vertical gap (left part
//     first), and order each part the same way (an XY-cut).
//  3. A region with no clean gap at all (a pinwheel) keeps its row grouping.
// Left-to-right only: there is no right-to-left (manga) mode.
inline void sort_reading_order(std::vector<Box>& boxes, const Params& p) {
  if (boxes.size() < 2) return;
  std::vector<Box> ordered;
  ordered.reserve(boxes.size());
  detail::order_region(boxes, p, ordered);
  boxes.swap(ordered);
}

}  // namespace panelshift
