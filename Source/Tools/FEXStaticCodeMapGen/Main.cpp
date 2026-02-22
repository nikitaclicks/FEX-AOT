// SPDX-License-Identifier: MIT
#include <FEXCore/Core/CodeCache.h>
#include <FEXCore/HLE/SourcecodeResolver.h>
#include <FEXCore/Utils/MathUtils.h>
#include <FEXCore/Utils/TypeDefines.h>

#include <FEXCore/fextl/string.h>
#include <FEXCore/fextl/vector.h>

#include <Linux/Utils/ELFParser.h>

#include <OptionParser.h>

#include <fmt/format.h>
#include <xxhash.h>

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <optional>
#include <queue>
#include <set>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
enum class BinaryClass {
  ELF32,
  ELF64,
};

struct DynamicMetadata {
  fextl::vector<fextl::string> Needed;
  fextl::vector<fextl::string> RPath;
  fextl::vector<fextl::string> RunPath;
};

struct BinaryRecord {
  std::filesystem::path Path;
  BinaryClass Class;
  uint64_t FileId;
  uint64_t ImageBase;
  std::set<uint64_t> SeedAddresses;
  DynamicMetadata Dynamic;
};

struct GraphState {
  std::unordered_map<std::string, BinaryRecord> Records;
  std::unordered_map<std::string, std::vector<std::string>> DirectDependencies;
  std::unordered_set<std::string> FailedRecords;
  size_t UnresolvedDependencies {};
};

struct ResolveConfig {
  std::optional<std::filesystem::path> RootFS;
  std::vector<std::filesystem::path> ExtraSearchPaths;
};

class FileCodeMapOpener final : public FEXCore::CodeMapOpener {
public:
  explicit FileCodeMapOpener(std::filesystem::path Path)
    : PathName(std::move(Path)) {}

  int OpenCodeMapFile() override {
    return open(PathName.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0644);
  }

private:
  const std::filesystem::path PathName;
};

uint64_t ComputePathFileId(std::string_view Filename) {
  if (Filename.empty()) {
    return 0xffff'ffff'ffff'ffffULL;
  }
  return XXH3_64bits(Filename.data(), Filename.size());
}

std::optional<uint64_t> ComputeContentHashFromFD(int FD) {
  if (FD == -1) {
    return std::nullopt;
  }

  struct stat Stat {};
  if (fstat(FD, &Stat) != 0 || !S_ISREG(Stat.st_mode) || Stat.st_size <= 0) {
    return std::nullopt;
  }

  XXH3_state_t* State = XXH3_createState();
  if (State == nullptr) {
    return std::nullopt;
  }

  XXH3_64bits_reset(State);

  std::array<char, 1 << 20> Buffer;
  off_t Offset = 0;
  while (Offset < Stat.st_size) {
    const auto Remaining = static_cast<size_t>(Stat.st_size - Offset);
    const auto ToRead = std::min(Remaining, Buffer.size());
    const auto Read = pread(FD, Buffer.data(), ToRead, Offset);
    if (Read <= 0) {
      XXH3_freeState(State);
      return std::nullopt;
    }

    XXH3_64bits_update(State, Buffer.data(), Read);
    Offset += Read;
  }

  const auto Hash = XXH3_64bits_digest(State);
  XXH3_freeState(State);
  return Hash;
}

std::vector<fextl::string> SplitColonList(const char* Value) {
  std::vector<fextl::string> Entries;
  if (!Value || Value[0] == '\0') {
    return Entries;
  }

  const char* Begin = Value;
  const char* End = Value;
  while (*End != '\0') {
    if (*End == ':') {
      if (End != Begin) {
        Entries.emplace_back(Begin, End - Begin);
      }
      Begin = End + 1;
    }
    ++End;
  }

  if (End != Begin) {
    Entries.emplace_back(Begin, End - Begin);
  }
  return Entries;
}

std::vector<fextl::string> SplitColonList(const fextl::string& Value) {
  return SplitColonList(Value.c_str());
}

BinaryClass GetBinaryClass(const ELFParser& Parser) {
  return Parser.type == ELFLoader::ELFContainer::TYPE_X86_64 ? BinaryClass::ELF64 : BinaryClass::ELF32;
}

const char* GetLibToken(BinaryClass Class) {
  return Class == BinaryClass::ELF64 ? "lib64" : "lib";
}

