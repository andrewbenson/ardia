#ifndef SOLARA_CORE_AC_AUTOFILL_TRIGGER_H_
#define SOLARA_CORE_AC_AUTOFILL_TRIGGER_H_

namespace content {
class WebContents;
}

namespace solaracore {

void TrackAutofillFocus(content::WebContents* contents);
bool ShowAutofillSuggestions(content::WebContents* contents, bool passwords);

}

#endif
