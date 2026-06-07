import os
import info
from Package.CMakePackageBase import *


class subinfo(info.infoclass):
    def registerOptions(self):
        self.options.dynamic.registerOption("buildType", "Release")

    def setTargets(self):
        # Use local source directory
        self.svnTargets["master"] = "C:/Dev/desktop"

        self.description = "Avuz Conecta Desktop Client"
        self.displayName = "Avuz Conecta"
        self.webpage = "https://avuz.app"

        self.defaultTarget = "master"

    def setDependencies(self):
        self.buildDependencies["dev-utils/cmake"] = None
        self.buildDependencies["dev-utils/nsis"] = None
        self.runtimeDependencies["libs/qt6/qtbase"] = None
        self.runtimeDependencies["libs/qt6/qtdeclarative"] = None
        self.runtimeDependencies["libs/qt6/qtwebengine"] = None
        self.runtimeDependencies["libs/qt6/qtwebsockets"] = None
        self.runtimeDependencies["libs/qt6/qtmultimedia"] = None
        self.runtimeDependencies["libs/qt6/qtsvg"] = None
        self.runtimeDependencies["libs/qt6/qt5compat"] = None
        self.runtimeDependencies["libs/zlib"] = None
        self.runtimeDependencies["libs/libp11"] = None
        self.runtimeDependencies["qt-libs/qtkeychain"] = None
        self.runtimeDependencies["kde/frameworks/tier1/karchive"] = None
        self.runtimeDependencies["libs/openssl"] = None


class Package(CMakePackageBase):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        self.subinfo.options.configure.args += [
            "-DNEXTCLOUD_DEV=OFF",
            "-DOEM_THEME_CMAKE_FILE=AVUZ.cmake",
        ]

    def createPackage(self):
        self.blacklist_file.append(os.path.join(self.blueprintDir(), 'blacklist.txt'))

        # Avuz Conecta branding
        self.defines["appname"] = "avuzconecta"
        self.defines["company"] = "Avuz"
        self.defines["productname"] = "Avuz Conecta"
        self.defines["display_name"] = "Avuz Conecta"
        self.defines["version"] = "4.0.9"
        self.defines["website"] = "https://avuz.app"
        self.defines["icon"] = os.path.join(self.sourceDir(), "admin/win/nsi/installer.ico")
        self.defines["icon_png"] = os.path.join(self.sourceDir(), "theme/colored/AvuzConecta-icon.png")
        self.defines["setupname"] = "AvuzConecta-4.0.9-setup.exe"
        self.defines["license"] = os.path.join(self.sourceDir(), "COPYING")
        self.defines["readme"] = os.path.join(self.sourceDir(), "README.md")

        self.applicationExecutable = "avuzconecta"

        self.ignoredPackages += ["binary/mysql"]
        if not CraftCore.compiler.isLinux:
            self.ignoredPackages += ["libs/dbus"]

        return super().createPackage()
