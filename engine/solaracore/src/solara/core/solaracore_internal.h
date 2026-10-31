#ifndef SOLARA_CORE_SOLARACORE_INTERNAL_H_
#define SOLARA_CORE_SOLARACORE_INTERNAL_H_

#import "solara/core/public/SolaraCore.h"

class Profile;

namespace content {
class WebContents;
}

namespace solaracore {
class WindowHost;

void NoteProfileDying(Profile* profile);
bool IsProfileDying(const Profile* profile);
void NoteProfileDeleting(Profile* profile);
bool IsProfileDeleting(const Profile* profile);
}

@interface SolaraCoreProfile ()
+ (SolaraCoreProfile*)wrapperFor:(Profile*)profile;
@property(readonly) Profile* chromeProfile;
@end

@interface SolaraCoreTab ()
- (instancetype)initWithContents:(content::WebContents*)contents;
@property(readonly) content::WebContents* contents;
- (void)contentsDestroyed;
- (void)notify:(SEL)selector;
@end

@interface SolaraCoreWindow ()
@property(readonly) solaracore::WindowHost* host;
@end

#endif
