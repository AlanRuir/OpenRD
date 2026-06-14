import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    namespace = LaunchConfiguration('namespace')
    bringup_dir = get_package_share_directory('openrd_bringup')

    web_bridge_config = os.path.join(bringup_dir, 'config', 'web_bridge.yaml')
    safety_config = os.path.join(bringup_dir, 'config', 'safety.yaml')
    serial_config = os.path.join(bringup_dir, 'config', 'serial.yaml')
    vehicle_config = os.path.join(bringup_dir, 'config', 'vehicle.yaml')
    video_config = os.path.join(bringup_dir, 'config', 'video.yaml')

    return LaunchDescription([
        DeclareLaunchArgument(
            'namespace',
            default_value='openrd',
            description='ROS2 namespace for OpenRD vehicle nodes.',
        ),
        Node(
            package='openrd_web_bridge',
            executable='openrd_web_bridge_node',
            name='openrd_web_bridge_node',
            namespace=namespace,
            output='screen',
            parameters=[web_bridge_config, vehicle_config],
        ),
        Node(
            package='openrd_safety',
            executable='openrd_safety_node',
            name='openrd_safety_node',
            namespace=namespace,
            output='screen',
            parameters=[safety_config, vehicle_config],
        ),
        Node(
            package='openrd_esp32_bridge',
            executable='openrd_esp32_bridge_node',
            name='openrd_esp32_bridge_node',
            namespace=namespace,
            output='screen',
            parameters=[serial_config, vehicle_config],
        ),
        Node(
            package='openrd_video',
            executable='openrd_video_node',
            name='openrd_video_node',
            namespace=namespace,
            output='screen',
            parameters=[video_config],
        ),
    ])
