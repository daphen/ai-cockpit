# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "Release")
  file(REMOVE_RECURSE
  "CMakeFiles/heidr-term-spike_autogen.dir/AutogenUsed.txt"
  "CMakeFiles/heidr-term-spike_autogen.dir/ParseCache.txt"
  "CMakeFiles/heidr_term_autogen.dir/AutogenUsed.txt"
  "CMakeFiles/heidr_term_autogen.dir/ParseCache.txt"
  "CMakeFiles/heidr_termplugin_autogen.dir/AutogenUsed.txt"
  "CMakeFiles/heidr_termplugin_autogen.dir/ParseCache.txt"
  "heidr-term-spike_autogen"
  "heidr_term_autogen"
  "heidr_termplugin_autogen"
  )
endif()
