# Keep kotlinx.serialization generated serializers
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.qchat.app.**$$serializer { *; }
-keepclassmembers class com.qchat.app.** { *** Companion; }
-keepclasseswithmembers class com.qchat.app.** { kotlinx.serialization.KSerializer serializer(...); }
