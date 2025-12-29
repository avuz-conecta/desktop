/*
 * SPDX-FileCopyrightText: 2024 Avuz
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef AVUZ_THEME_H
#define AVUZ_THEME_H

#include "theme.h"

namespace OCC {

/**
 * @brief The AvuzTheme class
 * @ingroup libsync
 */
class AvuzTheme : public Theme
{
    Q_OBJECT
public:
    AvuzTheme();

    [[nodiscard]] QString wizardUrlHint() const override;
};
}
#endif // AVUZ_THEME_H
