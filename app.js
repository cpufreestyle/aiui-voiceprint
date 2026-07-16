export default {
  onLaunch: function () {
    console.log('声纹识别应用启动 - 无障碍版');
  },
  onShow: function () {
    console.log('应用显示');
  },
  onHide: function () {
    console.log('应用隐藏');
  },
  globalData: {
    currentUser: null,
    voiceprintDB: null,
    lastRecording: null,
    lastResult: null,
    sessionStartTime: null,
    // 无障碍设置
    accessibilityMode: true,
    vibrationEnabled: true,
    voicePromptEnabled: true,
    highContrastEnabled: true
  }
}
