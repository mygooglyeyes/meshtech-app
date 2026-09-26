# MapLibre under R8 (release builds) - added 2026-09-26.
# The maplibre plugin's Dart bindings reach their Java layer BY
# NAME at runtime (raw JNI class and method strings in jni.g.dart).
# R8 renamed that layer (MapLibrePlugin -> vp, MapLibreMapFactory ->
# up) and map attach died with a NullPointerException. Keep every
# name the bindings address. Flutter merges this file into the
# release shrinker automatically.

-keep class com.github.josxha.maplibre.** { *; }

# The engine interfaces the bindings IMPLEMENT across the JNI
# boundary (Dart returns a PlatformView proxy to Java, and proxies
# the plugin-registry callbacks). Dart dials these by name and the
# runtime proxy dispatches by member name - R8 renamed
# PlatformView -> yr and map attach died on the null that came
# back. Keep class AND member names for every interface the
# bindings name.
-keep class io.flutter.plugin.platform.PlatformView { *; }
-keep class io.flutter.plugin.platform.PlatformViewFactory { *; }
-keep class io.flutter.plugin.common.PluginRegistry { *; }
-keep class io.flutter.plugin.common.PluginRegistry$* { *; }
-keep class io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding { *; }
-keep class io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding$* { *; }

# JNI law: native methods are looked up by name - never rename them
# or the classes that hold them.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
