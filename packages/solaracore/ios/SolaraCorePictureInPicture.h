#pragma once

#import <AppKit/AppKit.h>

@class SolaraCoreWebView;

namespace solaracore_pip {

void WatchZoom();

void VideoEntered(SolaraCoreWebView *view, NSString *host);

void TabRequestedActivation(SolaraCoreWebView *view);

}
