#include <algorithm>
#include <chrono>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <optional>
#include <regex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include <sys/wait.h>
#include <unistd.h>

#include "openrd_msgs/msg/video_state.hpp"
#include "rclcpp/rclcpp.hpp"
#include "std_srvs/srv/trigger.hpp"

using namespace std::chrono_literals;

extern char ** environ;

namespace openrd_video
{

struct RuntimeStatus
{
  bool runtime_running{false};
  uint32_t pid{0};
  std::string state{"UNKNOWN"};
  std::string mode;
  std::string device;
  std::string actual_device;
  uint32_t width{0};
  uint32_t height{0};
  uint32_t fps{0};
  uint32_t bitrate{0};
  uint32_t gop{0};
  std::string output;
  std::string rtsp_url;
  std::string rtsp_protocols;
  uint32_t rtsp_latency_ms{0};
  std::string rtp_host;
  uint32_t rtp_port{0};
  uint32_t rtp_payload_type{0};
  uint32_t rtp_mtu{0};
  std::string log_file;
  std::string message;
};

struct CommandResult
{
  int exit_code{127};
  std::string output;
};

std::string trim(const std::string & value)
{
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) {
    return {};
  }
  const auto last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::optional<std::string> extract_json_string(const std::string & json, const std::string & key)
{
  const std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
  std::smatch match;
  if (!std::regex_search(json, match, pattern) || match.size() < 2) {
    return std::nullopt;
  }
  return match[1].str();
}

std::optional<uint32_t> extract_json_uint(const std::string & json, const std::string & key)
{
  const std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*([0-9]+)");
  std::smatch match;
  if (!std::regex_search(json, match, pattern) || match.size() < 2) {
    return std::nullopt;
  }
  return static_cast<uint32_t>(std::stoul(match[1].str()));
}

std::optional<bool> extract_json_bool(const std::string & json, const std::string & key)
{
  const std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*(true|false)");
  std::smatch match;
  if (!std::regex_search(json, match, pattern) || match.size() < 2) {
    return std::nullopt;
  }
  return match[1].str() == "true";
}

std::vector<std::string> build_environment_entries(
  const std::vector<std::pair<std::string, std::string>> & overrides)
{
  std::set<std::string> override_keys;
  for (const auto & entry : overrides) {
    override_keys.insert(entry.first);
  }

  std::vector<std::string> entries;
  for (char ** environment = environ; environment != nullptr && *environment != nullptr; ++environment) {
    std::string entry(*environment);
    const auto equals = entry.find('=');
    if (equals == std::string::npos) {
      continue;
    }

    const std::string key = entry.substr(0, equals);
    if (override_keys.count(key) == 0) {
      entries.push_back(std::move(entry));
    }
  }

  for (const auto & entry : overrides) {
    entries.push_back(entry.first + "=" + entry.second);
  }

  return entries;
}

CommandResult run_command(
  const std::vector<std::string> & arguments,
  const std::vector<std::pair<std::string, std::string>> & env_overrides = {})
{
  CommandResult result;
  if (arguments.empty()) {
    result.exit_code = 2;
    result.output = "empty command";
    return result;
  }

  int pipe_fds[2];
  if (pipe(pipe_fds) != 0) {
    result.exit_code = errno;
    result.output = std::string("pipe failed: ") + std::strerror(errno);
    return result;
  }

  pid_t child_pid = fork();
  if (child_pid == 0) {
    dup2(pipe_fds[1], STDOUT_FILENO);
    dup2(pipe_fds[1], STDERR_FILENO);
    close(pipe_fds[0]);
    close(pipe_fds[1]);

    std::vector<std::string> environment_entries = build_environment_entries(env_overrides);
    std::vector<char *> argv;
    argv.reserve(arguments.size() + 1);
    for (const auto & argument : arguments) {
      argv.push_back(const_cast<char *>(argument.c_str()));
    }
    argv.push_back(nullptr);

    std::vector<char *> envp;
    envp.reserve(environment_entries.size() + 1);
    for (const auto & entry : environment_entries) {
      envp.push_back(const_cast<char *>(entry.c_str()));
    }
    envp.push_back(nullptr);

    execve(arguments[0].c_str(), argv.data(), envp.data());
    std::perror("execve");
    _exit(127);
  }

  if (child_pid < 0) {
    close(pipe_fds[0]);
    close(pipe_fds[1]);
    result.exit_code = errno;
    result.output = std::string("fork failed: ") + std::strerror(errno);
    return result;
  }

  close(pipe_fds[1]);

  std::string output;
  char buffer[4096];
  ssize_t bytes_read = 0;
  while ((bytes_read = read(pipe_fds[0], buffer, sizeof(buffer))) > 0) {
    output.append(buffer, static_cast<std::size_t>(bytes_read));
  }
  close(pipe_fds[0]);

  int wait_status = 0;
  pid_t waited_pid = 0;
  while ((waited_pid = waitpid(child_pid, &wait_status, 0)) < 0 && errno == EINTR) {
  }

  if (waited_pid < 0) {
    result.exit_code = errno;
    result.output = std::string("waitpid failed: ") + std::strerror(errno);
    return result;
  }

  if (WIFEXITED(wait_status)) {
    result.exit_code = WEXITSTATUS(wait_status);
  } else if (WIFSIGNALED(wait_status)) {
    result.exit_code = 128 + WTERMSIG(wait_status);
  } else {
    result.exit_code = 1;
  }

  result.output = std::move(output);
  return result;
}

RuntimeStatus parse_runtime_status(const std::string & json)
{
  RuntimeStatus status;

  if (const auto value = extract_json_string(json, "state")) {
    status.state = *value;
  }
  if (const auto value = extract_json_string(json, "message")) {
    status.message = *value;
  }
  if (const auto value = extract_json_uint(json, "pid")) {
    status.pid = *value;
  }
  if (const auto value = extract_json_string(json, "mode")) {
    status.mode = *value;
  }
  if (const auto value = extract_json_string(json, "device")) {
    status.device = *value;
  }
  if (const auto value = extract_json_string(json, "actual_device")) {
    status.actual_device = *value;
  }
  if (const auto value = extract_json_uint(json, "width")) {
    status.width = *value;
  }
  if (const auto value = extract_json_uint(json, "height")) {
    status.height = *value;
  }
  if (const auto value = extract_json_uint(json, "fps")) {
    status.fps = *value;
  }
  if (const auto value = extract_json_uint(json, "bitrate")) {
    status.bitrate = *value;
  }
  if (const auto value = extract_json_uint(json, "gop")) {
    status.gop = *value;
  }
  if (const auto value = extract_json_string(json, "output")) {
    status.output = *value;
  }
  if (const auto value = extract_json_string(json, "rtsp_url")) {
    status.rtsp_url = *value;
  }
  if (const auto value = extract_json_string(json, "rtsp_protocols")) {
    status.rtsp_protocols = *value;
  }
  if (const auto value = extract_json_uint(json, "rtsp_latency_ms")) {
    status.rtsp_latency_ms = *value;
  }
  if (const auto value = extract_json_string(json, "rtp_host")) {
    status.rtp_host = *value;
  }
  if (const auto value = extract_json_uint(json, "rtp_port")) {
    status.rtp_port = *value;
  }
  if (const auto value = extract_json_uint(json, "rtp_payload_type")) {
    status.rtp_payload_type = *value;
  }
  if (const auto value = extract_json_uint(json, "rtp_mtu")) {
    status.rtp_mtu = *value;
  }
  if (const auto value = extract_json_string(json, "log_file")) {
    status.log_file = *value;
  }
  if (const auto value = extract_json_bool(json, "runtime_running")) {
    status.runtime_running = *value;
  } else {
    status.runtime_running = status.state == "running" || status.state == "RUNNING";
  }

  return status;
}

class OpenRdVideoNode final : public rclcpp::Node
{
public:
  OpenRdVideoNode() : Node("openrd_video_node")
  {
    runtime_cli_ = declare_parameter<std::string>(
      "runtime_cli", "/home/linaro/OpenRD/vehicle/native_video/openrd-video-native");
    runtime_state_dir_ = declare_parameter<std::string>(
      "runtime_state_dir", "/home/linaro/OpenRD/vehicle/native_video/run");
    runtime_log_ = declare_parameter<std::string>(
      "runtime_log", "/home/linaro/OpenRD/vehicle/native_video/run/openrd-video-native.log");
    auto_start_ = declare_parameter<bool>("auto_start", false);
    poll_hz_ = declare_parameter<double>("poll_hz", 1.0);
    mode_ = declare_parameter<std::string>("mode", "fakesink");
    device_ = declare_parameter<std::string>("device", "/dev/openrd-cam-front");
    width_ = declare_parameter<int>("width", 1280);
    height_ = declare_parameter<int>("height", 720);
    fps_ = declare_parameter<int>("fps", 30);
    bitrate_ = declare_parameter<int>("bitrate", 2000000);
    gop_ = declare_parameter<int>("gop", 30);
    output_ = declare_parameter<std::string>("output", "/tmp/openrd_camera_test.h264");
    rtsp_url_ = declare_parameter<std::string>("rtsp_url", "rtsp://127.0.0.1:8554/live");
    rtsp_protocols_ = declare_parameter<std::string>("rtsp_protocols", "tcp");
    rtsp_latency_ms_ = declare_parameter<int>("rtsp_latency_ms", 100);
    rtp_host_ = declare_parameter<std::string>("rtp_host", "127.0.0.1");
    rtp_port_ = declare_parameter<int>("rtp_port", 5004);
    rtp_payload_type_ = declare_parameter<int>("rtp_payload_type", 96);
    rtp_mtu_ = declare_parameter<int>("rtp_mtu", 1200);

    state_publisher_ = create_publisher<openrd_msgs::msg::VideoState>("video_state", rclcpp::QoS(1));

    start_service_ = create_service<std_srvs::srv::Trigger>(
      "start_runtime",
      [this](
        const std::shared_ptr<std_srvs::srv::Trigger::Request> /*request*/,
        std::shared_ptr<std_srvs::srv::Trigger::Response> response) {
          response->success = start_runtime();
          response->message = last_operation_message_;
        });

    stop_service_ = create_service<std_srvs::srv::Trigger>(
      "stop_runtime",
      [this](
        const std::shared_ptr<std_srvs::srv::Trigger::Request> /*request*/,
        std::shared_ptr<std_srvs::srv::Trigger::Response> response) {
          response->success = stop_runtime();
          response->message = last_operation_message_;
        });

    restart_service_ = create_service<std_srvs::srv::Trigger>(
      "restart_runtime",
      [this](
        const std::shared_ptr<std_srvs::srv::Trigger::Request> /*request*/,
        std::shared_ptr<std_srvs::srv::Trigger::Response> response) {
          const bool stopped = stop_runtime();
          const bool started = start_runtime();
          response->success = stopped && started;
          response->message = last_operation_message_;
        });

    const auto poll_period_ms = std::max(200, static_cast<int>(1000.0 / std::max(0.1, poll_hz_)));
    poll_timer_ = create_wall_timer(
      std::chrono::milliseconds(poll_period_ms), [this]() { publish_current_status(); });

    RCLCPP_INFO(
      get_logger(),
      "OpenRD video manager started: cli=%s, state_dir=%s, log=%s, auto_start=%s",
      runtime_cli_.c_str(),
      runtime_state_dir_.c_str(),
      runtime_log_.c_str(),
      auto_start_ ? "true" : "false");

    publish_current_status();

    if (auto_start_) {
      if (!start_runtime()) {
        RCLCPP_WARN(get_logger(), "auto_start failed: %s", last_operation_message_.c_str());
      }
    }
  }

private:
  std::vector<std::pair<std::string, std::string>> runtime_environment() const
  {
    return {
      {"OPENRD_VIDEO_STATE_DIR", runtime_state_dir_},
      {"OPENRD_VIDEO_LOG", runtime_log_},
    };
  }

