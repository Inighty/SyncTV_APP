package lhht.synctv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode

class MainActivity : FlutterActivity() {
    // 使用 TextureView 渲染模式，确保视频画面在 Android TV 上正常显示
    override fun getRenderMode(): RenderMode = RenderMode.texture
}
