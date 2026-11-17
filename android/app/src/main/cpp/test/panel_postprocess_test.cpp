// panel_postprocess_layout_test.cpp
//
// Regression tests for the union-box guard and the reading order in
// panel_postprocess.h. Plain asserts, no framework:
//
//   g++ -std=c++17 -Wall -Wextra panel_postprocess_layout_test.cpp -o layout_test && ./layout_test
//
// (add -I<dir> if panel_postprocess.h is not next to this file)
//
// Every layout is a page of normalised boxes (x, y, w, h, score). The helper runs
// the same stages as panelshift_core.cpp and reports the surviving boxes by the name
// of the input box they match best, in reading order; '*' marks a box that no longer
// matches a single input box because merge_fragments enlarged it.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

#include "../../../../../../../Users/USER/AppData/Local/Temp/panel_postprocess.h"

using namespace panelshift;

namespace {

int g_failures = 0;
#define CHECK_EQ(actual, expected)                                                    \
  do {                                                                                \
    const std::string a_ = (actual);                                                  \
    const std::string e_ = (expected);                                                \
    if (a_ != e_) {                                                                   \
      ++g_failures;                                                                   \
      std::printf("FAIL %s:%d\n   got      \"%s\"\n   expected \"%s\"\n", __FILE__, __LINE__, a_.c_str(), e_.c_str()); \
    }                                                                                 \
  } while (0)

struct Named {
  char name;
  Box box;
};

Box B(float x, float y, float w, float h, float score = 0.9f) { return Box{x, y, w, h, score}; }

std::string describe(const std::vector<Box>& out, const std::vector<Named>& in) {
  std::string s;
  for (const Box& b : out) {
    char best = '?';
    float best_iou = 0.f;
    for (const Named& n : in) {
      const float v = iou(b, Box{n.box.x, n.box.y, n.box.w, n.box.h, 0.f});
      if (v > best_iou) {
        best_iou = v;
        best = n.name;
      }
    }
    if (!s.empty()) s += ' ';
    s += best;
    if (best_iou < 0.7f) s += '*';
  }
  return s;
}

std::vector<Box> boxes_of(const std::vector<Named>& in) {
  std::vector<Box> v;
  for (const Named& n : in) v.push_back(n.box);
  return v;
}

// nms -> filter_geometry -> drop_union_boxes -> merge_fragments -> sort_reading_order
std::string pipeline(const std::vector<Named>& in, bool use_cuts = true, float page_aspect = 0.667f) {
  Params p;
  p.page_aspect = page_aspect;
  p.use_cuts = use_cuts;
  std::vector<Box> k = nms(boxes_of(in), p);
  k = filter_geometry(k, p);
  drop_union_boxes(k, p);
  k = merge_fragments(k, p);
  sort_reading_order(k, p);
  return describe(k, in);
}

// ---------------------------------------------------------------- reading order

void test_tall_left_beside_a_stack() {
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .45f, .94f)},
                     {'B', B(.51f, .03f, .46f, .45f)},
                     {'C', B(.51f, .52f, .46f, .45f)}}),
           "A B C");
}

// Used to come out as "A C B" or "A B C" depending on a fraction of a percent of
// vertical offset between A and B.
void test_tall_right_beside_a_stack_is_stable() {
  for (float by : {0.020f, 0.025f, 0.030f, 0.033f, 0.036f, 0.045f}) {
    CHECK_EQ(pipeline({{'A', B(.03f, .03f, .45f, .45f)},
                       {'C', B(.03f, .52f, .45f, .45f)},
                       {'B', B(.51f, by, .46f, .94f)}}),
             "A C B");
  }
}

// Used to be read column by column: A B D C E.
void test_tall_left_beside_a_2x2_block() {
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .30f, .94f)},
                     {'B', B(.36f, .03f, .30f, .45f)},
                     {'C', B(.69f, .03f, .28f, .45f)},
                     {'D', B(.36f, .52f, .30f, .45f)},
                     {'E', B(.69f, .52f, .28f, .45f)}}),
           "A B C D E");
}