  std::vector<std::string> build_command(const std::string & command) const
  {
    std::vector<std::string> arguments = {
      runtime_cli_,
      command,
    };

    if (command == "start" || command == "run" || command == "test" || command == "pipeline" ||
        command == "restart") {
      arguments.emplace_back("--mode");
      arguments.emplace_back(mode_);
      arguments.emplace_back("--device");
      arguments.emplace_back(device_);
      arguments.emplace_back("--width");
      arguments.emplace_back(std::to_string(width_));
      arguments.emplace_back("--height");
      arguments.emplace_back(std::to_string(height_));
      arguments.emplace_back("--fps");
      arguments.emplace_back(std::to_string(fps_));
      arguments.emplace_back("--bitrate");
      arguments.emplace_back(std::to_string(bitrate_));
      arguments.emplace_back("--gop");
      arguments.emplace_back(std::to_string(gop_));
      if (command == "start" || command == "run" || command == "pipeline" || command == "restart") {
        arguments.emplace_back("--output");
        arguments.emplace_back(output_);
        arguments.emplace_back("--rtsp-url");
        arguments.emplace_back(rtsp_url_);
        arguments.emplace_back("--rtsp-protocols");
        arguments.emplace_back(rtsp_protocols_);
        arguments.emplace_back("--rtsp-latency-ms");
        arguments.emplace_back(std::to_string(rtsp_latency_ms_));
        arguments.emplace_back("--rtp-host");
        arguments.emplace_back(rtp_host_);
        arguments.emplace_back("--rtp-port");
        arguments.emplace_back(std::to_string(rtp_port_));
        arguments.emplace_back("--rtp-pt");
        arguments.emplace_back(std::to_string(rtp_payload_type_));
        arguments.emplace_back("--rtp-mtu");
        arguments.emplace_back(std::to_string(rtp_mtu_));
      }
      if (command == "start" || command == "run" || command == "test" || command == "pipeline" ||
          command == "restart") {
        arguments.emplace_back("--state-dir");
        arguments.emplace_back(runtime_state_dir_);
        arguments.emplace_back("--log");
        arguments.emplace_back(runtime_log_);
      }
    } else if (command == "status") {
      arguments.emplace_back("--json");
    }

    return arguments;
  }

