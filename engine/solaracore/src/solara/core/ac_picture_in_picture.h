// Copyright 2026 Solara. Apache-2.0.

#ifndef SOLARA_CORE_AC_PICTURE_IN_PICTURE_H_
#define SOLARA_CORE_AC_PICTURE_IN_PICTURE_H_

#include <string>

namespace content {
class WebContents;
}

namespace solaracore {

void StartPictureInPictureObserver();

bool PictureInPictureTracing();
void TracePictureInPicture(const std::string& line);

void TraceAutoPictureInPictureInputs(content::WebContents* contents, const char* when);

}

#endif