void test_three_columns_with_a_tall_middle() {
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .25f, .45f)},
                     {'B', B(.03f, .52f, .25f, .45f)},
                     {'M', B(.31f, .03f, .30f, .94f)},
                     {'C', B(.64f, .03f, .33f, .29f)},
                     {'D', B(.64f, .35f, .33f, .29f)},
                     {'E', B(.64f, .67f, .33f, .30f)}}),
           "A B M C D E");
}

void test_plain_grids_stay_row_major() {
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .46f, .46f)},
                     {'B', B(.51f, .03f, .46f, .46f)},
                     {'C', B(.03f, .51f, .46f, .46f)},
                     {'D', B(.51f, .51f, .46f, .46f)}}),
           "A B C D");
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .94f, .30f)},
                     {'B', B(.03f, .36f, .46f, .30f)},
                     {'C', B(.51f, .36f, .46f, .30f)},
                     {'D', B(.03f, .69f, .94f, .28f)}}),
           "A B C D");
}

// A box that straddles the gutter between two rows must not make the page read
// column by column (that is what a pure XY-cut does); it just sits between the rows.
void test_gutter_straddler_does_not_break_a_grid() {
  std::vector<Named> in;
  const char* names = "ABCDEFGHIJ";
  for (int r = 0; r < 5; ++r) {
    for (int c = 0; c < 2; ++c) {
      in.push_back({names[r * 2 + c], B(.028f + c * .4955f, .028f + r * .2478f, .4485f, .2008f, .8f)});
    }
  }
  in.push_back({'S', B(.616f, .159f, .158f, .155f, .86f)});
  CHECK_EQ(pipeline(in), "A B S C D E F G H I J");
}

// No clean cut anywhere: the row grouping is kept, whatever it decides.
void test_pinwheel_is_a_permutation_and_matches_row_grouping() {
  const std::vector<Named> in = {{'A', B(.03f, .03f, .58f, .36f)},
                                 {'B', B(.64f, .03f, .33f, .58f)},
                                 {'C', B(.39f, .64f, .58f, .33f)},
                                 {'D', B(.03f, .43f, .33f, .54f)}};
  Params p;
  std::vector<Box> with_cuts = boxes_of(in);
  std::vector<Box> rows_only = boxes_of(in);
  sort_reading_order(with_cuts, p);
  p.use_cuts = false;
  sort_reading_order(rows_only, p);
  CHECK_EQ(describe(with_cuts, in), describe(rows_only, in));
  std::string sorted = describe(with_cuts, in);
  sorted.erase(std::remove(sorted.begin(), sorted.end(), ' '), sorted.end());
  std::sort(sorted.begin(), sorted.end());
  CHECK_EQ(sorted, "ABCD");
}

// use_cuts=false is the previous behaviour, including its sensitivity to offsets.
void test_use_cuts_false_is_the_previous_row_grouping() {
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .45f, .45f)},
                     {'C', B(.03f, .52f, .45f, .45f)},
                     {'B', B(.51f, .036f, .46f, .94f)}},
                    /*use_cuts=*/false),
           "A B C");
}

// ---------------------------------------------------------------- union guard

void test_weak_union_over_two_panels_is_dropped() {
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .46f, .94f, .90f)},
                     {'B', B(.51f, .03f, .46f, .94f, .90f)},
                     {'U', B(.03f, .03f, .94f, .94f, .45f)}}),
           "A B");
}

void test_union_as_confident_as_its_children_is_kept() {
  std::vector<Box> v = {B(.03f, .03f, .46f, .94f, .90f), B(.51f, .03f, .46f, .94f, .90f),
                        B(.03f, .03f, .94f, .94f, .95f)};
  CHECK_EQ(std::to_string(drop_union_boxes(v, Params{})), "0");
  CHECK_EQ(std::to_string(v.size()), "3");
}

