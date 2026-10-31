// Copyright 2026 Solara. Apache-2.0.

#ifndef SOLARA_CORE_AC_HOST_VISIBILITY_H_
#define SOLARA_CORE_AC_HOST_VISIBILITY_H_

#include <optional>

namespace content {
class WebContents;
}

namespace solaracore {

void NoteTabShownByHost(content::WebContents* contents, bool shown);

std::optional<bool> ShownByHost(content::WebContents* contents);

void StartHostVisibility();

}

#endif
