#pragma once

#import <AppKit/AppKit.h>

@class ArdiaCoreWebView;

namespace ardiacore_pip {

void WatchZoom();

void VideoEntered(ArdiaCoreWebView *view, NSString *host);

void TabRequestedActivation(ArdiaCoreWebView *view);

}
