add_executable(TypeDuckCandidateInfo_test
  TypeDuckCandidateInfo_test.cpp
  "${PROJECT_SOURCE_DIR}/MoqiTextService/TypeDuckCandidateInfo.cpp"
)

target_include_directories(TypeDuckCandidateInfo_test PRIVATE
  "${PROJECT_SOURCE_DIR}"
  "${PROJECT_SOURCE_DIR}/MoqiTextService"
)

target_link_libraries(TypeDuckCandidateInfo_test
  gtest_main
  gmock_main
)

add_test(NAME TypeDuckCandidateInfo_test COMMAND TypeDuckCandidateInfo_test)

add_executable(CandidatePlacement_test CandidatePlacement_test.cpp)
target_include_directories(CandidatePlacement_test PRIVATE "${PROJECT_SOURCE_DIR}")
target_compile_features(CandidatePlacement_test PRIVATE cxx_std_17)
add_test(NAME CandidatePlacement_test COMMAND CandidatePlacement_test)
