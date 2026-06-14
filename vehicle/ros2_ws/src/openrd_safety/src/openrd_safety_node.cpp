#include <algorithm>
#include <chrono>
#include <cmath>
#include <memory>
#include <string>

#include "openrd_msgs/msg/drive_command.hpp"
#include "openrd_msgs/msg/vehicle_state.hpp"
#include "rclcpp/rclcpp.hpp"
#include "std_srvs/srv/trigger.hpp"

using namespace std::chrono_literals;

namespace openrd_safety
{

// RK3588 侧安全节点。
//
// 这个节点位于 WebSocket bridge 和 ESP32 bridge 中间，只接收上层“驾驶意图”，
// 然后输出经过限幅、死区、超时和急停处理后的安全驾驶命令。
//
// 注意：这里的安全逻辑是车端上层保护，不能替代 ESP32 固件里的独立超时停车。
class OpenRdSafetyNode final : public rclcpp::Node
{
public:
  OpenRdSafetyNode() : Node("openrd_safety_node")
  {
    // 参数全部放到 YAML 中，方便后续在不同底盘、不同测试阶段调整。
    control_timeout_ms_ = declare_parameter<int>("control_timeout_ms", 300);
    publish_hz_ = declare_parameter<double>("publish_hz", 20.0);
    max_output_ = declare_parameter<double>("max_output", 0.4);
    deadzone_ = declare_parameter<double>("deadzone", 0.05);
    require_zero_before_reset_estop_ = declare_parameter<bool>("require_zero_before_reset_estop", true);

    // 原始控制命令来自 openrd_web_bridge_node，后续也可以来自 cmd_vel 转换节点。
    drive_subscription_ = create_subscription<openrd_msgs::msg::DriveCommand>(
      "drive_cmd",
      rclcpp::QoS(1),
      [this](const openrd_msgs::msg::DriveCommand::SharedPtr message) {
        on_drive_command(*message);
      });

    // safe_drive_cmd 是唯一允许发往 ESP32 bridge 的控制 topic。
    safe_drive_publisher_ = create_publisher<openrd_msgs::msg::DriveCommand>("safe_drive_cmd", rclcpp::QoS(1));
    state_publisher_ = create_publisher<openrd_msgs::msg::VehicleState>("vehicle_state", rclcpp::QoS(1));

    // 急停复位使用 service，方便调用方获得明确的成功/失败反馈。
    reset_estop_service_ = create_service<std_srvs::srv::Trigger>(
      "reset_estop",
      [this](
        const std::shared_ptr<std_srvs::srv::Trigger::Request> request,
        std::shared_ptr<std_srvs::srv::Trigger::Response> response) {
        on_reset_estop(request, response);
      });

    const auto period_ms = std::max(10, static_cast<int>(1000.0 / std::max(1.0, publish_hz_)));
    timer_ = create_wall_timer(std::chrono::milliseconds(period_ms), [this]() { on_timer(); });

    RCLCPP_INFO(
      get_logger(),
      "OpenRD safety node started: timeout=%d ms, max_output=%.2f, deadzone=%.2f",
      control_timeout_ms_,
      max_output_,
      deadzone_);
  }

private:
  // 接收新的驾驶命令，只记录输入和急停意图；真正的安全处理统一在定时器中执行。
  void on_drive_command(const openrd_msgs::msg::DriveCommand & command)
  {
    last_command_ = command;
    last_command_time_ = now();
    has_command_ = true;

    if (command.estop) {
      estop_latched_ = true;
    }
  }

  // 急停复位必须满足输入归零，避免用户仍在推杆时复位后车辆立刻运动。
  void on_reset_estop(
    const std::shared_ptr<std_srvs::srv::Trigger::Request> request,
    std::shared_ptr<std_srvs::srv::Trigger::Response> response)
  {
    (void)request;

    if (require_zero_before_reset_estop_ && !last_input_is_neutral()) {
      response->success = false;
      response->message = "refuse to reset estop: input is not neutral";
      return;
    }

    estop_latched_ = false;
    response->success = true;
    response->message = "estop reset";
  }

  // 固定频率输出 safe_drive_cmd，保证 ESP32 bridge 能持续收到最新安全命令。
  void on_timer()
  {
    const auto current_time = now();
    const bool timed_out = is_timed_out(current_time);

    auto safe_command = make_stop_command(current_time, timed_out ? "timeout" : "safety");
    std::string state = "idle";
    std::string message = "waiting for drive command";
    bool failsafe = false;

    if (timed_out) {
      state = "timeout";
      message = "control command timeout";
      failsafe = true;
    } else if (estop_latched_) {
      state = "estop";
      message = "estop latched";
      safe_command.estop = true;
      safe_command.enable = false;
      safe_command.brake = 1.0F;
      failsafe = true;
    } else {
      safe_command = apply_safety(last_command_, current_time);
      state = is_stop_command(safe_command) ? "idle" : "drive";
      message = "ok";
    }

    safe_drive_publisher_->publish(safe_command);
    publish_vehicle_state(current_time, safe_command, state, message, failsafe);
  }

