// Windows only. The prebuilt webgpu_dawn.lib was compiled against an MSVC STL
// newer than the one installed here, and references the unsigned variants of
// the STL's vectorized min/max_element helpers (__std_min_element_8u etc.)
// that older msvcprt.lib doesn't export. They're one-liners, so define them
// rather than requiring a toolset upgrade. Semantics match std::min_element /
// std::max_element: first occurrence wins, `first` is returned for an empty
// range. Delete this file once the installed msvcprt.lib provides them (the
// link will then fail with duplicate symbols).
#include <stdint.h>

#define MIN_ELEMENT(name, T)                                                   \
  const void *name(const void *first, const void *last) {                      \
    const T *p = (const T *)first, *end = (const T *)last, *best = p;          \
    for (; p != end; ++p)                                                      \
      if (*p < *best)                                                          \
        best = p;                                                              \
    return best;                                                               \
  }

#define MAX_ELEMENT(name, T)                                                   \
  const void *name(const void *first, const void *last) {                      \
    const T *p = (const T *)first, *end = (const T *)last, *best = p;          \
    for (; p != end; ++p)                                                      \
      if (*p > *best)                                                          \
        best = p;                                                              \
    return best;                                                               \
  }

MIN_ELEMENT(__std_min_element_4u, uint32_t)
MIN_ELEMENT(__std_min_element_8u, uint64_t)
MAX_ELEMENT(__std_max_element_4u, uint32_t)