fextl::string ReplaceAllCopy(fextl::string Value, std::string_view From, std::string_view To) {
  if (From.empty()) {
    return Value;
  }

  size_t Position = 0;
  while ((Position = Value.find(From, Position)) != fextl::string::npos) {
    Value.replace(Position, From.size(), To);
    Position += To.size();
  }
  return Value;
}

fextl::string ExpandPathTokens(fextl::string Entry, const std::filesystem::path& Origin, BinaryClass Class) {
  const fextl::string OriginString {Origin.string().c_str()};
  const fextl::string LibString = GetLibToken(Class);

  Entry = ReplaceAllCopy(std::move(Entry), "$ORIGIN", OriginString);
  Entry = ReplaceAllCopy(std::move(Entry), "${ORIGIN}", OriginString);
  Entry = ReplaceAllCopy(std::move(Entry), "$LIB", LibString);
  Entry = ReplaceAllCopy(std::move(Entry), "${LIB}", LibString);

  Entry = ReplaceAllCopy(std::move(Entry), "$PLATFORM", "");
  Entry = ReplaceAllCopy(std::move(Entry), "${PLATFORM}", "");
  return Entry;
}

uint64_t ComputeImageBase(const ELFParser& Parser) {
  constexpr uint64_t PageSize = FEXCore::Utils::FEX_PAGE_SIZE;

  uint64_t Base = std::numeric_limits<uint64_t>::max();
  for (const auto& Header : Parser.phdrs) {
    if (Header.p_type != PT_LOAD) {
      continue;
    }

    Base = std::min(Base, FEXCore::AlignDown(Header.p_vaddr, PageSize));
  }

  if (Base == std::numeric_limits<uint64_t>::max()) {
    return 0;
  }

  return Base;
}

std::set<uint64_t> ComputeSeedAddresses(const ELFParser& Parser, uint64_t ImageBase) {
  std::set<uint64_t> Seeds;

  const auto EntryPoint = static_cast<uint64_t>(Parser.ehdr.e_entry);
  if (EntryPoint >= ImageBase && EntryPoint != 0) {
    Seeds.emplace(EntryPoint);
  }

  for (const auto& Header : Parser.phdrs) {
    if (Header.p_type != PT_LOAD || !(Header.p_flags & PF_X)) {
      continue;
    }

    const auto SectionBase = FEXCore::AlignDown(Header.p_vaddr, static_cast<uint64_t>(FEXCore::Utils::FEX_PAGE_SIZE));
    if (SectionBase >= ImageBase) {
      Seeds.emplace(SectionBase);
    }
    if (Header.p_vaddr >= ImageBase) {
      Seeds.emplace(Header.p_vaddr);
    }
  }

  return Seeds;
}

template<typename DynType>
DynamicMetadata ParseDynamicEntriesImpl(const ELFParser& Parser, const Elf64_Phdr& DynamicHeader) {
  DynamicMetadata Metadata;

  const auto EntryCount = DynamicHeader.p_filesz / sizeof(DynType);
  std::vector<DynType> Entries(EntryCount);
  if (pread(Parser.fd, Entries.data(), Entries.size() * sizeof(DynType), DynamicHeader.p_offset) == -1) {
    return Metadata;
  }

  uint64_t StrTabVA {};
  uint64_t StrTabSize {};
  std::vector<uint64_t> NeededOffsets;
  std::optional<uint64_t> RPathOffset;
  std::optional<uint64_t> RunPathOffset;

  for (const auto& Entry : Entries) {
    if (Entry.d_tag == DT_NULL) {
      break;
    }

    switch (Entry.d_tag) {
    case DT_STRTAB:
      StrTabVA = Entry.d_un.d_ptr;
      break;
    case DT_STRSZ:
      StrTabSize = Entry.d_un.d_val;
      break;
    case DT_NEEDED:
      NeededOffsets.emplace_back(Entry.d_un.d_val);
      break;
    case DT_RPATH:
      RPathOffset = Entry.d_un.d_val;
      break;
    case DT_RUNPATH:
      RunPathOffset = Entry.d_un.d_val;
      break;
    default:
      break;
    }
  }

  if (StrTabVA == 0 || StrTabSize == 0) {
    return Metadata;
  }

  const auto StrTabFileOffset = Parser.VAToFile(StrTabVA);
  if (StrTabFileOffset <= 0) {
    return Metadata;
  }

  std::vector<char> StrTab(StrTabSize);
  if (pread(Parser.fd, StrTab.data(), StrTabSize, StrTabFileOffset) == -1) {
    return Metadata;
  }

  auto ResolveString = [&](uint64_t Offset) -> fextl::string {
    if (Offset >= StrTab.size()) {
      return {};
    }

    const char* Str = StrTab.data() + Offset;
    const size_t MaxLen = StrTab.size() - Offset;
    const size_t Len = strnlen(Str, MaxLen);
    return fextl::string(Str, Len);
  };

  for (auto Offset : NeededOffsets) {
    auto Name = ResolveString(Offset);
    if (!Name.empty()) {
      Metadata.Needed.emplace_back(std::move(Name));
    }
  }

  if (RPathOffset.has_value()) {
    auto RPath = ResolveString(RPathOffset.value());
    for (auto& Entry : SplitColonList(RPath)) {
      if (!Entry.empty()) {
        Metadata.RPath.emplace_back(std::move(Entry));
      }
    }
  }

  if (RunPathOffset.has_value()) {
    auto RunPath = ResolveString(RunPathOffset.value());
    for (auto& Entry : SplitColonList(RunPath)) {
      if (!Entry.empty()) {
        Metadata.RunPath.emplace_back(std::move(Entry));
      }
    }
  }

  return Metadata;
}