  // 判断上层控制命令是否超时。超时后立即输出停车命令。
  bool is_timed_out(const rclcpp::Time & current_time) const
  {
    if (!has_command_) {
      return true;
    }

    const auto elapsed = current_time - last_command_time_;
    const auto timeout = rclcpp::Duration::from_nanoseconds(static_cast<int64_t>(control_timeout_ms_) * 1000000LL);
    return elapsed > timeout;
  }

  // 判断最近一次输入是否处于中位，用于急停复位前的保护。
  bool last_input_is_neutral() const
  {
    if (!has_command_) {
      return true;
    }

    return std::abs(last_command_.throttle) <= static_cast<float>(deadzone_) &&
           std::abs(last_command_.steering) <= static_cast<float>(deadzone_);
  }

  // 构造统一的停车命令，避免各分支手写停车字段导致行为不一致。
  openrd_msgs::msg::DriveCommand make_stop_command(const rclcpp::Time & current_time, const std::string & source) const
  {
    openrd_msgs::msg::DriveCommand command;
    command.seq = has_command_ ? last_command_.seq : 0;
    command.stamp = current_time;
    command.throttle = 0.0F;
    command.steering = 0.0F;
    command.brake = 1.0F;
    command.enable = false;
    command.estop = estop_latched_;
    command.source = source;
    return command;
  }

  // 对原始控制命令做限幅、死区、刹车处理，输出可发给下位机的安全命令。
  openrd_msgs::msg::DriveCommand apply_safety(
    const openrd_msgs::msg::DriveCommand & input,
    const rclcpp::Time & current_time) const
  {
    auto output = input;
    output.stamp = current_time;
    output.source = "safety";

    output.throttle = clamp_with_deadzone(output.throttle, -max_output_, max_output_);
    output.steering = clamp_with_deadzone(output.steering, -max_output_, max_output_);
    output.brake = static_cast<float>(std::clamp(static_cast<double>(output.brake), 0.0, 1.0));

    if (!output.enable || output.brake >= 0.5F) {
      output.throttle = 0.0F;
      output.steering = 0.0F;
      output.brake = 1.0F;
      output.enable = output.enable && !output.estop;
    }

    return output;
  }

  float clamp_with_deadzone(float value, double min_value, double max_value) const
  {
    if (std::abs(value) < deadzone_) {
      return 0.0F;
    }

    return static_cast<float>(std::clamp(static_cast<double>(value), min_value, max_value));
  }

  bool is_stop_command(const openrd_msgs::msg::DriveCommand & command) const
  {
    return std::abs(command.throttle) <= static_cast<float>(deadzone_) &&
           std::abs(command.steering) <= static_cast<float>(deadzone_);
  }

  // 发布给 Web bridge/UI 的汇总状态，便于前端直接显示安全状态。
  void publish_vehicle_state(
    const rclcpp::Time & current_time,
    const openrd_msgs::msg::DriveCommand & command,
    const std::string & state_name,
    const std::string & message,
    bool failsafe)
  {
    openrd_msgs::msg::VehicleState state;
    state.seq = state_seq_++;
    state.stamp = current_time;
    state.state = state_name;
    state.ws_connected = has_command_ && !is_timed_out(current_time);
    state.ros2_ok = true;
    state.esp32_connected = false;
    state.last_drive_seq = command.seq;
    state.failsafe = failsafe;
    state.estop = estop_latched_;
    state.battery_mv = 0;
    state.left_output = std::clamp(command.throttle + command.steering, -1.0F, 1.0F);
    state.right_output = std::clamp(command.throttle - command.steering, -1.0F, 1.0F);
    state.message = message;

    state_publisher_->publish(state);
  }

  int control_timeout_ms_{300};
  double publish_hz_{20.0};
  double max_output_{0.4};
  double deadzone_{0.05};
  bool require_zero_before_reset_estop_{true};

  bool has_command_{false};
  bool estop_latched_{false};
  uint32_t state_seq_{0};
  rclcpp::Time last_command_time_{0, 0, RCL_ROS_TIME};
  openrd_msgs::msg::DriveCommand last_command_;

  rclcpp::Subscription<openrd_msgs::msg::DriveCommand>::SharedPtr drive_subscription_;
  rclcpp::Publisher<openrd_msgs::msg::DriveCommand>::SharedPtr safe_drive_publisher_;
  rclcpp::Publisher<openrd_msgs::msg::VehicleState>::SharedPtr state_publisher_;
  rclcpp::Service<std_srvs::srv::Trigger>::SharedPtr reset_estop_service_;
  rclcpp::TimerBase::SharedPtr timer_;
};

}  // namespace openrd_safety

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<openrd_safety::OpenRdSafetyNode>());
  rclcpp::shutdown();
  return 0;
}