# SPDX-FileCopyrightText: 2024 Avuz
# SPDX-License-Identifier: GPL-2.0-or-later

if(NEXTCLOUD_DEV)
    set( APPLICATION_NAME       "Avuz ConectaDev" )
    set( APPLICATION_SHORTNAME  "AvuzConectaDev" )
    set( APPLICATION_EXECUTABLE "avuzconectadev" )
    set( APPLICATION_ICON_NAME  "AvuzConecta" )
else()
    set( APPLICATION_NAME       "Avuz Conecta" )
    set( APPLICATION_SHORTNAME  "AvuzConecta" )
    set( APPLICATION_EXECUTABLE "avuzconecta" )
    set( APPLICATION_ICON_NAME  "AvuzConecta" )
endif()

set( APPLICATION_CONFIG_NAME "${APPLICATION_EXECUTABLE}" )
set( APPLICATION_DOMAIN     "avuz.app" )
set( APPLICATION_VENDOR     "Avuz" )
set( APPLICATION_UPDATE_URL "https://avuz.app/updates/" CACHE STRING "URL for updater" )
set( APPLICATION_HELP_URL   "https://avuz.app/help" CACHE STRING "URL for the help menu" )

# Note: We don't override APPLICATION_ICON_NAME for macOS because the sized icons
# use the base "AvuzConecta" prefix (e.g., 16-AvuzConecta-icon.png)

set( APPLICATION_ICON_SET   "PNG" )
set( APPLICATION_SERVER_URL "" CACHE STRING "URL for the server to use. If entered, the UI field will be pre-filled with it" )
set( APPLICATION_SERVER_URL_ENFORCE OFF )
set( APPLICATION_REV_DOMAIN "app.avuz.conecta" )
set( APPLICATION_VIRTUALFILE_SUFFIX "avuzconecta" CACHE STRING "Virtual file suffix (not including the .)")
set( APPLICATION_OCSP_STAPLING_ENABLED OFF )
set( APPLICATION_FORBID_BAD_SSL OFF )

set( LINUX_PACKAGE_SHORTNAME "avuzconecta" )
set( LINUX_APPLICATION_ID "${APPLICATION_REV_DOMAIN}")

set( THEME_CLASS            "AvuzTheme" )
set( WIN_SETUP_BITMAP_PATH  "${CMAKE_SOURCE_DIR}/admin/win/nsi" )

set( MAC_INSTALLER_BACKGROUND_FILE "${CMAKE_SOURCE_DIR}/admin/osx/installer-background.png" CACHE STRING "The MacOSX installer background image")

# Updater options
option( BUILD_UPDATER "Build updater" OFF )

option( WITH_PROVIDERS "Build with providers list" OFF )

option( ENFORCE_VIRTUAL_FILES_SYNC_FOLDER "Enforce use of virtual files sync folder when available" OFF )
option( DISABLE_VIRTUAL_FILES_SYNC_FOLDER "Disable use of virtual files sync folder even when available" OFF )

option(ENFORCE_SINGLE_ACCOUNT "Enforce use of a single account in desktop client" OFF)

option( DO_NOT_USE_PROXY "Do not use system wide proxy, instead always do a direct connection to server" OFF )

option( WIN_DISABLE_USERNAME_PREFILL "Do not prefill the Windows user name when creating a new account" OFF )

# Theming options - Avuz brand color
set(NEXTCLOUD_BACKGROUND_COLOR "#2bb5e3" CACHE STRING "Default Avuz background color")
set( APPLICATION_WIZARD_HEADER_BACKGROUND_COLOR ${NEXTCLOUD_BACKGROUND_COLOR} CACHE STRING "Hex color of the wizard header background")
set( APPLICATION_WIZARD_HEADER_TITLE_COLOR "#ffffff" CACHE STRING "Hex color of the text in the wizard header")
option( APPLICATION_WIZARD_USE_CUSTOM_LOGO "Use the logo from ':/client/theme/colored/wizard_logo.(png|svg)' else the default application icon is used" ON )

#
# Windows Shell Extensions & MSI - IMPORTANT: New GUIDs for Avuz
#
if(WIN32)
    # Context Menu
    set( WIN_SHELLEXT_CONTEXT_MENU_GUID      "{A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D}" )

    # Overlays
    set( WIN_SHELLEXT_OVERLAY_GUID_ERROR     "{B2C3D4E5-F6A7-4B5C-9D0E-1F2A3B4C5D6E}" )
    set( WIN_SHELLEXT_OVERLAY_GUID_OK        "{C3D4E5F6-A7B8-4C5D-0E1F-2A3B4C5D6E7F}" )
    set( WIN_SHELLEXT_OVERLAY_GUID_OK_SHARED "{D4E5F6A7-B8C9-4D5E-1F2A-3B4C5D6E7F80}" )
    set( WIN_SHELLEXT_OVERLAY_GUID_SYNC      "{E5F6A7B8-C9D0-4E5F-2A3B-4C5D6E7F8091}" )
    set( WIN_SHELLEXT_OVERLAY_GUID_WARNING   "{F6A7B8C9-D0E1-4F5A-3B4C-5D6E7F8091A2}" )

    # MSI Upgrade Code (without brackets)
    set( WIN_MSI_UPGRADE_CODE                "A7B8C9D0-E1F2-4A5B-4C5D-6E7F8091A2B3" )

    # Windows build options
    option( BUILD_WIN_MSI "Build MSI scripts and helper DLL" OFF )
    option( BUILD_WIN_TOOLS "Build Win32 migration tools" OFF )
endif()

if (APPLE AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_GREATER_EQUAL 11.0)
    option( BUILD_FILE_PROVIDER_MODULE "Build the macOS virtual files File Provider module" OFF )
endif()