  bool runtime_cli_exists() const
  {
    return std::filesystem::exists(runtime_cli_) && access(runtime_cli_.c_str(), X_OK) == 0;
  }

  CommandResult call_runtime(const std::string & command) const
  {
    return run_command(build_command(command), runtime_environment());
  }

  RuntimeStatus query_runtime_status() const
  {
    const auto command = build_command("status");
    const auto result = run_command(command, runtime_environment());

    if (result.exit_code != 0 && trim(result.output).empty()) {
      RuntimeStatus status;
      status.state = "ERROR";
      status.message = "failed to query runtime status";
      return status;
    }

    RuntimeStatus status = parse_runtime_status(result.output);
    if (result.exit_code != 0 && status.state == "UNKNOWN") {
      status.state = "ERROR";
      if (status.message.empty()) {
        status.message = trim(result.output);
      }
    }
    return status;
  }

  void publish_status(const RuntimeStatus & status)
  {
    openrd_msgs::msg::VideoState message;
    message.seq = sequence_++;
    message.stamp = now();
    message.state = status.state;
    message.runtime_running = status.runtime_running;
    message.pid = status.pid;
    message.mode = status.mode.empty() ? mode_ : status.mode;
    message.device = status.device.empty() ? device_ : status.device;
    message.actual_device = status.actual_device;
    message.width = status.width == 0 ? static_cast<uint32_t>(width_) : status.width;
    message.height = status.height == 0 ? static_cast<uint32_t>(height_) : status.height;
    message.fps = status.fps == 0 ? static_cast<uint32_t>(fps_) : status.fps;
    message.bitrate = status.bitrate == 0 ? static_cast<uint32_t>(bitrate_) : status.bitrate;
    message.gop = status.gop == 0 ? static_cast<uint32_t>(gop_) : status.gop;
    message.output = status.output.empty() ? output_ : status.output;
    message.rtsp_url = status.rtsp_url.empty() ? rtsp_url_ : status.rtsp_url;
    message.rtsp_protocols = status.rtsp_protocols.empty() ? rtsp_protocols_ : status.rtsp_protocols;
    message.rtsp_latency_ms = status.rtsp_latency_ms == 0 ? static_cast<uint32_t>(rtsp_latency_ms_) : status.rtsp_latency_ms;
    message.rtp_host = status.rtp_host.empty() ? rtp_host_ : status.rtp_host;
    message.rtp_port = status.rtp_port == 0 ? static_cast<uint32_t>(rtp_port_) : status.rtp_port;
    message.rtp_payload_type = status.rtp_payload_type == 0 ? static_cast<uint32_t>(rtp_payload_type_) : status.rtp_payload_type;
    message.rtp_mtu = status.rtp_mtu == 0 ? static_cast<uint32_t>(rtp_mtu_) : status.rtp_mtu;
    message.log_file = status.log_file.empty() ? runtime_log_ : status.log_file;
    message.message = status.message;

    state_publisher_->publish(message);
    last_status_ = status;
  }

