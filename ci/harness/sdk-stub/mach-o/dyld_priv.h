// Stub for <mach-o/dyld_priv.h>, which Xcode 27's macOS SDK no longer ships.
// ld64's bundled libunwind only needs dyld_unwind_sections and the private unwind lookup; the linker never calls
// into dyld at run time, so declarations are enough.
#pragma once
#include <mach-o/loader.h>
#include <stdint.h>

struct dyld_unwind_sections {
  const struct mach_header* mh;
  const void* dwarf_section;
  uintptr_t dwarf_section_size;
  const void* compact_unwind_section;
  uintptr_t compact_unwind_section_size;
  const void* eh_frame_section;
  uintptr_t eh_frame_section_size;
};

#ifdef __cplusplus
extern "C" {
#endif
static inline bool _dyld_find_unwind_sections(void* addr, struct dyld_unwind_sections* info) { (void)addr; (void)info; return false; }
#ifdef __cplusplus
}
#endif
