// Build & run (no OpenCV needed):
//   g++ -std=c++14 -Wall -Wextra -I.. panel_postprocess_test.cpp -o pp_test && ./pp_test
#include <cstdio>
#include <vector>

#include "../panel_postprocess.h"

using panelshift::Box;
using panelshift::Params;

static int g_failed = 0;
#define CHECK(cond, msg)                                              \
  do {                                                                \
    if (!(cond)) {                                                    \
      std::printf("FAIL: %s  (%s:%d)\n", msg, __FILE__, __LINE__);    \
      ++g_failed;                                                     \
    } else {                                                          \
      std::printf("ok:   %s\n", msg);                                 \
    }                                                                 \
  } while (0)

static Box B(float x, float y, float w, float h, float s = 0.9f) { return Box{x, y, w, h, s}; }

static void test_nms() {
  Params p;
  // Two near-identical detections of one panel + one separate panel.
  std::vector<Box> in = {B(0.10f, 0.10f, 0.40f, 0.30f, 0.95f), B(0.11f, 0.11f, 0.40f, 0.30f, 0.80f),
                         B(0.55f, 0.10f, 0.35f, 0.30f, 0.90f)};
  std::vector<Box> out = panelshift::nms(in, p);
  CHECK(out.size() == 2, "nms removes the duplicate, keeps the other panel");
  CHECK(out[0].score > 0.94f, "nms keeps the highest-scoring duplicate");

  // Two heavily overlapping panels (IoU ~0.48): the old 0.45 threshold suppressed one.
  std::vector<Box> touching = {B(0.05f, 0.1f, 0.50f, 0.4f, 0.9f), B(0.226f, 0.1f, 0.50f, 0.4f, 0.85f)};
  float touching_iou = panelshift::iou(touching[0], touching[1]);
  CHECK(touching_iou > 0.45f && touching_iou < 0.50f, "test precondition: IoU is between the old 0.45 and new 0.50");
  CHECK(panelshift::nms(touching, p).size() == 2, "nms at 0.50 keeps both heavily-touching panels");
}

static void test_merge() {
  Params p;
  // Fragments of one panel: top 60% and bottom 60%, overlapping 20%.
  std::vector<Box> frag = {B(0.1f, 0.1f, 0.8f, 0.36f), B(0.1f, 0.30f, 0.8f, 0.36f)};
  std::vector<Box> m = panelshift::merge_fragments(frag, p);
  CHECK(m.size() == 1, "two overlapping fragments of one panel merge");
  CHECK(m[0].y < 0.101f && m[0].bottom() > 0.659f, "merged box spans both fragments");

  // A big panel and a smaller one overlapping at its corner (36% of the smaller
  // box, union bounding box only 80% filled): must NOT be merged. The old rule
  // merged anything overlapping by more than 45% of the smaller box, and its
  // union could swallow neighbours.
  std::vector<Box> el = {B(0.0f, 0.0f, 0.7f, 0.7f), B(0.4f, 0.4f, 0.5f, 0.5f)};
  float inter = panelshift::intersection_area(el[0], el[1]);
  float of_smaller = inter / std::min(el[0].area(), el[1].area());
  CHECK(of_smaller > 0.30f && of_smaller < 0.80f, "test precondition: partial overlap between 0.30 and 0.80");
  CHECK(panelshift::merge_fragments(el, p).size() == 2, "L-shaped neighbours stay separate (low fill ratio)");

  // Adjacent panels sharing a thin border sliver stay separate.
  std::vector<Box> adj = {B(0.05f, 0.1f, 0.44f, 0.8f), B(0.48f, 0.1f, 0.47f, 0.8f)};
  CHECK(panelshift::merge_fragments(adj, p).size() == 2, "panels touching on a thin sliver stay separate");

  // Containment: an inset detection inside a panel is absorbed.
  std::vector<Box> inset = {B(0.1f, 0.1f, 0.8f, 0.8f), B(0.3f, 0.3f, 0.2f, 0.2f)};
  std::vector<Box> mi = panelshift::merge_fragments(inset, p);
  CHECK(mi.size() == 1 && mi[0].w > 0.79f, "contained box is absorbed by its panel");

  // Chain: A+B overlap, and after merging the enlarged box overlaps C.
  // A single greedy pass (old code) would leave C unmerged.
  std::vector<Box> chain = {B(0.1f, 0.10f, 0.8f, 0.30f), B(0.1f, 0.30f, 0.8f, 0.30f), B(0.1f, 0.50f, 0.8f, 0.30f)};
  CHECK(panelshift::merge_fragments(chain, p).size() == 1, "chained fragments merge to a fixed point");

  // Order independence.
  std::vector<Box> rev = {chain[2], chain[1], chain[0]};
  CHECK(panelshift::merge_fragments(rev, p).size() == 1, "result does not depend on detector order");
}

