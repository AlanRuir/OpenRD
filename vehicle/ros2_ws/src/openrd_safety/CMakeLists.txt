cmake_minimum_required(VERSION 3.8)
project(openrd_safety)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(openrd_msgs REQUIRED)
find_package(std_srvs REQUIRED)

add_executable(openrd_safety_node src/openrd_safety_node.cpp)
target_compile_features(openrd_safety_node PUBLIC cxx_std_17)
ament_target_dependencies(openrd_safety_node rclcpp openrd_msgs std_srvs)

install(TARGETS openrd_safety_node
  DESTINATION lib/${PROJECT_NAME}
)

ament_package()