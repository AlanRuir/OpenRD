#include <chrono>
#include <memory>
#include <string>

#include "openrd_msgs/msg/vehicle_state.hpp"
#include "rclcpp/rclcpp.hpp"

using namespace std::chrono_literals;

namespace openrd_web_bridge
{

// WebSocket 到 ROS2 的桥接节点。
//
// 这个节点是 Flutter/浏览器进入车端 ROS2 graph 的边界。当前文件先保留为骨架：
// 已经读取 WebSocket 参数并订阅 vehicle_state，后续会在这里接入真实 WebSocket server，
// 将 JSON drive 消息发布为 /openrd/drive_cmd。
class OpenRdWebBridgeNode final : public rclcpp::Node
{
public:
  OpenRdWebBridgeNode() : Node("openrd_web_bridge_node")
  {
    listen_host_ = declare_parameter<std::string>("listen_host", "0.0.0.0");
    listen_port_ = declare_parameter<int>("listen_port", 8080);
    control_path_ = declare_parameter<std::string>("control_path", "/control");
    client_timeout_ms_ = declare_parameter<int>("client_timeout_ms", 300);

    // 先订阅车端状态，后续 WebSocket 实现后会把这些状态转成 JSON 推给前端。
    vehicle_state_subscription_ = create_subscription<openrd_msgs::msg::VehicleState>(
      "vehicle_state",
      rclcpp::QoS(1),
      [this](const openrd_msgs::msg::VehicleState::SharedPtr message) {
        last_state_ = *message;
        has_state_ = true;
      });

    timer_ = create_wall_timer(2s, [this]() { on_timer(); });

    RCLCPP_INFO(
      get_logger(),
      "OpenRD web bridge skeleton started at ws://%s:%d%s, client_timeout=%d ms",
      listen_host_.c_str(),
      listen_port_,
      control_path_.c_str(),
      client_timeout_ms_);
    RCLCPP_WARN(get_logger(), "WebSocket server is not implemented yet; this node is a ROS2 skeleton placeholder.");
  }

private:
  // 临时把 vehicle_state 打到日志，便于没有前端时确认 ROS2 链路已经工作。
  void on_timer()
  {
    if (!has_state_) {
      RCLCPP_INFO(get_logger(), "Waiting for vehicle_state messages...");
      return;
    }

    RCLCPP_INFO(
      get_logger(),
      "vehicle_state: state=%s, last_drive_seq=%u, estop=%s, message=%s",
      last_state_.state.c_str(),
      last_state_.last_drive_seq,
      last_state_.estop ? "true" : "false",
      last_state_.message.c_str());
  }

  std::string listen_host_;
  int listen_port_{8080};
  std::string control_path_;
  int client_timeout_ms_{300};

  bool has_state_{false};
  openrd_msgs::msg::VehicleState last_state_;

  rclcpp::Subscription<openrd_msgs::msg::VehicleState>::SharedPtr vehicle_state_subscription_;
  rclcpp::TimerBase::SharedPtr timer_;
};

}  // namespace openrd_web_bridge

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<openrd_web_bridge::OpenRdWebBridgeNode>());
  rclcpp::shutdown();
  return 0;
}