DynamicMetadata ParseDynamicMetadata(const ELFParser& Parser) {
  for (const auto& Header : Parser.phdrs) {
    if (Header.p_type != PT_DYNAMIC) {
      continue;
    }

    if (Parser.type == ELFLoader::ELFContainer::TYPE_X86_64) {
      return ParseDynamicEntriesImpl<Elf64_Dyn>(Parser, Header);
    }
    return ParseDynamicEntriesImpl<Elf32_Dyn>(Parser, Header);
  }

  return {};
}

bool LoadBinaryRecord(const std::filesystem::path& BinaryPath, BinaryRecord* OutRecord) {
  ELFParser Parser;
  if (!Parser.ReadElf(fextl::string {BinaryPath.string()})) {
    return false;
  }

  if (Parser.type != ELFLoader::ELFContainer::TYPE_X86_32 && Parser.type != ELFLoader::ELFContainer::TYPE_X86_64) {
    return false;
  }

  auto CanonicalPath = std::filesystem::weakly_canonical(BinaryPath);
  if (CanonicalPath.empty()) {
    return false;
  }

  const auto CanonicalString = CanonicalPath.string();
  const fextl::string CanonicalFEX {CanonicalString};

  const auto ImageBase = ComputeImageBase(Parser);
  const auto SeedAddresses = ComputeSeedAddresses(Parser, ImageBase);
  if (SeedAddresses.empty()) {
    return false;
  }

  OutRecord->Path = std::move(CanonicalPath);
  OutRecord->Class = GetBinaryClass(Parser);
  OutRecord->FileId = ComputeContentHashFromFD(Parser.fd).value_or(ComputePathFileId(CanonicalFEX));
  OutRecord->ImageBase = ImageBase;
  OutRecord->SeedAddresses = std::move(SeedAddresses);
  OutRecord->Dynamic = ParseDynamicMetadata(Parser);
  return true;
}

std::filesystem::path ApplyRootFS(const std::filesystem::path& Path, const ResolveConfig& Config) {
  if (!Config.RootFS.has_value() || !Path.is_absolute()) {
    return Path;
  }

  auto Relative = Path.relative_path();
  return Config.RootFS.value() / Relative;
}

void AppendWithRootFSPreference(std::vector<std::filesystem::path>* Paths, const std::filesystem::path& Path, const ResolveConfig& Config) {
  if (Path.empty()) {
    return;
  }

  if (Path.is_absolute() && Config.RootFS.has_value()) {
    Paths->emplace_back(ApplyRootFS(Path, Config));
  }
  Paths->emplace_back(Path);
}

