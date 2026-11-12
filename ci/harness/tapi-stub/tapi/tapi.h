// Minimal libtapi surface for building ld64 without Apple's libtapi.
// Xcode 27 ships neither the tapi tool nor its headers. The kernel link never loads a .tbd, so the text-stub
// parser is compiled out and these inline stubs only satisfy the remaining declarations in Options.cpp.
#pragma once
#include <cstdint>
#include <string>

#define TAPI_API_VERSION_MAJOR 1
#define TAPI_API_VERSION_MINOR 3

namespace tapi {

enum class Platform { Unknown, OSX, iOS, watchOS, tvOS, bridgeOS, iOSMac, DriverKit, zippered };

enum class ParsingFlags : unsigned {
  None = 0,
  ExactCpuSubType = 1,
  DisallowWeakImports = 2,
};
inline ParsingFlags operator|(ParsingFlags a, ParsingFlags b) {
  return static_cast<ParsingFlags>(static_cast<unsigned>(a) | static_cast<unsigned>(b));
}
inline ParsingFlags& operator|=(ParsingFlags& a, ParsingFlags b) { a = a | b; return a; }

class PackedVersion32 {
 public:
  explicit PackedVersion32(uint32_t v = 0) : _v(v) {}
  bool operator==(const PackedVersion32& o) const { return _v == o._v; }
  bool operator!=(const PackedVersion32& o) const { return _v != o._v; }
  bool operator<(const PackedVersion32& o) const { return _v < o._v; }
  uint32_t _v;
};

class APIVersion {
 public:
  static bool isAtLeast(int, int) { return true; }
  static int getMajor() { return TAPI_API_VERSION_MAJOR; }
  static int getMinor() { return TAPI_API_VERSION_MINOR; }
};

class Version {
 public:
  static std::string getFullVersionAsString() { return "tapi stub"; }
  static std::string getAsString() { return "tapi stub"; }
};

class LinkerInterfaceFile {
 public:
  static bool shouldPreferTextBasedStubFile(const std::string&) { return false; }
  static bool areEquivalent(const std::string&, const std::string&) { return false; }
  LinkerInterfaceFile* getInlinedFramework(...) { return nullptr; }
  uint32_t getCurrentVersion() const { return 0; }
  std::string getInstallName() const { return std::string(); }
};

}  // namespace tapi