void test_panel_with_speech_bubbles_is_kept() {
  // A weak panel box with two confident bubbles inside it: bubbles are small, so they
  // are not "children" and the panel is not mostly made of them.
  std::vector<Box> v = {B(.03f, .03f, .94f, .60f, .50f), B(.10f, .10f, .20f, .10f, .90f),
                        B(.60f, .30f, .20f, .10f, .90f)};
  CHECK_EQ(std::to_string(drop_union_boxes(v, Params{})), "0");
}

void test_weak_box_over_overlapping_fragments_is_kept() {
  // The two boxes inside overlap each other: fragments of ONE panel, not two panels.
  std::vector<Box> v = {B(.03f, .03f, .94f, .45f, .45f), B(.03f, .03f, .55f, .45f, .80f),
                        B(.40f, .03f, .57f, .45f, .80f)};
  CHECK_EQ(std::to_string(drop_union_boxes(v, Params{})), "0");
}

void test_guard_needs_a_union_and_two_children() {
  std::vector<Box> two = {B(.03f, .03f, .46f, .94f, .90f), B(.03f, .03f, .94f, .94f, .45f)};
  CHECK_EQ(std::to_string(drop_union_boxes(two, Params{})), "0");
  std::vector<Box> none;
  CHECK_EQ(std::to_string(drop_union_boxes(none, Params{})), "0");
}

void test_guard_can_be_switched_off() {
  Params p;
  p.union_coverage = 2.0f;
  std::vector<Box> v = {B(.03f, .03f, .46f, .94f, .90f), B(.51f, .03f, .46f, .94f, .90f),
                        B(.03f, .03f, .94f, .94f, .45f)};
  CHECK_EQ(std::to_string(drop_union_boxes(v, p)), "0");
}

// ---------------------------------------------------------------- merge behaviour
// These document what merge_fragments does today; they are not claims that it is ideal.

void test_loose_boxes_of_adjacent_panels_are_not_merged() {
  CHECK_EQ(pipeline({{'A', B(.03f, .03f, .475f, .94f)}, {'B', B(.485f, .03f, .485f, .94f)}}), "A B");
}

void test_fragments_that_overlap_enough_are_merged() {
  const std::string r = pipeline({{'F', B(.03f, .03f, .55f, .45f, .6f)}, {'G', B(.40f, .03f, .57f, .45f, .6f)}});
  CHECK_EQ(std::to_string(std::count(r.begin(), r.end(), ' ') + 1), "1");
}

// A panel split into two pieces that barely overlap, or leave a gap, is NOT rejoined:
// merge_fragments never bridges a gap, which is also what keeps thin gutters safe.
void test_fragments_that_barely_overlap_or_leave_a_gap_are_not_merged() {
  CHECK_EQ(pipeline({{'F', B(.03f, .03f, .50f, .45f, .6f)}, {'G', B(.43f, .03f, .54f, .45f, .6f)}}), "F G");
  CHECK_EQ(pipeline({{'F', B(.03f, .03f, .47f, .45f, .6f)}, {'G', B(.52f, .03f, .45f, .45f, .6f)}}), "F G");
}

}  // namespace

int main() {
  test_tall_left_beside_a_stack();
  test_tall_right_beside_a_stack_is_stable();
  test_tall_left_beside_a_2x2_block();
  test_three_columns_with_a_tall_middle();
  test_plain_grids_stay_row_major();
  test_gutter_straddler_does_not_break_a_grid();
  test_pinwheel_is_a_permutation_and_matches_row_grouping();
  test_use_cuts_false_is_the_previous_row_grouping();
  test_weak_union_over_two_panels_is_dropped();
  test_union_as_confident_as_its_children_is_kept();
  test_panel_with_speech_bubbles_is_kept();
  test_weak_box_over_overlapping_fragments_is_kept();
  test_guard_needs_a_union_and_two_children();
  test_guard_can_be_switched_off();
  test_loose_boxes_of_adjacent_panels_are_not_merged();
  test_fragments_that_overlap_enough_are_merged();
  test_fragments_that_barely_overlap_or_leave_a_gap_are_not_merged();
  if (g_failures == 0) std::printf("all layout tests passed\n");
  return g_failures == 0 ? 0 : 1;
}