std::vector<std::filesystem::path> BuildDefaultSearchPaths(BinaryClass Class, const ResolveConfig& Config) {
  std::vector<std::filesystem::path> Paths;
  if (Class == BinaryClass::ELF64) {
    Paths.emplace_back("/lib64");
    Paths.emplace_back("/usr/lib64");
    Paths.emplace_back("/lib");
    Paths.emplace_back("/usr/lib");
  } else {
    Paths.emplace_back("/lib");
    Paths.emplace_back("/usr/lib");
    Paths.emplace_back("/lib32");
    Paths.emplace_back("/usr/lib32");
  }

  std::vector<std::filesystem::path> Final;
  Final.reserve(Paths.size() * 2);
  for (auto& Path : Paths) {
    AppendWithRootFSPreference(&Final, Path, Config);
  }
  return Final;
}

std::vector<std::filesystem::path> ExpandSearchEntries(const fextl::vector<fextl::string>& Entries, const std::filesystem::path& Origin,
                                                       BinaryClass Class, const ResolveConfig& Config) {
  std::vector<std::filesystem::path> Paths;
  for (auto Entry : Entries) {
    auto Expanded = ExpandPathTokens(std::move(Entry), Origin, Class);
    if (Expanded.empty()) {
      continue;
    }

    std::filesystem::path Path = Expanded.c_str();
    if (Path.is_relative()) {
      Path = Origin / Path;
    }

    AppendWithRootFSPreference(&Paths, Path, Config);
  }
  return Paths;
}

std::vector<std::filesystem::path> BuildResolverSearchOrder(const BinaryRecord& Record, const ResolveConfig& Config) {
  std::vector<std::filesystem::path> Search;

  for (const auto& Path : Config.ExtraSearchPaths) {
    Search.emplace_back(Path);
  }

  fextl::vector<fextl::string> LDLibraryPath;
  for (auto& Entry : SplitColonList(getenv("LD_LIBRARY_PATH"))) {
    LDLibraryPath.emplace_back(std::move(Entry));
  }

  const auto Origin = Record.Path.parent_path();
  const auto ExpandedLDPath = ExpandSearchEntries(LDLibraryPath, Origin, Record.Class, Config);
  const auto ExpandedRPath = ExpandSearchEntries(Record.Dynamic.RPath, Origin, Record.Class, Config);
  const auto ExpandedRunPath = ExpandSearchEntries(Record.Dynamic.RunPath, Origin, Record.Class, Config);
  const auto DefaultPaths = BuildDefaultSearchPaths(Record.Class, Config);

  if (Record.Dynamic.RunPath.empty()) {
    Search.insert(Search.end(), ExpandedRPath.begin(), ExpandedRPath.end());
    Search.insert(Search.end(), ExpandedLDPath.begin(), ExpandedLDPath.end());
  } else {
    Search.insert(Search.end(), ExpandedLDPath.begin(), ExpandedLDPath.end());
    Search.insert(Search.end(), ExpandedRunPath.begin(), ExpandedRunPath.end());
  }
  Search.insert(Search.end(), DefaultPaths.begin(), DefaultPaths.end());

  std::vector<std::filesystem::path> Unique;
  std::unordered_set<std::string> Seen;
  for (auto& Path : Search) {
    if (Path.empty()) {
      continue;
    }

    auto Key = Path.string();
    if (Seen.insert(Key).second) {
      Unique.emplace_back(std::move(Path));
    }
  }
  return Unique;
}

std::optional<std::filesystem::path> ResolveDependency(const BinaryRecord& Parent, std::string_view Needed, const ResolveConfig& Config) {
  if (Needed.empty()) {
    return std::nullopt;
  }

  std::filesystem::path NeededPath {Needed};
  std::vector<std::filesystem::path> Candidates;
  if (NeededPath.is_absolute()) {
    AppendWithRootFSPreference(&Candidates, NeededPath, Config);
  } else if (Needed.find('/') != std::string_view::npos) {
    AppendWithRootFSPreference(&Candidates, Parent.Path.parent_path() / NeededPath, Config);
  } else {
    const auto SearchPaths = BuildResolverSearchOrder(Parent, Config);
    for (const auto& SearchPath : SearchPaths) {
      Candidates.emplace_back(SearchPath / NeededPath);
    }
  }

  for (const auto& Candidate : Candidates) {
    std::error_code ec;
    if (!std::filesystem::exists(Candidate, ec) || !std::filesystem::is_regular_file(Candidate, ec)) {
      continue;
    }

    auto Canonical = std::filesystem::weakly_canonical(Candidate, ec);
    if (ec) {
      continue;
    }

    ELFParser Parser;
    if (!Parser.ReadElf(fextl::string {Canonical.string()})) {
      continue;
    }

    if (Parser.type != ELFLoader::ELFContainer::TYPE_X86_32 && Parser.type != ELFLoader::ELFContainer::TYPE_X86_64) {
      continue;
    }

    if (GetBinaryClass(Parser) != Parent.Class) {
      continue;
    }

    return Canonical;
  }

  return std::nullopt;
}

