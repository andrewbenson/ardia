import { PRODUCT } from "./productName";

const FORK_ICONS: Record<string, number> = {
  Solara: require("../../assets/app-icon-solara.png"),
};

export const APP_ICON: number = FORK_ICONS[PRODUCT] ?? require("../../assets/app-icon.png");
