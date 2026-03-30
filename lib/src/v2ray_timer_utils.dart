import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class V2RayTimerUtils {
  /// Get current connection duration in milliseconds
  static Future<int> getConnectionDuration(MethodChannel channel) async {
    debugPrint('⏰ V2Ray: Getting connection duration...');
    try {
      final int duration = await channel.invokeMethod('getConnectionDuration');
      debugPrint('⏰ V2Ray: Connection duration: ${duration}ms');
      return duration;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting connection duration: $e');
      return 0;
    }
  }

  /// Get total connection time in milliseconds (accumulated across sessions)
  static Future<int> getTotalConnectionTime(MethodChannel channel) async {
    debugPrint('⏰ V2Ray: Getting total connection time...');
    try {
      final int totalTime =
          await channel.invokeMethod('getTotalConnectionTime');
      debugPrint('⏰ V2Ray: Total connection time: ${totalTime}ms');
      return totalTime;
    } catch (e) {
      debugPrint('❌ V2Ray: Error getting total connection time: $e');
      return 0;
    }
  }

  /// Reset connection timer (clear accumulated time)
  static Future<bool> resetConnectionTimer(MethodChannel channel) async {
    debugPrint('⏰ V2Ray: Resetting connection timer...');
    try {
      final bool success = await channel.invokeMethod('resetConnectionTimer');
      debugPrint('⏰ V2Ray: Timer reset result: $success');
      return success;
    } catch (e) {
      debugPrint('❌ V2Ray: Error resetting connection timer: $e');
      return false;
    }
  }

  /// Set connection limits for subscription control
  static Future<bool> setConnectionLimits(
    MethodChannel channel, {
    int? sessionLimit, // in milliseconds
    int? dailyLimit, // in milliseconds
  }) async {
    debugPrint('⏰ V2Ray: Setting connection limits...');
    try {
      final bool success = await channel.invokeMethod('setConnectionLimits', {
        'sessionLimit': sessionLimit,
        'dailyLimit': dailyLimit,
      });
      debugPrint('⏰ V2Ray: Connection limits set: $success');
      return success;
    } catch (e) {
      debugPrint('❌ V2Ray: Error setting connection limits: $e');
      return false;
    }
  }

  /// Get connection duration in human readable format
  static String formatConnectionDuration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final hours = minutes ~/ 60;
    final days = hours ~/ 24;

    if (days > 0) {
      return '${days}d ${hours % 24}h ${minutes % 60}m';
    } else if (hours > 0) {
      return '${hours}h ${minutes % 60}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds % 60}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Check if user has exceeded time limits
  static Future<Map<String, dynamic>> checkTimeLimits(
    MethodChannel channel, {
    int? sessionLimit,
    int? dailyLimit,
  }) async {
    debugPrint('⏰ V2Ray: Checking time limits...');
    try {
      final currentDuration = await getConnectionDuration(channel);
      final totalTime = await getTotalConnectionTime(channel);

      final sessionExceeded =
          sessionLimit != null && currentDuration > sessionLimit;
      final dailyExceeded = dailyLimit != null && totalTime > dailyLimit;

      debugPrint(
          '⏰ V2Ray: Session exceeded: $sessionExceeded, Daily exceeded: $dailyExceeded');

      return {
        'sessionExceeded': sessionExceeded,
        'dailyExceeded': dailyExceeded,
        'currentDuration': currentDuration,
        'totalTime': totalTime,
        'sessionLimit': sessionLimit,
        'dailyLimit': dailyLimit,
      };
    } catch (e) {
      debugPrint('❌ V2Ray: Error checking time limits: $e');
      return {
        'sessionExceeded': false,
        'dailyExceeded': false,
        'currentDuration': 0,
        'totalTime': 0,
        'sessionLimit': sessionLimit,
        'dailyLimit': dailyLimit,
      };
    }
  }
}

