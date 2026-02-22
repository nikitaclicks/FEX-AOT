add_executable(FEXStaticCodeMapGen Main.cpp)

target_link_libraries(FEXStaticCodeMapGen PRIVATE
  Common
  CommonTools
  cpp-optparse
  FEXCore
  JemallocLibs
  ${PTHREAD_LIB}
  fmt::fmt)

LinkerGC(FEXStaticCodeMapGen)

install(TARGETS FEXStaticCodeMapGen RUNTIME
  DESTINATION bin
  COMPONENT Runtime)
