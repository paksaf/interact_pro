package com.interactpak.interactpro

import android.content.Context
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider

/**
 * Tells the Cast SDK which receiver application to look for and which
 * customisations to apply at session start.
 *
 * AndroidManifest hooks this in via:
 *   <meta-data
 *     android:name="com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME"
 *     android:value="com.interactpak.interactpro.CastOptionsProvider" />
 *
 * Default Media Receiver (CC1AD845) handles image / audio / video URL
 * playback out of the box — exactly what we need for "stream a rendered
 * PDF page PNG to the TV". If we ever ship a custom HTML5 receiver
 * (richer layout, multi-page queues, in-cast annotations), swap in the
 * application id Google Cast Console returns there.
 */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions {
        return CastOptions.Builder()
            .setReceiverApplicationId(
                CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID
            )
            // Stop session on activity finish so backgrounding the app
            // doesn't leave a TV stuck on the last cast page indefinitely.
            // Users can keep casting via the persistent notification the
            // SDK shows.
            .setStopReceiverApplicationWhenEndingSession(true)
            .build()
    }

    /**
     * No additional session providers needed — the Default Media Receiver
     * is enough for our use case.
     */
    override fun getAdditionalSessionProviders(
        context: Context
    ): List<SessionProvider>? = null
}