  void publish_current_status()
  {
    if (!runtime_cli_exists()) {
      RuntimeStatus status;
      status.state = "ERROR";
      status.runtime_running = false;
      status.message = std::string("runtime CLI not found: ") + runtime_cli_;
      publish_status(status);
      RCLCPP_WARN_THROTTLE(
        get_logger(),
        *get_clock(),
        5000,
        "%s",
        status.message.c_str());
      return;
    }

    const RuntimeStatus status = query_runtime_status();
    const bool changed = status.state != last_status_.state || status.pid != last_status_.pid ||
      status.runtime_running != last_status_.runtime_running || status.message != last_status_.message;

    publish_status(status);

    if (changed) {
      RCLCPP_INFO(
        get_logger(),
        "video runtime state=%s running=%s pid=%u mode=%s device=%s",
        status.state.c_str(),
        status.runtime_running ? "true" : "false",
        status.pid,
        status.mode.empty() ? mode_.c_str() : status.mode.c_str(),
        status.device.empty() ? device_.c_str() : status.device.c_str());
      if (!status.message.empty()) {
        RCLCPP_INFO(get_logger(), "video runtime detail: %s", status.message.c_str());
      }
    }
  }

  bool start_runtime()
  {
    if (!runtime_cli_exists()) {
      last_operation_message_ = std::string("runtime CLI not found: ") + runtime_cli_;
      RCLCPP_ERROR(get_logger(), "%s", last_operation_message_.c_str());
      return false;
    }

    const auto result = call_runtime("start");
    last_operation_message_ = trim(result.output);
    if (result.exit_code != 0) {
      RCLCPP_ERROR(
        get_logger(),
        "video runtime start failed (exit=%d): %s",
        result.exit_code,
        last_operation_message_.c_str());
      publish_current_status();
      return false;
    }

    publish_current_status();
    return true;
  }

