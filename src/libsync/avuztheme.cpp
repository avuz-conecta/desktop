/*
 * SPDX-FileCopyrightText: 2024 Avuz
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "avuztheme.h"

#include <QString>
#include <QVariant>
#ifndef TOKEN_AUTH_ONLY
#include <QPixmap>
#include <QIcon>
#endif
#include <QCoreApplication>

#include "config.h"
#include "common/utility.h"
#include "version.h"

namespace OCC {

AvuzTheme::AvuzTheme()
    : Theme()
{
}

QString AvuzTheme::wizardUrlHint() const
{
    return QStringLiteral("https://avuz.app");
}

}
