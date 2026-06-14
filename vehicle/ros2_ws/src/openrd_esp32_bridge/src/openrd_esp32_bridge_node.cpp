#include <algorithm>
#include <chrono>
#include <cmath>
#include <memory>
#include <sstream>
#include <string>

#include "openrd_msgs/msg/drive_command.hpp"
#include "openrd_msgs/msg/esp32_state.hpp"
#include "rclcpp/rclcpp.hpp"

using namespace std::chrono_literals;

namespace openrd_esp32_bridge
{

// ROS2 与 ESP32 UART 的桥接节点。
//
// 该节点只订阅经过 safety node 处理后的 safe_drive_cmd，负责把 ROS2 消息转换为
// ESP32 固件能理解的文本行协议。当前默认 dry_run=true，不真正打开串口，适合早期
// 在没有 RK3588/ESP32 的环境中先验证 ROS2 graph。
class OpenRdEsp32BridgeNode final : public rclcpp::Node
{
public:
  OpenRdEsp32BridgeNode() : Node("openrd_esp32_bridge_node")
  {
    port_ = declare_parameter<std::string>("port", "/dev/ttyS0");
    baudrate_ = declare_parameter<int>("baudrate", 115200);
    dry_run_ = declare_parameter<bool>("dry_run", true);
    esp32_timeout_ms_ = declare_parameter<int>("esp32_timeout_ms", 500);
    publish_hz_ = declare_parameter<double>("publish_hz", 20.0);

    // 只接受 safety node 的输出，避免原始控制命令绕过安全层直达电机。
    safe_drive_subscription_ = create_subscription<openrd_msgs::msg::DriveCommand>(
      "safe_drive_cmd",
      rclcpp::QoS(1),
      [this](const openrd_msgs::msg::DriveCommand::SharedPtr message) {
        on_safe_drive_command(*message);
      });

    // 当前 dry-run 状态下由节点模拟 ESP32 状态；接入真实串口后改为解析 ESP32 的 S 行。
    esp32_state_publisher_ = create_publisher<openrd_msgs::msg::Esp32State>("esp32_state", rclcpp::QoS(1));

    const auto period_ms = std::max(10, static_cast<int>(1000.0 / std::max(1.0, publish_hz_)));
    timer_ = create_wall_timer(std::chrono::milliseconds(period_ms), [this]() { on_timer(); });

    RCLCPP_INFO(
      get_logger(),
      "OpenRD ESP32 bridge started: port=%s, baudrate=%d, dry_run=%s",
      port_.c_str(),
      baudrate_,
      dry_run_ ? "true" : "false");
  }

private:
  // 收到安全控制命令后，转换为 UART 文本行。真实串口写入会在后续实现。
  void on_safe_drive_command(const openrd_msgs::msg::DriveCommand & command)
  {
    last_command_ = command;
    last_command_time_ = now();
    has_command_ = true;

    last_uart_line_ = format_drive_line(command);

    if (dry_run_) {
      RCLCPP_DEBUG(get_logger(), "UART dry-run: %s", last_uart_line_.c_str());
      return;
    }

    // TODO: 打开配置的串口，并将 last_uart_line_ 写入 ESP32。
  }

  // 定时发布 ESP32 状态。dry-run 模式下模拟状态，真实模式下后续改为串口读取结果。
  void on_timer()
  {
    const auto current_time = now();
    publish_dry_run_state(current_time);

    if (dry_run_ && !last_uart_line_.empty()) {
      RCLCPP_INFO_THROTTLE(
        get_logger(),
        *get_clock(),
        2000,
        "UART dry-run last line: %s",
        last_uart_line_.c_str());
    }
  }

  // UART D 命令格式：D,<seq>,<throttle_i>,<steering_i>,<brake_i>,<flags>\n
  std::string format_drive_line(const openrd_msgs::msg::DriveCommand & command) const
  {
    const int throttle = scale_signed(command.throttle);
    const int steering = scale_signed(command.steering);
    const int brake = scale_unsigned(command.brake);
    const int flags = (command.enable ? 1 : 0) | (command.estop ? 2 : 0);

    std::ostringstream stream;
    stream << "D," << command.seq << "," << throttle << "," << steering << "," << brake << "," << flags << "\n";
    return stream.str();
  }

  int scale_signed(float value) const
  {
    const auto clamped = std::clamp(value, -1.0F, 1.0F);
    return static_cast<int>(std::lround(clamped * 1000.0F));
  }

  int scale_unsigned(float value) const
  {
    const auto clamped = std::clamp(value, 0.0F, 1.0F);
    return static_cast<int>(std::lround(clamped * 1000.0F));
  }

  bool is_timed_out(const rclcpp::Time & current_time) const
  {
    if (!has_command_) {
      return true;
    }

    const auto elapsed = current_time - last_command_time_;
    const auto timeout = rclcpp::Duration::from_nanoseconds(static_cast<int64_t>(esp32_timeout_ms_) * 1000000LL);
    return elapsed > timeout;
  }

  // dry-run 模拟状态用于前期联调：可以看到 safety 输出最终会变成什么左右轮输出。
  void publish_dry_run_state(const rclcpp::Time & current_time)
  {
    openrd_msgs::msg::Esp32State state;
    state.seq = state_seq_++;
    state.stamp = current_time;
    state.last_drive_seq = has_command_ ? last_command_.seq : 0;
    state.faults = 0;
    state.battery_mv = 0;

    if (is_timed_out(current_time)) {
      state.state = "TIMEOUT";
      state.left_output = 0.0F;
      state.right_output = 0.0F;
    } else if (last_command_.estop) {
      state.state = "ESTOP";
      state.left_output = 0.0F;
      state.right_output = 0.0F;
    } else if (!last_command_.enable || last_command_.brake >= 0.5F) {
      state.state = "STOP";
      state.left_output = 0.0F;
      state.right_output = 0.0F;
    } else {
      state.state = "DRIVE";
      state.left_output = std::clamp(last_command_.throttle + last_command_.steering, -1.0F, 1.0F);
      state.right_output = std::clamp(last_command_.throttle - last_command_.steering, -1.0F, 1.0F);
    }

    esp32_state_publisher_->publish(state);
  }

  std::string port_;
  int baudrate_{115200};
  bool dry_run_{true};
  int esp32_timeout_ms_{500};
  double publish_hz_{20.0};

  bool has_command_{false};
  uint32_t state_seq_{0};
  rclcpp::Time last_command_time_{0, 0, RCL_ROS_TIME};
  openrd_msgs::msg::DriveCommand last_command_;
  std::string last_uart_line_;

  rclcpp::Subscription<openrd_msgs::msg::DriveCommand>::SharedPtr safe_drive_subscription_;
  rclcpp::Publisher<openrd_msgs::msg::Esp32State>::SharedPtr esp32_state_publisher_;
  rclcpp::TimerBase::SharedPtr timer_;
};

}  // namespace openrd_esp32_bridge

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<openrd_esp32_bridge::OpenRdEsp32BridgeNode>());
  rclcpp::shutdown();
  return 0;
}