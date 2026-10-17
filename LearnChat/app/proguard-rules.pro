# Keep kotlinx.serialization generated serializers
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.learnchat.app.**$$serializer { *; }
-keepclassmembers class com.learnchat.app.** { *** Companion; }
-keepclasseswithmembers class com.learnchat.app.** { kotlinx.serialization.KSerializer serializer(...); }
