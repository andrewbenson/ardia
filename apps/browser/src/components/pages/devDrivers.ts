import { applyResult, applySafari, importArcSpace, importBookmarks, importTabs } from "../import/apply";
import { importModule } from "../import/module";
import { openImport, openSettings, useSettingsNav } from "../settings/windows";
import { useBookmarkDialog } from "../bookmarks/actions";
import { useBookmarkEditor } from "../bookmarks/edit";
import { useMeetingAlert } from "../../live/alerts";
import { useCalendar } from "../../live/calendar";
import { useEngineOffers } from "../../lib/engines";
import { setSidebarUi } from "../sidebar/state";
import { useClearDataRequest } from "./ClearDataDialog";
import { openInternalPage } from "./urls";

export const pagesDrivers = {
  openInternalPage,
  openSettings,
  openImport,
  settingsNav: useSettingsNav,
  importModule,
  bookmarkDialog: useBookmarkDialog,
  bookmarkEditor: useBookmarkEditor,
  clearDataRequest: useClearDataRequest,
  meetingAlert: useMeetingAlert,
  calendar: useCalendar,
  engineOffers: useEngineOffers,
  setSidebarUi,
  applyResult,
  applySafari,
  importArcSpace,
  importBookmarks,
  importTabs,
};
