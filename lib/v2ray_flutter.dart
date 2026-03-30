import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'src/v2ray_config_helper.dart';
import 'src/v2ray_timer_utils.dart';

/// V2Ray Flutter plugin for cross-platform V2Ray integration
/// Supports both legacy native implementations and new gomobile libraries
class V2rayFlutter {
  static const MethodChannel _channel = MethodChannel('v2ray_flutter');

  // ========== Gomobile V2Ray Methods (New) ==========

  /// Initialize V2Ray system (Gomobile)
  static Future<String> initializeV2Ray() async {
    debugPrint('🚀 V2Ray: Initializing V2Ray system...');
    try {
      final String result = await _channel.invokeMethod('initializeV2Ray');
      debugPrint('✅ V2Ray: Initialization result: $result');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error initializing V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  /// Start V2Ray with JSON configuration (Gomobile)
  static Future<String> startV2RayWithConfig(
      Map<String, dynamic> config) async {
    debugPrint('🚀 V2Ray: Starting V2Ray with config...');
    try {
      String configJson = json.encode(config);
      debugPrint('📋 V2Ray: Config JSON length: ${configJson.length} chars');
      debugPrint(
          '📋 V2Ray: Config preview: ${configJson.length > 200 ? configJson.substring(0, 200) + '...' : configJson}');

      final String result = await _channel.invokeMethod('startV2Ray', {
        'config': configJson,
      });
      debugPrint('✅ V2Ray: Start result: $result');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error starting V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  /// Stop V2Ray service (Gomobile)
  static Future<String> stopV2RayService() async {
    debugPrint('🛑 V2Ray: Stopping V2Ray service...');
    try {
      final String result = await _channel.invokeMethod('stopV2Ray');
      debugPrint('✅ V2Ray: Stop result: $result');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error stopping V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  /// Check if V2Ray is running (Gomobile)
  static Future<bool> isV2RayRunning() async {
    debugPrint('🔍 V2Ray: Checking if V2Ray is running...');
    try {
      final bool running = await _channel.invokeMethod('isV2RayRunning');
      debugPrint('🔍 V2Ray: Running status: $running');
      return running;
    } catch (e) {
      debugPrint('❌ V2Ray: Error checking V2Ray status: $e');
      return false;
    }
  }

  /// Get V2Ray version (Gomobile)
  static Future<String> getV2RayVersion() async {
    debugPrint('📋 V2Ray: Getting V2Ray version...');
    try {
      final String version = await _channel.invokeMethod('getV2RayVersion');
      debugPrint('📋 V2Ray: Version: $version');
      return version;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting V2Ray version: $e');
      return 'Unknown';
    }
  }

  /// Test V2Ray connection (Gomobile)
  static Future<String> testV2RayConnection({String? url}) async {
    debugPrint('🧪 V2Ray: Testing V2Ray connection...');
    try {
      final testUrl = url ?? 'https://www.google.com/generate_204';
      debugPrint('🧪 V2Ray: Testing connection to: $testUrl');
      final String result = await _channel.invokeMethod('testV2RayConnection', {
        'url': testUrl,
      });
      debugPrint('🧪 V2Ray: Connection test result: $result');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error testing V2Ray connection: $e');
      return 'ERROR: $e';
    }
  }

  /// Get V2Ray status (Gomobile)
  static Future<String> getV2RayStatus() async {
    debugPrint('📊 V2Ray: Getting V2Ray status...');
    try {
      final String status = await _channel.invokeMethod('getV2RayStatus');
      debugPrint('📊 V2Ray: Status: $status');
      return status;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting V2Ray status: $e');
      return 'ERROR: $e';
    }
  }

  /// Cleanup V2Ray resources (Gomobile)
  static Future<String> cleanupV2Ray() async {
    debugPrint('🧹 V2Ray: Cleaning up V2Ray resources...');
    try {
      final String result = await _channel.invokeMethod('cleanupV2Ray');
      debugPrint('🧹 V2Ray: Cleanup result: $result');
      return result;
    } catch (e) {
      debugPrint('❌ V2Ray: Error cleaning up V2Ray: $e');
      return 'ERROR: $e';
    }
  }

  // ========== Legacy Methods (Existing) ==========

  /// Get V2Ray core version (Legacy)
  static Future<String> getCoreVersion() async {
    debugPrint('📋 V2Ray: Getting core version (Legacy)...');
    try {
      final String version = await _channel.invokeMethod('getCoreVersion');
      debugPrint('📋 V2Ray: Core version (Legacy): $version');
      return version;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting core version (Legacy): $e');
      // Try gomobile version as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile version...');
      return await getV2RayVersion();
    }
  }

  /// Start V2Ray with the given configuration (Legacy)
  static Future<bool> startV2Ray(Map<String, dynamic> config) async {
    debugPrint('🚀 V2Ray: Starting V2Ray service (Legacy)...');
    try {
      String configJson = json.encode(config);
      debugPrint(
          '📋 V2Ray: Config JSON length (Legacy): ${configJson.length} chars');
      debugPrint(
          '📋 V2Ray: Config preview (Legacy): ${configJson.length > 200 ? configJson.substring(0, 200) + '...' : configJson}');

      final bool success = await _channel.invokeMethod('startV2Ray', {
        'config': configJson,
      });

      if (!success) {
        String error = await getLastError();
        debugPrint('❌ V2Ray: Failed to start V2Ray (Legacy): $error');
      } else {
        debugPrint('✅ V2Ray: Successfully started V2Ray (Legacy)');
      }

      return success;
    } catch (e) {
      debugPrint('❌ V2Ray: Error starting V2Ray (Legacy): $e');
      // Try gomobile as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile...');
      try {
        String result = await startV2RayWithConfig(config);
        if (result != 'SUCCESS') {
          debugPrint('❌ V2Ray: Fallback start failed with result: $result');
        }
        return result == 'SUCCESS';
      } catch (e2) {
        debugPrint('❌ V2Ray: Fallback to gomobile also failed: $e2');
        return false;
      }
    }
  }

  /// Stop V2Ray (Legacy)
  static Future<bool> stopV2Ray() async {
    debugPrint('🛑 V2Ray: Stopping V2Ray (Legacy)...');
    try {
      final bool success = await _channel.invokeMethod('stopV2Ray');
      debugPrint('✅ V2Ray: Stop result (Legacy): $success');
      return success;
    } catch (e) {
      debugPrint('❌ V2Ray: Error stopping V2Ray (Legacy): $e');
      // Try gomobile as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile...');
      try {
        String result = await stopV2RayService();
        return result == 'SUCCESS';
      } catch (e2) {
        debugPrint('❌ V2Ray: Fallback to gomobile also failed: $e2');
        return false;
      }
    }
  }

  /// Check if V2Ray is running (Legacy)
  static Future<bool> isRunning() async {
    debugPrint('🔍 V2Ray: Checking if V2Ray is running (Legacy)...');
    try {
      final bool running = await _channel.invokeMethod('isRunning');
      debugPrint('🔍 V2Ray: Running status (Legacy): $running');
      return running;
    } catch (e) {
      debugPrint('❌ V2Ray: Error checking V2Ray status (Legacy): $e');
      // Try gomobile as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile...');
      return await isV2RayRunning();
    }
  }

  /// Get last error message (Legacy)
  static Future<String> getLastError() async {
    debugPrint('❌ V2Ray: Getting last error (Legacy)...');
    try {
      final String error = await _channel.invokeMethod('getLastError');
      debugPrint('❌ V2Ray: Last error (Legacy): $error');
      return error;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting last error (Legacy): $e');
      // Try gomobile status as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile status...');
      return await getV2RayStatus();
    }
  }

  /// Cleanup resources (Legacy)
  static Future<void> cleanup() async {
    debugPrint('🧹 V2Ray: Cleaning up resources (Legacy)...');
    try {
      await _channel.invokeMethod('cleanup');
      debugPrint('✅ V2Ray: Cleanup completed (Legacy)');
    } catch (e) {
      debugPrint('❌ V2Ray: Error during cleanup (Legacy): $e');
      // Try gomobile cleanup as fallback
      debugPrint('🔄 V2Ray: Falling back to gomobile cleanup...');
      try {
        await cleanupV2Ray();
      } catch (e2) {
        debugPrint('❌ V2Ray: Fallback cleanup also failed: $e2');
      }
    }
  }

  /// Get active server index by parsing V2Ray logs
  static Future<int> getActiveServerIndex() async {
    try {
      final int index = await _channel.invokeMethod('getActiveServerIndex');
      return index;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting active server index: $e');
      return 0;
    }
  }

  // ========== Configuration Helpers ==========

  /// Create VLESS configuration
  static Map<String, dynamic> createVlessConfig({
    required String serverAddress,
    required int serverPort,
    required String uuid,
    String? path,
    String? host,
    bool enableTLS = true,
    int localPort = 1080,
  }) {
    return V2RayConfigHelper.createVlessConfig(
      serverAddress: serverAddress,
      serverPort: serverPort,
      uuid: uuid,
      path: path,
      host: host,
      enableTLS: enableTLS,
      localPort: localPort,
    );
  }

  // ========== Connection Timer Methods ==========

  /// Get current connection duration in milliseconds
  static Future<int> getConnectionDuration() async {
    return V2RayTimerUtils.getConnectionDuration(_channel);
  }

  /// Get total connection time in milliseconds (accumulated across sessions)
  static Future<int> getTotalConnectionTime() async {
    return V2RayTimerUtils.getTotalConnectionTime(_channel);
  }

  /// Reset connection timer (clear accumulated time)
  static Future<bool> resetConnectionTimer() async {
    return V2RayTimerUtils.resetConnectionTimer(_channel);
  }

  /// Set connection limits for subscription control
  static Future<bool> setConnectionLimits({
    int? sessionLimit, // in milliseconds
    int? dailyLimit, // in milliseconds
  }) async {
    return V2RayTimerUtils.setConnectionLimits(
      _channel,
      sessionLimit: sessionLimit,
      dailyLimit: dailyLimit,
    );
  }

  /// Get connection duration in human readable format
  static String formatConnectionDuration(int milliseconds) {
    return V2RayTimerUtils.formatConnectionDuration(milliseconds);
  }

  /// Check if user has exceeded time limits
  static Future<Map<String, dynamic>> checkTimeLimits({
    int? sessionLimit,
    int? dailyLimit,
  }) async {
    return V2RayTimerUtils.checkTimeLimits(
      _channel,
      sessionLimit: sessionLimit,
      dailyLimit: dailyLimit,
    );
  }
}