bool BuildDependencyGraph(const std::vector<std::filesystem::path>& Roots, const ResolveConfig& Config, GraphState* State) {
  std::queue<std::filesystem::path> Queue;
  std::unordered_set<std::string> Queued;

  for (const auto& Root : Roots) {
    std::error_code ec;
    auto Canonical = std::filesystem::weakly_canonical(Root, ec);
    if (ec) {
      continue;
    }

    auto Key = Canonical.string();
    if (Queued.insert(Key).second) {
      Queue.emplace(std::move(Canonical));
    }
  }

  while (!Queue.empty()) {
    auto Current = Queue.front();
    Queue.pop();

    const auto CurrentKey = Current.string();
    if (State->Records.contains(CurrentKey) || State->FailedRecords.contains(CurrentKey)) {
      continue;
    }

    BinaryRecord Record;
    if (!LoadBinaryRecord(Current, &Record)) {
      State->FailedRecords.emplace(CurrentKey);
      continue;
    }

    auto [It, Inserted] = State->Records.emplace(CurrentKey, std::move(Record));
    auto& Stored = It->second;

    std::vector<std::string> ResolvedDependencies;
    for (const auto& Needed : Stored.Dynamic.Needed) {
      auto Resolved = ResolveDependency(Stored, Needed, Config);
      if (!Resolved.has_value()) {
        ++State->UnresolvedDependencies;
        fmt::print("Unresolved dependency '{}' for {}\n", Needed, Stored.Path.string());
        continue;
      }

      const auto DepKey = Resolved->string();
      ResolvedDependencies.emplace_back(DepKey);
      if (!State->Records.contains(DepKey) && Queued.insert(DepKey).second) {
        Queue.emplace(*Resolved);
      }
    }

    State->DirectDependencies.emplace(CurrentKey, std::move(ResolvedDependencies));
  }

  return !State->Records.empty();
}

bool EmitSeedCodeMap(const BinaryRecord& Record, const std::vector<BinaryRecord>& Dependencies, const std::filesystem::path& OutDir) {
  const fextl::string CanonicalPathFEX {Record.Path.string()};
  FEXCore::ExecutableFileInfo FileInfo {
    .SourcecodeMap = nullptr,
    .FileId = Record.FileId,
    .Filename = CanonicalPathFEX,
  };

  const auto CodeMapBaseName = FEXCore::CodeMap::GetBaseFilename(FileInfo, false);
  const auto CodeMapPath = OutDir / CodeMapBaseName;

  FileCodeMapOpener Opener {CodeMapPath};
  {
    FEXCore::CodeMapWriter Writer {Opener, true};
    Writer.AppendSetMainExecutable(FileInfo);

    for (const auto& Dep : Dependencies) {
      FEXCore::ExecutableFileInfo DepInfo {
        .SourcecodeMap = nullptr,
        .FileId = Dep.FileId,
        .Filename = fextl::string {Dep.Path.string().c_str()},
      };
      Writer.AppendLibraryLoad(DepInfo);
    }

    FEXCore::ExecutableFileSectionInfo SectionInfo {
      .FileInfo = FileInfo,
      .FileStartVA = static_cast<uintptr_t>(Record.ImageBase),
      .BeginVA = static_cast<uintptr_t>(Record.ImageBase),
      .EndVA = static_cast<uintptr_t>(Record.ImageBase + FEXCore::Utils::FEX_PAGE_SIZE),
    };

    for (auto SeedAddress : Record.SeedAddresses) {
      Writer.AppendBlock(SectionInfo, SeedAddress);
    }
  }

  fmt::print("Generated {} (seeds={}, deps={})\n", CodeMapPath.string(), Record.SeedAddresses.size(), Dependencies.size());
  return true;
}

std::vector<std::filesystem::path> GatherCandidates(const std::filesystem::path& InputDir) {
  std::vector<std::filesystem::path> Files;
  for (const auto& Entry : std::filesystem::recursive_directory_iterator(InputDir)) {
    if (!Entry.is_regular_file()) {
      continue;
    }
    Files.emplace_back(Entry.path());
  }
  return Files;
}

