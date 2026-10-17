package com.learnchat.app

import android.app.Application
import com.learnchat.app.di.AppContainer

class LearnChatApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}
