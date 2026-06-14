cmake_minimum_required(VERSION 3.8)
project(openrd_web_bridge)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(openrd_msgs REQUIRED)

add_executable(openrd_web_bridge_node src/openrd_web_bridge_node.cpp)
target_compile_features(openrd_web_bridge_node PUBLIC cxx_std_17)
ament_target_dependencies(openrd_web_bridge_node rclcpp openrd_msgs)

install(TARGETS openrd_web_bridge_node
  DESTINATION lib/${PROJECT_NAME}
)

ament_package()