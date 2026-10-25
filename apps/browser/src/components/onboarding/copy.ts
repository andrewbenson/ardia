import { PRODUCT } from "../../lib/productName";

export const ONBOARDING_COPY = {
  wordmark: PRODUCT,
  system: {
    title: `Make ${PRODUCT} your default?`,
    setDefault: `Set ${PRODUCT} as default browser`,
    alreadyDefault: `${PRODUCT} is already your default browser`,
    openByDefault: `Open links and web pages in ${PRODUCT}`,
    isDefault: `${PRODUCT} is your default browser`,
    dock: `Add ${PRODUCT} to Dock`,
    login: `Open ${PRODUCT} at login`,
  },
  littleWindow: `Little ${PRODUCT}`,
  linksInLittleWindow: `Links from other apps open in Little ${PRODUCT}`,
  sourceSubtitle: `${PRODUCT} sets itself up the way you're used to. Change anything later.`,
  launchSubtitle: `What ${PRODUCT} opens to.`,
  startsFresh: `${PRODUCT} starts fresh each launch`,
  pinnedSubtitle: `Pin the apps you use most. They stay put when you open ${PRODUCT}.`,
} as const;
