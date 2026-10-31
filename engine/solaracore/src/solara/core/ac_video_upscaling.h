// Copyright 2026 Solara. Apache-2.0.

#ifndef SOLARA_CORE_AC_VIDEO_UPSCALING_H_
#define SOLARA_CORE_AC_VIDEO_UPSCALING_H_

#include <optional>

@class NSDictionary;

namespace solaracore {

void StartVideoUpscaling();

void SetVideoUpscalingEnabled(bool enabled);

void SetVideoUpscalingTestConditions(std::optional<bool> low_power,
                                     std::optional<bool> thermal_pressure);

void VideoUpscalingInputsChanged();

NSDictionary* VideoUpscalingState();

}

#endif