std::vector<std::filesystem::path> ParseSearchPaths(const optparse::Values& Options) {
  std::vector<std::filesystem::path> Paths;
  if (!Options.is_set("search_path")) {
    return Paths;
  }

  for (const auto& Entry : Options.all("search_path")) {
    if (Entry.empty()) {
      continue;
    }

    std::filesystem::path Path = Entry;
    if (!Path.is_absolute()) {
      std::error_code ec;
      Path = std::filesystem::weakly_canonical(Path, ec);
      if (ec) {
        continue;
      }
    }
    Paths.emplace_back(std::move(Path));
  }
  return Paths;
}

std::optional<std::filesystem::path> ParseRootFS(const optparse::Values& Options) {
  auto RootFSOpt = Options["rootfs"];
  if (!RootFSOpt.has_value() || RootFSOpt.value() == nullptr) {
    return std::nullopt;
  }

  const fextl::string RootFSValue {*RootFSOpt.value()};
  if (RootFSValue.empty()) {
    return std::nullopt;
  }

  std::error_code ec;
  auto Canonical = std::filesystem::weakly_canonical(std::filesystem::path {RootFSValue.c_str()}, ec);
  if (ec) {
    return std::nullopt;
  }
  return Canonical;
}

fextl::string GetOptionString(const optparse::Values& Options, const char* Key) {
  auto ValueOpt = Options[Key];
  if (!ValueOpt.has_value() || ValueOpt.value() == nullptr) {
    return {};
  }

  return fextl::string {*ValueOpt.value()};
}
} // namespace

int main(int argc, const char** argv) {
  optparse::OptionParser Parser {};
  Parser.add_option("--input-dir").help("Input directory to scan recursively for ELF binaries");
  Parser.add_option("--outdir").set_default(".").help("Output directory for generated codemap files");
  Parser.add_option("--rootfs").set_default("").help("Optional rootfs path used for resolving absolute guest library paths");
  Parser.add_option("--search-path").action("append").help("Additional library search path (can be repeated)");

  optparse::Values Options = Parser.parse_args(argc, argv);
  if (Parser.args().size() != 0) {
    Parser.print_usage();
    return 1;
  }

  const auto InputDirString = GetOptionString(Options, "input_dir");
  const auto OutDirString = GetOptionString(Options, "outdir");

  const std::filesystem::path InputDir {InputDirString.c_str()};
  const std::filesystem::path OutDir {OutDirString.empty() ? "." : OutDirString.c_str()};
  if (InputDir.empty()) {
    fmt::print("--input-dir is required\n");
    return 1;
  }

  std::error_code ec;
  if (!std::filesystem::exists(InputDir, ec) || !std::filesystem::is_directory(InputDir, ec)) {
    fmt::print("Input directory is invalid: {}\n", InputDir.string());
    return 1;
  }

  std::filesystem::create_directories(OutDir, ec);
  if (ec) {
    fmt::print("Failed to create output directory {}: {}\n", OutDir.string(), ec.message());
    return 1;
  }

  auto Candidates = GatherCandidates(InputDir);
  ResolveConfig Config {
    .RootFS = ParseRootFS(Options),
    .ExtraSearchPaths = ParseSearchPaths(Options),
  };

  GraphState State;
  if (!BuildDependencyGraph(Candidates, Config, &State)) {
    fmt::print("No eligible binaries found in {}\n", InputDir.string());
    return 1;
  }

  size_t Generated = 0;
  for (const auto& [Path, Record] : State.Records) {
    std::vector<BinaryRecord> Dependencies;
    if (auto It = State.DirectDependencies.find(Path); It != State.DirectDependencies.end()) {
      Dependencies.reserve(It->second.size());
      for (const auto& DepPath : It->second) {
        auto DepIt = State.Records.find(DepPath);
        if (DepIt != State.Records.end()) {
          Dependencies.emplace_back(DepIt->second);
        }
      }
    }

    Generated += EmitSeedCodeMap(Record, Dependencies, OutDir) ? 1 : 0;
  }

  fmt::print("Done. Generated {} codemap files from {} roots (tracked binaries={}, unresolved_deps={}).\n", Generated, Candidates.size(),
             State.Records.size(), State.UnresolvedDependencies);
  return Generated == 0 ? 1 : 0;
}
