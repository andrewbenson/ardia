import { PRODUCT } from "../../lib/productName";

export const ONBOARDING_COPY = {
  wordmark: PRODUCT,
  system: {
    title: "Fast, secure, and packed with all your browser essentials",
    subtitle: `${PRODUCT} works best as your default browser.`,
    setDefault: `Set ${PRODUCT} as default browser`,
    alreadyDefault: `${PRODUCT} is already your default browser`,
    openByDefault: `Open links and web pages in ${PRODUCT} by default`,
    trial: `Try ${PRODUCT} as your default for seven days`,
    dock: `Add ${PRODUCT} to Dock`,
    dockSubtitle: `Quick access to ${PRODUCT} whenever you need it`,
    login: `Open ${PRODUCT} at login`,
    loginSubtitle: `Automatically open ${PRODUCT} when you sign in`,
  },
  importOpened: `Finish up in the import window, then continue here. You can import more any time from the ${PRODUCT} menu.`,
  pinnedSubtitle: `Pin important apps so they're always available when you open ${PRODUCT}.`,
} as const;
