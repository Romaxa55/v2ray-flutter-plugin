Pod::Spec.new do |s|
  s.name             = 'v2ray_flutter'
  s.version          = '0.0.1'
  s.summary          = 'V2Ray plugin for Flutter with native iOS support'
  s.description      = <<-DESC
V2Ray plugin for Flutter supporting iOS and macOS platforms with native performance.
                       DESC
  s.homepage         = 'https://github.com/megav'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'MegaV' => 'support@megav.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # XCFramework bundled with the plugin.
  # vendored_frameworks автоматически добавит Libv2ray.xcframework в линковку
  # таргета через `-framework Libv2ray`. НЕ дублируем это в s.xcconfig —
  # иначе Libv2ray линкуется ДВАЖДЫ (один раз в v2ray_flutter.framework
  # как embedded, второй раз в Runner.debug.dylib напрямую) → классы Go
  # gomobile (goSeqDictionary, GoSeqRef, RefCounter, RefTracker)
  # регистрируются в ObjC runtime дважды → 2026-05-23 warning:
  # "Class X is implemented in both ... and ... mysterious crashes".
  s.vendored_frameworks = 'Frameworks/Libv2ray.xcframework'

  # 2026-05-19: -lresolv обязателен — Go runtime (внутри Libv2ray.xcframework)
  # использует libresolv (res_9_ninit/nsearch/nclose) для DNS resolver.
  # Без явной линковки linker падает с "Undefined symbol: _res_9_ninit" и т.д.
  # 2026-05-23 (юзер): убрали `-framework Libv2ray` отсюда (дубль линковки),
  # оставили только -lresolv.
  s.xcconfig = { 'OTHER_LDFLAGS' => '-lresolv' }

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

