import 'package:flutter/material.dart';

/// 统一的系统消息工具类
class MessageUtils {
  /// 私有构造函数，防止实例化
  MessageUtils._();

  /// 判断是否为大屏（TV/平板）
  static bool _isLargeScreen(BuildContext context) {
    return MediaQuery.of(context).size.width >= 600;
  }

  /// 大屏端用 Overlay 在顶部显示提示条
  static void _showOverlayMessage(
    BuildContext context,
    String message, {
    required Color backgroundColor,
    required IconData icon,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        top: 40 + MediaQuery.of(context).padding.top,
        left: 60,
        right: 60,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(duration, () {
      if (entry.mounted) entry.remove();
    });
  }

  /// 默认的底部边距（手机端）
  static EdgeInsets _getDefaultMargin(BuildContext context) {
    return EdgeInsets.only(
      bottom: 70 + MediaQuery.of(context).padding.bottom,
      left: 20,
      right: 20,
    );
  }

  /// 默认的形状
  static RoundedRectangleBorder get _defaultShape {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
  }

  /// 显示成功消息
  static void showSuccess(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    if (_isLargeScreen(context)) {
      _showOverlayMessage(context, message,
          backgroundColor: Colors.green.shade600,
          icon: Icons.check_circle,
          duration: duration);
      return;
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.green.shade600,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: _getDefaultMargin(context),
        shape: _defaultShape,
        action: action,
      ),
    );
  }

  /// 显示错误消息
  static void showError(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    if (_isLargeScreen(context)) {
      _showOverlayMessage(context, message,
          backgroundColor: Colors.red.shade600,
          icon: Icons.error,
          duration: duration);
      return;
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: _getDefaultMargin(context),
        shape: _defaultShape,
        action: action,
      ),
    );
  }

  /// 显示警告消息
  static void showWarning(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    if (_isLargeScreen(context)) {
      _showOverlayMessage(context, message,
          backgroundColor: Colors.orange.shade600,
          icon: Icons.warning,
          duration: duration);
      return;
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.orange.shade600,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: _getDefaultMargin(context),
        shape: _defaultShape,
        action: action,
      ),
    );
  }

  /// 显示信息消息
  static void showInfo(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    if (_isLargeScreen(context)) {
      _showOverlayMessage(context, message,
          backgroundColor: Colors.blue.shade700,
          icon: Icons.info,
          duration: duration);
      return;
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.blue.shade700,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: _getDefaultMargin(context),
        shape: _defaultShape,
        action: action,
      ),
    );
  }

  /// 显示删除操作消息（带撤销功能）
  static void showDelete(
    BuildContext context,
    String message, {
    required VoidCallback onUndo,
    Duration duration = const Duration(seconds: 3),
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: isDark ? Colors.grey.shade900 : Colors.grey.shade800,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: _getDefaultMargin(context),
        shape: _defaultShape,
        action: SnackBarAction(
          label: '撤销',
          textColor: Colors.white,
          onPressed: onUndo,
        ),
      ),
    );
  }

  /// 显示自定义颜色的消息
  static void showCustom(
    BuildContext context,
    String message, {
    required Color backgroundColor,
    Color textColor = Colors.white,
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: textColor),
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        duration: duration,
        margin: _getDefaultMargin(context),
        shape: _defaultShape,
        action: action,
      ),
    );
  }

  /// 显示开关状态变更消息
  static void showToggle(
    BuildContext context,
    String message, {
    required bool isEnabled,
    Duration duration = const Duration(seconds: 2),
  }) {
    showCustom(
      context,
      message,
      backgroundColor: isEnabled ? Colors.green.shade600 : Colors.orange.shade600,
      duration: duration,
    );
  }

  /// 显示加载中消息（带圆形进度指示器）
  static void showLoading(
    BuildContext context,
    String message, {
    Duration? duration,
    Color? indicatorColor,
  }) {
    final theme = Theme.of(context);
    
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  indicatorColor ?? Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.blue.shade700,
        behavior: SnackBarBehavior.floating,
        duration: duration ?? const Duration(seconds: 5), // 默认较长时间，通常需要手动关闭
        margin: _getDefaultMargin(context),
        shape: _defaultShape,
      ),
    );
  }
} 