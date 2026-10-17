package com.qchat.app

import android.app.Application
import com.qchat.app.di.AppContainer

class QChatApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}