  bool stop_runtime()
  {
    if (!runtime_cli_exists()) {
      last_operation_message_ = std::string("runtime CLI not found: ") + runtime_cli_;
      RCLCPP_ERROR(get_logger(), "%s", last_operation_message_.c_str());
      return false;
    }

    const auto result = call_runtime("stop");
    last_operation_message_ = trim(result.output);
    if (result.exit_code != 0) {
      RCLCPP_ERROR(
        get_logger(),
        "video runtime stop failed (exit=%d): %s",
        result.exit_code,
        last_operation_message_.c_str());
      publish_current_status();
      return false;
    }

    publish_current_status();
    return true;
  }

  std::string runtime_cli_;
  std::string runtime_state_dir_;
  std::string runtime_log_;
  bool auto_start_{false};
  double poll_hz_{1.0};
  std::string mode_{"fakesink"};
  std::string device_{"/dev/openrd-cam-front"};
  int width_{1280};
  int height_{720};
  int fps_{30};
  int bitrate_{2000000};
  int gop_{30};
  std::string output_{"/tmp/openrd_camera_test.h264"};
  std::string rtsp_url_{"rtsp://127.0.0.1:8554/live"};
  std::string rtsp_protocols_{"tcp"};
  int rtsp_latency_ms_{100};
  std::string rtp_host_{"127.0.0.1"};
  int rtp_port_{5004};
  int rtp_payload_type_{96};
  int rtp_mtu_{1200};

  uint32_t sequence_{0};
  RuntimeStatus last_status_;
  std::string last_operation_message_;

  rclcpp::Publisher<openrd_msgs::msg::VideoState>::SharedPtr state_publisher_;
  rclcpp::Service<std_srvs::srv::Trigger>::SharedPtr start_service_;
  rclcpp::Service<std_srvs::srv::Trigger>::SharedPtr stop_service_;
  rclcpp::Service<std_srvs::srv::Trigger>::SharedPtr restart_service_;
  rclcpp::TimerBase::SharedPtr poll_timer_;
};

}  // namespace openrd_video

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<openrd_video::OpenRdVideoNode>());
  rclcpp::shutdown();
  return 0;
}
