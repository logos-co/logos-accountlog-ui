cmake_minimum_required(VERSION 3.14)
project(AccountLogUiPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

# SOURCES must be listed explicitly -- the macro does not glob.
logos_module(
    NAME accountlog_ui
    REP_FILE src/accountlog_ui.rep
    SOURCES
        src/AccountLogBackend.h
        src/AccountLogBackend.cpp
    # The account write path, linked in. A static archive, deliberately: the
    # builder copies every shared library an external library ships into the
    # plugin's lib/, where ui-host then tries to load each one as a Qt plugin.
    EXTERNAL_LIBS
        logos_account_core
    INCLUDE_DIRS
        src
)