static void test_geometry() {
  Params p;
  p.page_aspect = 1600.0f / 2400.0f;
  std::vector<Box> in = {
      B(0.1f, 0.1f, 0.4f, 0.3f),        // fine
      B(0.1f, 0.5f, 0.005f, 0.3f),      // too narrow
      B(0.1f, 0.5f, 0.3f, 0.002f),      // too flat
      B(0.1f, 0.6f, 0.9f, 0.008f),      // wide strip: allowed by the lower wide min_height?
  };
  std::vector<Box> out = panelshift::filter_geometry(in, p);
  CHECK(!out.empty() && out[0].w > 0.39f, "normal panel survives geometry filter");
  CHECK(out.size() <= 2, "tiny boxes are dropped");
  // Pixel aspect = (w/h)*page_aspect: 0.9/0.008*0.667 = 75 > 8 -> rejected as implausible.
  CHECK(out.size() == 1, "implausibly thin strip is rejected by the aspect limit");
}

static void test_reading_order() {
  Params p;
  // 2x2 grid with jitter, supplied scrambled.
  std::vector<Box> grid = {B(0.52f, 0.52f, 0.43f, 0.43f), B(0.05f, 0.04f, 0.43f, 0.43f),
                           B(0.05f, 0.53f, 0.43f, 0.43f), B(0.52f, 0.06f, 0.43f, 0.43f)};
  panelshift::sort_reading_order(grid, p);
  CHECK(grid[0].x < 0.1f && grid[0].y < 0.1f, "grid: top-left first");
  CHECK(grid[1].x > 0.5f && grid[1].y < 0.1f, "grid: top-right second");
  CHECK(grid[2].x < 0.1f && grid[2].y > 0.5f, "grid: bottom-left third");
  CHECK(grid[3].x > 0.5f && grid[3].y > 0.5f, "grid: bottom-right last");

  // Tall panel on the left, two stacked panels on the right, wide strip below.
  std::vector<Box> mixed = {B(0.05f, 0.65f, 0.90f, 0.30f), B(0.52f, 0.34f, 0.43f, 0.28f),
                            B(0.05f, 0.04f, 0.43f, 0.58f), B(0.52f, 0.04f, 0.43f, 0.28f)};
  panelshift::sort_reading_order(mixed, p);
  CHECK(mixed[0].x < 0.1f && mixed[0].y < 0.1f, "mixed: tall left panel first");
  CHECK(mixed[1].x > 0.5f && mixed[1].y < 0.1f, "mixed: right column top-to-bottom (upper)");
  CHECK(mixed[2].x > 0.5f && mixed[2].y > 0.3f && mixed[2].y < 0.4f, "mixed: right column (lower)");
  CHECK(mixed[3].y > 0.6f, "mixed: wide strip last");

  // Pathological input that made the old non-transitive comparator unsafe.
  std::vector<Box> many;
  for (int i = 0; i < 40; ++i) many.push_back(B(0.01f * static_cast<float>((i * 7) % 40), 0.012f * static_cast<float>((i * 13) % 40), 0.05f, 0.05f));
  panelshift::sort_reading_order(many, p);
  CHECK(many.size() == 40, "reading order is safe on arbitrary input (no crash, nothing lost)");
}

int main() {
  test_nms();
  test_merge();
  test_geometry();
  test_reading_order();
  if (g_failed == 0) {
    std::printf("\nALL TESTS PASSED\n");
    return 0;
  }
  std::printf("\n%d TEST(S) FAILED\n", g_failed);
  return 1;
}
