package com.sinyalist

import android.app.Application
import android.util.Log

class SinyalistApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Log.i("Sinyalist", "Application initialized")
    }
}
