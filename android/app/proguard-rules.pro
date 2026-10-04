# kotlinx.serialization: keep generated serializers for the job-store DTOs
-keepclassmembers class **$$serializer { *; }
-keepclasseswithmembers class dev.utatane.imprima.** {
    kotlinx.serialization.KSerializer serializer(...);
}
