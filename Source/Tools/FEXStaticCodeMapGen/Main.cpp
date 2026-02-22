// SPDX-License-Identifier: MIT
#include <FEXCore/Core/CodeCache.h>
#include <FEXCore/HLE/SourcecodeResolver.h>
#include <FEXCore/Utils/MathUtils.h>
#include <FEXCore/Utils/TypeDefines.h>

#include <FEXCore/fextl/string.h>

#include <Linux/Utils/ELFParser.h>

#include <OptionParser.h>

#include <fmt/format.h>
#include <xxhash.h>

#include <filesystem>
#include <vector>

#include <fcntl.h>

namespace {
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

bool EmitSeedCodeMap(const std::filesystem::path& BinaryPath, const std::filesystem::path& OutDir) {
  ELFParser Parser;
  if (!Parser.ReadElf(fextl::string {BinaryPath.string()})) {
    return false;
  }

  if (Parser.type != ELFLoader::ELFContainer::TYPE_X86_32 && Parser.type != ELFLoader::ELFContainer::TYPE_X86_64) {
    return false;
  }

  const auto CanonicalPath = std::filesystem::canonical(BinaryPath).string();
  const fextl::string CanonicalPathFEX {CanonicalPath};
  FEXCore::ExecutableFileInfo FileInfo {
    .SourcecodeMap = nullptr,
    .FileId = ComputePathFileId(CanonicalPathFEX),
    .Filename = CanonicalPathFEX,
  };

  const auto ImageBase = ComputeImageBase(Parser);
  const auto EntryPoint = static_cast<uint64_t>(Parser.ehdr.e_entry);
  if (EntryPoint < ImageBase) {
    fmt::print("Skipping {}: invalid entrypoint {:#x} below image base {:#x}\n", CanonicalPath, EntryPoint, ImageBase);
    return false;
  }

  const auto CodeMapBaseName = FEXCore::CodeMap::GetBaseFilename(FileInfo, false);
  const auto CodeMapPath = OutDir / CodeMapBaseName;

  FileCodeMapOpener Opener {CodeMapPath};
  {
    FEXCore::CodeMapWriter Writer {Opener, true};
    Writer.AppendSetMainExecutable(FileInfo);

    FEXCore::ExecutableFileSectionInfo SectionInfo {
      .FileInfo = FileInfo,
      .FileStartVA = static_cast<uintptr_t>(ImageBase),
      .BeginVA = static_cast<uintptr_t>(ImageBase),
      .EndVA = static_cast<uintptr_t>(ImageBase + FEXCore::Utils::FEX_PAGE_SIZE),
    };
    Writer.AppendBlock(SectionInfo, EntryPoint);
  }

  fmt::print("Generated {} (entry={:#x}, base={:#x})\n", CodeMapPath.string(), EntryPoint, ImageBase);
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
} // namespace

int main(int argc, const char** argv) {
  optparse::OptionParser Parser {};
  Parser.add_option("--input-dir").help("Input directory to scan recursively for ELF binaries");
  Parser.add_option("--outdir").set_default(".").help("Output directory for generated codemap files");

  optparse::Values Options = Parser.parse_args(argc, argv);
  if (Parser.args().size() != 0) {
    Parser.print_usage();
    return 1;
  }

  const std::filesystem::path InputDir {fextl::string(Options.get("input_dir"))};
  const std::filesystem::path OutDir {fextl::string(Options.get("outdir"))};
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
  size_t Generated = 0;
  for (const auto& Candidate : Candidates) {
    Generated += EmitSeedCodeMap(Candidate, OutDir) ? 1 : 0;
  }

  fmt::print("Done. Generated {} codemap files from {} candidates.\n", Generated, Candidates.size());
  return Generated == 0 ? 1 : 0;
}
