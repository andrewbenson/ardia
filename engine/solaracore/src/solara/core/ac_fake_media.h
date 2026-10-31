#ifndef SOLARA_CORE_AC_FAKE_MEDIA_H_
#define SOLARA_CORE_AC_FAKE_MEDIA_H_

namespace content {
struct MediaStreamRequest;
}

namespace solaracore {

bool UsingFakeMediaDevices();

void InstallFakeMediaDevices();

void KeepAudioCaptureFake(content::MediaStreamRequest& request);

}

#endif
